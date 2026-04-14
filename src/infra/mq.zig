//! Message queue for zigzero
//!
//! Provides in-memory pub/sub messaging aligned with go-zero patterns.

const std = @import("std");

/// Message
pub const Message = struct {
    topic: []const u8,
    payload: []const u8,
    timestamp: i64,

    pub fn copy(self: Message, allocator: std.mem.Allocator) !Message {
        return .{
            .topic = try allocator.dupe(u8, self.topic),
            .payload = try allocator.dupe(u8, self.payload),
            .timestamp = self.timestamp,
        };
    }

    pub fn free(self: Message, allocator: std.mem.Allocator) void {
        allocator.free(self.topic);
        allocator.free(self.payload);
    }
};

/// Message handler type
pub const Handler = *const fn (*anyopaque, Message) void;

/// Subscription
pub const Subscription = struct {
    id: u64,
    topic: []const u8,
    handler: Handler,
    context: *anyopaque,
};

/// In-memory message queue
pub const Queue = struct {
    allocator: std.mem.Allocator,
    subscriptions: std.ArrayList(Subscription),
    messages: std.ArrayList(Message),
    mutex: std.Thread.Mutex,
    next_id: std.atomic.Value(u64),
    running: std.atomic.Value(bool),
    dispatch_thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator) Queue {
        return .{
            .allocator = allocator,
            .subscriptions = .{},
            .messages = .{},
            .mutex = .{},
            .next_id = std.atomic.Value(u64).init(1),
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Queue) void {
        self.stop();

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.messages.items) |*msg| {
            msg.free(self.allocator);
        }
        self.messages.deinit(self.allocator);

        for (self.subscriptions.items) |*sub| {
            self.allocator.free(sub.topic);
        }
        self.subscriptions.deinit(self.allocator);
    }

    /// Subscribe to a topic
    pub fn subscribe(self: *Queue, topic: []const u8, handler: Handler, context: *anyopaque) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id = self.next_id.fetchAdd(1, .monotonic);
        try self.subscriptions.append(self.allocator, .{
            .id = id,
            .topic = try self.allocator.dupe(u8, topic),
            .handler = handler,
            .context = context,
        });
        return id;
    }

    /// Unsubscribe from a topic
    pub fn unsubscribe(self: *Queue, id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.subscriptions.items, 0..) |*sub, i| {
            if (sub.id == id) {
                self.allocator.free(sub.topic);
                _ = self.subscriptions.orderedRemove(i);
                return;
            }
        }
    }

    /// Publish a message to a topic
    pub fn publish(self: *Queue, topic: []const u8, payload: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const msg = Message{
            .topic = try self.allocator.dupe(u8, topic),
            .payload = try self.allocator.dupe(u8, payload),
            .timestamp = std.time.milliTimestamp(),
        };
        try self.messages.append(self.allocator, msg);
    }

    /// Start background dispatch thread
    pub fn start(self: *Queue) !void {
        if (self.running.load(.monotonic)) return;
        self.running.store(true, .monotonic);
        self.dispatch_thread = try std.Thread.spawn(.{}, dispatchLoop, .{self});
    }

    /// Stop background dispatch thread
    pub fn stop(self: *Queue) void {
        self.running.store(false, .monotonic);
        if (self.dispatch_thread) |t| {
            t.join();
            self.dispatch_thread = null;
        }
    }

    fn dispatchLoop(self: *Queue) void {
        while (self.running.load(.monotonic)) {
            self.dispatchPending();
            std.time.sleep(10 * std.time.ns_per_ms);
        }
    }

    fn dispatchPending(self: *Queue) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.messages.items.len > 0) {
            const msg = self.messages.orderedRemove(0);

            for (self.subscriptions.items) |sub| {
                if (std.mem.eql(u8, sub.topic, msg.topic) or std.mem.eql(u8, sub.topic, "*")) {
                    sub.handler(sub.context, msg);
                }
            }

            msg.free(self.allocator);
        }
    }
};

/// File-backed persistent message queue.
/// Messages are appended to a log file with a length prefix.
/// Consumer offsets are tracked per consumer group.
pub const PersistentQueue = struct {
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    queue_name: []const u8,
    log_file: ?std.fs.File = null,
    offsets: std.StringHashMap(u64),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8, queue_name: []const u8) !PersistentQueue {
        std.fs.cwd().makePath(data_dir) catch {};

        const log_path = try std.fs.path.join(allocator, &.{ data_dir, queue_name });
        defer allocator.free(log_path);

        const log_file = try std.fs.cwd().createFile(log_path, .{ .read = true, .truncate = false });

        var self = PersistentQueue{
            .allocator = allocator,
            .data_dir = try allocator.dupe(u8, data_dir),
            .queue_name = try allocator.dupe(u8, queue_name),
            .log_file = log_file,
            .offsets = std.StringHashMap(u64).init(allocator),
            .mutex = .{},
        };

        try self.loadOffsets();
        return self;
    }

    pub fn deinit(self: *PersistentQueue) void {
        self.saveOffsets() catch {};
        if (self.log_file) |f| f.close();

        var iter = self.offsets.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.offsets.deinit();

        self.allocator.free(self.data_dir);
        self.allocator.free(self.queue_name);
    }

    /// Append a message to the queue.
    pub fn enqueue(self: *PersistentQueue, payload: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const file = self.log_file.?;
        const len_bytes: [4]u8 = std.mem.toBytes(@as(u32, @intCast(payload.len)));
        try file.seekFromEnd(0);
        _ = try file.write(&len_bytes);
        _ = try file.write(payload);
        try file.sync();
    }

    /// Read up to max_messages for a consumer group starting from its offset.
    /// Returns allocated messages; caller must free each with allocator.free().
    pub fn dequeue(self: *PersistentQueue, consumer_group: []const u8, max_messages: usize) !std.ArrayList([]const u8) {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result: std.ArrayList([]const u8) = .{};
        errdefer {
            for (result.items) |item| self.allocator.free(item);
            result.deinit(self.allocator);
        }

        const gop = try self.offsets.getOrPut(consumer_group);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, consumer_group);
            gop.value_ptr.* = 0;
        }
        var offset = gop.value_ptr.*;

        const file = self.log_file.?;
        try file.seekTo(offset);

        var count: usize = 0;
        while (count < max_messages) : (count += 1) {
            var len_bytes: [4]u8 = undefined;
            const n = try file.read(&len_bytes);
            if (n < 4) break;
            const len = std.mem.bytesToValue(u32, &len_bytes);

            const payload = try self.allocator.alloc(u8, len);
            errdefer self.allocator.free(payload);
            const payload_n = try file.read(payload);
            if (payload_n < len) {
                self.allocator.free(payload);
                break;
            }

            try result.append(self.allocator, payload);
            offset = try file.getPos();
        }

        gop.value_ptr.* = offset;
        try self.saveOffset(consumer_group, offset);
        return result;
    }

    /// Acknowledge all messages up to the current offset for a consumer group.
    pub fn ack(self: *PersistentQueue, consumer_group: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.offsets.get(consumer_group)) |offset| {
            try self.saveOffset(consumer_group, offset);
        }
    }

    fn offsetFilePath(self: *PersistentQueue, group: []const u8) ![]u8 {
        const filename = try std.fmt.allocPrint(self.allocator, "{s}.{s}.offset", .{ self.queue_name, group });
        defer self.allocator.free(filename);
        return std.fs.path.join(self.allocator, &.{ self.data_dir, filename });
    }

    fn saveOffset(self: *PersistentQueue, group: []const u8, offset: u64) !void {
        const path = try self.offsetFilePath(group);
        defer self.allocator.free(path);

        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        const bytes: [8]u8 = std.mem.toBytes(offset);
        _ = try file.write(&bytes);
        try file.sync();
    }

    fn loadOffsets(self: *PersistentQueue) !void {
        var dir = std.fs.cwd().openDir(self.data_dir, .{}) catch return;
        defer dir.close();

        var iter = dir.iterate();
        const prefix = try std.fmt.allocPrint(self.allocator, "{s}.", .{self.queue_name});
        defer self.allocator.free(prefix);
        const suffix = ".offset";

        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
            if (!std.mem.endsWith(u8, entry.name, suffix)) continue;

            const group_start = prefix.len;
            const group_end = entry.name.len - suffix.len;
            const group = entry.name[group_start..group_end];

            const path = try self.offsetFilePath(group);
            defer self.allocator.free(path);

            const file = std.fs.cwd().openFile(path, .{}) catch continue;
            defer file.close();
            var bytes: [8]u8 = undefined;
            const n = try file.read(&bytes);
            if (n < 8) continue;
            const offset = std.mem.bytesToValue(u64, &bytes);

            const group_copy = try self.allocator.dupe(u8, group);
            try self.offsets.put(group_copy, offset);
        }
    }

    fn saveOffsets(self: *PersistentQueue) !void {
        var iter = self.offsets.iterator();
        while (iter.next()) |entry| {
            try self.saveOffset(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
};

test "message queue" {
    var mq = Queue.init(std.testing.allocator);
    defer mq.deinit();

    var received: bool = false;
    const handler = struct {
        fn handle(ctx: *anyopaque, msg: Message) void {
            _ = msg;
            const r = @as(*bool, @ptrCast(@alignCast(ctx)));
            r.* = true;
        }
    }.handle;

    const id = try mq.subscribe("test-topic", handler, &received);
    try mq.publish("test-topic", "hello");
    mq.dispatchPending();
    try std.testing.expect(received);

    mq.unsubscribe(id);
}

test "persistent queue" {
    const allocator = std.testing.allocator;
    const data_dir = ".test-mq-data";
    std.fs.cwd().deleteTree(data_dir) catch {};
    defer std.fs.cwd().deleteTree(data_dir) catch {};

    var pq = try PersistentQueue.init(allocator, data_dir, "test-queue");
    defer pq.deinit();

    try pq.enqueue("message-one");
    try pq.enqueue("message-two");

    var msgs = try pq.dequeue("group-a", 10);
    defer {
        for (msgs.items) |m| allocator.free(m);
        msgs.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), msgs.items.len);
    try std.testing.expectEqualStrings("message-one", msgs.items[0]);
    try std.testing.expectEqualStrings("message-two", msgs.items[1]);

    // Second dequeue should return nothing (offset advanced)
    var empty = try pq.dequeue("group-a", 10);
    defer {
        for (empty.items) |m| allocator.free(m);
        empty.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);

    // New consumer group should see all messages
    var msgs2 = try pq.dequeue("group-b", 10);
    defer {
        for (msgs2.items) |m| allocator.free(m);
        msgs2.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 2), msgs2.items.len);
}
