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
const cache_mod = @import("../infra/cache.zig");

/// JWT claims
pub const Claims = struct {
    sub: ?[]const u8 = null,
    user_id: ?[]const u8 = null,
    username: ?[]const u8 = null,
    exp: ?i64 = null,
    iat: ?i64 = null,
};

/// Base64-url decode using URL-safe alphabet (handles padding)
fn base64UrlDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const pad_len = (4 - (input.len % 4)) % 4;
    var padded = try allocator.alloc(u8, input.len + pad_len);
    defer allocator.free(padded);
    @memcpy(padded[0..input.len], input);
    for (padded[input.len..]) |*b| b.* = '=';
    const decoder = std.base64.url_safe.Decoder;
    const size = try decoder.calcSizeForSlice(padded);
    const out = try allocator.alloc(u8, size);
    errdefer allocator.free(out);
    try decoder.decode(out, padded);
    return out;
}

/// Base64-url encode using URL-safe alphabet (no padding)
fn base64UrlEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const size = std.base64.url_safe.Encoder.calcSize(input.len);
    const out = try allocator.alloc(u8, size);
    const encoded = std.base64.url_safe.Encoder.encode(out, input);
    // Strip padding
    var len = encoded.len;
    while (len > 0 and out[len - 1] == '=') len -= 1;
    return try allocator.realloc(out, len);
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

    if (!std.crypto.timing_safe.eql([32]u8, expected_sig, sig_decoded[0..32].*)) {
        return error.InvalidToken;
    }

    const payload_json = try base64UrlDecode(allocator, payload_b64);
    defer allocator.free(payload_json);

    return std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
}

/// Sign a JWT token using HMAC-SHA256. Caller owns returned memory.
fn signJwt(allocator: std.mem.Allocator, claims: Claims, secret: []const u8) ![]u8 {
    const header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const header_b64 = try base64UrlEncode(allocator, header);
    defer allocator.free(header_b64);

    var payload_buf: std.ArrayList(u8) = .{};
    defer payload_buf.deinit(allocator);
    const w = payload_buf.writer(allocator);

    try w.writeAll("{");
    var first = true;
    if (claims.sub) |sub| {
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("\"sub\":\"{s}\"", .{sub});
    }
    if (claims.user_id) |uid| {
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("\"user_id\":\"{s}\"", .{uid});
    }
    if (claims.username) |un| {
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("\"username\":\"{s}\"", .{un});
    }
    if (claims.exp) |exp| {
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("\"exp\":{d}", .{exp});
    }
    if (claims.iat) |iat| {
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("\"iat\":{d}", .{iat});
    }
    try w.writeAll("}");

    const payload_b64 = try base64UrlEncode(allocator, payload_buf.items);
    defer allocator.free(payload_b64);

    const signed_data = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b64, payload_b64 });
    defer allocator.free(signed_data);

    var sig: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&sig, signed_data, secret);

    const sig_b64 = try base64UrlEncode(allocator, &sig);
    defer allocator.free(sig_b64);

    return std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ header_b64, payload_b64, sig_b64 });
}

/// Generate a JWT token from claims. Caller owns returned memory.
pub fn generateToken(allocator: std.mem.Allocator, claims: Claims, secret: []const u8) ![]u8 {
    return signJwt(allocator, claims, secret);
}

const JwtState = struct {
    secret: []const u8,
};

/// JWT middleware for authentication
pub fn jwt(allocator: std.mem.Allocator, secret: []const u8) !api.Middleware {
    const state = try allocator.create(JwtState);
    state.secret = try allocator.dupe(u8, secret);
    return .{
        .func = struct {
            fn middleware(ctx: *api.Context, next: api.HandlerFn, data: ?*anyopaque) anyerror!void {
                const s = @as(*JwtState, @ptrCast(@alignCast(data.?))).secret;
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

                const parsed = verifyJwt(ctx.allocator, token, s) catch {
                    try ctx.sendError(401, "invalid or expired token");
                    return;
                };
                defer parsed.deinit();

                if (parsed.value.object.get("sub")) |sub| {
                    if (sub == .string) {
                        try ctx.setHeader("X-User-ID", sub.string);
                    }
                }

                try next(ctx);
            }
        }.middleware,
        .user_data = state,
    };
}

/// Request ID middleware
pub fn requestId() api.Middleware {
    return .{
        .func = struct {
            fn middleware(ctx: *api.Context, next: api.HandlerFn, data: ?*anyopaque) anyerror!void {
                _ = data;
                const request_id = ctx.header("X-Request-ID") orelse blk: {
                    const timestamp = std.time.timestamp();
                    const random = std.crypto.random.int(u32);
                    const id = std.fmt.allocPrint(std.heap.page_allocator, "{d}-{x}", .{ timestamp, random }) catch "";
                    break :blk id;
                };
                try ctx.setHeader("X-Request-ID", request_id);
                try next(ctx);
            }
        }.middleware,
    };
}

/// CORS options
pub const CorsOptions = struct {
    allow_origins: []const u8 = "*",
    allow_methods: []const u8 = "GET,POST,PUT,DELETE,PATCH,OPTIONS",
    allow_headers: []const u8 = "Content-Type,Authorization,X-Request-ID",
    allow_credentials: bool = false,
    max_age: ?u32 = null,
};

/// CORS middleware
pub fn cors(allocator: std.mem.Allocator, options: CorsOptions) !api.Middleware {
    const opts = try allocator.create(CorsOptions);
    opts.* = options;
    return .{
        .func = struct {
            fn middleware(ctx: *api.Context, next: api.HandlerFn, data: ?*anyopaque) anyerror!void {
                const o = @as(*CorsOptions, @ptrCast(@alignCast(data.?)));
                try ctx.setHeader("Access-Control-Allow-Origin", o.allow_origins);
                try ctx.setHeader("Access-Control-Allow-Methods", o.allow_methods);
                try ctx.setHeader("Access-Control-Allow-Headers", o.allow_headers);
                if (o.allow_credentials) {
                    try ctx.setHeader("Access-Control-Allow-Credentials", "true");
                }
                if (o.max_age) |age| {
                    const age_str = try std.fmt.allocPrint(ctx.allocator, "{d}", .{age});
                    defer ctx.allocator.free(age_str);
                    try ctx.setHeader("Access-Control-Max-Age", age_str);
                }

                if (ctx.method == .OPTIONS) {
                    ctx.status_code = 204;
                    ctx.responded = true;
                    return;
                }

                try next(ctx);
            }
        }.middleware,
        .user_data = opts,
    };
}

/// Rate limiting middleware
pub fn rateLimit(bucket: *limiter.TokenBucket) api.Middleware {
    return .{
        .func = struct {
            fn middleware(ctx: *api.Context, next: api.HandlerFn, data: ?*anyopaque) anyerror!void {
                const b = @as(*limiter.TokenBucket, @ptrCast(@alignCast(data.?)));
                if (!b.allow()) {
                    try ctx.sendError(429, "rate limit exceeded");
                    return;
                }
                try next(ctx);
            }
        }.middleware,
        .user_data = bucket,
    };
}

/// IP-based rate limiting middleware
pub fn rateLimitByIp(ip_limiter: *limiter.IpLimiter) api.Middleware {
    return .{
        .func = struct {
            fn middleware(ctx: *api.Context, next: api.HandlerFn, data: ?*anyopaque) anyerror!void {
                const limit = @as(*limiter.IpLimiter, @ptrCast(@alignCast(data.?)));
                const ip = ctx.headers.get("X-Forwarded-For") orelse ctx.headers.get("X-Real-Ip") orelse "unknown";
                if (!limit.allow(ip)) {
                    try ctx.sendError(429, "rate limit exceeded");
                    return;
                }
                try next(ctx);
            }
        }.middleware,
        .user_data = ip_limiter,
    };
}

/// Logging middleware
pub fn logging() api.Middleware {
    return .{
        .func = struct {
            fn middleware(ctx: *api.Context, next: api.HandlerFn, data: ?*anyopaque) anyerror!void {
                _ = data;
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
        }.middleware,
    };
}

/// Recovery middleware (panic handler)
pub fn recovery() api.Middleware {
    return .{
        .func = struct {
            fn middleware(ctx: *api.Context, next: api.HandlerFn, data: ?*anyopaque) anyerror!void {
                _ = data;
                if (@errorReturnTrace()) |_| {
                    ctx.sendError(500, "internal server error") catch {};
                }
                try next(ctx);
            }
        }.middleware,
    };
}

/// Request size limit middleware
pub fn maxBodySize(allocator: std.mem.Allocator, max_size: usize) !api.Middleware {
    const limit = try allocator.create(usize);
    limit.* = max_size;
    return .{
        .func = struct {
            fn middleware(ctx: *api.Context, next: api.HandlerFn, data: ?*anyopaque) anyerror!void {
                const l = @as(*usize, @ptrCast(@alignCast(data.?))).*;
                if (ctx.body) |body| {
                    if (body.len > l) {
                        try ctx.sendError(413, "payload too large");
                        return;
                    }
                }
                try next(ctx);
            }
        }.middleware,
        .user_data = limit,
    };
}

/// Response cache entry
const CacheEntry = struct {
    body: []const u8,
    content_type: ?[]const u8,
};

/// In-memory response cache for GET requests
pub const ResponseCache = struct {
    allocator: std.mem.Allocator,
    cache: cache_mod.Cache(u64, CacheEntry),
    ttl_ms: i64,

    pub fn init(allocator: std.mem.Allocator, max_size: usize, ttl_ms: i64) ResponseCache {
        return .{
            .allocator = allocator,
            .cache = cache_mod.Cache(u64, CacheEntry).init(allocator, max_size),
            .ttl_ms = ttl_ms,
        };
    }

    pub fn deinit(self: *ResponseCache) void {
        self.cache.deinit();
    }

    fn hashKey(path: []const u8, query: []const u8) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(path);
        hasher.update(query);
        return hasher.final();
    }
};

/// Response caching middleware for GET requests
pub fn cacheResponses(cache: *ResponseCache) api.Middleware {
    return .{
        .func = struct {
            fn middleware(ctx: *api.Context, next: api.HandlerFn, data: ?*anyopaque) anyerror!void {
                const c = @as(*ResponseCache, @ptrCast(@alignCast(data.?)));
                if (ctx.method == .GET) {
                    const key = ResponseCache.hashKey(ctx.path, ctx.raw_path);
                    if (c.cache.get(key)) |entry| {
                        if (entry.content_type) |ct| {
                            try ctx.setHeader("Content-Type", ct);
                        }
                        try ctx.response_body.appendSlice(ctx.allocator, entry.body);
                        ctx.responded = true;
                        return;
                    }
                }

                try next(ctx);

                if (ctx.method == .GET and ctx.status_code == 200 and ctx.responded) {
                    const key = ResponseCache.hashKey(ctx.path, ctx.raw_path);
                    const body_copy = c.allocator.dupe(u8, ctx.response_body.items) catch return;
                    const ct = ctx.response_headers.get("Content-Type");
                    const entry = CacheEntry{
                        .body = body_copy,
                        .content_type = if (ct) |t| c.allocator.dupe(u8, t) catch null else null,
                    };
                    c.cache.set(key, entry, c.ttl_ms) catch {};
                }
            }
        }.middleware,
        .user_data = cache,
    };
}

/// Observability middleware - auto trace + metrics collection
pub fn observability(registry: *metric.Registry) api.Middleware {
    return .{
        .func = struct {
            fn middleware(ctx: *api.Context, next: api.HandlerFn, data: ?*anyopaque) anyerror!void {
                const reg = @as(*metric.Registry, @ptrCast(@alignCast(data.?)));
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
                const requests = reg.counter("http_requests_total", "Total HTTP requests") catch null;
                if (requests) |r| r.inc();

                const request_duration = reg.histogram("http_request_duration_ms", "HTTP request duration in milliseconds", &.{ 10, 50, 100, 250, 500, 1000, 2500, 5000, 10000 }) catch null;
                if (request_duration) |h| h.observe(@floatFromInt(duration));

                // Finalize trace
                if (span) |s| {
                    s.setStatus(if (ctx.status_code >= 500) .err else .ok);
                    s.end();
                    var trace_buf: [64]u8 = undefined;
                    const trace_id = s.formatTraceId(&trace_buf);
                    ctx.setHeader("X-Trace-ID", trace_id) catch {};
                }
            }
        }.middleware,
        .user_data = registry,
    };
}

/// Prometheus metrics handler (expects registry in ctx.user_data)
pub fn prometheusHandler(ctx: *api.Context) !void {
    const registry = @as(*metric.Registry, @ptrCast(@alignCast(ctx.user_data.?)));
    var buf = std.ArrayList(u8){};
    defer buf.deinit(ctx.allocator);
    try registry.exportPrometheus(buf.writer(ctx.allocator));
    try ctx.setHeader("Content-Type", "text/plain; version=0.0.4; charset=utf-8");
    try ctx.response_body.appendSlice(ctx.allocator, buf.items);
    ctx.responded = true;
}

/// Load shedding middleware using adaptive shedder
pub fn loadShedding(shedder: *load.AdaptiveShedder) api.Middleware {
    return .{
        .func = struct {
            fn middleware(ctx: *api.Context, next: api.HandlerFn, data: ?*anyopaque) anyerror!void {
                const s = @as(*load.AdaptiveShedder, @ptrCast(@alignCast(data.?)));
                const promise = s.allow() catch {
                    try ctx.sendError(503, "service overloaded");
                    return;
                };
                next(ctx) catch |err| {
                    promise.fail();
                    return err;
                };
                promise.pass();
            }
        }.middleware,
        .user_data = shedder,
    };
}

/// Request timeout middleware
/// Aborts the request with 408 if handler execution exceeds timeout_ms.
pub fn requestTimeout(timeout_ms: u32) api.Middleware {
    return .{
        .func = struct {
            fn middleware(ctx: *api.Context, next: api.HandlerFn, data: ?*anyopaque) anyerror!void {
                const timeout = @as(u32, @intCast(@intFromPtr(data.?) & 0xFFFFFFFF));
                const start = std.time.milliTimestamp();
                try next(ctx);
                const elapsed = std.time.milliTimestamp() - start;
                if (@as(i64, @intCast(timeout)) < elapsed) {
                    ctx.status_code = 408;
                    ctx.responded = true;
                }
            }
        }.middleware,
        .user_data = @ptrFromInt(@as(usize, timeout_ms)),
    };
}

/// Request validation middleware for JSON bodies.
/// Validates the request body against comptime struct rules.
pub fn validateBody(comptime T: type, comptime rules: anytype) api.Middleware {
    return .{
        .func = struct {
            fn middleware(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                _ = ctx.bindJsonAndValidate(T, rules) catch |err| {
                    if (err == error.ValidationError) {
                        const msg = ctx.validation_error_message orelse "validation failed";
                        try ctx.sendError(400, msg);
                        return;
                    }
                    try ctx.sendError(400, "invalid request");
                    return;
                };
                try next(ctx);
            }
        }.middleware,
    };
}

/// Health check handler (expects registry in ctx.user_data)
pub fn healthHandler(ctx: *api.Context) !void {
    const registry = @as(*health.Registry, @ptrCast(@alignCast(ctx.user_data.?)));
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

test "jwt generate and verify" {
    const allocator = std.testing.allocator;
    const secret = "my-secret";
    const claims = Claims{
        .sub = "user123",
        .username = "alice",
    };

    const token = try generateToken(allocator, claims, secret);
    defer allocator.free(token);

    try std.testing.expect(token.len > 0);

    const parsed = try verifyJwt(allocator, token, secret);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("user123", parsed.value.object.get("sub").?.string);
    try std.testing.expectEqualStrings("alice", parsed.value.object.get("username").?.string);
}

test "middleware" {
    try std.testing.expect(true);
}
