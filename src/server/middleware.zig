//! Middleware for zigzero
//!
//! Provides common middleware implementations like auth, CORS, logging.

const std = @import("std");
const api = @import("../net/api.zig");
const errors = @import("../core/errors.zig");
const limiter = @import("../infra/limiter.zig");
const trace = @import("../infra/trace.zig");
const metric = @import("../infra/metric.zig");
const load = @import("../core/load.zig");
const health = @import("../infra/health.zig");

/// JWT claims
pub const Claims = struct {
    sub: ?[]const u8 = null,
    user_id: ?[]const u8 = null,
    username: ?[]const u8 = null,
    exp: ?i64 = null,
    iat: ?i64 = null,
};

/// Base64-url decode (no padding)
fn base64UrlDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var padded = try allocator.alloc(u8, std.mem.alignForward(usize, input.len + 2, 4));
    defer allocator.free(padded);
    @memcpy(padded[0..input.len], input);
    var i: usize = input.len;
    while (i < padded.len) : (i += 1) {
        padded[i] = '=';
    }
    const decoder = std.base64.Base64Decoder.init(std.base64.standard_alphabet_chars, '=');
    const size = decoder.calcSizeForSlice(padded) catch return error.InvalidToken;
    const out = try allocator.alloc(u8, size);
    errdefer allocator.free(out);
    try decoder.decode(out, padded);
    return out;
}

/// Verify a JWT token using HMAC-SHA256. Returns decoded payload on success.
fn verifyJwt(allocator: std.mem.Allocator, token: []const u8, secret: []const u8) !std.json.Parsed(std.json.Value) {
    var parts_iter = std.mem.splitScalar(u8, token, '.');
    const header_b64 = parts_iter.next() orelse return error.InvalidToken;
    const payload_b64 = parts_iter.next() orelse return error.InvalidToken;
    const sig_b64 = parts_iter.next() orelse return error.InvalidToken;
    if (parts_iter.next() != null) return error.InvalidToken;

    const signed_data = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b64, payload_b64 });
    defer allocator.free(signed_data);

    // Compute expected signature
    var expected_sig: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&expected_sig, signed_data, secret);

    // Decode provided signature
    const sig_decoded = try base64UrlDecode(allocator, sig_b64);
    defer allocator.free(sig_decoded);

    if (!std.crypto.utils.timingSafeEql([32]u8, expected_sig, sig_decoded[0..32].*)) {
        return error.InvalidToken;
    }

    const payload_json = try base64UrlDecode(allocator, payload_b64);
    defer allocator.free(payload_json);

    return std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
}

/// JWT middleware for authentication
pub fn jwt(secret: []const u8) api.MiddlewareFn {
    return struct {
        fn middleware(ctx: *api.Context, next: api.HandlerFn) anyerror!void {
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

            const parsed = verifyJwt(ctx.allocator, token, secret) catch |err| {
                _ = err;
                try ctx.sendError(401, "invalid or expired token");
                return;
            };
            defer parsed.deinit();

            // Optionally attach claims to context via header for downstream use
            if (parsed.value.object.get("sub")) |sub| {
                if (sub == .string) {
                    try ctx.setHeader("X-User-ID", sub.string);
                }
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
pub fn logging() api.MiddlewareFn {
    return struct {
        fn middleware(ctx: *api.Context, next: api.HandlerFn) anyerror!void {
            const start = std.time.milliTimestamp();
            try next(ctx);
            const duration = std.time.milliTimestamp() - start;
            const msg = std.fmt.allocPrint(ctx.allocator, "{s} {s} - {d} ({d}ms)", .{
                ctx.method.toString(),
                ctx.raw_path,
                ctx.status_code,
                duration,
            }) catch return;
            defer ctx.allocator.free(msg);
            ctx.logger.info(msg);
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

/// Observability middleware - auto trace + metrics collection
pub fn observability(registry: *metric.Registry) api.MiddlewareFn {
    return struct {
        fn middleware(ctx: *api.Context, next: api.HandlerFn) anyerror!void {
            const start = std.time.milliTimestamp();

            // Auto trace span
            var tracer = trace.Tracer.init(ctx.allocator, ctx.logger.service_name) catch null;
            defer if (tracer) |*t| t.deinit();

            var span: ?*trace.Span = null;
            if (tracer) |*t| {
                span = t.startTrace("http-request") catch null;
                if (span) |s| {
                    s.setAttribute("http.method", ctx.method.toString()) catch {};
                    s.setAttribute("http.path", ctx.path) catch {};
                }
            }

            try next(ctx);

            const duration = std.time.milliTimestamp() - start;

            // Record metrics
            const requests = registry.counter("http_requests_total", "Total HTTP requests") catch null;
            if (requests) |r| r.inc();

            const request_duration = registry.histogram("http_request_duration_ms", "HTTP request duration in milliseconds", &.{ 10, 50, 100, 250, 500, 1000, 2500, 5000, 10000 }) catch null;
            if (request_duration) |h| h.observe(@floatFromInt(duration)) catch {};

            // Finalize trace
            if (span) |s| {
                s.setStatus(if (ctx.status_code >= 500) .err else .ok);
                s.end();
                var trace_buf: [64]u8 = undefined;
                const trace_id = s.formatTraceId(&trace_buf);
                ctx.setHeader("X-Trace-ID", trace_id) catch {};
            }
        }
    }.middleware;
}

/// Prometheus metrics handler
pub fn prometheusHandler(registry: *metric.Registry) api.HandlerFn {
    return struct {
        fn handle(ctx: *api.Context) !void {
            var buf = std.ArrayList(u8){};
            defer buf.deinit(ctx.allocator);
            try registry.exportPrometheus(buf.writer(ctx.allocator));
            try ctx.setHeader("Content-Type", "text/plain; version=0.0.4; charset=utf-8");
            try ctx.response_body.appendSlice(ctx.allocator, buf.items);
            ctx.responded = true;
        }
    }.handle;
}

/// Load shedding middleware using adaptive shedder
pub fn loadShedding(shedder: *load.AdaptiveShedder) api.MiddlewareFn {
    return struct {
        fn middleware(ctx: *api.Context, next: api.HandlerFn) anyerror!void {
            const promise = shedder.allow() catch {
                try ctx.sendError(503, "service overloaded");
                return;
            };
            next(ctx) catch |err| {
                promise.fail();
                return err;
            };
            promise.pass();
        }
    }.middleware;
}

/// Health check handler
pub fn healthHandler(registry: *health.Registry) api.HandlerFn {
    return struct {
        fn handle(ctx: *api.Context) !void {
            var results = try registry.checkAll();
            defer results.deinit();

            var buf = std.ArrayList(u8){};
            defer buf.deinit(ctx.allocator);
            const w = buf.writer(ctx.allocator);

            try w.writeAll("{\"status\":\"");
            const overall = try registry.overall();
            const status_str = switch (overall) {
                .healthy => "healthy",
                .degraded => "degraded",
                .unhealthy => "unhealthy",
            };
            try w.writeAll(status_str);
            try w.writeAll("\",\"checks\":{");

            var first = true;
            var iter = results.iterator();
            while (iter.next()) |entry| {
                if (!first) try w.writeAll(",");
                first = false;
                const r = entry.value_ptr.*;
                const check_status = switch (r.status) {
                    .healthy => "healthy",
                    .degraded => "degraded",
                    .unhealthy => "unhealthy",
                };
                if (r.message) |msg| {
                    try w.print("\"{s}\":{{\"status\":\"{s}\",\"message\":\"{s}\"}}", .{ r.name, check_status, msg });
                } else {
                    try w.print("\"{s}\":{{\"status\":\"{s}\"}}", .{ r.name, check_status });
                }
            }
            try w.writeAll("}}");

            const code: u16 = if (overall == .unhealthy) 503 else 200;
            try ctx.json(code, buf.items);
        }
    }.handle;
}

test "middleware" {
    try std.testing.expect(true);
}
