//! Local cache for zigzero
//!
//! Provides in-memory LRU cache aligned with go-zero's cache patterns.

const std = @import("std");
const compat = @import("../compat.zig");

pub fn Cache(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        /// Called for every entry the cache drops — overwrite, expiry, LRU
        /// eviction, `delete`, `clear`, `deinit` — so an owning `V` can release
        /// what it holds. Without it the cache frees the node but not the value.
        pub const EvictFn = *const fn (ctx: ?*anyopaque, key: K, value: V) void;

        /// Intrusive list node: link fields plus the cached entry.
        const Node = struct {
            link: std.DoublyLinkedList.Node = .{},
            key: K,
            value: V,
            expires_at: ?i64,
        };

        // Access-order chain: first = least recently used, last = most recently used.
        const Map = std.AutoHashMap(K, *Node);

        allocator: std.mem.Allocator,
        map: Map,
        list: std.DoublyLinkedList,
        max_size: usize,
        mutex: compat.Mutex,
        on_evict: ?EvictFn = null,
        evict_ctx: ?*anyopaque = null,

        pub fn init(allocator: std.mem.Allocator, max_size: usize) Self {
            return .{
                .allocator = allocator,
                .map = Map.init(allocator),
                .list = .{},
                .max_size = max_size,
                .mutex = .init,
            };
        }

        fn notify(self: *Self, key: K, value: V) void {
            if (self.on_evict) |f| f(self.evict_ctx, key, value);
        }

        pub fn deinit(self: *Self) void {
            self.freeAllNodes();
            self.map.deinit();
        }

        fn freeAllNodes(self: *Self) void {
            var node = self.list.first;
            while (node) |n| {
                const next = n.next;
                const owned = nodeFromLink(n);
                self.notify(owned.key, owned.value);
                self.allocator.destroy(owned);
                node = next;
            }
            self.list = .{};
        }

        fn nodeFromLink(link: *std.DoublyLinkedList.Node) *Node {
            return @alignCast(@fieldParentPtr("link", link));
        }

        /// Move node to the most-recently-used end of the list.
        fn touch(self: *Self, node: *Node) void {
            self.list.remove(&node.link);
            self.list.append(&node.link);
        }

        /// Get value from cache
        pub fn get(self: *Self, key: K) ?V {
            self.mutex.lock();
            defer self.mutex.unlock();

            const node = self.map.get(key) orelse return null;

            if (node.expires_at) |expires| {
                if (compat.milliTimestamp() > expires) {
                    self.list.remove(&node.link);
                    _ = self.map.remove(key);
                    self.notify(node.key, node.value);
                    self.allocator.destroy(node);
                    return null;
                }
            }

            self.touch(node);
            return node.value;
        }

        /// Set value in cache with optional TTL
        pub fn set(self: *Self, key: K, value: V, ttl_ms: ?i64) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const expires_at = if (ttl_ms) |ttl| compat.milliTimestamp() + ttl else null;

            if (self.map.get(key)) |node| {
                self.notify(node.key, node.value);
                node.value = value;
                node.expires_at = expires_at;
                self.touch(node);
                return;
            }

            // Evict the least recently used entry when at capacity
            if (self.map.count() >= self.max_size) {
                if (self.list.first) |oldest_link| {
                    const oldest = nodeFromLink(oldest_link);
                    _ = self.map.remove(oldest.key);
                    self.list.remove(&oldest.link);
                    self.notify(oldest.key, oldest.value);
                    self.allocator.destroy(oldest);
                }
            }

            const node = try self.allocator.create(Node);
            node.* = .{ .key = key, .value = value, .expires_at = expires_at };
            self.list.append(&node.link);
            errdefer {
                self.list.remove(&node.link);
                self.allocator.destroy(node);
            }
            try self.map.put(key, node);
        }

        /// Delete key from cache
        pub fn delete(self: *Self, key: K) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.map.fetchRemove(key)) |kv| {
                self.list.remove(&kv.value.link);
                self.notify(kv.value.key, kv.value.value);
                self.allocator.destroy(kv.value);
            }
        }

        /// Clear all cache entries
        pub fn clear(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.freeAllNodes();
            self.map.clearRetainingCapacity();
        }

        /// Current cache size
        pub fn size(self: *Self) usize {
            self.mutex.lock();
            const s = self.map.count();
            self.mutex.unlock();
            return s;
        }
    };
}

test "cache basic" {
    var cache = Cache(u32, []const u8).init(std.testing.allocator, 10);
    defer cache.deinit();

    try cache.set(1, "hello", null);
    try std.testing.expectEqualStrings("hello", cache.get(1).?);

    cache.delete(1);
    try std.testing.expect(cache.get(1) == null);
}

test "cache ttl" {
    var cache = Cache(u32, []const u8).init(std.testing.allocator, 10);
    defer cache.deinit();

    try cache.set(1, "hello", 1);
    try std.testing.expectEqualStrings("hello", cache.get(1).?);

    compat.sleep(2 * std.time.ns_per_ms);
    try std.testing.expect(cache.get(1) == null);
}

test "cache lru eviction order" {
    var cache = Cache(u32, []const u8).init(std.testing.allocator, 3);
    defer cache.deinit();

    try cache.set(1, "A", null);
    try cache.set(2, "B", null);
    try cache.set(3, "C", null);

    // Access A so B becomes the least recently used entry
    _ = cache.get(1);

    // Inserting D at capacity must evict B, not A or C
    try cache.set(4, "D", null);

    try std.testing.expectEqual(@as(usize, 3), cache.size());
    try std.testing.expect(cache.get(1) != null);
    try std.testing.expect(cache.get(2) == null);
    try std.testing.expect(cache.get(3) != null);
    try std.testing.expect(cache.get(4) != null);
}

test "cache eviction hook fires for every drop path" {
    const Built = struct {
        var keys: std.ArrayList(u32) = .empty;
        fn onEvict(_: ?*anyopaque, key: u32, _: []const u8) void {
            keys.append(std.testing.allocator, key) catch unreachable;
        }
    };
    Built.keys = .empty;
    defer Built.keys.deinit(std.testing.allocator);

    var cache = Cache(u32, []const u8).init(std.testing.allocator, 2);
    cache.on_evict = Built.onEvict;

    try cache.set(1, "A", null);
    try cache.set(2, "B", null);
    try cache.set(3, "C", null); // evicts 1
    cache.delete(2); // explicit delete
    try cache.set(4, "D", 1); // expires via get below
    compat.sleep(2 * std.time.ns_per_ms);
    _ = cache.get(4);
    try cache.set(5, "E", null);
    cache.clear(); // drops 3 and 5
    cache.deinit(); // empty by now

    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 4, 3, 5 }, Built.keys.items);
}
