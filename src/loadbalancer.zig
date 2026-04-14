//! Load balancer implementation for zigzero
//!
//! Provides various load balancing strategies aligned with go-zero's loadbalance.

const std = @import("std");

/// Load balancer algorithm type
pub const Algorithm = enum {
    round_robin, // Round robin selection
    random, // Random selection
    weighted_round_robin, // Weighted round robin
    least_connection, // Least connections
    ip_hash, // Hash by client IP
};

/// Service endpoint
pub const Endpoint = struct {
    address: []const u8,
    weight: u32 = 1,
    connections: u32 = 0,
    is_healthy: bool = true,
};

/// Load balancer interface
pub const LoadBalancer = struct {
    allocator: ?std.mem.Allocator = null,
    algorithm: Algorithm,
    endpoints: std.ArrayList(Endpoint),
    current_index: u32 = 0,

    /// Create a new load balancer
    pub fn new(algorithm: Algorithm) LoadBalancer {
        return LoadBalancer{
            .algorithm = algorithm,
            .endpoints = .{},
            .current_index = 0,
        };
    }

    pub fn init(allocator: std.mem.Allocator, algorithm: Algorithm) LoadBalancer {
        return LoadBalancer{
            .allocator = allocator,
            .algorithm = algorithm,
            .endpoints = .{},
            .current_index = 0,
        };
    }

    pub fn deinit(self: *LoadBalancer) void {
        if (self.allocator) |a| {
            self.endpoints.deinit(a);
        }
    }

    /// Add an endpoint
    pub fn addEndpoint(self: *LoadBalancer, address: []const u8) void {
        if (self.allocator) |a| {
            self.endpoints.append(a, .{ .address = address }) catch return;
        }
    }

    /// Get count of healthy endpoints
    fn healthyCount(self: *const LoadBalancer) usize {
        var count: usize = 0;
        for (self.endpoints.items) |ep| {
            if (ep.is_healthy) count += 1;
        }
        return count;
    }

    /// Select an endpoint based on the algorithm
    pub fn select(self: *LoadBalancer) ?*Endpoint {
        if (self.endpoints.items.len == 0) return null;
        if (self.healthyCount() == 0) return null;

        return switch (self.algorithm) {
            .round_robin => self.selectRoundRobin(),
            .random => self.selectRandom(),
            .weighted_round_robin => self.selectWeightedRoundRobin(),
            .least_connection => self.selectLeastConnection(),
            .ip_hash => self.selectByIpHash(""),
        };
    }

    /// Select endpoint by IP hash
    pub fn selectForIp(self: *LoadBalancer, ip: []const u8) ?*Endpoint {
        if (self.endpoints.items.len == 0) return null;
        if (self.healthyCount() == 0) return null;
        return self.selectByIpHash(ip);
    }

    fn selectRoundRobin(self: *LoadBalancer) ?*Endpoint {
        const healthy_total = self.healthyCount();
        if (healthy_total == 0) return null;

        var healthy_seen: u32 = 0;
        const target_idx = self.current_index % healthy_total;
        self.current_index += 1;

        for (self.endpoints.items) |*ep| {
            if (!ep.is_healthy) continue;
            if (healthy_seen == target_idx) return ep;
            healthy_seen += 1;
        }
        return null;
    }

    fn selectRandom(self: *LoadBalancer) ?*Endpoint {
        const healthy_total = self.healthyCount();
        if (healthy_total == 0) return null;

        const seed = @as(u64, @intCast(std.time.timestamp()));
        var rng = std.Random.DefaultPrng.init(seed);
        const target_idx = rng.random().uintLessThan(u32, @as(u32, @intCast(healthy_total)));

        var healthy_seen: u32 = 0;
        for (self.endpoints.items) |*ep| {
            if (!ep.is_healthy) continue;
            if (healthy_seen == target_idx) return ep;
            healthy_seen += 1;
        }
        return null;
    }

    fn selectWeightedRoundRobin(self: *LoadBalancer) ?*Endpoint {
        // Simplified weighted round robin
        for (self.endpoints.items) |*ep| {
            if (!ep.is_healthy) continue;
            if (ep.weight > 0) {
                ep.weight -= 1;
                return ep;
            }
        }
        // Reset weights
        for (self.endpoints.items) |*ep| {
            if (!ep.is_healthy) continue;
            ep.weight = if (ep.weight == 0) 1 else ep.weight;
        }
        return self.selectWeightedRoundRobin();
    }

    fn selectLeastConnection(self: *LoadBalancer) ?*Endpoint {
        var min_connections: u32 = std.math.maxInt(u32);
        var selected: ?*Endpoint = null;

        for (self.endpoints.items) |*ep| {
            if (!ep.is_healthy) continue;
            if (ep.connections < min_connections) {
                min_connections = ep.connections;
                selected = ep;
            }
        }
        if (selected) |s| {
            s.connections += 1;
        }
        return selected;
    }

    fn selectByIpHash(self: *LoadBalancer, ip: []const u8) ?*Endpoint {
        const healthy_total = self.healthyCount();
        if (healthy_total == 0) return null;

        var hash: u32 = 0;
        for (ip) |c| {
            hash = hash *% 31 +% @as(u32, c);
        }

        const target_idx = @as(u32, hash) % @as(u32, @intCast(healthy_total));
        var healthy_seen: u32 = 0;
        for (self.endpoints.items) |*ep| {
            if (!ep.is_healthy) continue;
            if (healthy_seen == target_idx) return ep;
            healthy_seen += 1;
        }
        return null;
    }

    /// Record connection closed (for least_connection)
    pub fn recordConnectionClosed(self: *LoadBalancer, endpoint: *Endpoint) void {
        _ = self;
        if (endpoint.connections > 0) {
            endpoint.connections -= 1;
        }
    }
};

test "load balancer" {
    var lb = LoadBalancer.init(std.testing.allocator, .round_robin);
    defer lb.deinit();

    lb.addEndpoint("192.168.1.1:8080");
    lb.addEndpoint("192.168.1.2:8080");
    lb.addEndpoint("192.168.1.3:8080");

    try std.testing.expect(lb.select() != null);
    try std.testing.expect(lb.select() != null);
    try std.testing.expect(lb.select() != null);
}
