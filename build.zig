const std = @import("std");

pub const version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };
pub const name = "zigzero";
pub const description = "Zero-cost microservice framework for Zig, aligned with go-zero patterns";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigzero_mod = b.addModule("zigzero", .{
        .root_source_file = b.path("src/zigzero.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link database C libraries
    zigzero_mod.addSystemIncludePath(.{ .cwd_relative = "/usr/local/opt/libpq/include" });
    zigzero_mod.addLibraryPath(.{ .cwd_relative = "/usr/local/opt/libpq/lib" });
    zigzero_mod.linkSystemLibrary("pq", .{});

    zigzero_mod.addSystemIncludePath(.{ .cwd_relative = "/usr/local/opt/mariadb-connector-c/include/mariadb" });
    zigzero_mod.addLibraryPath(.{ .cwd_relative = "/usr/local/opt/mariadb-connector-c/lib" });
    zigzero_mod.linkSystemLibrary("mysqlclient", .{});

    zigzero_mod.linkSystemLibrary("sqlite3", .{});

    // zigzeroctl code generation tool
    const ctl_module = b.createModule(.{
        .root_source_file = b.path("tools/zigzeroctl/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ctl = b.addExecutable(.{
        .name = "zigzeroctl",
        .root_module = ctl_module,
    });
    b.installArtifact(ctl);

    // Example builds
    const api_server_module = b.createModule(.{
        .root_source_file = b.path("examples/api-server/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    api_server_module.addImport("zigzero", zigzero_mod);
    const api_server = b.addExecutable(.{
        .name = "api-server",
        .root_module = api_server_module,
    });
    b.installArtifact(api_server);

    const test_step = b.step("test", "Run unit tests");

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/zigzero.zig"),
        .target = target,
        .optimize = optimize,
    });

    test_module.addSystemIncludePath(.{ .cwd_relative = "/usr/local/opt/libpq/include" });
    test_module.addLibraryPath(.{ .cwd_relative = "/usr/local/opt/libpq/lib" });
    test_module.linkSystemLibrary("pq", .{});

    test_module.addSystemIncludePath(.{ .cwd_relative = "/usr/local/opt/mariadb-connector-c/include/mariadb" });
    test_module.addLibraryPath(.{ .cwd_relative = "/usr/local/opt/mariadb-connector-c/lib" });
    test_module.linkSystemLibrary("mysqlclient", .{});

    test_module.linkSystemLibrary("sqlite3", .{});

    const tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
