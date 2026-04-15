//! chy3 — Prometheus metrics infrastructure
//!
//! Initializes and owns all metric entities.
//! The registry lives in AppContext; this module creates the specific
//! metrics used by each domain.

const std = @import("std");
const zigzero = @import("zigzero");
const metric = zigzero.metric;

pub const Metrics = struct {
    http_requests: metric.Counter,
    worlds_gauge: metric.Gauge,
    npcs_gauge: metric.Gauge,
    quests_gauge: metric.Gauge,
    request_duration: metric.Histogram,
};

/// Initialize all chy3 metrics. Caller owns the returned struct.
pub fn init(registry: *metric.Registry, allocator: std.mem.Allocator) !Metrics {
    _ = allocator;
    return .{
        .http_requests = try registry.counter(
            "chy3_http_requests_total",
            "Total HTTP requests",
        ),
        .worlds_gauge = try registry.gauge(
            "chy3_active_worlds",
            "Active metaverse worlds",
        ),
        .npcs_gauge = try registry.gauge(
            "chy3_total_npcs",
            "Total NPCs spawned",
        ),
        .quests_gauge = try registry.gauge(
            "chy3_active_quests",
            "Active quests",
        ),
        .request_duration = try registry.histogram(
            "chy3_request_duration_ms",
            "Request duration in milliseconds",
            &.{},
        ),
    };
}
