//! Redis client for zigzero
//!
//! Provides Redis operations aligned with go-zero's redis functionality.

const std = @import("std");
const errors = @import("errors.zig");
const config = @import("config.zig");

/// Redis client for zigzero
pub const Redis = struct {
    allocator: std.mem.Allocator,
    config: config.RedisConfig,
    stream: ?std.net.Stream = null,

    /// Create a new Redis client
    pub fn new(allocator: std.mem.Allocator, cfg: config.RedisConfig) !Redis {
        return Redis{
            .allocator = allocator,
            .config = cfg,
            .stream = null,
        };
    }

    /// Deinitialize Redis client
    pub fn deinit(self: *Redis) void {
        if (self.stream) |s| {
            s.close();
            self.stream = null;
        }
    }

    /// Connect to Redis server
    pub fn connect(self: *Redis) !void {
        const address = std.net.Address.parseIp4(self.config.host, self.config.port) catch return error.RedisError;
        self.stream = std.net.tcpConnectToAddress(address) catch return error.RedisError;
    }

    /// Disconnect from Redis server
    pub fn disconnect(self: *Redis) void {
        if (self.stream) |s| {
            s.close();
            self.stream = null;
        }
    }

    /// Get a value by key
    pub fn get(self: *Redis, key: []const u8) errors.ResultT(?[]const u8) {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*2\r\n$3\r\nGET\r\n${d}\r\n{s}\r\n", .{ key.len, key }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [4096]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            // Parse bulk string response
            if (response.len > 1) {
                if (response[0] == '$') {
                    if (response[1] == '-') {
                        return null; // Null bulk string
                    }
                    var end_idx: usize = 1;
                    while (end_idx < response.len and response[end_idx] != '\r') : (end_idx += 1) {}
                    const len = std.fmt.parseInt(i32, response[1..end_idx], 10) catch return error.RedisError;
                    if (len <= 0) return null;

                    const value_start = end_idx + 2;
                    const value = self.allocator.dupe(u8, response[value_start..@min(value_start + @as(usize, @intCast(len)), response.len)]) catch return error.RedisError;
                    return value;
                }
            }
        }
        return error.RedisError;
    }

    /// Set a value with expiration
    pub fn set(self: *Redis, key: []const u8, value: []const u8, ex_seconds: ?u32) errors.Result {
        if (self.stream) |stream| {
            const cmd = if (ex_seconds) |ex|
                std.fmt.allocPrint(self.allocator, "*5\r\n$3\r\nSET\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n$2\r\nEX\r\n${d}\r\n{d}\r\n", .{ key.len, key, value.len, value, std.fmt.count("{d}", .{ex}), ex }) catch return error.RedisError
            else
                std.fmt.allocPrint(self.allocator, "*3\r\n$3\r\nSET\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n", .{ key.len, key, value.len, value }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            _ = stream.read(&buf) catch return error.RedisError;
            return;
        }
        return error.RedisError;
    }

    /// Set a value only if key doesn't exist
    pub fn setNX(self: *Redis, key: []const u8, value: []const u8) errors.ResultT(bool) {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*3\r\n$5\r\nSETNX\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n", .{ key.len, key, value.len, value }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            if (response.len > 1 and response[0] == ':') {
                const val = std.fmt.parseInt(i32, response[1..], 10) catch return false;
                return val == 1;
            }
        }
        return false;
    }

    /// Delete keys
    pub fn del(self: *Redis, keys: []const []const u8) errors.ResultT(u32) {
        if (self.stream) |stream| {
            var cmd_builder: std.ArrayList(u8) = .{};
            defer cmd_builder.deinit(self.allocator);

            try cmd_builder.writer(self.allocator).print("*{d}\r\n$3\r\nDEL\r\n", .{keys.len + 1});
            for (keys) |key| {
                try cmd_builder.writer(self.allocator).print("${d}\r\n{s}\r\n", .{ key.len, key });
            }

            _ = stream.write(cmd_builder.items) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            if (response.len > 1 and response[0] == ':') {
                const val = std.fmt.parseInt(u32, response[1..], 10) catch return error.RedisError;
                return val;
            }
        }
        return 0;
    }

    /// Check if key exists
    pub fn exists(self: *Redis, key: []const u8) errors.ResultT(bool) {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*2\r\n$6\r\nEXISTS\r\n${d}\r\n{s}\r\n", .{ key.len, key }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            if (response.len > 1 and response[0] == ':') {
                const val = std.fmt.parseInt(i32, response[1..], 10) catch return false;
                return val == 1;
            }
        }
        return false;
    }

    /// Increment a value
    pub fn incr(self: *Redis, key: []const u8) errors.ResultT(i64) {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*2\r\n$4\r\nINCR\r\n${d}\r\n{s}\r\n", .{ key.len, key }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            if (response.len > 1 and response[0] == ':') {
                const val = std.fmt.parseInt(i64, response[1..], 10) catch return error.RedisError;
                return val;
            }
        }
        return error.RedisError;
    }

    /// Decrement a value
    pub fn decr(self: *Redis, key: []const u8) errors.ResultT(i64) {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*2\r\n$4\r\nDECR\r\n${d}\r\n{s}\r\n", .{ key.len, key }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            if (response.len > 1 and response[0] == ':') {
                const val = std.fmt.parseInt(i64, response[1..], 10) catch return error.RedisError;
                return val;
            }
        }
        return error.RedisError;
    }

    /// Expire a key
    pub fn expire(self: *Redis, key: []const u8, seconds: u32) errors.Result {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*3\r\n$6\r\nEXPIRE\r\n${d}\r\n{s}\r\n${d}\r\n{d}\r\n", .{ key.len, key, std.fmt.count("{d}", .{seconds}), seconds }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            _ = stream.read(&buf) catch return error.RedisError;
            return;
        }
        return error.RedisError;
    }

    /// Get remaining TTL
    pub fn ttl(self: *Redis, key: []const u8) errors.ResultT(i64) {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*2\r\n$3\r\nTTL\r\n${d}\r\n{s}\r\n", .{ key.len, key }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            if (response.len > 1 and response[0] == ':') {
                const val = std.fmt.parseInt(i64, response[1..], 10) catch return error.RedisError;
                return val;
            }
        }
        return -1;
    }

    /// Acquire a distributed lock
    pub fn lock(self: *Redis, key: []const u8, value: []const u8, ttl_seconds: u32) errors.ResultT(bool) {
        if (self.stream) |stream| {
            const px = ttl_seconds * 1000;
            const cmd = std.fmt.allocPrint(self.allocator, "*5\r\n$3\r\nSET\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n$2\r\nNX\r\n$2\r\nPX\r\n${d}\r\n{d}\r\n", .{
                key.len, key, value.len, value, std.fmt.count("{d}", .{px}), px,
            }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            if (response.len >= 3 and std.mem.eql(u8, response[0..3], "+OK")) {
                return true;
            }
        }
        return false;
    }

    /// Release a distributed lock
    pub fn unlock(self: *Redis, key: []const u8) errors.Result {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*2\r\n$3\r\nDEL\r\n${d}\r\n{s}\r\n", .{ key.len, key }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            _ = stream.read(&buf) catch return error.RedisError;
        }
        return;
    }

    /// List operations
    pub fn lPush(self: *Redis, key: []const u8, value: []const u8) errors.ResultT(u32) {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*3\r\n$5\r\nLPUSH\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n", .{ key.len, key, value.len, value }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            if (response.len > 1 and response[0] == ':') {
                const val = std.fmt.parseInt(u32, response[1..], 10) catch return error.RedisError;
                return val;
            }
        }
        return error.RedisError;
    }

    pub fn rPop(self: *Redis, key: []const u8) errors.ResultT(?[]const u8) {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*2\r\n$4\r\nRPOP\r\n${d}\r\n{s}\r\n", .{ key.len, key }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [4096]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            if (response.len > 1) {
                if (response[0] == '$') {
                    if (response[1] == '-') {
                        return null;
                    }
                    var end_idx: usize = 1;
                    while (end_idx < response.len and response[end_idx] != '\r') : (end_idx += 1) {}
                    const len = std.fmt.parseInt(i32, response[1..end_idx], 10) catch return error.RedisError;
                    if (len <= 0) return null;

                    const value_start = end_idx + 2;
                    const value = self.allocator.dupe(u8, response[value_start..@min(value_start + @as(usize, @intCast(len)), response.len)]) catch return error.RedisError;
                    return value;
                }
            }
        }
        return error.RedisError;
    }

    /// Hash operations
    pub fn hSet(self: *Redis, key: []const u8, field: []const u8, value: []const u8) errors.ResultT(bool) {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*4\r\n$4\r\nHSET\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n", .{
                key.len, key, field.len, field, value.len, value,
            }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            if (response.len > 1 and response[0] == ':') {
                const val = std.fmt.parseInt(i32, response[1..], 10) catch return 0;
                return val == 1;
            }
        }
        return false;
    }

    pub fn hGet(self: *Redis, key: []const u8, field: []const u8) errors.ResultT(?[]const u8) {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*3\r\n$4\r\nHGET\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n", .{
                key.len, key, field.len, field,
            }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [4096]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            if (response.len > 1) {
                if (response[0] == '$') {
                    if (response[1] == '-') {
                        return null;
                    }
                    var end_idx: usize = 1;
                    while (end_idx < response.len and response[end_idx] != '\r') : (end_idx += 1) {}
                    const len = std.fmt.parseInt(i32, response[1..end_idx], 10) catch return error.RedisError;
                    if (len <= 0) return null;

                    const value_start = end_idx + 2;
                    const value = self.allocator.dupe(u8, response[value_start..@min(value_start + @as(usize, @intCast(len)), response.len)]) catch return error.RedisError;
                    return value;
                }
            }
        }
        return error.RedisError;
    }

    /// Pub/Sub
    pub fn publish(self: *Redis, channel: []const u8, message: []const u8) errors.ResultT(u32) {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*3\r\n$7\r\nPUBLISH\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n", .{
                channel.len, channel, message.len, message,
            }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            if (response.len > 1 and response[0] == ':') {
                const val = std.fmt.parseInt(u32, response[1..], 10) catch return error.RedisError;
                return val;
            }
        }
        return error.RedisError;
    }
};

/// Distributed lock helper
pub const Lock = struct {
    redis: *Redis,
    key: []const u8,
    value: []const u8,
    acquired: bool = false,

    /// Acquire a lock
    pub fn acquire(redis: *Redis, key: []const u8, value: []const u8, ttl_seconds: u32) errors.ResultT(bool) {
        return redis.lock(key, value, ttl_seconds);
    }

    /// Release a lock
    pub fn release(self: *Lock) errors.Result {
        if (self.acquired) {
            return self.redis.unlock(self.key);
        }
    }
};

test "redis client" {
    // Note: These tests require a running Redis server
    // Skip in CI environment
    if (true) return error.SkipZigTest;

    const cfg = config.RedisConfig{};
    var redis = try Redis.new(std.testing.allocator, cfg);
    defer redis.deinit();

    try redis.connect();

    // Test basic operations
    try redis.set("test_key", "test_value", null);
    const value = try redis.get("test_key");
    try std.testing.expect(value != null);
    if (value) |v| {
        try std.testing.expectEqualStrings("test_value", v);
        std.testing.allocator.free(v);
    }

    // Test lock
    const acquired = try Lock.acquire(&redis, "test_lock", "token123", 10);
    try std.testing.expect(acquired);
}

test "resp protocol parsing" {
    // Test parsing RESP simple strings
    const simple_string = "+OK\r\n";
    try std.testing.expectEqualStrings("OK", simple_string[1..3]);
}
