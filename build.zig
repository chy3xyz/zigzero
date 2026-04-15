const std = @import("std");

pub const version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };
pub const name = "zigzero";
pub const description = "Zero-cost microservice framework for Zig, aligned with go-zero patterns";

const CLibPaths = struct {
    include: ?[]const u8 = null,
    lib: ?[]const u8 = null,
};

fn detectPqPaths(b: *std.Build, allocator: std.mem.Allocator) CLibPaths {
    if (b.graph.env_map.get("PQ_INCLUDE")) |inc| {
        return .{ .include = b.dupe(inc), .lib = b.graph.env_map.get("PQ_LIB") };
    }
    const target = b.graph.host.result;
    if (target.os.tag == .macos) {
        if (dirExists("/opt/homebrew/opt/libpq")) {
            return .{
                .include = "/opt/homebrew/opt/libpq/include",
                .lib = "/opt/homebrew/opt/libpq/lib",
            };
        }
        if (dirExists("/usr/local/opt/libpq")) {
            return .{
                .include = "/usr/local/opt/libpq/include",
                .lib = "/usr/local/opt/libpq/lib",
            };
        }
    } else if (target.os.tag == .linux) {
        // Common Debian/Ubuntu/RHEL paths
        const candidates = &[_][]const u8{
            "/usr/include/postgresql",
            "/usr/include/pgsql",
            "/usr/pgsql/include",
        };
        for (candidates) |c| {
            if (dirExists(c)) {
                return .{
                    .include = c,
                    .lib = "/usr/lib/x86_64-linux-gnu",
                };
            }
        }
    }
    _ = allocator;
    return .{};
}

fn detectMysqlPaths(b: *std.Build, allocator: std.mem.Allocator) CLibPaths {
    if (b.graph.env_map.get("MYSQL_INCLUDE")) |inc| {
        return .{ .include = b.dupe(inc), .lib = b.graph.env_map.get("MYSQL_LIB") };
    }
    const target = b.graph.host.result;
    if (target.os.tag == .macos) {
        const prefixes = &[_][]const u8{
            "/opt/homebrew/opt/mariadb-connector-c",
            "/usr/local/opt/mariadb-connector-c",
            "/opt/homebrew/opt/mysql-client",
            "/usr/local/opt/mysql-client",
        };
        for (prefixes) |prefix| {
            if (dirExists(prefix)) {
                return .{
                    .include = b.fmt("{s}/include/mariadb", .{prefix}),
                    .lib = b.fmt("{s}/lib", .{prefix}),
                };
            }
        }
    } else if (target.os.tag == .linux) {
        const candidates = &[_][]const u8{
            "/usr/include/mariadb",
            "/usr/include/mysql",
            "/usr/local/include/mariadb",
        };
        for (candidates) |c| {
            if (dirExists(c)) {
                return .{
                    .include = c,
                    .lib = "/usr/lib/x86_64-linux-gnu",
                };
            }
        }
    }
    _ = allocator;
    return .{};
}

fn dirExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn linkDbLibs(mod: *std.Build.Module, b: *std.Build) void {
    const allocator = b.allocator;

    const pq = detectPqPaths(b, allocator);
    if (pq.include) |inc| {
        mod.addSystemIncludePath(.{ .cwd_relative = inc });
    }
    if (pq.lib) |lib| {
        mod.addLibraryPath(.{ .cwd_relative = lib });
    }
    mod.linkSystemLibrary("pq", .{});

    const mysql = detectMysqlPaths(b, allocator);
    if (mysql.include) |inc| {
        mod.addSystemIncludePath(.{ .cwd_relative = inc });
    }
    if (mysql.lib) |lib| {
        mod.addLibraryPath(.{ .cwd_relative = lib });
    }
    mod.linkSystemLibrary("mysqlclient", .{});

    mod.linkSystemLibrary("sqlite3", .{});
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigzero_mod = b.addModule("zigzero", .{
        .root_source_file = b.path("src/zigzero.zig"),
        .target = target,
        .optimize = optimize,
    });

    linkDbLibs(zigzero_mod, b);

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

    // chy3 — Creator Metaverse Platform example (multi-file layout)
    const chy3_module = b.createModule(.{
        .root_source_file = b.path("examples/chy3/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    chy3_module.addImport("zigzero", zigzero_mod);
    const chy3 = b.addExecutable(.{
        .name = "chy3",
        .root_module = chy3_module,
    });
    b.installArtifact(chy3);

    const chy3_step = b.step("chy3", "Build the chy3 example");
    chy3_step.dependOn(&chy3.step);

    const test_step = b.step("test", "Run unit tests");

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/zigzero.zig"),
        .target = target,
        .optimize = optimize,
    });

    linkDbLibs(test_module, b);

    const tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
