//! Service discovery for zigzero
//!
//! Provides service discovery patterns aligned with go-zero's discovery.

const std = @import("std");
const errors = @import("../core/errors.zig");
const loadbalancer = @import("loadbalancer.zig");
const etcd = @import("etcd.zig");
const compat = @import("../compat.zig");

/// Service node
pub const Node = struct {
    id: []const u8,
    address: []const u8,
    weight: u32 = 1,
    metadata: std.StringHashMap([]const u8),
    is_healthy: bool = true,

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.address);
        var iter = self.metadata.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.metadata.deinit();
    }
};

/// Service instance list
pub const Instance = struct {
    nodes: []Node,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Instance) void {
        for (self.nodes) |*node| {
            node.deinit(self.allocator);
        }
        self.allocator.free(self.nodes);
    }
};

/// Static service discovery (for simple setups)
pub const StaticDiscovery = struct {
    allocator: std.mem.Allocator,
    services: std.StringHashMap([]Node),

    pub fn init(allocator: std.mem.Allocator) StaticDiscovery {
        return .{
            .allocator = allocator,
            .services = std.StringHashMap([]Node).init(allocator),
        };
    }

    pub fn deinit(self: *StaticDiscovery) void {
        var iter = self.services.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.*) |*node| {
                node.deinit(self.allocator);
            }
            self.allocator.free(entry.value_ptr.*);
        }
        self.services.deinit();
    }

    /// Register static nodes for a service
    pub fn register(self: *StaticDiscovery, service_name: []const u8, nodes: []const Node) !void {
        const copy = try self.allocator.alloc(Node, nodes.len);
        for (nodes, 0..) |node, i| {
            copy[i] = .{
                .id = try self.allocator.dupe(u8, node.id),
                .address = try self.allocator.dupe(u8, node.address),
                .weight = node.weight,
                .metadata = std.StringHashMap([]const u8).init(self.allocator),
                .is_healthy = node.is_healthy,
            };
        }
        try self.services.put(try self.allocator.dupe(u8, service_name), copy);
    }

    /// Get nodes for a service
    pub fn getNodes(self: *StaticDiscovery, service_name: []const u8) ?[]Node {
        return self.services.get(service_name);
    }

    /// Build a load balancer for a service
    pub fn loadBalancer(self: *StaticDiscovery, service_name: []const u8) ?loadbalancer.LoadBalancer {
        const nodes = self.services.get(service_name) orelse return null;

        var lb = loadbalancer.LoadBalancer.init(self.allocator, .round_robin);
        for (nodes) |node| {
            lb.addEndpoint(node.address);
        }
        return lb;
    }
};

/// etcd-based service discovery
pub const EtcdDiscovery = struct {
    allocator: std.mem.Allocator,
    etcd: etcd.Client,
    lease_id: i64,
    keepalive_running: std.atomic.Value(bool),
    keepalive_thread: ?std.Thread = null,
    registered: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator, etcd_endpoint: []const u8, ttl: i64) !EtcdDiscovery {
        var client = try etcd.Client.init(allocator, etcd_endpoint);
        errdefer client.deinit();

        const lease_id = try client.leaseGrant(ttl);

        var self = EtcdDiscovery{
            .allocator = allocator,
            .etcd = client,
            .lease_id = lease_id,
            .keepalive_running = std.atomic.Value(bool).init(true),
            .keepalive_thread = null,
            .registered = std.StringHashMap(void).init(allocator),
        };

        self.keepalive_thread = try std.Thread.spawn(.{}, keepAliveLoop, .{ &self, ttl });
        return self;
    }

    pub fn deinit(self: *EtcdDiscovery) void {
        self.keepalive_running.store(false, .monotonic);
        if (self.keepalive_thread) |t| t.join();

        var iter = self.registered.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.registered.deinit();
        self.etcd.deinit();
    }

    /// Register a node for a service
    pub fn register(self: *EtcdDiscovery, service_name: []const u8, node: Node) !void {
        const key = try std.fmt.allocPrint(self.allocator, "/etcd-registry/{s}/{s}", .{ service_name, node.id });
        defer self.allocator.free(key);

        const value = try std.json.valueAlloc(self.allocator, .{
            .id = node.id,
            .address = node.address,
            .weight = node.weight,
            .is_healthy = node.is_healthy,
        }, .{});
        defer self.allocator.free(value);

        try self.etcd.put(key, value, self.lease_id);

        const name_copy = try self.allocator.dupe(u8, service_name);
        try self.registered.put(name_copy, {});
    }

    /// Deregister a node
    pub fn deregister(self: *EtcdDiscovery, service_name: []const u8, node_id: []const u8) !void {
        const key = try std.fmt.allocPrint(self.allocator, "/etcd-registry/{s}/{s}", .{ service_name, node_id });
        defer self.allocator.free(key);
        try self.etcd.delete(key);
    }

    /// Get nodes for a service
    pub fn getNodes(self: *EtcdDiscovery, service_name: []const u8) !?[]Node {
        const prefix = try std.fmt.allocPrint(self.allocator, "/etcd-registry/{s}/", .{service_name});
        defer self.allocator.free(prefix);

        var kvs = try self.etcd.getPrefix(prefix);
        defer {
            for (kvs.items) |*kv| kv.deinit(self.etcd.allocator);
            kvs.deinit();
        }

        if (kvs.items.len == 0) return null;

        var nodes = try self.allocator.alloc(Node, kvs.items.len);
        errdefer {
            for (nodes) |*n| n.deinit(self.allocator);
            self.allocator.free(nodes);
        }

        for (kvs.items, 0..) |kv, i| {
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, kv.value, .{}) catch {
                nodes[i] = .{
                    .id = try self.allocator.dupe(u8, "unknown"),
                    .address = try self.allocator.dupe(u8, "unknown"),
                    .weight = 1,
                    .metadata = std.StringHashMap([]const u8).init(self.allocator),
                    .is_healthy = true,
                };
                continue;
            };
            defer parsed.deinit();

            const id = if (parsed.value.object.get("id")) |v| if (v == .string) v.string else "unknown" else "unknown";
            const address = if (parsed.value.object.get("address")) |v| if (v == .string) v.string else "unknown" else "unknown";
            const weight = if (parsed.value.object.get("weight")) |v| switch (v) {
                .integer => @as(u32, @intCast(v.integer)),
                else => 1,
            } else 1;
            const is_healthy = if (parsed.value.object.get("is_healthy")) |v| switch (v) {
                .bool => v.bool,
                else => true,
            } else true;

            nodes[i] = .{
                .id = try self.allocator.dupe(u8, id),
                .address = try self.allocator.dupe(u8, address),
                .weight = weight,
                .metadata = std.StringHashMap([]const u8).init(self.allocator),
                .is_healthy = is_healthy,
            };
        }

        return nodes;
    }

    /// Build a load balancer for a service
    pub fn loadBalancer(self: *EtcdDiscovery, service_name: []const u8) !?loadbalancer.LoadBalancer {
        const nodes = try self.getNodes(service_name) orelse return null;
        defer {
            for (nodes) |*n| n.deinit(self.allocator);
            self.allocator.free(nodes);
        }

        var lb = loadbalancer.LoadBalancer.init(self.allocator, .round_robin);
        for (nodes) |node| {
            lb.addEndpoint(node.address);
        }
        return lb;
    }

    fn keepAliveLoop(self: *EtcdDiscovery, ttl: i64) void {
        const interval_ms = @max(1000, @as(u64, @intCast(ttl)) * 1000 / 3);
        while (self.keepalive_running.load(.monotonic)) {
            self.etcd.keepAlive(self.lease_id) catch {};
            compat.sleep(interval_ms * std.time.ns_per_ms);
        }
    }
};

test "static discovery" {
    var discovery = StaticDiscovery.init(std.testing.allocator);
    defer discovery.deinit();

    const nodes = &[_]Node{
        .{ .id = "node1", .address = "127.0.0.1:8080", .metadata = std.StringHashMap([]const u8).init(std.testing.allocator) },
        .{ .id = "node2", .address = "127.0.0.1:8081", .metadata = std.StringHashMap([]const u8).init(std.testing.allocator) },
    };

    try discovery.register("user-service", nodes);

    const found = discovery.getNodes("user-service").?;
    try std.testing.expectEqual(@as(usize, 2), found.len);
}
