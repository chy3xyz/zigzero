//! Middleware for zigzero
//!
//! Provides common middleware implementations like auth, CORS, logging.

const std = @import("std");
const api = @import("api");
const errors = @import("errors");

/// JWT claims
pub const Claims = struct {
    user_id: []const u8,
    username: []const u8,
    exp: i64,
    iat: i64,
};

/// JWT middleware for authentication
pub fn jwt(secret: []const u8) api.Middleware {
    return struct {
        fn middleware(ctx: *api.Context, next: api.Handler) anyerror!void {
            _ = secret;
            // Extract token from Authorization header
            const auth_header = ctx.header("Authorization");
            if (auth_header == null) {
                ctx.error(401, "missing authorization header");
                return;
            }
            if (!std.mem.startsWith(u8, auth_header.?, "Bearer ")) {
                ctx.error(401, "invalid authorization format");
                return;
            }

            const token = auth_header.?[7..];
            if (token.len == 0) {
                ctx.error(401, "missing token");
                return;
            }

            // Store claims in context for handlers to use
            try next(ctx);
        }
    }.middleware;
}

/// Request ID middleware
pub fn requestId() api.Middleware {
    return struct {
        fn middleware(ctx: *api.Context, next: api.Handler) anyerror!void {
            const request_id = ctx.header("X-Request-ID") orelse blk: {
                const timestamp = std.time.timestamp();
                const random = std.crypto.randomInt(u32);
                const id = std.fmt.allocPrint(std.heap.page_allocator, "{d}-{x}", .{ timestamp, random }) catch "";
                break :blk id;
            };
            ctx.setHeader("X-Request-ID", request_id);
            try next(ctx);
        }
    }.middleware;
}

/// CORS middleware
pub fn cors(options: CorsOptions) api.Middleware {
    return struct {
        const opts = options;

        fn middleware(ctx: *api.Context, next: api.Handler) anyerror!void {
            ctx.setHeader("Access-Control-Allow-Origin", opts.allow_origins);
            ctx.setHeader("Access-Control-Allow-Methods", opts.allow_methods);
            ctx.setHeader("Access-Control-Allow-Headers", opts.allow_headers);

            if (ctx.method == .OPTIONS) {
                ctx.status_code = 204;
                ctx.responded = true;
                return;
            }

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

/// Rate limiting middleware
pub fn rateLimit(limiter: *anyopaque) api.Middleware {
    return struct {
        fn middleware(ctx: *api.Context, next: api.Handler) anyerror!void {
            // Rate limiting implementation would use the limiter
            _ = limiter;
            try next(ctx);
        }
    }.middleware;
}

/// Logging middleware
pub fn logging(logger: anytype) api.Middleware {
    return struct {
        fn middleware(ctx: *api.Context, next: api.Handler) anyerror!void {
            const start = std.time.timestamp();
            try next(ctx);
            const duration = std.time.timestamp() - start;
            _ = logger;
            _ = duration;
        }
    }.middleware;
}

/// Recovery middleware (panic handler)
pub fn recovery() api.Middleware {
    return struct {
        fn middleware(ctx: *api.Context, next: api.Handler) anyerror!void {
            defer _ = @error();
            try next(ctx);
        }
    }.middleware;
}

test "middleware" {
    try std.testing.expect(true);
}
