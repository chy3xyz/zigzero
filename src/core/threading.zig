//! Threading utilities for zigzero
//!
//! Aligned with go-zero's core/threading package.

const std = @import("std");
const errors = @import("errors.zig");

/// RoutineGroup is like Go's sync.WaitGroup.
/// Spawns tasks and waits for all to complete.
pub const RoutineGroup = struct {
    wg: std.Thread.WaitGroup,

    pub fn init() RoutineGroup {
        return .{ .wg = .{} };
    }

    /// Run a function in a new thread.
    pub fn go(self: *RoutineGroup, func: *const fn () void) !void {
        self.wg.start();
        const thread = try std.Thread.spawn(.{}, struct {
            fn run(f: *const fn () void, w: *std.Thread.WaitGroup) void {
                defer w.finish();
                f();
            }
        }.run, .{ func, &self.wg });
        thread.detach();
    }

    /// Run a function with a single argument in a new thread.
    pub fn goWith(self: *RoutineGroup, comptime T: type, func: *const fn (T) void, arg: T) !void {
        self.wg.start();
        const thread = try std.Thread.spawn(.{}, struct {
            fn run(a: T, f: *const fn (T) void, w: *std.Thread.WaitGroup) void {
                defer w.finish();
                f(a);
            }
        }.run, .{ arg, func, &self.wg });
        thread.detach();
    }

    /// Wait for all routines to finish.
    pub fn wait(self: *RoutineGroup) void {
        self.wg.wait();
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
pub const TaskRunner = struct {
    semaphore: std.Thread.Semaphore,

    pub fn init(max_concurrent: usize) TaskRunner {
        return .{
            .semaphore = std.Thread.Semaphore{ .permits = @intCast(max_concurrent) },
        };
    }

    pub fn run(self: *TaskRunner, func: *const fn () void) !void {
        self.semaphore.wait();
        const thread = try std.Thread.spawn(.{}, struct {
            fn run(f: *const fn () void, s: *std.Thread.Semaphore) void {
                defer s.post();
                f();
            }
        }.run, .{ func, &self.semaphore });
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
    };
    Ctx.count.store(0, .monotonic);

    var runner = TaskRunner.init(2);
    try runner.run(struct {
        fn f() void {
            _ = @atomicRmw(usize, &Ctx.count.raw, .Add, 1, .monotonic);
        }
    }.f);

    // Give thread time to start
    std.Thread.sleep(10 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 1), Ctx.count.load(.monotonic));
}
