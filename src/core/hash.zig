//! Hash utilities for zigzero
//!
//! Aligned with go-zero's core/hash package.

const std = @import("std");

/// Consistent hash ring
pub const ConsistentHash = struct {
    allocator: std.mem.Allocator,
    replicas: u32,
    nodes: std.ArrayList([]const u8),
    ring: std.ArrayList(u32),
    node_map: std.AutoHashMap(u32, []const u8),

    pub fn init(allocator: std.mem.Allocator, replicas: u32) ConsistentHash {
        return .{
            .allocator = allocator,
            .replicas = if (replicas == 0) 1 else replicas,
            .nodes = .{},
            .ring = .{},
            .node_map = std.AutoHashMap(u32, []const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ConsistentHash) void {
        for (self.nodes.items) |node| {
            self.allocator.free(node);
        }
        self.nodes.deinit(self.allocator);
        self.ring.deinit(self.allocator);
        self.node_map.deinit();
    }

    /// Add a node to the ring
    pub fn add(self: *ConsistentHash, node: []const u8) !void {
        const node_copy = try self.allocator.dupe(u8, node);
        try self.nodes.append(self.allocator, node_copy);

        var i: u32 = 0;
        while (i < self.replicas) : (i += 1) {
            const replica_key = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ node, i });
            defer self.allocator.free(replica_key);
            const hash = fnv1a(replica_key);

            try self.ring.append(self.allocator, hash);
            try self.node_map.put(hash, node_copy);
        }

        // Keep ring sorted
        const slice = self.ring.items;
        std.mem.sort(u32, slice, {}, comptime std.sort.asc(u32));
    }

    /// Remove a node from the ring
    pub fn remove(self: *ConsistentHash, node: []const u8) void {
        var i: usize = 0;
        while (i < self.nodes.items.len) {
            if (std.mem.eql(u8, self.nodes.items[i], node)) {
                self.allocator.free(self.nodes.items[i]);
                _ = self.nodes.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        // Rebuild ring
        self.ring.clearRetainingCapacity();
        self.node_map.clearRetainingCapacity();

        for (self.nodes.items) |n| {
            var r: u32 = 0;
            while (r < self.replicas) : (r += 1) {
                const replica_key = std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ n, r }) catch continue;
                defer self.allocator.free(replica_key);
                const hash = fnv1a(replica_key);

                self.ring.append(self.allocator, hash) catch continue;
                self.node_map.put(hash, n) catch continue;
            }
        }

        const slice = self.ring.items;
        std.mem.sort(u32, slice, {}, comptime std.sort.asc(u32));
    }

    /// Get the node for a given key
    pub fn get(self: *const ConsistentHash, key: []const u8) ?[]const u8 {
        if (self.ring.items.len == 0) return null;

        const hash = fnv1a(key);

        // Binary search for the first hash >= target
        const idx = binarySearch(self.ring.items, hash);
        const ring_idx = if (idx < self.ring.items.len) idx else 0;
        const node_hash = self.ring.items[ring_idx];
        return self.node_map.get(node_hash);
    }

    fn binarySearch(ring: []const u32, target: u32) usize {
        var left: usize = 0;
        var right = ring.len;
        while (left < right) {
            const mid = left + (right - left) / 2;
            if (ring[mid] < target) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        return left;
    }
};

/// FNV-1a 32-bit hash
pub fn fnv1a(input: []const u8) u32 {
    var hash: u32 = 2166136261;
    for (input) |c| {
        hash ^= c;
        hash *%= 16777619;
    }
    return hash;
}

/// MD5 hash (uses std.crypto.hash.Md5)
pub fn md5(input: []const u8) [16]u8 {
    var out: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(input, &out, .{});
    return out;
}

/// MurmurHash3 32-bit (simplified)
pub fn murmur3(input: []const u8, seed: u32) u32 {
    const c1: u32 = 0xcc9e2d47;
    const c2: u32 = 0x1b873593;
    const r1: u5 = 15;
    const r2: u5 = 13;
    const m: u32 = 5;
    const n: u32 = 0xe6546b64;

    var hash: u32 = seed;
    var i: usize = 0;

    // Process 4-byte chunks
    while (i + 4 <= input.len) : (i += 4) {
        var k: u32 = std.mem.readInt(u32, input[i..][0..4], .little);
        k *%= c1;
        k = std.math.rotl(u32, k, r1);
        k *%= c2;

        hash ^= k;
        hash = std.math.rotl(u32, hash, r2);
        hash = hash *% m +% n;
    }

    // Handle remainder
    var k: u32 = 0;
    const rem = input.len - i;
    if (rem >= 3) k ^= @as(u32, input[i + 2]) << 16;
    if (rem >= 2) k ^= @as(u32, input[i + 1]) << 8;
    if (rem >= 1) {
        k ^= @as(u32, input[i]);
        k *%= c1;
        k = std.math.rotl(u32, k, r1);
        k *%= c2;
        hash ^= k;
    }

    hash ^= @truncate(input.len);
    hash ^= hash >> 16;
    hash *%= 0x85ebca6b;
    hash ^= hash >> 13;
    hash *%= 0xc2b2ae35;
    hash ^= hash >> 16;

    return hash;
}

test "consistent hash" {
    var ch = ConsistentHash.init(std.testing.allocator, 150);
    defer ch.deinit();

    try ch.add("node1");
    try ch.add("node2");
    try ch.add("node3");

    const n1 = ch.get("user-123");
    try std.testing.expect(n1 != null);

    // Same key should map to same node
    const n2 = ch.get("user-123");
    try std.testing.expectEqualStrings(n1.?, n2.?);

    // Adding a node shouldn't change all mappings dramatically
    try ch.add("node4");
    const n3 = ch.get("user-123");
    try std.testing.expect(n3 != null);
}

test "fnv1a" {
    try std.testing.expect(fnv1a("hello") == fnv1a("hello"));
    try std.testing.expect(fnv1a("hello") != fnv1a("world"));
}

test "murmur3" {
    try std.testing.expect(murmur3("hello", 0) == murmur3("hello", 0));
    try std.testing.expect(murmur3("hello", 0) != murmur3("world", 0));
}
