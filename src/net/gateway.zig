//! API Gateway for zigzero
//!
//! Provides HTTP reverse proxy capabilities aligned with go-zero's gateway.
//! Routes incoming HTTP requests to upstream backend services.

const std = @import("std");
const api = @import("api.zig");
const http = @import("http.zig");
const loadbalancer = @import("../infra/loadbalancer.zig");
const errors = @import("../core/errors.zig");

/// Upstream backend service configuration
pub const Upstream = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    endpoints: std.ArrayList([]const u8),
    lb: loadbalancer.LoadBalancer,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Upstream {
        return .{
            .allocator = allocator,
            .name = name,
            .endpoints = std.ArrayList([]const u8){},
            .lb = loadbalancer.LoadBalancer.init(allocator, .round_robin),
        };
    }

    pub fn deinit(self: *Upstream) void {
        for (self.endpoints.items) |ep| {
            self.allocator.free(ep);
        }
        self.endpoints.deinit(self.allocator);
        self.lb.deinit();
    }

    pub fn addEndpoint(self: *Upstream, endpoint: []const u8) !void {
        try self.endpoints.append(self.allocator, try self.allocator.dupe(u8, endpoint));
        self.lb.addEndpoint(endpoint);
    }

    pub fn pickEndpoint(self: *Upstream) ?[]const u8 {
        const ep = self.lb.select() orelse return null;
        return ep.address;
    }
};

/// Gateway route configuration
pub const GatewayRoute = struct {
    method: api.Method,
    path: []const u8,
    upstream: []const u8,
    upstream_path: ?[]const u8 = null,
    strip_prefix: ?[]const u8 = null,
    middleware: []const api.MiddlewareFn = &.{},
};

/// Internal route configuration stored per registered route
const RouteConfig = struct {
    gateway: *Gateway,
    upstream: []const u8,
    upstream_path: ?[]const u8,
    strip_prefix: ?[]const u8,
};

/// API Gateway reverse proxy
pub const Gateway = struct {
    allocator: std.mem.Allocator,
    client: http.Client,
    upstreams: std.StringHashMap(Upstream),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, client_config: http.Config) Self {
        return .{
            .allocator = allocator,
            .client = http.Client.init(allocator, client_config),
            .upstreams = std.StringHashMap(Upstream).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.upstreams.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.upstreams.deinit();
    }

    /// Add an upstream service with a list of endpoint base URLs (e.g. "http://localhost:8081")
    pub fn addUpstream(self: *Self, name: []const u8, endpoints: []const []const u8) !void {
        var upstream = Upstream.init(self.allocator, name);
        for (endpoints) |ep| {
            try upstream.addEndpoint(ep);
        }
        const name_copy = try self.allocator.dupe(u8, name);
        try self.upstreams.put(name_copy, upstream);
    }

    /// Register a gateway route on the given API server
    pub fn registerRoute(self: *Self, server: *api.Server, route: GatewayRoute) !void {
        const config = try self.allocator.create(RouteConfig);
        config.* = .{
            .gateway = self,
            .upstream = try self.allocator.dupe(u8, route.upstream),
            .upstream_path = if (route.upstream_path) |up| try self.allocator.dupe(u8, up) else null,
            .strip_prefix = if (route.strip_prefix) |sp| try self.allocator.dupe(u8, sp) else null,
        };

        try server.addRoute(.{
            .method = route.method,
            .path = route.path,
            .handler = proxyHandler,
            .middleware = route.middleware,
            .user_data = config,
        });
    }

    /// Build the target upstream URL from the incoming request context
    fn buildTargetUrl(self: *Self, ctx: *api.Context, config: *RouteConfig) ![]const u8 {
        const upstream = self.upstreams.get(config.upstream) orelse return error.NotFound;
        const endpoint = upstream.pickEndpoint() orelse return error.ServiceUnavailable;

        var raw = ctx.raw_path;

        // Strip prefix if configured
        if (config.strip_prefix) |prefix| {
            if (std.mem.startsWith(u8, raw, prefix)) {
                raw = raw[prefix.len..];
                if (raw.len == 0) raw = "/";
            }
        }

        // Use explicit upstream path if configured (ignoring incoming path)
        if (config.upstream_path) |up_path| {
            // Preserve query string
            if (std.mem.indexOf(u8, raw, "?")) |qidx| {
                raw = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ up_path, raw[qidx..] });
            } else {
                raw = up_path;
            }
        }

        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ endpoint, raw });
        return url;
    }

    fn proxyHandler(ctx: *api.Context) !void {
        const config = @as(*RouteConfig, @ptrCast(@alignCast(ctx.user_data.?)));
        const self = config.gateway;

        const target_url = try self.buildTargetUrl(ctx, config);
        defer self.allocator.free(target_url);

        // Build headers for upstream request
        var headers = std.StringHashMap([]const u8).init(self.allocator);
        defer {
            var hiter = headers.iterator();
            while (hiter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            headers.deinit();
        }

        var iter = ctx.headers.iterator();
        while (iter.next()) |entry| {
            const k = try self.allocator.dupe(u8, entry.key_ptr.*);
            const v = try self.allocator.dupe(u8, entry.value_ptr.*);
            try headers.put(k, v);
        }

        const method = apiToHttpMethod(ctx.method);
        const body = ctx.body orelse "";

        var resp = self.client.request(method, target_url, if (body.len > 0) body else null, headers) catch |err| {
            try ctx.json(503, try errors.toJson(ctx.allocator, .{
                .code = @intFromEnum(errors.Code.ServiceUnavailable),
                .message = @errorName(err),
            }));
            return;
        };
        defer resp.deinit();

        // Copy upstream response headers back
        var resp_iter = resp.headers.iterator();
        while (resp_iter.next()) |entry| {
            try ctx.setHeader(entry.key_ptr.*, entry.value_ptr.*);
        }

        // Set response body
        ctx.status_code = resp.status_code;
        try ctx.response_body.appendSlice(ctx.allocator, resp.body);
        ctx.responded = true;
    }
};

fn apiToHttpMethod(method: api.Method) http.Method {
    return switch (method) {
        .GET => .GET,
        .POST => .POST,
        .PUT => .PUT,
        .DELETE => .DELETE,
        .PATCH => .PATCH,
        .HEAD => .HEAD,
        .OPTIONS => .OPTIONS,
    };
}

test "gateway upstream" {
    const allocator = std.testing.allocator;
    var upstream = Upstream.init(allocator, "test");
    defer upstream.deinit();

    try upstream.addEndpoint("http://localhost:8081");
    try upstream.addEndpoint("http://localhost:8082");

    try std.testing.expectEqual(@as(usize, 2), upstream.endpoints.items.len);
}

test "gateway init" {
    const allocator = std.testing.allocator;
    var gateway = Gateway.init(allocator, .{});
    defer gateway.deinit();

    try gateway.addUpstream("users", &.{ "http://localhost:8081", "http://localhost:8082" });
    try std.testing.expect(gateway.upstreams.contains("users"));
}
