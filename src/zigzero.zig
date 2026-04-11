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

pub const version = @import("build").version;
pub const name = @import("build").name;

// Core modules
pub const api = @import("api");
pub const rpc = @import("rpc");
pub const config = @import("config");
pub const log = @import("log");
pub const breaker = @import("breaker");
pub const limiter = @import("limiter");
pub const loadbalancer = @import("loadbalancer");
pub const redis = @import("redis");
pub const errors = @import("errors");
pub const middleware = @import("middleware");

test "zigzero version" {
    try std.testing.expectEqual(@as(u32, 0), version.major);
    try std.testing.expectEqual(@as(u32, 1), version.minor);
}
