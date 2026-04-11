//! HTTP API server for zigzero
//!
//! Provides HTTP server with routing, middleware, and handlers.
//! Aligned with go-zero's rest package.

const std = @import("std");
const errors = @import("errors");

/// HTTP method
pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
};

/// HTTP handler function type
pub const Handler = fn (*Context) anyerror!void;

/// Route definition
pub const Route = struct {
    method: Method,
    path: []const u8,
    handler: Handler,
    middleware: []const Middleware = &.{},
};

/// HTTP context
pub const Context = struct {
    /// Request method
    method: Method,
    /// Request path
    path: []const u8,
    /// Query parameters
    query: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    /// Path parameters
    params: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    /// Request headers
    headers: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    /// Request body
    body: ?[]const u8 = null,
    /// Response body
    response_body: std.ArrayListUnmanaged(u8) = .{},
    /// Response status code
    status_code: u16 = 200,
    /// Response headers
    response_headers: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    /// Is response sent
    responded: bool = false,

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
    pub fn setHeader(self: *Context, key: []const u8, value: []const u8) void {
        _ = self;
        _ = key;
        _ = value;
    }

    /// Set JSON response
    pub fn json(self: *Context, status: u16, data: []const u8) void {
        _ = self;
        _ = status;
        _ = data;
    }

    /// Set plain text response
    pub fn text(self: *Context, status: u16, data: []const u8) void {
        _ = self;
        _ = status;
        _ = data;
    }

    /// Send error response
    pub fn error(self: *Context, status: u16, message: []const u8) void {
        _ = self;
        _ = status;
        _ = message;
    }

    /// Get JSON body as typed value
    pub fn bindJson(self: *const Context, comptime T: type) errors.ResultT(T) {
        _ = T;
        return error.ValidationError;
    }
};

/// Middleware function type
pub const Middleware = fn (*Context, Handler) anyerror!void;

/// HTTP server
pub const Server = struct {
    port: u16,
    routes: []Route = &.{},
    middleware: []Middleware = &.{},
    name: []const u8 = "zigzero-api",

    /// Create a new server
    pub fn new(port: u16) Server {
        return Server{ .port = port };
    }

    /// Add a route
    pub fn addRoute(self: *Server, route: Route) void {
        self.routes = self.routes ++ .{route};
    }

    /// Add middleware
    pub fn addMiddleware(self: *Server, mw: Middleware) void {
        self.middleware = &.{mw} ++ self.middleware;
    }

    /// Start the server
    pub fn start(self: *const Server) errors.Result {
        _ = self;
        // Server startup logic would go here
        // In production, use Zig's async networking or integrate with hyper/ altri
        return error.ServerError;
    }

    /// Stop the server
    pub fn stop(self: *const Server) void {
        _ = self;
    }
};

/// Request/Response type wrapper
pub const Request(T: type) = T;
pub const Response(T: type) = T;

/// JSON request/response wrapper
pub fn Json(comptime T: type) type {
    return struct {
        json: T,
    };
}

test "api server" {
    var server = Server.new(8080);
    try std.testing.expect(server.port == 8080);
    
    const route = Route{
        .method = .GET,
        .path = "/health",
        .handler = struct {
            fn handle(ctx: *Context) anyerror!void {
                _ = ctx;
            }
        }.handle,
    };
    server.addRoute(route);
}
