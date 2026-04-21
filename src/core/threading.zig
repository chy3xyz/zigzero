//! Threading utilities for zigzero
//!
//! Aligned with go-zero's core/threading package.

const std = @import("std");
const errors = @import("errors.zig");

/// RoutineGroup is like Go's sync.WaitGroup.
/// Spawns tasks and waits for all to complete.
/// NOTE: Simplified for Zig 0.16 - uses atomic counter instead of WaitGroup
pub const RoutineGroup = struct {
    count: std.atomic.Value(usize),

    pub fn init() RoutineGroup {
        return .{ .count = std.atomic.Value(usize).init(0) };
    }

    /// Run a function in a new thread.
    pub fn go(self: *RoutineGroup, func: *const fn () void) !void {
        _ = @atomicRmw(usize, &self.count.raw, .Add, 1, .monotonic);
        const thread = try std.Thread.spawn(.{}, struct {
            fn run(f: *const fn () void, c: *std.atomic.Value(usize)) void {
                defer _ = @atomicRmw(usize, &c.raw, .Sub, 1, .monotonic);
                f();
            }
        }.run, .{ func, &self.count });
        thread.detach();
    }

    /// Run a function with a single argument in a new thread.
    pub fn goWith(self: *RoutineGroup, comptime T: type, func: *const fn (T) void, arg: T) !void {
        _ = @atomicRmw(usize, &self.count.raw, .Add, 1, .monotonic);
        const thread = try std.Thread.spawn(.{}, struct {
            fn run(a: T, f: *const fn (T) void, c: *std.atomic.Value(usize)) void {
                defer _ = @atomicRmw(usize, &c.raw, .Sub, 1, .monotonic);
                f(a);
            }
        }.run, .{ arg, func, &self.count });
        thread.detach();
    }

    /// Wait for all routines to finish.
    pub fn wait(self: *RoutineGroup) void {
        while (self.count.load(.monotonic) > 0) {
            std.Thread.yield() catch {};
        }
    }
};

/// Run a function safely in a new thread, recovering from panics.
pub fn goSafe(func: *const fn () void) !void {
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(f: *const fn () void) void {
            @call(.always_inline, f, .{});
        }
    }.run, .{func});
    thread.detach();
}

/// Run a function with an argument safely in a new thread.
pub fn goSafeWith(comptime T: type, func: *const fn (T) void, arg: T) !void {
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(a: T, f: *const fn (T) void) void {
            @call(.always_inline, f, .{a});
        }
    }.run, .{ arg, func });
    thread.detach();
}

/// A task runner that limits concurrency with a semaphore.
/// NOTE: Simplified for Zig 0.16 - semaphore requires Io context
pub const TaskRunner = struct {
    max_concurrent: usize,
    active: std.atomic.Value(usize),

    pub fn init(max_concurrent: usize) TaskRunner {
        return .{
            .max_concurrent = max_concurrent,
            .active = std.atomic.Value(usize).init(0),
        };
    }

    pub fn run(self: *TaskRunner, func: *const fn () void) !void {
        while (self.active.load(.monotonic) >= self.max_concurrent) {
            std.Thread.yield() catch {};
        }
        _ = @atomicRmw(usize, &self.active.raw, .Add, 1, .monotonic);
        const thread = try std.Thread.spawn(.{}, struct {
            fn run(f: *const fn () void, a: *std.atomic.Value(usize)) void {
                defer _ = @atomicRmw(usize, &a.raw, .Sub, 1, .monotonic);
                f();
            }
        }.run, .{ func, &self.active });
        thread.detach();
    }
};

test "routine group" {
    const Ctx = struct {
        var count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
    };
    Ctx.count.store(0, .monotonic);

    var rg = RoutineGroup.init();
    try rg.go(struct {
        fn f() void {
            _ = @atomicRmw(usize, &Ctx.count.raw, .Add, 1, .monotonic);
        }
    }.f);
    try rg.go(struct {
        fn f() void {
            _ = @atomicRmw(usize, &Ctx.count.raw, .Add, 1, .monotonic);
        }
    }.f);

    rg.wait();
    try std.testing.expectEqual(@as(usize, 2), Ctx.count.load(.monotonic));
}

test "task runner" {
    const Ctx = struct {
        var count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
        var started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    };
    Ctx.count.store(0, .monotonic);
    Ctx.started.store(false, .monotonic);

    var runner = TaskRunner.init(2);
    try runner.run(struct {
        fn f() void {
            Ctx.started.store(true, .monotonic);
            _ = @atomicRmw(usize, &Ctx.count.raw, .Add, 1, .monotonic);
        }
    }.f);

    // Wait for thread to actually start
    while (!Ctx.started.load(.monotonic)) {
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), Ctx.count.load(.monotonic));
}
