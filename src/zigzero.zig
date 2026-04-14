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

// Core
pub const errors = @import("core/errors.zig");
pub const fx = @import("core/fx.zig");
pub const threading = @import("core/threading.zig");
pub const mapreduce = @import("core/mapreduce.zig");
pub const hash = @import("core/hash.zig");
pub const codec = @import("core/codec.zig");
pub const load = @import("core/load.zig");

// Network
pub const api = @import("net/api.zig");
pub const http = @import("net/http.zig");
pub const rpc = @import("net/rpc.zig");
pub const websocket = @import("net/websocket.zig");
pub const tls = @import("net/tls.zig");

// Server
pub const static = @import("server/static.zig");
pub const middleware = @import("server/middleware.zig");

// Infrastructure
pub const log = @import("infra/log.zig");
pub const redis = @import("infra/redis.zig");
pub const pool = @import("infra/pool.zig");
pub const cache = @import("infra/cache.zig");
pub const mq = @import("infra/mq.zig");
pub const cron = @import("infra/cron.zig");
pub const lifecycle = @import("infra/lifecycle.zig");
pub const health = @import("infra/health.zig");
pub const discovery = @import("infra/discovery.zig");
pub const lock = @import("infra/lock.zig");
pub const trace = @import("infra/trace.zig");
pub const metric = @import("infra/metric.zig");
pub const retry = @import("infra/retry.zig");
pub const sqlx = @import("infra/sqlx.zig");
pub const loadbalancer = @import("infra/loadbalancer.zig");
pub const breaker = @import("infra/breaker.zig");
pub const limiter = @import("infra/limiter.zig");

// Data
pub const orm = @import("data/orm.zig");
pub const validate = @import("data/validate.zig");

// Config & Service
pub const config = @import("config.zig");
pub const svc = @import("svc.zig");

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
    _ = fx.Stream(u8);
    _ = threading.RoutineGroup;
    _ = mapreduce.MapReduce(u8, u8);
    _ = hash.ConsistentHash;
    _ = codec.Base64;
    _ = load.AdaptiveShedder;
    _ = middleware.jwt;
    _ = svc.Context;
    _ = trace.Tracer;
    _ = metric.Registry;
    _ = orm.Pool;
    _ = health.Registry;
    _ = discovery.StaticDiscovery;
    _ = lock.Lock;
    _ = lifecycle.Manager;
    _ = tls.Config;
    _ = retry.Policy;
    _ = sqlx.Client;
    _ = websocket.Conn;
    _ = static.Server;
    _ = cron.Scheduler;
    _ = mq.Queue;
}
