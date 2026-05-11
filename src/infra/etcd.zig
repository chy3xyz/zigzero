//! etcd v3 HTTP client for zigzero
//!
//! Provides a lightweight etcd v3 gRPC-gateway HTTP client for service
//! registration, discovery, and lease management.

const std = @import("std");
const http = @import("../net/http.zig");

pub const Error = error{
    EtcdError,
    InvalidResponse,
};

/// Key-value pair
pub const KV = struct {
    key: []const u8,
    value: []const u8,

    pub fn deinit(self: *KV, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

/// etcd v3 HTTP client
pub const Client = struct {
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    http_client: http.Client,

    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8) !Client {
        return .{
            .allocator = allocator,
            .endpoint = try allocator.dupe(u8, endpoint),
            .http_client = http.Client.init(allocator, .{ .timeout_ms = 5000 }),
        };
    }

    pub fn deinit(self: *Client) void {
        self.allocator.free(self.endpoint);
    }

    /// Grant a lease with the given TTL in seconds.
    pub fn leaseGrant(self: *Client, ttl: i64) !i64 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/v3/lease/grant", .{self.endpoint});
        defer self.allocator.free(url);

        const req_body = try std.fmt.allocPrint(self.allocator, "{{\"TTL\":{d},\"ID\":0}}", .{ttl});
        defer self.allocator.free(req_body);

        var resp = try self.http_client.post(url, req_body, null);
        defer resp.deinit();

        if (resp.status_code != 200) return error.EtcdError;

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp.body, .{});
        defer parsed.deinit();

        const id_val = parsed.value.object.get("ID") orelse return error.InvalidResponse;
        if (id_val != .string and id_val != .integer) return error.InvalidResponse;

        if (id_val == .integer) return id_val.integer;
        return std.fmt.parseInt(i64, id_val.string, 10);
    }

    /// Keep a lease alive.
    pub fn keepAlive(self: *Client, lease_id: i64) !void {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/v3/lease/keepalive", .{self.endpoint});
        defer self.allocator.free(url);

        const req_body = try std.fmt.allocPrint(self.allocator, "{{\"ID\":{d}}}", .{lease_id});
        defer self.allocator.free(req_body);

        var resp = try self.http_client.post(url, req_body, null);
        defer resp.deinit();

        if (resp.status_code != 200) return error.EtcdError;
    }

    /// Put a key-value pair with an optional lease.
    pub fn put(self: *Client, key: []const u8, value: []const u8, lease_id: ?i64) !void {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/v3/kv/put", .{self.endpoint});
        defer self.allocator.free(url);

        const key_b64 = try encodeBase64(self.allocator, key);
        defer self.allocator.free(key_b64);
        const value_b64 = try encodeBase64(self.allocator, value);
        defer self.allocator.free(value_b64);

        const req_body = if (lease_id) |lid|
            try std.fmt.allocPrint(self.allocator, "{{\"key\":\"{s}\",\"value\":\"{s}\",\"lease\":{d}}}", .{ key_b64, value_b64, lid })
        else
            try std.fmt.allocPrint(self.allocator, "{{\"key\":\"{s}\",\"value\":\"{s}\"}}", .{ key_b64, value_b64 });
        defer self.allocator.free(req_body);

        var resp = try self.http_client.post(url, req_body, null);
        defer resp.deinit();

        if (resp.status_code != 200) return error.EtcdError;
    }

    /// Get all key-value pairs with the given prefix.
    pub fn getPrefix(self: *Client, prefix: []const u8) !std.ArrayList(KV) {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/v3/kv/range", .{self.endpoint});
        defer self.allocator.free(url);

        const key_b64 = try encodeBase64(self.allocator, prefix);
        defer self.allocator.free(key_b64);

        // Compute range_end by incrementing the last byte of the prefix.
        var range_end = try self.allocator.alloc(u8, prefix.len);
        defer self.allocator.free(range_end);
        @memcpy(range_end, prefix);
        if (range_end.len > 0) {
            range_end[range_end.len - 1] +%= 1;
        }
        const range_end_b64 = try encodeBase64(self.allocator, range_end);
        defer self.allocator.free(range_end_b64);

        const req_body = try std.fmt.allocPrint(self.allocator, "{{\"key\":\"{s}\",\"range_end\":\"{s}\"}}", .{ key_b64, range_end_b64 });
        defer self.allocator.free(req_body);

        var resp = try self.http_client.post(url, req_body, null);
        defer resp.deinit();

        if (resp.status_code != 200) return error.EtcdError;

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp.body, .{});
        defer parsed.deinit();

        var result: std.ArrayList(KV) = .empty;
        errdefer {
            for (result.items) |*kv| kv.deinit(self.allocator);
            result.deinit(self.allocator);
        }

        const kvs = parsed.value.object.get("kvs") orelse return result;
        if (kvs != .array) return result;

        for (kvs.array.items) |item| {
            if (item != .object) continue;
            const k = item.object.get("key") orelse continue;
            const v = item.object.get("value") orelse continue;
            if (k != .string or v != .string) continue;

            const key_decoded = try decodeBase64(self.allocator, k.string);
            errdefer self.allocator.free(key_decoded);
            const value_decoded = try decodeBase64(self.allocator, v.string);
            errdefer self.allocator.free(value_decoded);

            try result.append(.{
                .key = key_decoded,
                .value = value_decoded,
            });
        }

        return result;
    }

    /// Delete a key.
    pub fn delete(self: *Client, key: []const u8) !void {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/v3/kv/deleterange", .{self.endpoint});
        defer self.allocator.free(url);

        const key_b64 = try encodeBase64(self.allocator, key);
        defer self.allocator.free(key_b64);

        const req_body = try std.fmt.allocPrint(self.allocator, "{{\"key\":\"{s}\"}}", .{key_b64});
        defer self.allocator.free(req_body);

        var resp = try self.http_client.post(url, req_body, null);
        defer resp.deinit();

        if (resp.status_code != 200) return error.EtcdError;
    }
};

fn encodeBase64(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const size = std.base64.standard.Encoder.calcSize(data.len);
    const buf = try allocator.alloc(u8, size);
    _ = std.base64.standard.Encoder.encode(buf, data);
    return buf;
}

fn decodeBase64(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(data);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    try decoder.decode(buf, data);
    return buf;
}

test "etcd base64 helpers" {
    const allocator = std.testing.allocator;
    const encoded = try encodeBase64(allocator, "hello");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("aGVsbG8=", encoded);

    const decoded = try decodeBase64(allocator, encoded);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("hello", decoded);
}
