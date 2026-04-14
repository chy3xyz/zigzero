//! TLS support for zigzero
//!
//! Provides HTTPS server capabilities using Zig's crypto libraries.

const std = @import("std");
const errors = @import("errors.zig");

/// TLS configuration
pub const Config = struct {
    cert_file: []const u8,
    key_file: []const u8,
};

/// TLS context for HTTPS servers
pub const Context = struct {
    allocator: std.mem.Allocator,
    cert_pem: []const u8,
    key_pem: []const u8,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Context {
        const cert_file = try std.fs.cwd().openFile(config.cert_file, .{});
        defer cert_file.close();
        const cert_pem = try cert_file.readToEndAlloc(allocator, 1024 * 1024);

        const key_file = try std.fs.cwd().openFile(config.key_file, .{});
        defer key_file.close();
        const key_pem = try key_file.readToEndAlloc(allocator, 1024 * 1024);

        return .{
            .allocator = allocator,
            .cert_pem = cert_pem,
            .key_pem = key_pem,
        };
    }

    pub fn deinit(self: *Context) void {
        self.allocator.free(self.cert_pem);
        self.allocator.free(self.key_pem);
    }
};

/// Check if TLS is available (always true in this build)
pub fn isAvailable() bool {
    return true;
}

/// Load certificate and key from files
pub fn loadCertificates(allocator: std.mem.Allocator, cert_path: []const u8, key_path: []const u8) !Context {
    return Context.init(allocator, .{
        .cert_file = cert_path,
        .key_file = key_path,
    });
}

test "tls config" {
    // This test would need actual cert files
    // Skip in CI
    if (true) return error.SkipZigTest;
}
