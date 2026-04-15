//! chy3 — Middleware chain setup
//!
//! Factory functions for global and per-route middleware slices.
//! All middleware is created once at startup and reused across requests.

const std = @import("std");
const zigzero = @import("zigzero");
const api = zigzero.api;
const middleware = zigzero.middleware;
const metric = zigzero.metric;
const limiter = zigzero.limiter;
const load = zigzero.load;
const health = zigzero.health;

/// Global middleware applied to every request.
/// Caller must deallocate the returned slice.
pub fn globalMiddleware(
    allocator: std.mem.Allocator,
    registry: *metric.Registry,
    ip_limiter: *limiter.IpLimiter,
    shedder: *load.AdaptiveShedder,
) ![]const api.Middleware {
    const cors_mw = try middleware.cors(allocator, .{ .max_age = 86400 });
    const mws = [_]api.Middleware{
        middleware.requestId(),
        middleware.logging(),
        cors_mw,
        middleware.observability(registry),
        middleware.loadShedding(shedder),
        middleware.rateLimitByIp(ip_limiter),
    };
    return try allocator.dupe(api.Middleware, &mws);
}

/// Per-route middleware for JWT-protected asset minting (large body).
pub fn mintAssetMiddleware(allocator: std.mem.Allocator) ![]const api.Middleware {
    const mws = [_]api.Middleware{
        try middleware.jwt(allocator, "chy3-secret-key"),
        try middleware.maxBodySize(allocator, 1024 * 1024 * 10),
    };
    return try allocator.dupe(api.Middleware, &mws);
}

/// Per-route middleware for JWT-protected world creation.
pub fn worldCreateMiddleware(allocator: std.mem.Allocator) ![]const api.Middleware {
    const mws = [_]api.Middleware{try middleware.jwt(allocator, "chy3-secret-key")};
    return try allocator.dupe(api.Middleware, &mws);
}

/// Per-route middleware for JWT-protected NPC spawning.
pub fn npcSpawnMiddleware(allocator: std.mem.Allocator) ![]const api.Middleware {
    const mws = [_]api.Middleware{try middleware.jwt(allocator, "chy3-secret-key")};
    return try allocator.dupe(api.Middleware, &mws);
}

/// Per-route middleware for event triggering (public).
pub fn eventTriggerMiddleware() []const api.Middleware {
    return &.{};
}

/// Per-route middleware for JWT-protected quest issuance.
pub fn questIssueMiddleware(allocator: std.mem.Allocator) ![]const api.Middleware {
    const mws = [_]api.Middleware{try middleware.jwt(allocator, "chy3-secret-key")};
    return try allocator.dupe(api.Middleware, &mws);
}

/// Per-route middleware for JWT-protected subscriptions.
pub fn subscribeMiddleware(allocator: std.mem.Allocator) ![]const api.Middleware {
    const mws = [_]api.Middleware{try middleware.jwt(allocator, "chy3-secret-key")};
    return try allocator.dupe(api.Middleware, &mws);
}

/// Per-route middleware for problem submission (body size limit).
pub fn problemSubmitMiddleware(allocator: std.mem.Allocator) ![]const api.Middleware {
    const mws = [_]api.Middleware{try middleware.maxBodySize(allocator, 1024 * 64)};
    return try allocator.dupe(api.Middleware, &mws);
}

/// Health check user data — pointer to health registry.
pub fn healthUserData(registry: *health.Registry) *health.Registry {
    return registry;
}

/// Prometheus metrics user data — pointer to metric registry.
pub fn metricsUserData(registry: *metric.Registry) *metric.Registry {
    return registry;
}
