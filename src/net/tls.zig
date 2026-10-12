//! TLS certificate handling for zigzero
//!
//! This module loads certificate and key files; it does **not** implement a TLS
//! handshake, and nothing in the server uses it yet (`isAvailable()` reports
//! that honestly). Terminate TLS in a sidecar or gateway when deploying.

const std = @import("std");
const compat = @import("../compat.zig");
const errors = @import("../core/errors.zig");

/// TLS configuration
pub const Config = struct {
    cert_file: []const u8,
    key_file: []const u8,
};

/// Certificate material loaded from disk. Holding this does not imply that a
/// connection is encrypted; see the module note.
pub const Context = struct {
    allocator: std.mem.Allocator,
    cert_pem: []const u8,
    key_pem: []const u8,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Context {
        const cert_pem = try compat.cwd().readFileAlloc(compat.io(), config.cert_file, allocator, .limited(1024 * 1024));

        const key_pem = compat.cwd().readFileAlloc(compat.io(), config.key_file, allocator, .limited(1024 * 1024)) catch |err| {
            allocator.free(cert_pem);
            return err;
        };

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

/// Whether this build can terminate TLS.
///
/// It cannot: the module only reads certificate and key files off disk, and no
/// handshake is implemented (`Context` holds the PEM bytes and nothing more).
/// This returns false so a caller that gates HTTPS on it fails loudly instead
/// of serving plaintext to a client that asked for TLS. Terminate TLS in a
/// sidecar or gateway in front of the server, or supply your own handshake.
pub fn isAvailable() bool {
    return false;
}

/// Load certificate and key from files
pub fn loadCertificates(allocator: std.mem.Allocator, cert_path: []const u8, key_path: []const u8) !Context {
    return Context.init(allocator, .{
        .cert_file = cert_path,
        .key_file = key_path,
    });
}

test "tls context loads certificate and key files" {
    const allocator = std.testing.allocator;
    const dir = ".test-tls";
    compat.cwd().deleteTree(compat.io(), dir) catch {};
    try compat.cwd().createDirPath(compat.io(), dir);
    defer compat.cwd().deleteTree(compat.io(), dir) catch {};
    try compat.cwd().writeFile(compat.io(), .{ .sub_path = dir ++ "/cert.pem", .data = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n" });
    try compat.cwd().writeFile(compat.io(), .{ .sub_path = dir ++ "/key.pem", .data = "-----BEGIN PRIVATE KEY-----\nMIIB\n-----END PRIVATE KEY-----\n" });

    var ctx = try Context.init(allocator, .{
        .cert_file = dir ++ "/cert.pem",
        .key_file = dir ++ "/key.pem",
    });
    defer ctx.deinit();

    try std.testing.expect(std.mem.indexOf(u8, ctx.cert_pem, "BEGIN CERTIFICATE") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx.key_pem, "BEGIN PRIVATE KEY") != null);

    // A missing key file must not leak the certificate it already read.
    try std.testing.expectError(error.FileNotFound, Context.init(allocator, .{
        .cert_file = dir ++ "/cert.pem",
        .key_file = dir ++ "/missing.pem",
    }));
}

test "tls reports no handshake support" {
    // The module loads files only; a caller that gates HTTPS on this must not be
    // told otherwise.
    try std.testing.expect(!isAvailable());
}
