//! Retry utilities for zigzero
//!
//! Provides exponential backoff retry aligned with go-zero patterns.

const std = @import("std");
const compat = @import("../compat.zig");
const errors = @import("../core/errors.zig");
const circuit = @import("breaker.zig");

/// Retry policy configuration
pub const Policy = struct {
    /// Maximum number of retry attempts
    max_attempts: u32 = 3,
    /// Initial delay in milliseconds
    initial_delay_ms: u64 = 100,
    /// Maximum delay in milliseconds
    max_delay_ms: u64 = 10000,
    /// Multiplier for exponential backoff
    multiplier: f64 = 2.0,
    /// Add random jitter (0.0 - 1.0)
    jitter: f64 = 0.1,
};

/// Delay before the next attempt: the current backoff base, jittered by up to
/// `policy.jitter`.
///
/// The random term is drawn modulo twice the jitter amount, so a zero (or
/// sub-1) span would be a division by zero — it is skipped instead. Clamping
/// keeps a pathological caller-supplied `jitter` from tripping the panics on
/// float→int conversion, and the subtraction saturates so a jitter factor above
/// 1.0 yields 0 rather than wrapping.
fn jitteredDelay(delay_ms: u64, policy: Policy) u64 {
    const base: f64 = @floatFromInt(delay_ms);
    const jitter_amount = base * policy.jitter;

    const span_f = jitter_amount * 2;
    const span: u32 = if (span_f < 1.0) 0 else @intFromFloat(@min(span_f, @as(f64, @floatFromInt(std.math.maxInt(u32)))));
    const random_jitter = if (span > 0) compat.randomInt(u32) % span else 0;

    const floor: u64 = if (jitter_amount >= base) delay_ms else @intFromFloat(jitter_amount);
    return (delay_ms + random_jitter) -| floor;
}

fn nextBackoff(delay_ms: u64, policy: Policy) u64 {
    return @min(policy.max_delay_ms, @as(u64, @intFromFloat(@as(f64, @floatFromInt(delay_ms)) * policy.multiplier)));
}

/// Retry function with generic return type
pub fn retry(comptime T: type, policy: Policy, operation: *const fn () errors.ResultT(T)) errors.ResultT(T) {
    var delay_ms: u64 = policy.initial_delay_ms;

    var attempt: u32 = 0;
    while (attempt < policy.max_attempts) : (attempt += 1) {
        const result = operation();
        if (result) |value| {
            return value;
        } else |_| {
            if (attempt == policy.max_attempts - 1) {
                return result;
            }

            const actual_delay = jitteredDelay(delay_ms, policy);
            compat.sleep(actual_delay * std.time.ns_per_ms);

            delay_ms = nextBackoff(delay_ms, policy);
        }
    }

    return error.ServerError;
}

/// Retry a function that returns void
pub fn retryVoid(policy: Policy, operation: *const fn () errors.Result) errors.Result {
    var delay_ms: u64 = policy.initial_delay_ms;

    var attempt: u32 = 0;
    while (attempt < policy.max_attempts) : (attempt += 1) {
        operation() catch |err| {
            if (attempt == policy.max_attempts - 1) {
                return err;
            }

            const actual_delay = jitteredDelay(delay_ms, policy);
            compat.sleep(actual_delay * std.time.ns_per_ms);

            delay_ms = nextBackoff(delay_ms, policy);
        };
        return;
    }

    return error.ServerError;
}

/// Circuit breaker + retry combo
pub fn retryWithBreaker(comptime T: type, policy: Policy, breaker: *anyopaque, operation: *const fn () errors.ResultT(T)) errors.ResultT(T) {
    const cb: *circuit.CircuitBreaker = @ptrCast(@alignCast(breaker));
    var delay_ms: u64 = policy.initial_delay_ms;

    var attempt: u32 = 0;
    while (attempt < policy.max_attempts) : (attempt += 1) {
        if (!cb.allow()) {
            return error.CircuitBreakerOpen;
        }

        const result = operation();
        if (result) |value| {
            cb.recordSuccess();
            return value;
        } else |_| {
            cb.recordFailure();
            if (attempt == policy.max_attempts - 1) {
                return result;
            }

            const actual_delay = jitteredDelay(delay_ms, policy);
            compat.sleep(actual_delay * std.time.ns_per_ms);

            delay_ms = nextBackoff(delay_ms, policy);
        }
    }

    return error.ServerError;
}

test "jitteredDelay handles zero and pathological jitter" {
    // Used to divide by zero: jitter 0 makes the random span 0.
    try std.testing.expectEqual(@as(u64, 100), jitteredDelay(100, .{ .jitter = 0.0 }));
    // Sub-1 span (100 * 0.001 * 2 = 0.2) is skipped rather than truncated to 0.
    try std.testing.expectEqual(@as(u64, 100), jitteredDelay(100, .{ .jitter = 0.001 }));
    // Jitter above 1.0 must not wrap below zero on the subtraction.
    try std.testing.expect(jitteredDelay(100, .{ .jitter = 5.0 }) <= 1000);
    // An absurd jitter must not trap on the float→int conversions.
    _ = jitteredDelay(100, .{ .jitter = 1e12 });
}

test "retry success" {
    var count: u32 = 0;
    const Op = struct {
        var c: *u32 = undefined;
        fn operation() errors.ResultT(u32) {
            c.* += 1;
            if (c.* < 3) return error.ServerError;
            return c.*;
        }
    };

    Op.c = &count;
    const result = retry(u32, .{ .max_attempts = 5, .initial_delay_ms = 10 }, Op.operation);
    try std.testing.expectEqual(@as(u32, 3), result);
}

test "retry failure" {
    const op = struct {
        fn operation() errors.ResultT(u32) {
            return error.ServerError;
        }
    }.operation;

    const result = retry(u32, .{ .max_attempts = 2, .initial_delay_ms = 10 }, op);
    try std.testing.expectError(error.ServerError, result);
}

test "retryWithBreaker rejects when breaker open" {
    var cb = circuit.CircuitBreaker.withConfig(.{
        .request_threshold = 1,
        .failure_rate_threshold = 50,
        .sleep_duration_sec = 3600,
        .half_open_success_threshold = 1,
    });

    var calls: u32 = 0;
    const Op = struct {
        var c: *u32 = undefined;
        fn operation() errors.ResultT(u32) {
            c.* += 1;
            return error.ServerError;
        }
    };
    Op.c = &calls;

    // A single failure trips the breaker (request_threshold = 1)
    cb.recordFailure();
    try std.testing.expect(cb.getState() == .open);

    const result = retryWithBreaker(u32, .{ .max_attempts = 3, .initial_delay_ms = 10 }, &cb, Op.operation);
    try std.testing.expectError(error.CircuitBreakerOpen, result);
    try std.testing.expectEqual(@as(u32, 0), calls);
}

test "retryWithBreaker records outcomes" {
    var cb = circuit.CircuitBreaker.withConfig(.{
        .request_threshold = 5,
        .failure_rate_threshold = 50,
        .sleep_duration_sec = 3600,
        .half_open_success_threshold = 1,
    });

    var calls: u32 = 0;
    const Op = struct {
        var c: *u32 = undefined;
        fn operation() errors.ResultT(u32) {
            c.* += 1;
            if (c.* < 2) return error.ServerError;
            return c.*;
        }
    };
    Op.c = &calls;

    // First attempt fails and is recorded, retry succeeds
    const result = retryWithBreaker(u32, .{ .max_attempts = 3, .initial_delay_ms = 10 }, &cb, Op.operation);
    try std.testing.expectEqual(@as(u32, 2), result);
    try std.testing.expectEqual(@as(u32, 1), cb.failed_requests);
    try std.testing.expectEqual(@as(u32, 1), cb.successful_requests);
}
