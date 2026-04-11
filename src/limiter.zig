//! Rate limiter implementation for zigzero
//!
//! Provides token bucket and sliding window rate limiting aligned with go-zero's limit.

const std = @import("std");
const errors = @import("errors");

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
    last_update: i64, // Last update timestamp in nanoseconds

    /// Create a new token bucket
    pub fn new(rate: f64, burst: u32) TokenBucket {
        return TokenBucket{
            .rate = rate,
            .burst = burst,
            .tokens = @as(f64, @floatFromInt(burst)),
            .last_update = std.time.nanoTimestamp(),
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
        const now = std.time.nanoTimestamp();
        const elapsed = @as(f64, @floatFromInt(now - self.last_update)) / 1_000_000_000.0;

        self.tokens = @min(@as(f64, @floatFromInt(self.burst)), self.tokens + elapsed * self.rate);
        self.last_update = now;
    }
};

/// Sliding window rate limiter
pub const SlidingWindow = struct {
    rate: f64, // Max requests per second
    window_size_ns: i64, // Window size in nanoseconds
    requests: []i64, // Timestamps of recent requests
    capacity: u32,
    head: u32 = 0,

    /// Create a new sliding window limiter
    pub fn new(rate: f64, window_sec: u32) SlidingWindow {
        const capacity = @as(u32, @intFromFloat(@ceil(rate * @as(f64, @floatFromInt(window_sec)) * 2.0)));
        return SlidingWindow{
            .rate = rate,
            .window_size_ns = @as(i64, @intCast(window_sec)) * 1_000_000_000,
            .requests = &.{},
            .capacity = capacity,
        };
    }

    /// Try to allow a request
    pub fn allow(self: *SlidingWindow) bool {
        const now = std.time.nanoTimestamp();
        const window_start = now - self.window_size_ns;

        // Count requests in current window
        var count: u32 = 0;
        for (self.requests) |ts| {
            if (ts > window_start) count += 1;
        }

        return count < @as(u32, @intFromFloat(self.rate));
    }
};

/// Global rate limiter storage
var global_limiters: std.StringHashMapUnmanaged(TokenBucket) = .{};

/// Get or create a rate limiter
pub fn getLimiter(name: []const u8, config: Config) *TokenBucket {
    const gpa = std.heap.page_allocator;
    if (global_limiters.get(gpa, name)) |limiter| {
        return limiter;
    }

    var limiter = TokenBucket.new(config.rate, config.burst);
    global_limiters.put(gpa, name, limiter) catch return &global_limiters.get(gpa, name).?;
    return &global_limiters.get(gpa, name).?;
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
