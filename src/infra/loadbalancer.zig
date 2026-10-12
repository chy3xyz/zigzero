//! Load balancer implementation for zigzero
//!
//! Provides various load balancing strategies aligned with go-zero's loadbalance.

const std = @import("std");
const compat = @import("../compat.zig");
const hash = @import("../core/hash.zig");

/// Virtual nodes per endpoint on the consistent-hash ring. More replicas give
/// a more even ring at the cost of a larger, slower-to-build ring; 300 keeps
/// the per-node share close to the ideal with a few hundred vnodes per node.
const consistent_hash_replicas: u32 = 300;

/// Load balancer algorithm type
pub const Algorithm = enum {
    round_robin, // Round robin selection
    random, // Random selection
    weighted_round_robin, // Weighted round robin
    least_connection, // Least connections
    ip_hash, // Hash by client IP
    consistent_hash, // Consistent hashing
};

/// Service endpoint
pub const Endpoint = struct {
    address: []const u8,
    weight: u32 = 1,
    connections: u32 = 0,
    is_healthy: bool = true,

    /// Running weight used by smooth weighted round-robin; internal state.
    current_weight: i64 = 0,
};

/// Load balancer interface
pub const LoadBalancer = struct {
    allocator: ?std.mem.Allocator = null,
    algorithm: Algorithm,
    endpoints: std.ArrayList(Endpoint),
    current_index: u32 = 0,
    /// Consistent-hash ring over the healthy endpoints. Built lazily on the
    /// first consistent-hash lookup and rebuilt whenever the healthy endpoint
    /// set changes. Only used when an allocator is available.
    ring: ?hash.ConsistentHash = null,
    ring_signature: u64 = 0,

    /// Create a new load balancer
    pub fn new(algorithm: Algorithm) LoadBalancer {
        return LoadBalancer{
            .algorithm = algorithm,
            .endpoints = .empty,
            .current_index = 0,
        };
    }

    pub fn init(allocator: std.mem.Allocator, algorithm: Algorithm) LoadBalancer {
        return LoadBalancer{
            .allocator = allocator,
            .algorithm = algorithm,
            .endpoints = .empty,
            .current_index = 0,
        };
    }

    pub fn deinit(self: *LoadBalancer) void {
        if (self.allocator) |a| {
            if (self.ring) |*ring| ring.deinit();
            self.ring = null;
            self.endpoints.deinit(a);
        }
    }

    /// Add an endpoint
    pub fn addEndpoint(self: *LoadBalancer, address: []const u8) void {
        if (self.allocator) |a| {
            self.endpoints.append(a, .{ .address = address }) catch return;
        }
    }

    /// Add an endpoint with an explicit weight
    pub fn addEndpointWithWeight(self: *LoadBalancer, address: []const u8, weight: u32) void {
        if (self.allocator) |a| {
            self.endpoints.append(a, .{ .address = address, .weight = weight }) catch return;
        }
    }

    /// Remove the first endpoint matching `address`; returns true when removed
    pub fn removeEndpoint(self: *LoadBalancer, address: []const u8) bool {
        var i: usize = 0;
        while (i < self.endpoints.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.endpoints.items[i].address, address)) {
                _ = self.endpoints.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Get count of healthy endpoints
    fn healthyCount(self: *const LoadBalancer) usize {
        var count: usize = 0;
        for (self.endpoints.items) |ep| {
            if (ep.is_healthy) count += 1;
        }
        return count;
    }

    /// Select an endpoint, using the algorithm configured on the balancer.
    ///
    /// The hash-based algorithms (`.ip_hash`, `.consistent_hash`) need a client
    /// key to be meaningful; prefer `selectWithKey` for those. This entry point
    /// keeps the previous behaviour and hashes an empty key.
    pub fn select(self: *LoadBalancer) ?*Endpoint {
        return self.selectWithKey("");
    }

    /// Select an endpoint for an explicit client key (client IP, request id, ...).
    /// The key is ignored by the key-agnostic algorithms.
    pub fn selectWithKey(self: *LoadBalancer, key: []const u8) ?*Endpoint {
        if (self.endpoints.items.len == 0) return null;
        if (self.healthyCount() == 0) return null;

        return switch (self.algorithm) {
            .round_robin => self.selectRoundRobin(),
            .random => self.selectRandom(),
            .weighted_round_robin => self.selectWeightedRoundRobin(),
            .least_connection => self.selectLeastConnection(),
            .ip_hash => self.selectByIpHash(key),
            .consistent_hash => self.selectConsistentHash(key),
        };
    }

    /// Select endpoint by IP hash
    pub fn selectForIp(self: *LoadBalancer, ip: []const u8) ?*Endpoint {
        if (self.endpoints.items.len == 0) return null;
        if (self.healthyCount() == 0) return null;
        return self.selectByIpHash(ip);
    }

    /// Select endpoint by consistent hash for a given key
    pub fn selectForKey(self: *LoadBalancer, key: []const u8) ?*Endpoint {
        if (self.endpoints.items.len == 0) return null;
        if (self.healthyCount() == 0) return null;
        return self.selectConsistentHash(key);
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

        const seed = @as(u64, @intCast(compat.timestamp()));
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
        // Smooth weighted round-robin (nginx style): every healthy endpoint
        // accumulates its configured weight, the largest running weight wins,
        // and the winner is reduced by the total weight. Over one full cycle of
        // `total_weight` picks each endpoint is chosen exactly `weight` times,
        // and the configured weights themselves are never modified.
        var total_weight: i64 = 0;
        for (self.endpoints.items) |ep| {
            if (!ep.is_healthy) continue;
            if (ep.weight == 0) continue;
            total_weight += ep.weight;
        }
        if (total_weight == 0) return self.selectRoundRobin();

        var selected: ?*Endpoint = null;
        var best: i64 = std.math.minInt(i64);
        for (self.endpoints.items) |*ep| {
            if (!ep.is_healthy) continue;
            if (ep.weight == 0) continue;
            ep.current_weight += ep.weight;
            if (selected == null or ep.current_weight > best) {
                best = ep.current_weight;
                selected = ep;
            }
        }

        if (selected) |ep| {
            ep.current_weight -= total_weight;
        }
        return selected;
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

        const key_hash = hash.fnv1a(ip);
        const target_idx = key_hash % @as(u32, @intCast(healthy_total));
        var healthy_seen: u32 = 0;
        for (self.endpoints.items) |*ep| {
            if (!ep.is_healthy) continue;
            if (healthy_seen == target_idx) return ep;
            healthy_seen += 1;
        }
        return null;
    }

    fn selectConsistentHash(self: *LoadBalancer, key: []const u8) ?*Endpoint {
        if (self.healthyCount() == 0) return null;

        // Consistent hashing needs the ring, and the ring needs an allocator.
        if (self.allocator == null) return null;

        if (!self.refreshRing()) return null;
        const ring = if (self.ring) |*ring| ring else return null;
        const address = ring.get(key) orelse return null;

        for (self.endpoints.items) |*ep| {
            if (!ep.is_healthy) continue;
            if (std.mem.eql(u8, ep.address, address)) return ep;
        }
        return null;
    }

    /// Rebuild the ring when the healthy endpoint set changed.
    fn refreshRing(self: *LoadBalancer) bool {
        const signature = self.ringSignatureValue();
        if (self.ring != null and self.ring_signature == signature) return true;

        if (self.ring) |*old| old.deinit();
        self.ring = null;

        const allocator = self.allocator orelse return false;
        var ring = hash.ConsistentHash.init(allocator, consistent_hash_replicas);
        for (self.endpoints.items) |ep| {
            if (!ep.is_healthy) continue;
            ring.add(ep.address) catch {
                ring.deinit();
                return false;
            };
        }

        self.ring = ring;
        self.ring_signature = signature;
        return true;
    }

    /// Cheap fingerprint of the healthy endpoint set, used to invalidate the ring.
    fn ringSignatureValue(self: *const LoadBalancer) u64 {
        var signature: u64 = 1469598103934665603;
        for (self.endpoints.items) |ep| {
            if (!ep.is_healthy) continue;
            signature = signature *% 31 +% hash.fnv1a(ep.address);
        }
        return signature;
    }

    /// Record connection closed (for least_connection)
    pub fn recordConnectionClosed(self: *LoadBalancer, endpoint: *Endpoint) void {
        _ = self;
        if (endpoint.connections > 0) {
            endpoint.connections -= 1;
        }
    }
};

test "round robin distributes evenly across the pool" {
    var lb = LoadBalancer.init(std.testing.allocator, .round_robin);
    defer lb.deinit();

    lb.addEndpoint("192.168.1.1:8080");
    lb.addEndpoint("192.168.1.2:8080");
    lb.addEndpoint("192.168.1.3:8080");

    var counts = [_]usize{ 0, 0, 0 };
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        const ep = lb.select() orelse return error.NoEndpoint;
        counts[endpointIndex(&lb, ep)] += 1;
    }

    try std.testing.expectEqual(@as(usize, 3), counts[0]);
    try std.testing.expectEqual(@as(usize, 3), counts[1]);
    try std.testing.expectEqual(@as(usize, 3), counts[2]);
}

test "least connection picks the idle endpoint and releases it" {
    var lb = LoadBalancer.init(std.testing.allocator, .least_connection);
    defer lb.deinit();

    lb.addEndpoint("node-a");
    lb.addEndpoint("node-b");

    const first = lb.select() orelse return error.NoEndpoint;
    try std.testing.expectEqual(@as(u32, 1), first.connections);

    const second = lb.select() orelse return error.NoEndpoint;
    try std.testing.expectEqualStrings("node-b", second.address);
    try std.testing.expectEqual(@as(u32, 1), second.connections);

    lb.recordConnectionClosed(first);
    try std.testing.expectEqual(@as(u32, 0), first.connections);
}

test "weighted round robin follows the configured weights" {
    var lb = LoadBalancer.init(std.testing.allocator, .weighted_round_robin);
    defer lb.deinit();

    lb.addEndpointWithWeight("node-a", 5);
    lb.addEndpointWithWeight("node-b", 2);
    lb.addEndpointWithWeight("node-c", 1);

    const picks: usize = 1000;
    var counts = [_]usize{ 0, 0, 0 };
    var i: usize = 0;
    while (i < picks) : (i += 1) {
        const ep = lb.select() orelse return error.NoEndpoint;
        counts[endpointIndex(&lb, ep)] += 1;
    }

    // weights 5:2:1 over 1000 picks -> 625:250:125
    const expected = [_]usize{ 625, 250, 125 };
    for (counts, expected) |got, want| {
        const diff = if (got > want) got - want else want - got;
        try std.testing.expect(diff * 100 <= want * 2);
    }

    // Selection must not consume the configured weights.
    try std.testing.expectEqual(@as(u32, 5), lb.endpoints.items[0].weight);
    try std.testing.expectEqual(@as(u32, 2), lb.endpoints.items[1].weight);
    try std.testing.expectEqual(@as(u32, 1), lb.endpoints.items[2].weight);

    // A second full run keeps the same distribution (weights were not degraded).
    var again = [_]usize{ 0, 0, 0 };
    i = 0;
    while (i < picks) : (i += 1) {
        const ep = lb.select() orelse return error.NoEndpoint;
        again[endpointIndex(&lb, ep)] += 1;
    }
    for (again, expected) |got, want| {
        const diff = if (got > want) got - want else want - got;
        try std.testing.expect(diff * 100 <= want * 2);
    }
}

test "consistent hash keeps a key on the same node" {
    var lb = LoadBalancer.init(std.testing.allocator, .consistent_hash);
    defer lb.deinit();

    lb.addEndpoint("node-1");
    lb.addEndpoint("node-2");
    lb.addEndpoint("node-3");

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "user-{d}", .{i});
        const first = lb.selectForKey(key) orelse return error.NoEndpoint;
        const second = lb.selectForKey(key) orelse return error.NoEndpoint;
        try std.testing.expectEqualStrings(first.address, second.address);
        try std.testing.expect(lb.removeEndpoint("does-not-exist") == false);
    }
}

test "consistent hash remaps few keys when a node is removed" {
    var lb = LoadBalancer.init(std.testing.allocator, .consistent_hash);
    defer lb.deinit();

    lb.addEndpoint("node-1");
    lb.addEndpoint("node-2");
    lb.addEndpoint("node-3");
    lb.addEndpoint("node-4");

    const total = 1000;
    var keys: [total][24]u8 = undefined;
    var before: [total][]const u8 = undefined;

    var i: usize = 0;
    while (i < total) : (i += 1) {
        const key = try std.fmt.bufPrint(&keys[i], "user-{d}", .{i});
        const ep = lb.selectForKey(key) orelse return error.NoEndpoint;
        before[i] = ep.address;
    }

    try std.testing.expect(lb.removeEndpoint("node-4"));

    var remapped: usize = 0;
    i = 0;
    while (i < total) : (i += 1) {
        const key = try std.fmt.bufPrint(&keys[i], "user-{d}", .{i});
        const ep = lb.selectForKey(key) orelse return error.NoEndpoint;
        if (!std.mem.eql(u8, ep.address, before[i])) remapped += 1;
    }

    // Removing 1 of 4 nodes must move roughly a quarter of the keys, and never
    // anything close to all of them.
    try std.testing.expect(remapped > 0);
    try std.testing.expect(remapped < total / 2);
    try std.testing.expect(remapped * 100 < total * 40);

    // Adding a node back has the same bounded effect.
    var after_removal: [total][]const u8 = undefined;
    i = 0;
    while (i < total) : (i += 1) {
        const key = try std.fmt.bufPrint(&keys[i], "user-{d}", .{i});
        after_removal[i] = (lb.selectForKey(key) orelse return error.NoEndpoint).address;
    }

    lb.addEndpoint("node-5");

    var reshuffled: usize = 0;
    i = 0;
    while (i < total) : (i += 1) {
        const key = try std.fmt.bufPrint(&keys[i], "user-{d}", .{i});
        const ep = lb.selectForKey(key) orelse return error.NoEndpoint;
        if (!std.mem.eql(u8, ep.address, after_removal[i])) reshuffled += 1;
    }
    try std.testing.expect(reshuffled > 0);
    try std.testing.expect(reshuffled < total / 2);
}

/// Index of `ep` inside the balancer's endpoint list.
fn endpointIndex(lb: *const LoadBalancer, ep: *const Endpoint) usize {
    for (lb.endpoints.items, 0..) |item, i| {
        if (std.mem.eql(u8, item.address, ep.address)) return i;
    }
    unreachable;
}
