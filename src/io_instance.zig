//! zigzero - Io instance and helpers for Zig 0.16+
//!
//! This module provides a global Io instance for modules that need it.
//! The api.Server sets this internally when starting the async runtime.

const std = @import("std");

/// Global Io instance for blocking I/O operations.
//: Set by Server.start() when the async runtime is created.
//: Used by modules like net/http.zig, redis.zig for blocking operations.
/// Global Io instance for blocking I/O operations.
//: Initialized from Threaded.global_single_threaded by default.
//: Server.start() may override with a multi-threaded Io when using std.Io.Threaded.
pub var io: std.Io = std.Io.Threaded.global_single_threaded.io();

/// Global allocator - initialized in main()
pub var allocator: std.mem.Allocator = undefined;

/// Get current time in milliseconds
pub fn millis() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1000000);
}

/// Get current time in seconds
pub fn seconds() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return ts.sec;
}
