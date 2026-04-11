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
    algorithm: Algorithm,
    endpoints: []Endpoint,
    current_index: u32 = 0,

    /// Create a new load balancer
    pub fn new(algorithm: Algorithm) LoadBalancer {
        return LoadBalancer{
            .algorithm = algorithm,
            .endpoints = &.{},
            .current_index = 0,
        };
    }

    /// Add an endpoint
    pub fn addEndpoint(self: *LoadBalancer, address: []const u8) void {
        const endpoint = Endpoint{ .address = address };
        self.endpoints = self.endpoints ++ .{endpoint};
    }

    /// Select an endpoint based on the algorithm
    pub fn select(self: *LoadBalancer) ?*Endpoint {
        if (self.endpoints.len == 0) return null;

        const healthy = self.getHealthyEndpoints();
        if (healthy.len == 0) return null;

        return switch (self.algorithm) {
            .round_robin => self.selectRoundRobin(healthy),
            .random => self.selectRandom(healthy),
            .weighted_round_robin => self.selectWeightedRoundRobin(healthy),
            .least_connection => self.selectLeastConnection(healthy),
            .ip_hash => self.selectByIpHash(healthy, ""),
        };
    }

    /// Select endpoint by IP hash
    pub fn selectForIp(self: *LoadBalancer, ip: []const u8) ?*Endpoint {
        const healthy = self.getHealthyEndpoints();
        if (healthy.len == 0) return null;
        return self.selectByIpHash(healthy, ip);
    }

    fn getHealthyEndpoints(self: *const LoadBalancer) []Endpoint {
        var result: []Endpoint = &.{};
        for (self.endpoints) |ep| {
            if (ep.is_healthy) {
                result = result ++ .{ep};
            }
        }
        return result;
    }

    fn selectRoundRobin(self: *LoadBalancer, endpoints: []Endpoint) *Endpoint {
        const idx = self.current_index % @as(u32, @intCast(endpoints.len));
        self.current_index += 1;
        return &endpoints[idx];
    }

    fn selectRandom(self: *LoadBalancer, endpoints: []Endpoint) *Endpoint {
        const seed = @as(u64, @intCast(std.time.timestamp()));
        var rng = std.Random.DefaultPrng.init(seed);
        const idx = rng.random().uintLessThan(u32, @as(u32, @intCast(endpoints.len)));
        return &endpoints[idx];
    }

    fn selectWeightedRoundRobin(self: *LoadBalancer, endpoints: []Endpoint) *Endpoint {
        // Simplified weighted round robin
        for (endpoints) |*ep| {
            if (ep.weight > 0) {
                ep.weight -= 1;
                return ep;
            }
        }
        // Reset weights
        for (endpoints) |*ep| {
            ep.weight = if (ep.weight == 0) 1 else ep.weight;
        }
        return &endpoints[0];
    }

    fn selectLeastConnection(self: *LoadBalancer, endpoints: []Endpoint) *Endpoint {
        var min_connections: u32 = std.math.maxInt(u32);
        var selected: *Endpoint = &endpoints[0];

        for (endpoints) |*ep| {
            if (ep.connections < min_connections) {
                min_connections = ep.connections;
                selected = ep;
            }
        }
        selected.connections += 1;
        return selected;
    }

    fn selectByIpHash(self: *LoadBalancer, endpoints: []Endpoint, ip: []const u8) *Endpoint {
        var hash: u32 = 0;
        for (ip) |c| {
            hash = hash *% 31 +% @as(u32, c);
        }
        return &endpoints[@as(usize, hash) % endpoints.len];
    }

    /// Record connection closed (for least_connection)
    pub fn recordConnectionClosed(self: *LoadBalancer, endpoint: *Endpoint) void {
        if (endpoint.connections > 0) {
            endpoint.connections -= 1;
        }
    }
};

test "load balancer" {
    var lb = LoadBalancer.new(.round_robin);
    lb.addEndpoint("192.168.1.1:8080");
    lb.addEndpoint("192.168.1.2:8080");
    lb.addEndpoint("192.168.1.3:8080");

    try std.testing.expect(lb.select() != null);
    try std.testing.expect(lb.select() != null);
    try std.testing.expect(lb.select() != null);
}
