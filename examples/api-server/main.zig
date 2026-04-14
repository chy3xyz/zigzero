const std = @import("std");
const zigzero = @import("zigzero");
const api = zigzero.api;
const log = zigzero.log;
const health = zigzero.health;
const middleware = zigzero.middleware;
const metric = zigzero.metric;
const load = zigzero.load;
const websocket = zigzero.websocket;
const discovery = zigzero.discovery;
const limiter = zigzero.limiter;
const breaker = zigzero.breaker;
const http = zigzero.http;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize logger
    log.initFromConfig(.{
        .service_name = "api-server",
        .level = "info",
    });
    const logger = log.Logger.new(.info, "api-server");

    // Create metrics registry
    var registry = metric.Registry.init(allocator);
    defer registry.deinit();

    // Create health registry
    var health_registry = health.Registry.init(allocator);
    defer health_registry.deinit();
    try health_registry.register("memory", health.checks.memory);
    try health_registry.register("disk", health.checks.disk);

    // Create adaptive load shedder
    var shedder = try load.newAdaptiveShedder(allocator, .{});
    defer shedder.deinit();

    // Create IP-based rate limiter
    var ip_limiter = limiter.IpLimiter.init(allocator, 10.0, 5);
    defer ip_limiter.deinit();

    // Create response cache
    var response_cache = middleware.ResponseCache.init(allocator, 100, 5000);
    defer response_cache.deinit();

    // Create WebSocket hub
    var hub = websocket.Hub.init(allocator);
    defer hub.deinit();

    // Create static service discovery
    var static_discovery = discovery.StaticDiscovery.init(allocator);
    defer static_discovery.deinit();
    const service_nodes = &[_]discovery.Node{
        .{ .id = "node1", .address = "127.0.0.1:8081", .metadata = std.StringHashMap([]const u8).init(allocator) },
        .{ .id = "node2", .address = "127.0.0.1:8082", .metadata = std.StringHashMap([]const u8).init(allocator) },
    };
    try static_discovery.register("user-service", service_nodes);

    // Create HTTP server
    var server = api.Server.init(allocator, 8080, logger);
    defer server.deinit();

    // Add global middleware
    try server.addMiddleware(middleware.requestId());
    try server.addMiddleware(try middleware.cors(allocator, .{ .max_age = 86400 }));
    try server.addMiddleware(middleware.logging());
    try server.addMiddleware(middleware.observability(&registry));
    try server.addMiddleware(middleware.loadShedding(&shedder));
    try server.addMiddleware(middleware.rateLimitByIp(&ip_limiter));
    try server.addMiddleware(middleware.cacheResponses(&response_cache));
    try server.addMiddleware(try middleware.maxBodySize(allocator, 1024 * 1024));

    // Health check endpoint
    try server.addRoute(.{
        .method = .GET,
        .path = "/health",
        .handler = middleware.healthHandler,
        .user_data = &health_registry,
    });

    // Prometheus metrics endpoint
    try server.addRoute(.{
        .method = .GET,
        .path = "/metrics",
        .handler = middleware.prometheusHandler,
        .user_data = &registry,
    });

    // Hello endpoint
    try server.addRoute(.{
        .method = .GET,
        .path = "/hello/:name",
        .handler = struct {
            fn handle(ctx: *api.Context) !void {
                const name = ctx.param("name") orelse "World";
                try ctx.jsonStruct(200, .{
                    .message = std.fmt.allocPrint(ctx.allocator, "Hello, {s}!", .{name}) catch "Hello!",
                });
            }
        }.handle,
    });

    // Echo endpoint
    try server.addRoute(.{
        .method = .POST,
        .path = "/echo",
        .handler = struct {
            fn handle(ctx: *api.Context) !void {
                if (ctx.body) |body| {
                    try ctx.json(200, body);
                } else {
                    try ctx.sendError(400, "missing body");
                }
            }
        }.handle,
    });

    // Slow endpoint with per-route timeout
    try server.addRoute(.{
        .method = .GET,
        .path = "/slow",
        .handler = struct {
            fn handle(ctx: *api.Context) !void {
                std.Thread.sleep(200 * std.time.ns_per_ms);
                try ctx.jsonStruct(200, .{ .status = "completed" });
            }
        }.handle,
        .middleware = &.{middleware.requestTimeout(100)},
    });

    // Protected endpoint with JWT
    try server.addRoute(.{
        .method = .GET,
        .path = "/admin",
        .handler = struct {
            fn handle(ctx: *api.Context) !void {
                try ctx.jsonStruct(200, .{ .status = "admin access granted" });
            }
        }.handle,
        .middleware = &.{try middleware.jwt(allocator, "my-secret-key")},
    });

    // Login endpoint that generates JWT tokens
    try server.addRoute(.{
        .method = .POST,
        .path = "/login",
        .handler = struct {
            fn handle(ctx: *api.Context) !void {
                const token = try middleware.generateToken(ctx.allocator, .{
                    .sub = "user123",
                    .username = "alice",
                    .exp = std.time.timestamp() + 3600,
                }, "my-secret-key");
                defer ctx.allocator.free(token);
                try ctx.jsonStruct(200, .{ .token = token });
            }
        }.handle,
    });

    // User endpoint with validation middleware
    const CreateUserReq = struct {
        name: []const u8,
        email: []const u8,
        age: u32,
    };
    const create_user_rules = .{
        .name = zigzero.validate.FieldRules{ .required = true, .min_len = 2, .max_len = 50 },
        .email = zigzero.validate.FieldRules{ .required = true, .email = true },
        .age = zigzero.validate.FieldRules{ .min = 0, .max = 150 },
    };

    try server.addRoute(.{
        .method = .POST,
        .path = "/users",
        .handler = struct {
            fn handle(ctx: *api.Context) !void {
                const req = try ctx.bindJson(CreateUserReq);
                try ctx.jsonStruct(201, .{
                    .id = 1,
                    .name = req.name,
                    .email = req.email,
                    .age = req.age,
                });
            }
        }.handle,
        .middleware = &.{middleware.validateBody(CreateUserReq, create_user_rules)},
    });

    // WebSocket chat endpoint with room broadcasting
    try server.addRoute(.{
        .method = .GET,
        .path = "/ws/chat",
        .handler = struct {
            fn handle(ctx: *api.Context) !void {
                if (ctx.stream == null) return error.ServerError;
                var ws_conn = try websocket.upgrade(ctx, ctx.stream.?, std.heap.page_allocator);
                ctx.upgraded = true;

                const h = @as(*websocket.Hub, @ptrCast(@alignCast(ctx.user_data.?)));
                const room = try h.room("chat");
                try room.join(&ws_conn);

                const t = std.Thread.spawn(.{}, struct {
                    fn run(conn_ptr: *websocket.Conn, r: *websocket.Room) void {
                        defer {
                            r.leave(conn_ptr);
                            conn_ptr.close();
                        }
                        while (!conn_ptr.closed.load(.monotonic)) {
                            var frame = conn_ptr.readFrame() catch break;
                            defer frame.deinit();
                            switch (frame.opcode) {
                                .text => r.broadcast(frame.payload),
                                .close => break,
                                else => {},
                            }
                        }
                    }
                }.run, .{ &ws_conn, room }) catch return error.ServerError;
                t.detach();
            }
        }.handle,
        .user_data = &hub,
    });

    // HTTP client with circuit breaker demo endpoint
    var cb = breaker.CircuitBreaker.new();
    var http_client = http.Client.init(allocator, .{ .timeout_ms = 3000 });
    http_client.withBreaker(&cb);

    try server.addRoute(.{
        .method = .GET,
        .path = "/proxy",
        .handler = struct {
            fn handle(ctx: *api.Context) !void {
                const client = @as(*http.Client, @ptrCast(@alignCast(ctx.user_data.?)));
                var resp = client.get("http://httpbin.org/get") catch |err| {
                    try ctx.sendError(503, @errorName(err));
                    return;
                };
                defer resp.deinit();
                try ctx.setHeader("Content-Type", "application/json");
                try ctx.json(200, resp.body);
            }
        }.handle,
        .user_data = &http_client,
    });

    // Service discovery endpoint
    try server.addRoute(.{
        .method = .GET,
        .path = "/discover/:service",
        .handler = struct {
            fn handle(ctx: *api.Context) !void {
                const service_name = ctx.param("service") orelse return error.InvalidParameter;
                const disc = @as(*discovery.StaticDiscovery, @ptrCast(@alignCast(ctx.user_data.?)));
                if (disc.getNodes(service_name)) |nodes| {
                    var endpoints: std.ArrayList([]const u8) = .{};
                    defer endpoints.deinit(ctx.allocator);
                    for (nodes) |node| {
                        try endpoints.append(ctx.allocator, node.address);
                    }
                    try ctx.jsonStruct(200, .{ .service = service_name, .nodes = endpoints.items });
                } else {
                    try ctx.sendError(404, "service not found");
                }
            }
        }.handle,
        .user_data = &static_discovery,
    });

    logger.info("Starting API server on port 8080");
    try server.start();
}
