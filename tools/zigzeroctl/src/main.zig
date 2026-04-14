const std = @import("std");
const generate = @import("generate.zig");
const dsl = @import("dsl.zig");

const usage =
    \\zigzeroctl - Code generation tool for zigzero
    \\n    \\Usage:
    \\  zigzeroctl new <project-name>      Create a new zigzero service project
    \\  zigzeroctl api <spec.(json|api)>   Generate API routes and handlers from spec
    \\  zigzeroctl model <ddl.sql>         Generate ORM models from SQL DDL
    \\n    \\Examples:
    \\  zigzeroctl new my-service
    \\  zigzeroctl api api-spec.json -o ./gen
    \\  zigzeroctl api api-spec.api -o ./gen
    \\  zigzeroctl model schema.sql -o ./gen/models
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("{s}", .{usage});
        return;
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "new")) {
        if (args.len < 3) {
            std.debug.print("Usage: zigzeroctl new <project-name>\n", .{});
            return;
        }
        const project_name = args[2];
        const output_dir = if (args.len > 3) args[3] else project_name;
        try generate.newProject(allocator, project_name, output_dir);
        std.debug.print("Created project '{s}' in {s}/\n", .{ project_name, output_dir });
    } else if (std.mem.eql(u8, cmd, "api")) {
        if (args.len < 3) {
            std.debug.print("Usage: zigzeroctl api <spec.(json|api)> [-o <output-dir>]\n", .{});
            return;
        }
        const spec_file = args[2];
        const output_dir = parseOutputDir(args) orelse "gen/api";

        const content = try std.fs.cwd().readFileAlloc(allocator, spec_file, 1024 * 1024);
        defer allocator.free(content);

        if (std.mem.endsWith(u8, spec_file, ".api")) {
            var def = try dsl.parse(allocator, content);
            defer def.deinit(allocator);
            try generate.generateApiFromDsl(allocator, def, output_dir);
        } else {
            const spec = try generate.parseApiSpec(allocator, content);
            defer {
                allocator.free(spec.name);
                for (spec.routes) |route| {
                    allocator.free(route.method);
                    allocator.free(route.path);
                    allocator.free(route.handler);
                }
                allocator.free(spec.routes);
            }
            try generate.generateApi(allocator, spec, output_dir);
        }
        std.debug.print("Generated API code in {s}/\n", .{output_dir});
    } else if (std.mem.eql(u8, cmd, "model")) {
        if (args.len < 3) {
            std.debug.print("Usage: zigzeroctl model <ddl.sql> [-o <output-dir>]\n", .{});
            return;
        }
        const sql_file = args[2];
        const output_dir = parseOutputDir(args) orelse "gen/models";

        const content = try std.fs.cwd().readFileAlloc(allocator, sql_file, 1024 * 1024);
        defer allocator.free(content);

        const result = try generate.parseCreateTable(allocator, content);
        defer {
            allocator.free(result.table_name);
            allocator.free(result.primary_key);
            for (result.columns) |col| {
                allocator.free(col.name);
            }
            allocator.free(result.columns);
        }

        try generate.generateModel(allocator, result.table_name, result.columns, result.primary_key, output_dir);
        std.debug.print("Generated model code in {s}/\n", .{output_dir});
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        std.debug.print("{s}", .{usage});
    } else {
        std.debug.print("Unknown command: {s}\n{s}", .{ cmd, usage });
    }
}

fn parseOutputDir(args: []const [:0]u8) ?[]const u8 {
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o") and i + 1 < args.len) {
            return args[i + 1];
        }
    }
    return null;
}
