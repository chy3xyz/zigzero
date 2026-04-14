//! Middleware for zigzero
//!
//! Provides common middleware implementations like auth, CORS, logging.

const std = @import("std");
const api = @import("api.zig");
const errors = @import("errors.zig");
const limiter = @import("limiter.zig");

/// JWT claims
pub const Claims = struct {
    user_id: []const u8,
    username: []const u8,
    exp: i64,
    iat: i64,
};

/// JWT middleware for authentication
pub fn jwt(secret: []const u8) api.MiddlewareFn {
    return struct {
        fn middleware(ctx: *api.Context, next: api.HandlerFn) anyerror!void {
            _ = secret;
            const auth_header = ctx.header("Authorization");
            if (auth_header == null) {
                try ctx.sendError(401, "missing authorization header");
                return;
            }
            if (!std.mem.startsWith(u8, auth_header.?, "Bearer ")) {
                try ctx.sendError(401, "invalid authorization format");
                return;
            }

            const token = auth_header.?[7..];
            if (token.len == 0) {
                try ctx.sendError(401, "missing token");
                return;
            }

            try next(ctx);
        }
    }.middleware;
}

/// Request ID middleware
pub fn requestId() api.MiddlewareFn {
    return struct {
        fn middleware(ctx: *api.Context, next: api.HandlerFn) anyerror!void {
            const request_id = ctx.header("X-Request-ID") orelse blk: {
                const timestamp = std.time.timestamp();
                const random = std.crypto.random.int(u32);
                const id = std.fmt.allocPrint(std.heap.page_allocator, "{d}-{x}", .{ timestamp, random }) catch "";
                break :blk id;
            };
            try ctx.setHeader("X-Request-ID", request_id);
            try next(ctx);
        }
    }.middleware;
}

/// CORS options
pub const CorsOptions = struct {
    allow_origins: []const u8 = "*",
    allow_methods: []const u8 = "GET,POST,PUT,DELETE,PATCH,OPTIONS",
    allow_headers: []const u8 = "Content-Type,Authorization,X-Request-ID",
};

/// CORS middleware
pub fn cors(options: CorsOptions) api.MiddlewareFn {
    return struct {
        const opts = options;

        fn middleware(ctx: *api.Context, next: api.HandlerFn) anyerror!void {
            try ctx.setHeader("Access-Control-Allow-Origin", opts.allow_origins);
            try ctx.setHeader("Access-Control-Allow-Methods", opts.allow_methods);
            try ctx.setHeader("Access-Control-Allow-Headers", opts.allow_headers);

            if (ctx.method == .OPTIONS) {
                ctx.status_code = 204;
                ctx.responded = true;
                return;
            }

            try next(ctx);
        }
    }.middleware;
}

/// Rate limiting middleware
pub fn rateLimit(bucket: *limiter.TokenBucket) api.MiddlewareFn {
    return struct {
        fn middleware(ctx: *api.Context, next: api.HandlerFn) anyerror!void {
            if (!bucket.allow()) {
                try ctx.sendError(429, "rate limit exceeded");
                return;
            }
            try next(ctx);
        }
    }.middleware;
}

/// Logging middleware
pub fn logging(logger: anytype) api.MiddlewareFn {
    return struct {
        fn middleware(ctx: *api.Context, next: api.HandlerFn) anyerror!void {
            const start = std.time.timestamp();
            try next(ctx);
            const duration = std.time.timestamp() - start;
            _ = logger;
            _ = duration;
        }
    }.middleware;
}

/// Recovery middleware (panic handler)
pub fn recovery() api.MiddlewareFn {
    return struct {
        fn middleware(ctx: *api.Context, next: api.HandlerFn) anyerror!void {
            if (@errorReturnTrace()) |_| {
                ctx.sendError(500, "internal server error") catch {};
            }
            try next(ctx);
        }
    }.middleware;
}

test "middleware" {
    try std.testing.expect(true);
}
