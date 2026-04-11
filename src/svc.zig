//! Service Context for zigzero
//!
//! Provides dependency injection and service context management.
//! Aligned with go-zero's svc.ServiceContext.

const std = @import("std");
const config = @import("config");
const log = @import("log");
const redis = @import("redis");
const rpc = @import("rpc");

/// Service context holding all dependencies
pub const Context = struct {
    allocator: std.mem.Allocator,
    config: *const config.Config,
    logger: log.Logger,
    redis: ?*redis.Redis = null,

    // Trace context
    trace_id: []const u8 = "",
    span_id: []const u8 = "",

    // Metadata
    metadata: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, cfg: *const config.Config, logger: log.Logger) !Context {
        return Context{
            .allocator = allocator,
            .config = cfg,
            .logger = logger,
            .metadata = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Context) void {
        var iter = self.metadata.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.metadata.deinit();
    }

    /// Set trace context
    pub fn setTrace(self: *Context, trace_id: []const u8, span_id: []const u8) !void {
        self.trace_id = try self.allocator.dupe(u8, trace_id);
        self.span_id = try self.allocator.dupe(u8, span_id);
    }

    /// Get metadata value
    pub fn getMetadata(self: *const Context, key: []const u8) ?[]const u8 {
        return self.metadata.get(key);
    }

    /// Set metadata value
    pub fn setMetadata(self: *Context, key: []const u8, value: []const u8) !void {
        const k = try self.allocator.dupe(u8, key);
        const v = try self.allocator.dupe(u8, value);
        try self.metadata.put(k, v);
    }

    /// Get Redis client
    pub fn getRedis(self: *Context) !*redis.Redis {
        if (self.redis) |r| return r;

        const rds = try self.allocator.create(redis.Redis);
        rds.* = try redis.Redis.new(self.allocator, self.config.redis);
        try rds.connect();
        self.redis = rds;
        return rds;
    }
};

/// Service context builder
pub const Builder = struct {
    allocator: std.mem.Allocator,
    config: ?*const config.Config = null,
    logger: ?log.Logger = null,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn withConfig(self: *Builder, cfg: *const config.Config) *Builder {
        self.config = cfg;
        return self;
    }

    pub fn withLogger(self: *Builder, logger: log.Logger) *Builder {
        self.logger = logger;
        return self;
    }

    pub fn build(self: *const Builder) !Context {
        const cfg = self.config orelse return error.MissingConfig;
        const logger = self.logger orelse log.Logger.new(.info, "zigzero");

        return try Context.init(self.allocator, cfg, logger);
    }
};

test "service context" {
    const allocator = std.testing.allocator;
    const cfg = config.Config{
        .name = "test",
        .port = 8080,
        .log = .{},
        .redis = .{},
        .mysql = .{},
        .etcd = .{ .endpoints = &.{} },
    };

    const logger = log.Logger.new(.info, "test");
    var ctx = try Context.init(allocator, &cfg, logger);
    defer ctx.deinit();

    try ctx.setMetadata("key", "value");
    try std.testing.expectEqualStrings("value", ctx.getMetadata("key").?);
}
