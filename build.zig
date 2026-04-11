const std = @import("std");

pub const version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };
pub const name = "zigzero";
pub const description = "Zero-cost microservice framework for Zig, aligned with go-zero patterns";

pub fn build(b: *std.Build) void {
    _ = b.addModule("zigzero", .{
        .root_source_file = b.path("src/zigzero.zig"),
    });
}
