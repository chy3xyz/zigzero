//! Health check for zigzero
//!
//! Provides health check endpoints and probes.

const std = @import("std");
const compat = @import("../compat.zig");

/// Health status
pub const Status = enum {
    healthy,
    unhealthy,
    degraded,
};

/// Health check result
pub const Result = struct {
    name: []const u8,
    status: Status,
    message: ?[]const u8,
    timestamp: i64,

    pub fn init(name: []const u8, status: Status) Result {
        return .{
            .name = name,
            .status = status,
            .message = null,
            .timestamp = compat.milliTimestamp(),
        };
    }

    pub fn withMessage(self: Result, msg: []const u8) Result {
        return .{
            .name = self.name,
            .status = self.status,
            .message = msg,
            .timestamp = self.timestamp,
        };
    }
};

/// Health checker function type
pub const CheckerFn = *const fn (std.mem.Allocator) anyerror!Result;

/// Health registry
pub const Registry = struct {
    allocator: std.mem.Allocator,
    checks: std.StringHashMap(CheckerFn),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .checks = std.StringHashMap(CheckerFn).init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        self.checks.deinit();
    }

    /// Register a health check
    pub fn register(self: *Registry, name: []const u8, checker: CheckerFn) !void {
        try self.checks.put(name, checker);
    }

    /// Run all health checks
    pub fn checkAll(self: *Registry) !std.StringHashMap(Result) {
        var results = std.StringHashMap(Result).init(self.allocator);
        errdefer results.deinit();

        var iter = self.checks.iterator();
        while (iter.next()) |entry| {
            const result = entry.value_ptr.*(self.allocator) catch |err| blk: {
                break :blk Result{
                    .name = entry.key_ptr.*,
                    .status = .unhealthy,
                    .message = @errorName(err),
                    .timestamp = compat.milliTimestamp(),
                };
            };
            try results.put(entry.key_ptr.*, result);
        }

        return results;
    }

    /// Get overall health status
    pub fn overall(self: *Registry) !Status {
        var results = try self.checkAll();
        defer results.deinit();

        var has_unhealthy = false;
        var iter = results.iterator();
        while (iter.next()) |entry| {
            switch (entry.value_ptr.status) {
                .unhealthy => has_unhealthy = true,
                .degraded => {},
                .healthy => {},
            }
        }

        if (has_unhealthy) return .unhealthy;
        return .healthy;
    }
};

/// Common health checks
pub const checks = struct {
    pub fn memory(allocator: std.mem.Allocator) !Result {
        _ = allocator;
        return Result.init("memory", .healthy);
    }

    pub fn disk(allocator: std.mem.Allocator) !Result {
        _ = allocator;
        return Result.init("disk", .healthy);
    }
};

test "health registry" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register("memory", checks.memory);
    try registry.register("disk", checks.disk);

    const status = try registry.overall();
    try std.testing.expectEqual(Status.healthy, status);
}


test "health check result with message" {
    var r = Result.init("test", .degraded);
    r = r.withMessage("high latency");
    try std.testing.expectEqualStrings("test", r.name);
    try std.testing.expectEqual(Status.degraded, r.status);
    try std.testing.expectEqualStrings("high latency", r.message.?);
    try std.testing.expect(r.timestamp > 0);
}

test "health registry catches checker errors" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const failingChecker = struct {
        fn check(allocator: std.mem.Allocator) !Result {
            _ = allocator;
            return error.SimulatedFailure;
        }
    }.check;

    try registry.register("failing", failingChecker);
    const status = try registry.overall();
    try std.testing.expectEqual(Status.unhealthy, status);
}

test "health registry empty is healthy" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const status = try registry.overall();
    try std.testing.expectEqual(Status.healthy, status);
}
