const std = @import("std");

pub const project_build_zig =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {{
    \\    const target = b.standardTargetOptions(.{{}});
    \\    const optimize = b.standardOptimizeOption(.{{}});
    \\
    \\    const zigzero = b.dependency("zigzero", .{{
    \\        .target = target,
    \\        .optimize = optimize,
    \\    }});
    \\
    \\    const exe_module = b.createModule(.{{
    \\        .root_source_file = b.path("src/main.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\    }});
    \\    exe_module.addImport("zigzero", zigzero.module("zigzero"));
    \\
    \\    const exe = b.addExecutable(.{{
    \\        .name = "{s}",
    \\        .root_module = exe_module,
    \\    }});
    \\    b.installArtifact(exe);
    \\
    \\    const run_cmd = b.addRunArtifact(exe);
    \\    run_cmd.step.dependOn(b.getInstallStep());
    \\    run_cmd.addPassthruArgs();
    \\    const run_step = b.step("run", "Run the app");
    \\    run_step.dependOn(&run_cmd.step);
    \\
    \\    const test_step = b.step("test", "Run unit tests");
    \\    const test_module = b.createModule(.{{
    \\        .root_source_file = b.path("src/main.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\    }});
    \\    test_module.addImport("zigzero", zigzero.module("zigzero"));
    \\    const tests = b.addTest(.{{
    \\        .root_module = test_module,
    \\    }});
    \\    const run_tests = b.addRunArtifact(tests);
    \\    test_step.dependOn(&run_tests.step);
    \\}}
    \\
;

pub const build_zon =
    \\.{{
    \\    .name = .{s},
    \\    .fingerprint = 0x{x:0>16},
    \\    .version = "0.1.0",
    \\    .minimum_zig_version = "0.17.0",
    \\    .dependencies = .{{
    \\        .zigzero = .{{
    \\            .url = "https://github.com/chy3xyz/zigzero/archive/refs/heads/main.tar.gz",
    \\        }},
    \\    }},
    \\    .paths = .{{
    \\        "build.zig",
    \\        "build.zig.zon",
    \\        "src",
    \\    }},
    \\}}
    \\
;

pub const main_zig =
    \\const std = @import("std");
    \\const zigzero = @import("zigzero");
    \\const api = zigzero.api;
    \\const compat = zigzero.compat;
    \\const log = zigzero.log;
    \\const health = zigzero.health;
    \\
    \\fn aliveCheck(allocator: std.mem.Allocator) !health.Result {{
    \\    _ = allocator;
    \\    return health.Result.init("alive", .healthy);
    \\}}
    \\
    \\pub fn main() !void {{
    \\    var gpa: std.heap.DebugAllocator(.{{}}) = .init;
    \\    defer _ = gpa.deinit();
    \\    const allocator = gpa.allocator();
    \\
    \\    compat.initIo(allocator);
    \\    defer compat.deinitIo();
    \\
    \\    const logger = log.Logger.new(.info, "{s}");
    \\
    \\    var health_registry = health.Registry.init(allocator);
    \\    defer health_registry.deinit();
    \\    try health_registry.register("alive", aliveCheck);
    \\
    \\    var server = api.Server.init(allocator, 8080, logger);
    \\    defer server.deinit();
    \\
    \\    try server.addRoute(.{{
    \\        .method = .GET,
    \\        .path = "/health",
    \\        .handler = struct {{
    \\            fn handle(ctx: *api.Context) !void {{
    \\                try ctx.json(200, "{{\"status\":\"ok\"}}");
    \\            }}
    \\        }}.handle,
    \\    }});
    \\
    \\    logger.info("Starting {s} on port 8080");
    \\    try server.start();
    \\}}
    \\
;
