//! HTTP API server for zigzero
//!
//! Provides HTTP server with routing, middleware, and handlers.
//! Aligned with go-zero's rest package.

const std = @import("std");
const errors = @import("errors.zig");
const log = @import("log.zig");

/// HTTP method
pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,

    pub fn fromString(s: []const u8) Method {
        if (std.mem.eql(u8, s, "GET")) return .GET;
        if (std.mem.eql(u8, s, "POST")) return .POST;
        if (std.mem.eql(u8, s, "PUT")) return .PUT;
        if (std.mem.eql(u8, s, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, s, "PATCH")) return .PATCH;
        if (std.mem.eql(u8, s, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, s, "OPTIONS")) return .OPTIONS;
        return .GET;
    }

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .PATCH => "PATCH",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
        };
    }
};

/// HTTP handler function type
pub const HandlerFn = *const fn (*Context) anyerror!void;

/// Middleware function type
pub const MiddlewareFn = *const fn (*Context, HandlerFn) anyerror!void;

/// Route definition
pub const Route = struct {
    method: Method,
    path: []const u8,
    handler: HandlerFn,
    middleware: []const MiddlewareFn = &.{},
};

/// HTTP context - holds request/response data
pub const Context = struct {
    allocator: std.mem.Allocator,
    method: Method,
    path: []const u8,
    raw_path: []const u8,
    query: std.StringHashMap([]const u8),
    params: std.StringHashMap([]const u8),
    headers: std.StringHashMap([]const u8),
    body: ?[]const u8 = null,
    response_body: std.ArrayList(u8),
    status_code: u16 = 200,
    response_headers: std.StringHashMap([]const u8),
    responded: bool = false,
    logger: log.Logger,

    pub fn init(allocator: std.mem.Allocator, method: Method, path: []const u8, logger: log.Logger) !Context {
        return Context{
            .allocator = allocator,
            .method = method,
            .path = path,
            .raw_path = path,
            .query = std.StringHashMap([]const u8).init(allocator),
            .params = std.StringHashMap([]const u8).init(allocator),
            .headers = std.StringHashMap([]const u8).init(allocator),
            .response_body = std.ArrayList(u8){},
            .response_headers = std.StringHashMap([]const u8).init(allocator),
            .logger = logger,
        };
    }

    pub fn deinit(self: *Context) void {
        var query_iter = self.query.iterator();
        while (query_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.query.deinit();

        var params_iter = self.params.iterator();
        while (params_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.params.deinit();

        var headers_iter = self.headers.iterator();
        while (headers_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();

        self.response_body.deinit(self.allocator);

        var resp_headers_iter = self.response_headers.iterator();
        while (resp_headers_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.response_headers.deinit();
    }

    /// Get query parameter
    pub fn queryParam(self: *const Context, key: []const u8) ?[]const u8 {
        return self.query.get(key);
    }

    /// Get path parameter
    pub fn param(self: *const Context, key: []const u8) ?[]const u8 {
        return self.params.get(key);
    }

    /// Get header
    pub fn header(self: *const Context, key: []const u8) ?[]const u8 {
        return self.headers.get(key);
    }

    /// Set response header
    pub fn setHeader(self: *Context, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.response_headers.put(key_copy, value_copy);
    }

    /// Set JSON response
    pub fn json(self: *Context, status: u16, data: []const u8) !void {
        self.status_code = status;
        try self.setHeader("Content-Type", "application/json");
        try self.response_body.appendSlice(self.allocator, data);
        self.responded = true;
    }

    /// Set plain text response
    pub fn text(self: *Context, status: u16, data: []const u8) !void {
        self.status_code = status;
        try self.setHeader("Content-Type", "text/plain");
        try self.response_body.appendSlice(self.allocator, data);
        self.responded = true;
    }

    /// Send error response
    pub fn sendError(self: *Context, status: u16, message: []const u8) !void {
        self.status_code = status;
        try self.setHeader("Content-Type", "application/json");
        const err_json = try std.fmt.allocPrint(self.allocator, "{{\"error\":\"{s}\"}}", .{message});
        defer self.allocator.free(err_json);
        try self.response_body.appendSlice(self.allocator, err_json);
        self.responded = true;
    }

    /// Parse JSON body into type T
    pub fn bindJson(self: *const Context, comptime T: type) !T {
        if (self.body == null) return error.NoBody;
        return std.json.parseFromSlice(T, self.allocator, self.body.?, .{}) catch return error.InvalidJson;
    }

    /// Send JSON from struct
    pub fn jsonStruct(self: *Context, status: u16, value: anytype) !void {
        self.status_code = status;
        try self.setHeader("Content-Type", "application/json");
        const json_str = try std.json.stringifyAlloc(self.allocator, value, .{});
        defer self.allocator.free(json_str);
        try self.response_body.appendSlice(self.allocator, json_str);
        self.responded = true;
    }
};

/// HTTP request parser
const RequestParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RequestParser {
        return .{ .allocator = allocator };
    }

    pub fn parse(self: *RequestParser, reader: std.io.AnyReader) !ParsedRequest {
        var buffer: [8192]u8 = undefined;

        // Read request line
        const request_line = try reader.readUntilDelimiterOrEof(&buffer, '\n') orelse return error.InvalidRequest;
        if (request_line.len < 14) return error.InvalidRequest; // Minimum: "GET / HTTP/1.1"

        // Parse method
        const method_end = std.mem.indexOf(u8, request_line, " ") orelse return error.InvalidRequest;
        const method_str = request_line[0..method_end];
        const method = Method.fromString(method_str);

        // Parse path
        const path_start = method_end + 1;
        const path_end = std.mem.indexOfPos(u8, request_line, path_start, " ") orelse return error.InvalidRequest;
        const raw_path = request_line[path_start..path_end];

        // Parse query string
        var path = raw_path;
        var query_map = std.StringHashMap([]const u8).init(self.allocator);

        if (std.mem.indexOf(u8, raw_path, "?")) |query_start| {
            path = raw_path[0..query_start];
            const query_str = raw_path[query_start + 1 ..];

            var iter = std.mem.splitScalar(u8, query_str, '&');
            while (iter.next()) |param| {
                if (param.len == 0) continue;
                if (std.mem.indexOf(u8, param, "=")) |eq_pos| {
                    const key = try self.allocator.dupe(u8, param[0..eq_pos]);
                    const value = try self.allocator.dupe(u8, param[eq_pos + 1 ..]);
                    try query_map.put(key, value);
                }
            }
        }

        // Parse headers
        var headers = std.StringHashMap([]const u8).init(self.allocator);
        while (true) {
            const line = try reader.readUntilDelimiterOrEof(&buffer, '\n') orelse return error.InvalidRequest;
            if (line.len == 0 or (line.len == 1 and line[0] == '\r')) break;

            const header_line = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;

            if (std.mem.indexOf(u8, header_line, ": ")) |colon_pos| {
                const key = try self.allocator.dupe(u8, header_line[0..colon_pos]);
                const value = try self.allocator.dupe(u8, header_line[colon_pos + 2 ..]);
                try headers.put(key, value);
            }
        }

        // Read body if Content-Length present
        var body: ?[]const u8 = null;
        if (headers.get("Content-Length")) |len_str| {
            const content_len = std.fmt.parseInt(usize, len_str, 10) catch 0;
            if (content_len > 0) {
                const body_buf = try self.allocator.alloc(u8, content_len);
                const bytes_read = try reader.readAll(body_buf);
                if (bytes_read == content_len) {
                    body = body_buf;
                } else {
                    self.allocator.free(body_buf);
                }
            }
        }

        return ParsedRequest{
            .method = method,
            .path = try self.allocator.dupe(u8, path),
            .raw_path = try self.allocator.dupe(u8, raw_path),
            .query = query_map,
            .headers = headers,
            .body = body,
        };
    }
};

const ParsedRequest = struct {
    method: Method,
    path: []const u8,
    raw_path: []const u8,
    query: std.StringHashMap([]const u8),
    headers: std.StringHashMap([]const u8),
    body: ?[]const u8,

    pub fn deinit(self: *ParsedRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.raw_path);

        var query_iter = self.query.iterator();
        while (query_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.query.deinit();

        var headers_iter = self.headers.iterator();
        while (headers_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();

        if (self.body) |b| allocator.free(b);
    }
};

/// Router for matching routes
const Router = struct {
    allocator: std.mem.Allocator,
    routes: std.ArrayList(Route),

    pub fn init(allocator: std.mem.Allocator) Router {
        return .{
            .allocator = allocator,
            .routes = std.ArrayList(Route){},
        };
    }

    pub fn deinit(self: *Router) void {
        self.routes.deinit(self.allocator);
    }

    pub fn addRoute(self: *Router, route: Route) !void {
        try self.routes.append(self.allocator, route);
    }

    pub fn match(self: *const Router, method: Method, path: []const u8) ?MatchedRoute {
        for (self.routes.items) |route| {
            if (route.method != method) continue;

            const params = matchPath(route.path, path) catch continue;
            if (params != null) {
                return MatchedRoute{
                    .route = route,
                    .params = params.?,
                };
            }
        }
        return null;
    }
};

const MatchedRoute = struct {
    route: Route,
    params: std.StringHashMap([]const u8),
};

fn matchPath(pattern: []const u8, path: []const u8) !?std.StringHashMap([]const u8) {
    var params = std.StringHashMap([]const u8).init(std.heap.page_allocator);
    errdefer {
        var iter = params.iterator();
        while (iter.next()) |entry| {
            std.heap.page_allocator.free(entry.key_ptr.*);
            std.heap.page_allocator.free(entry.value_ptr.*);
        }
        params.deinit();
    }

    var pattern_parts = std.mem.splitScalar(u8, pattern, '/');
    var path_parts = std.mem.splitScalar(u8, path, '/');

    while (pattern_parts.next()) |p_part| {
        const path_part = path_parts.next() orelse return null;

        if (p_part.len == 0 and path_part.len == 0) continue;
        if (p_part.len == 0) continue;
        if (path_part.len == 0 and p_part.len > 0) return null;

        if (std.mem.startsWith(u8, p_part, "{")) {
            // Parameter
            const param_name = if (std.mem.endsWith(u8, p_part, "}"))
                p_part[1 .. p_part.len - 1]
            else
                p_part[1..];

            const key = try std.heap.page_allocator.dupe(u8, param_name);
            const value = try std.heap.page_allocator.dupe(u8, path_part);
            try params.put(key, value);
        } else if (!std.mem.eql(u8, p_part, path_part)) {
            return null;
        }
    }

    // Check if there are extra path parts
    if (path_parts.next() != null) return null;

    return params;
}

/// HTTP response writer
const ResponseWriter = struct {
    pub fn write(writer: std.io.AnyWriter, status: u16, headers: *const std.StringHashMap([]const u8), body: []const u8) !void {
        const status_text = getStatusText(status);
        try writer.print("HTTP/1.1 {d} {s}\r\n", .{ status, status_text });

        var iter = headers.iterator();
        while (iter.next()) |entry| {
            try writer.print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        try writer.print("Content-Length: {d}\r\n", .{body.len});
        try writer.writeAll("\r\n");
        try writer.writeAll(body);
    }

    fn getStatusText(status: u16) []const u8 {
        return switch (status) {
            200 => "OK",
            201 => "Created",
            204 => "No Content",
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            429 => "Too Many Requests",
            500 => "Internal Server Error",
            502 => "Bad Gateway",
            503 => "Service Unavailable",
            else => "Unknown",
        };
    }
};

/// HTTP server
pub const Server = struct {
    allocator: std.mem.Allocator,
    port: u16,
    router: Router,
    global_middleware: std.ArrayList(MiddlewareFn),
    name: []const u8,
    running: std.atomic.Value(bool),
    server_socket: ?std.net.Server = null,
    logger: log.Logger,

    pub fn init(allocator: std.mem.Allocator, port: u16, logger: log.Logger) Server {
        return .{
            .allocator = allocator,
            .port = port,
            .router = Router.init(allocator),
            .global_middleware = std.ArrayList(MiddlewareFn){},
            .name = "zigzero-api",
            .running = std.atomic.Value(bool).init(false),
            .server_socket = null,
            .logger = logger,
        };
    }

    pub fn deinit(self: *Server) void {
        self.router.deinit();
        self.global_middleware.deinit(self.allocator);
        if (self.server_socket) |*ss| {
            ss.deinit();
        }
    }

    /// Add a route
    pub fn addRoute(self: *Server, route: Route) !void {
        try self.router.addRoute(route);
    }

    /// Add global middleware
    pub fn addMiddleware(self: *Server, mw: MiddlewareFn) !void {
        try self.global_middleware.append(self.allocator, mw);
    }

    /// Start the server
    pub fn start(self: *Server) !void {
        const addr = std.net.Address.parseIp4("0.0.0.0", self.port) catch {
            return error.ServerError;
        };

        var server = addr.listen(.{
            .reuse_address = true,
            .kernel_backlog = 128,
        }) catch {
            return error.ServerError;
        };

        self.server_socket = server;
        self.running.store(true, .monotonic);

        self.logger.info(try std.fmt.allocPrint(self.allocator, "Server listening on port {d}", .{self.port}));

        while (self.running.load(.monotonic)) {
            const conn = server.accept() catch |err| {
                if (!self.running.load(.monotonic)) break;
                self.logger.err(try std.fmt.allocPrint(self.allocator, "Accept error: {any}", .{err}));
                continue;
            };

            const conn_ptr = try self.allocator.create(std.net.Server.Connection);
            conn_ptr.* = conn;

            const thread = std.Thread.spawn(.{}, handleConnection, .{ self, conn_ptr }) catch |err| {
                self.logger.err(try std.fmt.allocPrint(self.allocator, "Failed to spawn thread: {any}", .{err}));
                conn_ptr.stream.close();
                self.allocator.destroy(conn_ptr);
                continue;
            };
            thread.detach();
        }
    }

    /// Stop the server
    pub fn stop(self: *Server) void {
        self.running.store(false, .monotonic);
        if (self.server_socket) |*ss| {
            ss.deinit();
            self.server_socket = null;
        }
    }

    fn handleConnection(self: *Server, conn: *std.net.Server.Connection) void {
        defer {
            conn.stream.close();
            self.allocator.destroy(conn);
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const reader = conn.stream.reader();
        const writer = conn.stream.writer();

        var parser = RequestParser.init(arena_alloc);
        var request = parser.parse(reader.any()) catch |err| {
            self.logger.err(try std.fmt.allocPrint(arena_alloc, "Parse error: {any}", .{err}));
            _ = writer.write("HTTP/1.1 400 Bad Request\r\n\r\n") catch {};
            return;
        };
        defer request.deinit(arena_alloc);

        // Find matching route
        const matched = self.router.match(request.method, request.path);

        var ctx = Context.init(arena_alloc, request.method, request.path, self.logger) catch |err| {
            self.logger.err(try std.fmt.allocPrint(arena_alloc, "Context init error: {any}", .{err}));
            return;
        };
        defer ctx.deinit();

        // Copy query params
        var query_iter = request.query.iterator();
        while (query_iter.next()) |entry| {
            const key = arena_alloc.dupe(u8, entry.key_ptr.*) catch continue;
            const value = arena_alloc.dupe(u8, entry.value_ptr.*) catch continue;
            ctx.query.put(key, value) catch {};
        }

        // Copy headers
        var headers_iter = request.headers.iterator();
        while (headers_iter.next()) |entry| {
            const key = arena_alloc.dupe(u8, entry.key_ptr.*) catch continue;
            const value = arena_alloc.dupe(u8, entry.value_ptr.*) catch continue;
            ctx.headers.put(key, value) catch {};
        }

        ctx.body = request.body;
        ctx.raw_path = request.raw_path;

        if (matched) |m| {
            // Copy path params
            var params_iter = m.params.iterator();
            while (params_iter.next()) |entry| {
                const key = arena_alloc.dupe(u8, entry.key_ptr.*) catch continue;
                const value = arena_alloc.dupe(u8, entry.value_ptr.*) catch continue;
                ctx.params.put(key, value) catch {};
            }

            // Execute handler with middleware chain
            const final_handler = struct {
                fn handler(c: *Context) !void {
                    const route: Route = @ptrCast(@alignCast(c.route.?));
                    try route.handler(c);
                }
            }.handler;

            ctx.route = @ptrFromInt(@intFromPtr(&m.route));

            self.executeWithMiddleware(&ctx, final_handler) catch |err| {
                if (!ctx.responded) {
                    ctx.sendError(500, @errorName(err)) catch {};
                }
            };
        } else {
            ctx.sendError(404, "Not Found") catch {};
        }

        // Send response
        ResponseWriter.write(writer.any(), ctx.status_code, &ctx.response_headers, ctx.response_body.items) catch {};
    }

    fn executeWithMiddleware(self: *Server, ctx: *Context, final_handler: HandlerFn) !void {
        // Build middleware chain
        const Chain = struct {
            server: *Server,

            fn execute(s: *Server, c: *Context) anyerror!void {
                if (c.chain_index < c.chain_middlewares.len) {
                    const mw = c.chain_middlewares[c.chain_index];
                    c.chain_index += 1;
                    try mw(c, struct {
                        fn next(context: *Context) !void {
                            try execute(s, context);
                        }
                    }.next);
                } else {
                    try c.chain_handler(c);
                }
            }
        };

        ctx.chain_middlewares = self.global_middleware.items;
        ctx.chain_handler = final_handler;
        ctx.chain_index = 0;

        try Chain.execute(self, ctx);
    }
};

// Context extension fields for middleware chain
const ContextExt = struct {
    route: ?*const Route = null,
    chain_middlewares: []const MiddlewareFn = &.{},
    chain_handler: HandlerFn = undefined,
    chain_index: usize = 0,
};

/// Internal fields for Context
const ContextInternal = struct {
    route: ?*const Route,
    chain_middlewares: []const MiddlewareFn,
    chain_handler: HandlerFn,
    chain_index: usize,
};

/// Request/Response type wrapper
pub fn Request(comptime T: type) type {
    return struct {
        body: T,
    };
}

pub fn Response(comptime T: type) type {
    return struct {
        status: u16 = 200,
        body: T,
    };
}

/// JSON request/response wrapper
pub fn Json(comptime T: type) type {
    return struct {
        json: T,
    };
}

// Internal fields for Context
var context_route: ?*const Route = null;
var context_chain_middlewares: []const MiddlewareFn = &.{};
var context_chain_handler: HandlerFn = undefined;
var context_chain_index: usize = 0;

// Store chain data in thread-local storage or use a different approach
// For now, use a simpler approach with a wrapper

const ServerHandler = struct {
    server: *Server,

    fn deinit(self: *ServerHandler, ctx: *Context) !void {
        _ = self;
        _ = ctx;
        // Implementation
    }
};

test "api server" {
    const allocator = std.testing.allocator;
    const logger = log.Logger.new(.info, "test");
    var server = Server.init(allocator, 0, logger);
    defer server.deinit();

    const route = Route{
        .method = .GET,
        .path = "/health",
        .handler = struct {
            fn handle(ctx: *Context) anyerror!void {
                try ctx.json(200, "{\"status\":\"ok\"}");
            }
        }.handle,
    };

    try server.addRoute(route);
    try std.testing.expect(server.port == 0);
}

test "path matching" {
    var params = try matchPath("/users/{id}", "/users/123");
    if (params) |*p| {
        defer {
            var iter = p.iterator();
            while (iter.next()) |entry| {
                std.heap.page_allocator.free(entry.key_ptr.*);
                std.heap.page_allocator.free(entry.value_ptr.*);
            }
            p.deinit();
        }
        try std.testing.expectEqualStrings("123", p.get("id").?);
    } else {
        try std.testing.expect(false);
    }

    const no_match = try matchPath("/users/{id}", "/posts/123");
    try std.testing.expect(no_match == null);
}

test "http methods" {
    try std.testing.expectEqual(Method.GET, Method.fromString("GET"));
    try std.testing.expectEqualStrings("POST", Method.POST.toString());
}
