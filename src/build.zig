const std = @import("std");
const Version = std.SemanticVersion;

pub const version = Version{ .major = 0, .minor = 1, .patch = 0 };

pub const name = "zigzero";
pub const description = "Zero-cost microservice framework for Zig, aligned with go-zero patterns";
