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
    \\    const exe = b.addExecutable(.{{
    \\        .name = "{s}",
    \\        .root_source_file = b.path("src/main.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\    }});
    \\    exe.root_module.addImport("zigzero", zigzero.module("zigzero"));
    \\    b.installArtifact(exe);
    \\
    \\    const run_cmd = b.addRunArtifact(exe);
    \\    run_cmd.step.dependOn(b.getInstallStep());
    \\    if (b.args) |args| {{
    \\        run_cmd.addArgs(args);
    \\    }}
    \\    const run_step = b.step("run", "Run the app");
    \\    run_step.dependOn(\u0026run_cmd.step);
    \\
    \\    const test_step = b.step("test", "Run unit tests");
    \\    const tests = b.addTest(.{{
    \\        .root_source_file = b.path("src/main.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\    }});
    \\    tests.root_module.addImport("zigzero", zigzero.module("zigzero"));
    \\    const run_tests = b.addRunArtifact(tests);
    \\    test_step.dependOn(\u0026run_tests.step);
    \\}}
    \\
;

pub const build_zon =
    \\.{{
    \\    .name = "{s}",
    \\    .version = "0.1.0",
    \\    .dependencies = .{{
    \\        .zigzero = .{{
    \\            .url = "https://github.com/knot3bot/zigzero/archive/refs/heads/main.tar.gz",
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
    \\const log = zigzero.log;
    \\const health = zigzero.health;
    \\
    \\pub fn main() !void {{
    \\    var gpa: std.heap.DebugAllocator(.{{}}) = .init;
    \\    defer _ = gpa.deinit();
    \\    const allocator = gpa.allocator();
    \\
    \\    const logger = log.Logger.new(.info, "{s}");
    \\    var server = api.Server.init(allocator, 8080, logger);
    \\    defer server.deinit();
    \\
    \\    var registry = health.Registry.init(allocator);
    \\    defer registry.deinit();
    \\    try registry.addProbe("alive", struct {{ fn check() health.Status {{ return .healthy; }} }}.check);
    \\
    \\    // Health check endpoint
    \\    try server.get("/health", struct {{
    \\        fn handle(ctx: *api.Context) !void {{
    \\            try ctx.json(200, "{{\"status\":\"ok\"}}");
    \\        }}
    \\    }}.handle);
    \\
    \\    logger.info("Starting {s} on port 8080");
    \\    try server.start();
    \\}}
    \\
;

pub const handler_zig =
    \\const std = @import("std");
    \\const zigzero = @import("zigzero");
    \\const api = zigzero.api;
    \\
    \\pub fn {s}Handler(ctx: *api.Context) !void {{
    \\    try ctx.json(200, "{{\"message\":\"ok\"}}");
    \\}}
    \\
;

pub const routes_zig =
    \\const std = @import("std");
    \\const zigzero = @import("zigzero");
    \\const api = zigzero.api;
    \\const handlers = @import("handlers.zig");
    \\
    \\pub fn registerRoutes(server: *api.Server) !void {{
    \\{s}
    \\}}
    \\
;

pub const route_line =
    \\    try server.{s}("{s}", handlers.{s}Handler);
    \\
;

pub const model_zig =
    \\const std = @import("std");
    \\const zigzero = @import("zigzero");
    \\const orm = zigzero.orm;
    \\
    \\pub const {s} = struct {{
    \\    pub const table_name = "{s}";
    \\    pub const primary_key = "{s}";
    \\
    \\{s}
    \\
    \\    pub fn query() orm.QueryBuilder(@This()) {{
    \\        return orm.QueryBuilder(@This()).new(table_name);
    \\    }}
    \\}};
    \\
;

pub const model_field =
    \\    {s}: {s},
    \\
;
