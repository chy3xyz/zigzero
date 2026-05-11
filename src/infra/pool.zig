//! Generic connection pool for zigzero
//!
//! Provides a reusable connection pool pattern aligned with go-zero.

const std = @import("std");
const compat = @import("../compat.zig");
const errors = @import("../core/errors.zig");

/// Connection factory interface
pub const Factory = struct {
    create: *const fn (*anyopaque, std.mem.Allocator) errors.ResultT(*anyopaque),
    destroy: *const fn (*anyopaque, *anyopaque) void,
    validate: *const fn (*anyopaque, *anyopaque) bool,
    context: *anyopaque,
};

/// Generic connection pool
pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();
        const Node = struct {
            conn: *T,
            last_used: i64,
        };

        allocator: std.mem.Allocator,
        createFn: *const fn () errors.ResultT(*T),
        destroyFn: *const fn (*T) void,
        validateFn: *const fn (*T) bool,
        min_idle: u32,
        max_active: u32,
        active_count: std.atomic.Value(u32),
        idle_conns: std.ArrayList(Node),
        mutex: compat.Mutex,
        cond: compat.Condition,
        max_wait_ms: u32 = 5000,
        closed: std.atomic.Value(bool),

        pub fn init(
            allocator: std.mem.Allocator,
            createFn: *const fn () errors.ResultT(*T),
            destroyFn: *const fn (*T) void,
            validateFn: *const fn (*T) bool,
            config: Config,
        ) !Self {
            var pool = Self{
                .allocator = allocator,
                .createFn = createFn,
                .destroyFn = destroyFn,
                .validateFn = validateFn,
                .min_idle = config.min_idle,
                .max_active = config.max_active,
                .active_count = std.atomic.Value(u32).init(0),
                .idle_conns = .empty,
                .mutex = .init,
                .cond = .init,
                .max_wait_ms = config.max_wait_ms,
                .closed = std.atomic.Value(bool).init(false),
            };

            // Pre-create min idle connections
            var i: u32 = 0;
            while (i < config.min_idle) : (i += 1) {
                const conn = createFn() catch continue;
                try pool.idle_conns.append(allocator, .{
                    .conn = conn,
                    .last_used = compat.milliTimestamp(),
                });
                _ = pool.active_count.fetchAdd(1, .monotonic);
            }

            return pool;
        }

        pub fn deinit(self: *Self) void {
            self.closed.store(true, .monotonic);
            self.cond.broadcast();

            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.idle_conns.items) |node| {
                self.destroyFn(node.conn);
            }
            self.idle_conns.deinit(self.allocator);
        }

        /// Get a connection from the pool
        pub fn acquire(self: *Self) !*T {
            if (self.closed.load(.monotonic)) return error.ServerError;

            self.mutex.lock();

            // Try to get an idle connection
            while (self.idle_conns.items.len > 0) {
                const node = self.idle_conns.pop();
                if (node) |n| {
                    if (self.validateFn(n.conn)) {
                        self.mutex.unlock();
                        return n.conn;
                    }
                    self.destroyFn(n.conn);
                    _ = self.active_count.fetchSub(1, .monotonic);
                }
            }

            // Check if we can create a new connection
            const current_active = self.active_count.load(.monotonic);
            if (current_active < self.max_active) {
                self.mutex.unlock();
                const conn = try self.createFn();
                _ = self.active_count.fetchAdd(1, .monotonic);
                return conn;
            }

            // Wait for a connection to be released
            const wait_until = compat.milliTimestamp() + @as(i64, @intCast(self.max_wait_ms));
            while (self.idle_conns.items.len == 0 and compat.milliTimestamp() < wait_until) {
                self.cond.timedWait(&self.mutex, @intCast(wait_until - compat.milliTimestamp())) catch break;
            }

            if (self.idle_conns.items.len > 0) {
                const node = self.idle_conns.pop();
                self.mutex.unlock();
                if (node) |n| return n.conn;
            }

            self.mutex.unlock();
            return error.Timeout;
        }

        /// Return a connection to the pool
        pub fn release(self: *Self, conn: *T) void {
            if (self.closed.load(.monotonic)) {
                self.destroyFn(conn);
                _ = self.active_count.fetchSub(1, .monotonic);
                return;
            }

            self.mutex.lock();
            self.idle_conns.append(self.allocator, .{
                .conn = conn,
                .last_used = compat.milliTimestamp(),
            }) catch {
                self.mutex.unlock();
                self.destroyFn(conn);
                _ = self.active_count.fetchSub(1, .monotonic);
                return;
            };
            self.mutex.unlock();
            self.cond.signal();
        }

        /// Current active connection count
        pub fn active(self: *Self) u32 {
            return self.active_count.load(.monotonic);
        }

        /// Current idle connection count
        pub fn idle(self: *Self) usize {
            self.mutex.lock();
            const count = self.idle_conns.items.len;
            self.mutex.unlock();
            return count;
        }
    };
}

pub const Config = struct {
    min_idle: u32 = 2,
    max_active: u32 = 20,
    max_wait_ms: u32 = 5000,
    max_idle_time_ms: u32 = 300000, // 5 minutes
};

test "connection pool" {
    const CreateCtx = struct {
        var count: *u32 = undefined;
    };
    const DestroyCtx = struct {
        var count: *u32 = undefined;
    };

    var create_count: u32 = 0;
    var destroy_count: u32 = 0;
    CreateCtx.count = &create_count;
    DestroyCtx.count = &destroy_count;

    const createFn = struct {
        fn create() errors.ResultT(*u32) {
            CreateCtx.count.* += 1;
            const ptr = std.testing.allocator.create(u32) catch return error.ServerError;
            ptr.* = 42;
            return ptr;
        }
    }.create;

    const destroyFn = struct {
        fn destroy(ptr: *u32) void {
            DestroyCtx.count.* += 1;
            std.testing.allocator.destroy(ptr);
        }
    }.destroy;

    const validateFn = struct {
        fn validate(ptr: *u32) bool {
            _ = ptr;
            return true;
        }
    }.validate;

    var pool = try Pool(u32).init(
        std.testing.allocator,
        createFn,
        destroyFn,
        validateFn,
        .{ .min_idle = 2, .max_active = 5 },
    );
    defer pool.deinit();

    try std.testing.expect(pool.idle() >= 2);

    const conn = try pool.acquire();
    try std.testing.expectEqual(@as(u32, 42), conn.*);
    pool.release(conn);

    try std.testing.expect(create_count >= 2);
}


test "connection pool max active and timeout" {
    const CreateCtx = struct {
        var count: *u32 = undefined;
    };
    const DestroyCtx = struct {
        var count: *u32 = undefined;
    };

    var create_count: u32 = 0;
    var destroy_count: u32 = 0;
    CreateCtx.count = &create_count;
    DestroyCtx.count = &destroy_count;

    const createFn = struct {
        fn create() errors.ResultT(*u32) {
            CreateCtx.count.* += 1;
            const ptr = std.testing.allocator.create(u32) catch return error.ServerError;
            ptr.* = 42;
            return ptr;
        }
    }.create;

    const destroyFn = struct {
        fn destroy(ptr: *u32) void {
            DestroyCtx.count.* += 1;
            std.testing.allocator.destroy(ptr);
        }
    }.destroy;

    const validateFn = struct {
        fn validate(ptr: *u32) bool {
            _ = ptr;
            return true;
        }
    }.validate;

    var pool = try Pool(u32).init(
        std.testing.allocator,
        createFn,
        destroyFn,
        validateFn,
        .{ .min_idle = 1, .max_active = 2, .max_wait_ms = 50 },
    );
    defer pool.deinit();

    // Exhaust pool
    const c1 = try pool.acquire();
    const c2 = try pool.acquire();
    try std.testing.expectEqual(@as(u32, 2), pool.active());

    // Third acquire should timeout quickly
    const c3 = pool.acquire();
    try std.testing.expectError(error.Timeout, c3);

    pool.release(c1);
    pool.release(c2);
}

test "connection pool validation rejects bad connections" {
    const ValidateCtx = struct {
        var count: u32 = 0;
    };
    ValidateCtx.count = 0;

    const createFn = struct {
        fn create() errors.ResultT(*u32) {
            const ptr = std.testing.allocator.create(u32) catch return error.ServerError;
            ptr.* = 42;
            return ptr;
        }
    }.create;

    const destroyFn = struct {
        fn destroy(ptr: *u32) void {
            std.testing.allocator.destroy(ptr);
        }
    }.destroy;

    const validateFn = struct {
        fn validate(ptr: *u32) bool {
            _ = ptr;
            ValidateCtx.count += 1;
            return ValidateCtx.count <= 1; // Reject after first validation
        }
    }.validate;

    var pool = try Pool(u32).init(
        std.testing.allocator,
        createFn,
        destroyFn,
        validateFn,
        .{ .min_idle = 1, .max_active = 2 },
    );
    defer pool.deinit();

    const c1 = try pool.acquire();
    pool.release(c1);

    // On next acquire, validation should fail and connection be destroyed + recreated
    const c2 = try pool.acquire();
    try std.testing.expectEqual(@as(u32, 42), c2.*);
    pool.release(c2);
}
