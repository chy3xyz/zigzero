//! Circuit breaker implementation for zigzero
//!
//! Implements the circuit breaker pattern aligned with go-zero's breaker.

const std = @import("std");
const errors = @import("errors");

/// Circuit breaker state
pub const State = enum {
    closed, // Normal operation, requests pass through
    open, // Circuit is open, requests fail immediately
    half_open, // Testing if service recovered
};

/// Circuit breaker configuration
pub const Config = struct {
    /// Number of requests required before calculating failure rate
    request_threshold: u32 = 10,
    /// Percentage of failures that triggers open state (0-100)
    failure_rate_threshold: u32 = 50,
    /// Seconds to stay in open state before transitioning to half-open
    sleep_duration_sec: u64 = 30,
    /// Minimum number of successful requests in half-open to close
    half_open_success_threshold: u32 = 3,
};

/// Circuit breaker implementation
pub const CircuitBreaker = struct {
    state: State = .closed,
    config: Config,

    // Counters
    total_requests: u32 = 0,
    successful_requests: u32 = 0,
    failed_requests: u32 = 0,

    // Timing
    last_failure_time: i64 = 0,
    opened_at: i64 = 0,

    /// Create a new circuit breaker with default config
    pub fn new() CircuitBreaker {
        return CircuitBreaker{ .config = Config{} };
    }

    /// Create a new circuit breaker with custom config
    pub fn withConfig(config: Config) CircuitBreaker {
        return CircuitBreaker{ .config = config };
    }

    /// Check if requests are allowed
    pub fn allow(self: *CircuitBreaker) bool {
        switch (self.state) {
            .closed => return true,
            .open => {
                const now = std.time.timestamp();
                if (now - self.opened_at >= @as(i64, @intCast(self.config.sleep_duration_sec))) {
                    self.state = .half_open;
                    self.total_requests = 0;
                    self.successful_requests = 0;
                    self.failed_requests = 0;
                    return true;
                }
                return false;
            },
            .half_open => return true,
        }
    }

    /// Record a successful request
    pub fn recordSuccess(self: *CircuitBreaker) void {
        self.total_requests += 1;
        self.successful_requests += 1;

        if (self.state == .half_open) {
            if (self.successful_requests >= self.config.half_open_success_threshold) {
                self.close();
            }
        }
    }

    /// Record a failed request
    pub fn recordFailure(self: *CircuitBreaker) void {
        self.total_requests += 1;
        self.failed_requests += 1;
        self.last_failure_time = std.time.timestamp();

        if (self.state == .closed) {
            if (self.shouldTrip()) {
                self.open();
            }
        } else if (self.state == .half_open) {
            self.open();
        }
    }

    /// Check if the circuit should trip (open)
    fn shouldTrip(self: *const CircuitBreaker) bool {
        if (self.total_requests < self.config.request_threshold) {
            return false;
        }

        const failure_rate = @as(f64, @floatFromInt(self.failed_requests)) /
            @as(f64, @floatFromInt(self.total_requests)) * 100;

        return failure_rate >= @as(f64, @floatFromInt(self.config.failure_rate_threshold));
    }

    /// Open the circuit
    fn open(self: *CircuitBreaker) void {
        self.state = .open;
        self.opened_at = std.time.timestamp();
    }

    /// Close the circuit (reset)
    pub fn close(self: *CircuitBreaker) void {
        self.state = .closed;
        self.total_requests = 0;
        self.successful_requests = 0;
        self.failed_requests = 0;
    }

    /// Get current state as string
    pub fn getState(self: *const CircuitBreaker) State {
        return self.state;
    }
};

test "circuit breaker" {
    var cb = CircuitBreaker.new();

    // Initially should allow
    try std.testing.expect(cb.allow());

    // Record some failures
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        cb.recordFailure();
    }

    // Should trip after enough failures
    try std.testing.expect(cb.state == .open);
    try std.testing.expect(!cb.allow());
}
