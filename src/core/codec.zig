//! Codec utilities for zigzero
//!
//! Aligned with go-zero's core/codec package.

const std = @import("std");

/// Codec interface for serialization
pub fn Codec(comptime T: type) type {
    return struct {
        encode: *const fn (allocator: std.mem.Allocator, value: T) anyerror![]u8,
        decode: *const fn (allocator: std.mem.Allocator, data: []const u8) anyerror!T,
    };
}

/// JSON codec
pub fn JsonCodec(comptime T: type) Codec(T) {
    return .{
        .encode = struct {
            fn encode(allocator: std.mem.Allocator, value: T) anyerror![]u8 {
                return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
            }
        }.encode,
        .decode = struct {
            fn decode(allocator: std.mem.Allocator, data: []const u8) anyerror!T {
                var parsed = try std.json.parseFromSlice(T, allocator, data, .{});
                defer parsed.deinit();
                return parsed.value;
            }
        }.decode,
    };
}

/// Simple binary codec using std.mem bytes
pub fn BinaryCodec(comptime T: type) Codec(T) {
    return .{
        .encode = struct {
            fn encode(allocator: std.mem.Allocator, value: T) anyerror![]u8 {
                const bytes = std.mem.asBytes(&value);
                return allocator.dupe(u8, bytes);
            }
        }.encode,
        .decode = struct {
            fn decode(_allocator: std.mem.Allocator, data: []const u8) anyerror!T {
                _ = _allocator;
                if (data.len != @sizeOf(T)) return error.InvalidData;
                return std.mem.bytesToValue(T, data[0..@sizeOf(T)]);
            }
        }.decode,
    };
}

/// Base64 codec for strings
pub const Base64 = struct {
    pub fn encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        const encoder = std.base64.standard.Encoder;
        const size = encoder.calcSize(data.len);
        const out = try allocator.alloc(u8, size);
        _ = encoder.encode(out, data);
        return out;
    }

    pub fn decode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        const decoder = std.base64.standard.Decoder;
        const size = try decoder.calcSizeForSlice(data);
        const out = try allocator.alloc(u8, size);
        try decoder.decode(out, data);
        return out;
    }
};

/// Hex codec
pub const Hex = struct {
    pub fn encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        const out = try allocator.alloc(u8, data.len * 2);
        for (data, 0..) |byte, i| {
            out[i * 2] = hexDigit(@truncate(byte >> 4));
            out[i * 2 + 1] = hexDigit(@truncate(byte & 0x0F));
        }
        return out;
    }

    fn hexDigit(n: u4) u8 {
        return if (n < 10) '0' + @as(u8, n) else 'a' + (@as(u8, n) - 10);
    }

    pub fn decode(allocator: std.mem.Allocator, hex_str: []const u8) ![]u8 {
        if (hex_str.len % 2 != 0) return error.InvalidHex;
        const out = try allocator.alloc(u8, hex_str.len / 2);
        errdefer allocator.free(out);
        for (0..out.len) |i| {
            const hi = try parseHexDigit(hex_str[i * 2]);
            const lo = try parseHexDigit(hex_str[i * 2 + 1]);
            out[i] = (hi << 4) | lo;
        }
        return out;
    }

    fn parseHexDigit(c: u8) !u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => error.InvalidHex,
        };
    }
};

/// URL-safe encoding (percent-encoding)
pub const Url = struct {
    pub fn encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        var count: usize = 0;
        for (data) |c| {
            if (needsEncoding(c)) count += 2;
        }

        const out = try allocator.alloc(u8, data.len + count * 2);
        var j: usize = 0;
        for (data) |c| {
            if (needsEncoding(c)) {
                out[j] = '%';
                out[j + 1] = hexDigit(c >> 4);
                out[j + 2] = hexDigit(c & 0x0F);
                j += 3;
            } else {
                out[j] = c;
                j += 1;
            }
        }
        return out;
    }

    fn needsEncoding(c: u8) bool {
        return !std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.' and c != '~';
    }

    fn hexDigit(n: u4) u8 {
        return if (n < 10) '0' + n else 'a' + (n - 10);
    }
};

test "json codec" {
    const allocator = std.testing.allocator;
    const codec = JsonCodec(u32);

    const encoded = try codec.encode(allocator, 42);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("42", encoded);

    const decoded = try codec.decode(allocator, "42");
    try std.testing.expectEqual(@as(u32, 42), decoded);
}

test "base64" {
    const allocator = std.testing.allocator;
    const encoded = try Base64.encode(allocator, "hello");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("aGVsbG8=", encoded);

    const decoded = try Base64.decode(allocator, encoded);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("hello", decoded);
}

test "hex" {
    const allocator = std.testing.allocator;
    const encoded = try Hex.encode(allocator, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("deadbeef", encoded);

    const decoded = try Hex.decode(allocator, encoded);
    defer allocator.free(decoded);
    try std.testing.expectEqual(@as(u8, 0xDE), decoded[0]);
}
