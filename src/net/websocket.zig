//! WebSocket support for zigzero
//!
//! Provides WebSocket server capabilities (RFC 6455).

const std = @import("std");
const compat = @import("../compat.zig");
const errors = @import("../core/errors.zig");
const api = @import("api.zig");

/// WebSocket opcode
pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};

/// WebSocket frame
pub const Frame = struct {
    fin: bool,
    opcode: Opcode,
    payload: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Frame) void {
        self.allocator.free(self.payload);
    }
};

/// WebSocket connection
pub const Conn = struct {
    stream: compat.net.Stream,
    allocator: std.mem.Allocator,
    closed: std.atomic.Value(bool),

    pub fn init(stream: compat.net.Stream, allocator: std.mem.Allocator) Conn {
        return .{
            .stream = stream,
            .allocator = allocator,
            .closed = std.atomic.Value(bool).init(false),
        };
    }

    /// Read a WebSocket frame
    pub fn readFrame(self: *Conn) !Frame {
        var header: [2]u8 = undefined;
        _ = try compat.net.streamReadAll(self.stream, &header);

        const fin = (header[0] & 0x80) != 0;
        const opcode: Opcode = @enumFromInt(header[0] & 0x0F);
        const masked = (header[1] & 0x80) != 0;
        var payload_len: u64 = @as(u64, header[1] & 0x7F);

        if (payload_len == 126) {
            var len_bytes: [2]u8 = undefined;
            _ = try compat.net.streamReadAll(self.stream, &len_bytes);
            payload_len = @as(u64, std.mem.readInt(u16, &len_bytes, .big));
        } else if (payload_len == 127) {
            var len_bytes: [8]u8 = undefined;
            _ = try compat.net.streamReadAll(self.stream, &len_bytes);
            payload_len = std.mem.readInt(u64, &len_bytes, .big);
        }

        var mask_key: [4]u8 = undefined;
        if (masked) {
            _ = try compat.net.streamReadAll(self.stream, &mask_key);
        }

        const payload = try self.allocator.alloc(u8, payload_len);
        errdefer self.allocator.free(payload);
        _ = try compat.net.streamReadAll(self.stream, payload);

        if (masked) {
            for (payload, 0..) |*byte, i| {
                byte.* ^= mask_key[i % 4];
            }
        }

        return Frame{
            .fin = fin,
            .opcode = opcode,
            .payload = payload,
            .allocator = self.allocator,
        };
    }

    /// Write a text frame
    pub fn writeText(self: *Conn, text: []const u8) !void {
        return self.writeFrame(.text, text);
    }

    /// Write a binary frame
    pub fn writeBinary(self: *Conn, data: []const u8) !void {
        return self.writeFrame(.binary, data);
    }

    /// Write a pong frame
    pub fn writePong(self: *Conn, data: []const u8) !void {
        return self.writeFrame(.pong, data);
    }

    /// Write a close frame
    pub fn writeClose(self: *Conn, code: u16, reason: []const u8) !void {
        var payload: [128]u8 = undefined;
        std.mem.writeInt(u16, payload[0..2], code, .big);
        @memcpy(payload[2..][0..reason.len], reason);
        return self.writeFrame(.close, payload[0 .. 2 + reason.len]);
    }

    fn writeFrame(self: *Conn, opcode: Opcode, payload: []const u8) !void {
        if (self.closed.load(.monotonic)) return error.NetworkError;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        const first_byte: u8 = 0x80 | @as(u8, @intFromEnum(opcode));
        try buf.append(self.allocator, first_byte);

        if (payload.len < 126) {
            try buf.append(self.allocator, @as(u8, @intCast(payload.len)));
        } else if (payload.len < 65536) {
            try buf.append(self.allocator, 126);
            var len_bytes: [2]u8 = undefined;
            std.mem.writeInt(u16, &len_bytes, @as(u16, @intCast(payload.len)), .big);
            try buf.appendSlice(self.allocator, &len_bytes);
        } else {
            try buf.append(self.allocator, 127);
            var len_bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &len_bytes, payload.len, .big);
            try buf.appendSlice(self.allocator, &len_bytes);
        }

        try buf.appendSlice(self.allocator, payload);
        try compat.net.streamWrite(self.stream, buf.items);
    }

    /// Close the connection
    pub fn close(self: *Conn) void {
        if (!self.closed.load(.monotonic)) {
            self.writeClose(1000, "normal") catch {};
            self.closed.store(true, .monotonic);
            compat.net.streamClose(self.stream);
        }
    }
};

/// Compute WebSocket accept key from Sec-WebSocket-Key
pub fn computeAcceptKey(allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
    const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    const concat = try std.fmt.allocPrint(allocator, "{s}{s}", .{ key, magic });
    defer allocator.free(concat);

    var hash: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(concat, &hash, .{});

    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(hash.len));
    _ = std.base64.standard.Encoder.encode(encoded, &hash);
    return encoded;
}

/// Upgrade an HTTP connection to WebSocket
pub fn upgrade(ctx: *api.Context, conn: compat.net.Stream, allocator: std.mem.Allocator) !Conn {
    const key = ctx.header("Sec-WebSocket-Key") orelse return error.ValidationError;
    const accept_key = try computeAcceptKey(allocator, key);
    defer allocator.free(accept_key);

    const response = try std.fmt.allocPrint(
        allocator,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n" ++
            "\r\n",
        .{accept_key},
    );
    defer allocator.free(response);

    try compat.net.streamWrite(conn, response);
    return Conn.init(conn, allocator);
}

/// WebSocket room for managing a group of connections
pub const Room = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    conns: std.AutoHashMap(*Conn, void),
    mutex: compat.Mutex,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !Room {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .conns = std.AutoHashMap(*Conn, void).init(allocator),
            .mutex = .init,
        };
    }

    pub fn deinit(self: *Room) void {
        self.allocator.free(self.name);
        self.conns.deinit();
    }

    /// Add a connection to the room
    pub fn join(self: *Room, conn: *Conn) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.conns.put(conn, {});
    }

    /// Remove a connection from the room
    pub fn leave(self: *Room, conn: *Conn) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.conns.remove(conn);
    }

    /// Broadcast a text message to all connections in the room
    pub fn broadcast(self: *Room, data: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var iter = self.conns.keyIterator();
        while (iter.next()) |conn_ptr| {
            const conn = conn_ptr.*;
            if (!conn.closed.load(.monotonic)) {
                conn.writeText(data) catch {};
            }
        }
    }

    /// Number of connections in the room
    pub fn size(self: *Room) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.conns.count();
    }
};

/// WebSocket hub for managing multiple rooms
pub const Hub = struct {
    allocator: std.mem.Allocator,
    rooms: std.StringHashMap(*Room),
    mutex: compat.Mutex,

    pub fn init(allocator: std.mem.Allocator) Hub {
        return .{
            .allocator = allocator,
            .rooms = std.StringHashMap(*Room).init(allocator),
            .mutex = .init,
        };
    }

    pub fn deinit(self: *Hub) void {
        self.mutex.lock();
        var iter = self.rooms.valueIterator();
        while (iter.next()) |room_ptr| {
            room_ptr.*.deinit();
            self.allocator.destroy(room_ptr.*);
        }
        self.rooms.deinit();
    }

    /// Get an existing room or create a new one
    pub fn room(self: *Hub, name: []const u8) !*Room {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.rooms.get(name)) |r| return r;

        const r = try self.allocator.create(Room);
        r.* = try Room.init(self.allocator, name);
        try self.rooms.put(r.name, r);
        return r;
    }

    /// Remove a room and all its connections
    pub fn removeRoom(self: *Hub, name: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.rooms.fetchRemove(name)) |kv| {
            kv.value.deinit();
            self.allocator.destroy(kv.value);
        }
    }

    /// Broadcast a text message to all rooms
    pub fn broadcastAll(self: *Hub, data: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var iter = self.rooms.valueIterator();
        while (iter.next()) |room_ptr| {
            room_ptr.*.broadcast(data);
        }
    }
};

test "websocket accept key" {
    const allocator = std.testing.allocator;
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    const accept = try computeAcceptKey(allocator, key);
    defer allocator.free(accept);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}

test "websocket room" {
    const allocator = std.testing.allocator;
    var room = try Room.init(allocator, "test-room");
    defer room.deinit();

    // Create a dummy connection (won't actually write)
    var conn = Conn{
        .stream = undefined,
        .allocator = allocator,
        .closed = std.atomic.Value(bool).init(false),
    };

    try room.join(&conn);
    try std.testing.expectEqual(@as(usize, 1), room.size());

    room.leave(&conn);
    try std.testing.expectEqual(@as(usize, 0), room.size());
}

test "websocket hub" {
    const allocator = std.testing.allocator;
    var hub = Hub.init(allocator);
    defer hub.deinit();

    const r = try hub.room("room1");
    try std.testing.expectEqualStrings("room1", r.name);

    const r2 = try hub.room("room1");
    try std.testing.expectEqual(r, r2);

    hub.removeRoom("room1");
}
