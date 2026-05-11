//! Rate limiter implementation for zigzero
//!
//! Provides token bucket and sliding window rate limiting aligned with go-zero's limit.

const std = @import("std");
const compat = @import("../compat.zig");
const errors = @import("../core/errors.zig");

/// Rate limiter type
pub const Type = enum {
    token_bucket, // Token bucket algorithm
    sliding_window, // Sliding window algorithm
    leaky_bucket, // Leaky bucket algorithm
};

/// Rate limiter configuration
pub const Config = struct {
    /// Maximum number of requests allowed per second
    rate: f64,
    /// Burst capacity (maximum tokens/requests that can be accumulated)
    burst: u32,
    /// Type of rate limiter
    type: Type = .token_bucket,
};

/// Token bucket rate limiter
pub const TokenBucket = struct {
    rate: f64, // Tokens per second
    burst: u32, // Maximum tokens
    tokens: f64, // Current tokens
    last_update: i128, // Last update timestamp in nanoseconds

    /// Create a new token bucket
    pub fn new(rate: f64, burst: u32) TokenBucket {
        return TokenBucket{
            .rate = rate,
            .burst = burst,
            .tokens = @as(f64, @floatFromInt(burst)),
            .last_update = compat.nanoTimestamp(),
        };
    }

    /// Try to acquire a token
    pub fn allow(self: *TokenBucket) bool {
        return self.allowN(1);
    }

    /// Try to acquire n tokens
    pub fn allowN(self: *TokenBucket, n: u32) bool {
        self.replenish();

        if (self.tokens >= @as(f64, @floatFromInt(n))) {
            self.tokens -= @as(f64, @floatFromInt(n));
            return true;
        }
        return false;
    }

    /// Replenish tokens based on elapsed time
    fn replenish(self: *TokenBucket) void {
        const now = compat.nanoTimestamp();
        const elapsed = @as(f64, @floatFromInt(now - self.last_update)) / 1_000_000_000.0;

        self.tokens = @min(@as(f64, @floatFromInt(self.burst)), self.tokens + elapsed * self.rate);
        self.last_update = now;
    }
};

/// Sliding window rate limiter
pub const SlidingWindow = struct {
    allocator: std.mem.Allocator,
    rate: f64, // Max requests per second
    window_size_ns: i64, // Window size in nanoseconds
    requests: std.ArrayList(i64), // Timestamps of recent requests

    /// Create a new sliding window limiter
    pub fn init(allocator: std.mem.Allocator, rate: f64, window_sec: u32) !SlidingWindow {
        return SlidingWindow{
            .allocator = allocator,
            .rate = rate,
            .window_size_ns = @as(i64, @intCast(window_sec)) * 1_000_000_000,
            .requests = std.ArrayList(i64).empty,
        };
    }

    pub fn deinit(self: *SlidingWindow) void {
        self.requests.deinit(self.allocator);
    }

    /// Try to allow a request. Expired entries are removed in-place (O(n) scan,
    /// but avoids O(n²) orderedRemove shuffle).
    pub fn allow(self: *SlidingWindow) bool {
        const now = compat.nanoTimestamp();
        const window_start = now - self.window_size_ns;

        // In-place compaction: shift live timestamps to the front.
        var write_idx: usize = 0;
        for (self.requests.items) |ts| {
            if (ts > window_start) {
                self.requests.items[write_idx] = ts;
                write_idx += 1;
            }
        }
        self.requests.shrinkRetainingCapacity(write_idx);

        // Check if under limit
        const count = @as(u32, @intCast(self.requests.items.len));
        if (count < @as(u32, @intFromFloat(self.rate))) {
            self.requests.append(self.allocator, @intCast(now)) catch return false;
            return true;
        }

        return false;
    }
};

/// IP-based rate limiter using token buckets per client
pub const IpLimiter = struct {
    allocator: std.mem.Allocator,
    rate: f64,
    burst: u32,
    buckets: std.StringHashMap(TokenBucket),
    mutex: compat.Mutex,
    last_cleanup: i64,
    cleanup_interval_ms: i64,

    pub fn init(allocator: std.mem.Allocator, rate: f64, burst: u32) IpLimiter {
        return .{
            .allocator = allocator,
            .rate = rate,
            .burst = burst,
            .buckets = std.StringHashMap(TokenBucket).init(allocator),
            .mutex = .init,
            .last_cleanup = compat.milliTimestamp(),
            .cleanup_interval_ms = 60000, // cleanup every 60s
        };
    }

    pub fn deinit(self: *IpLimiter) void {
        var iter = self.buckets.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.buckets.deinit();
    }

    /// Check if request from ip is allowed
    pub fn allow(self: *IpLimiter, ip: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const gop = self.buckets.getOrPut(ip) catch return false;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, ip) catch return false;
            gop.value_ptr.* = TokenBucket.new(self.rate, self.burst);
        }

        const result = gop.value_ptr.allow();

        // Periodic cleanup of stale buckets
        const now = compat.milliTimestamp();
        if (now - self.last_cleanup > self.cleanup_interval_ms) {
            self.last_cleanup = now;
            self.cleanupStaleBuckets();
        }

        return result;
    }

    fn cleanupStaleBuckets(self: *IpLimiter) void {
        const now = compat.nanoTimestamp();
        var iter = self.buckets.iterator();
        var to_remove: std.ArrayList([]const u8) = .empty;
        defer {
            for (to_remove.items) |k| self.allocator.free(k);
            to_remove.deinit(self.allocator);
        }

        while (iter.next()) |entry| {
            // Remove buckets that haven't been used in 5 minutes
            const elapsed = @as(f64, @floatFromInt(now - entry.value_ptr.last_update)) / 1_000_000_000.0;
            if (elapsed > 300) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }

        for (to_remove.items) |k| {
            _ = self.buckets.remove(k);
        }
    }
};

/// Global rate limiter storage
var global_limiters: std.StringHashMapUnmanaged(TokenBucket) = .{};
var global_limiter_mutex: compat.Mutex = .init;
var limiter_allocator: ?std.mem.Allocator = null;

/// Initialize global limiter storage with a dedicated allocator.
/// Call this once during application startup (e.g. with GPA allocator).
pub fn initGlobalLimiters(allocator: std.mem.Allocator) void {
    limiter_allocator = allocator;
}

/// Get or create a rate limiter. Thread-safe.
pub fn getLimiter(name: []const u8, config: Config) *TokenBucket {
    const allocator = limiter_allocator orelse std.heap.page_allocator;

    global_limiter_mutex.lock();
    defer global_limiter_mutex.unlock();

    if (global_limiters.getPtr(name)) |limiter| {
        return limiter;
    }

    const limiter = TokenBucket.new(config.rate, config.burst);
    global_limiters.put(allocator, name, limiter) catch return global_limiters.getPtr(name).?;
    return global_limiters.getPtr(name).?;
}

test "token bucket" {
    var tb = TokenBucket.new(10.0, 5);

    // Should allow initial burst
    try std.testing.expect(tb.allow());
    try std.testing.expect(tb.allow());
    try std.testing.expect(tb.allow());
    try std.testing.expect(tb.allow());
    try std.testing.expect(tb.allow());

    // Should deny when exhausted
    try std.testing.expect(!tb.allow());
}

test "ip limiter" {
    const allocator = std.testing.allocator;
    var limiter = IpLimiter.init(allocator, 2.0, 2);
    defer limiter.deinit();

    try std.testing.expect(limiter.allow("192.168.1.1"));
    try std.testing.expect(limiter.allow("192.168.1.1"));
    try std.testing.expect(!limiter.allow("192.168.1.1"));

    // Different IP should have its own bucket
    try std.testing.expect(limiter.allow("192.168.1.2"));
    try std.testing.expect(limiter.allow("192.168.1.2"));
}


test "sliding window compaction" {
    const allocator = std.testing.allocator;
    var sw = try SlidingWindow.init(allocator, 100.0, 1);
    defer sw.deinit();

    // Fill up to limit
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try std.testing.expect(sw.allow());
    }
    // Should reject when at limit
    try std.testing.expect(!sw.allow());

    // After compaction, expired entries should be removed correctly
    // (we can't easily sleep in tests, but we verify internal state consistency)
    try std.testing.expectEqual(@as(usize, 100), sw.requests.items.len);
}

test "global limiter thread safety init" {
    // Just verify getLimiter doesn't crash and returns a stable pointer
    const ptr1 = getLimiter("test-limit-1", .{ .rate = 10.0, .burst = 5 });
    const ptr2 = getLimiter("test-limit-1", .{ .rate = 10.0, .burst = 5 });
    try std.testing.expectEqual(ptr1, ptr2);
    try std.testing.expect(ptr1.allow());
}
