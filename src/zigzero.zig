//! zigzero - Zero-cost microservice framework for Zig
//!
//! This framework is aligned with go-zero patterns, providing:
//! - API server (HTTP)
//! - RPC framework
//! - Configuration management
//! - Logging
//! - Circuit breaker
//! - Rate limiter
//! - Load balancer
//! - Redis client
//! - And more...

const std = @import("std");

pub const version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };
pub const name = "zigzero";

// Core modules
pub const api = @import("api.zig");
pub const rpc = @import("rpc.zig");
pub const config = @import("config.zig");
pub const log = @import("log.zig");
pub const breaker = @import("breaker.zig");
pub const limiter = @import("limiter.zig");
pub const loadbalancer = @import("loadbalancer.zig");
pub const redis = @import("redis.zig");
pub const errors = @import("errors.zig");
pub const middleware = @import("middleware.zig");
pub const svc = @import("svc.zig");
pub const trace = @import("trace.zig");
pub const metric = @import("metric.zig");
pub const orm = @import("orm.zig");

test "zigzero version" {
    try std.testing.expectEqual(@as(u32, 0), version.major);
    try std.testing.expectEqual(@as(u32, 1), version.minor);
}

comptime {
    _ = api.Server;
    _ = rpc.Client;
    _ = config.Config;
    _ = log.Logger;
    _ = breaker.CircuitBreaker;
    _ = limiter.TokenBucket;
    _ = loadbalancer.LoadBalancer;
    _ = redis.Redis;
    _ = errors.Error;
    _ = middleware.jwt;
    _ = svc.Context;
    _ = trace.Tracer;
    _ = metric.Registry;
    _ = orm.Pool;
}
