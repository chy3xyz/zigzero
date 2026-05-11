//! Distributed lock for zigzero
//!
//! Provides distributed locking patterns aligned with go-zero.

const std = @import("std");
const compat = @import("../compat.zig");
const errors = @import("../core/errors.zig");
const redis = @import("redis.zig");

/// Distributed lock interface
pub const Lock = struct {
    /// Acquire the lock
    pub const AcquireFn = *const fn (*anyopaque, []const u8, []const u8, u32) errors.ResultT(bool);
    /// Release the lock
    pub const ReleaseFn = *const fn (*anyopaque, []const u8, []const u8) errors.Result;
    /// Renew the lock
    pub const RenewFn = *const fn (*anyopaque, []const u8, []const u8, u32) errors.ResultT(bool);
};

/// Redis-based distributed lock
pub const RedisLock = struct {
    client: *redis.Redis,

    pub fn init(client: *redis.Redis) RedisLock {
        return .{ .client = client };
    }

    /// Acquire lock
    pub fn acquire(self: *RedisLock, key: []const u8, value: []const u8, ttl_seconds: u32) errors.ResultT(bool) {
        return self.client.lock(key, value, ttl_seconds);
    }

    /// Release lock (only if value matches)
    pub fn release(self: *RedisLock, key: []const u8, value: []const u8) errors.Result {
        // Use Lua script for atomic release: if value matches, delete key
        const script_fmt = "*4\r\n$6\r\nEVAL\r\n$45\r\nif redis.call('get',KEYS[1])==ARGV[1] then return redis.call('del',KEYS[1]) else return 0 end\r\n$1\r\n1\r\n";
        if (self.client.stream) |stream| {
            var cmd_builder: std.ArrayList(u8) = .empty;
            defer cmd_builder.deinit(self.client.allocator);
            cmd_builder.appendSlice(self.client.allocator, script_fmt) catch return error.RedisError;
            cmd_builder.print(self.client.allocator, "${d}\r\n{s}\r\n", .{ key.len, key }) catch return error.RedisError;
            cmd_builder.print(self.client.allocator, "${d}\r\n{s}\r\n", .{ value.len, value }) catch return error.RedisError;
            compat.net.streamWrite(stream, cmd_builder.items) catch return error.RedisError;
            var buf: [256]u8 = undefined;
            _ = compat.net.streamRead(stream, &buf) catch return error.RedisError;
        }
        return;
    }

    /// Renew lock TTL
    pub fn renew(self: *RedisLock, key: []const u8, value: []const u8, ttl_seconds: u32) errors.ResultT(bool) {
        _ = value;
        if (self.client.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.client.allocator, "*3\\r\\n$6\\r\\nEXPIRE\\r\\n${d}\\r\\n{s}\\r\\n${d}\\r\\n{d}\\r\\n", .{ key.len, key, std.fmt.count("{d}", .{ttl_seconds}), ttl_seconds }) catch return error.RedisError;
            defer self.client.allocator.free(cmd);
            compat.net.streamWrite(stream, cmd) catch return error.RedisError;
            var buf: [256]u8 = undefined;
            const n = compat.net.streamRead(stream, &buf) catch return error.RedisError;
            if (n > 1 and buf[0] == ':') {
                const val = std.fmt.parseInt(i32, buf[1..n], 10) catch return error.RedisError;
                return val == 1;
            }
        }
        return false;
    }
};

/// In-process lock for single-node use
pub const LocalLock = struct {
    mutex: compat.Mutex,
    locked: std.atomic.Value(bool),
    owner: ?[]const u8,

    pub fn init() LocalLock {
        return .{
            .mutex = .init,
            .locked = std.atomic.Value(bool).init(false),
            .owner = null,
        };
    }

    pub fn acquire(self: *LocalLock, key: []const u8, value: []const u8, ttl_seconds: u32) errors.ResultT(bool) {
        _ = ttl_seconds;
        self.mutex.lock();
        if (self.locked.load(.monotonic)) {
            self.mutex.unlock();
            return false;
        }
        self.locked.store(true, .monotonic);
        self.owner = key;
        _ = value;
        self.mutex.unlock();
        return true;
    }

    pub fn release(self: *LocalLock, key: []const u8, value: []const u8) errors.Result {
        _ = value;
        self.mutex.lock();
        if (self.owner != null and std.mem.eql(u8, self.owner.?, key)) {
            self.locked.store(false, .monotonic);
            self.owner = null;
        }
        self.mutex.unlock();
    }
};

test "local lock" {
    var lock = LocalLock.init();

    const acquired = try lock.acquire("my_key", "owner1", 10);
    try std.testing.expect(acquired);

    const acquired2 = try lock.acquire("my_key", "owner2", 10);
    try std.testing.expect(!acquired2);

    try lock.release("my_key", "owner1");
}
