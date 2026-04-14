//! Service discovery for zigzero
//!
//! Provides service discovery patterns aligned with go-zero's discovery.

const std = @import("std");
const errors = @import("errors.zig");
const loadbalancer = @import("loadbalancer.zig");

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
