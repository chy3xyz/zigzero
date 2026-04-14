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
