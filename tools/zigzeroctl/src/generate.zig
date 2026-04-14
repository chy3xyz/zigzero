const std = @import("std");
const template = @import("template.zig");
const dsl = @import("dsl.zig");

/// Generate API from DSL definition
pub fn generateApiFromDsl(allocator: std.mem.Allocator, def: dsl.ApiDef, output_dir: []const u8) !void {
    const cwd = std.fs.cwd();
    var out_dir = try cwd.makeOpenPath(output_dir, .{});
    defer out_dir.close();

    // Generate types.zig
    var types_buf: std.ArrayList(u8) = .{};
    defer types_buf.deinit(allocator);
    const tw = types_buf.writer(allocator);

    try tw.writeAll("const std = @import(\"std\");\n\n");
    for (def.types) |t| {
        try tw.print("pub const {s} = struct {{\n", .{t.name});
        for (t.fields) |f| {
            try tw.print("    {s}: {s},\n", .{ f.name, f.field_type.toZigType() });
        }
        try tw.writeAll("};\n\n");
    }
    try out_dir.writeFile(.{ .sub_path = "types.zig", .data = types_buf.items });

    // Generate handlers.zig
    var handlers_buf: std.ArrayList(u8) = .{};
    defer handlers_buf.deinit(allocator);
    const hw = handlers_buf.writer(allocator);

    try hw.writeAll("const std = @import(\"std\");\n");
    try hw.writeAll("const zigzero = @import(\"zigzero\");\n");
    try hw.writeAll("const api = zigzero.api;\n");
    if (def.types.len > 0) {
        try hw.writeAll("const types = @import(\"types.zig\");\n");
    }
    try hw.writeAll("\n");

    for (def.routes) |route| {
        try hw.print("pub fn {s}Handler(ctx: *api.Context) !void {{\n", .{route.handler});
        if (route.req_type) |req| {
            try hw.print("    const req = try ctx.bindJson(types.{s});\n", .{req});
        }
        if (route.resp_type) |resp| {
            try hw.print("    var resp: types.{s} = undefined;\n", .{resp});
            try hw.writeAll("    _ = resp;\n");
            try hw.writeAll("    // TODO: implement handler logic\n");
            try hw.writeAll("    try ctx.jsonStruct(200, resp);\n");
        } else {
            try hw.writeAll("    try ctx.json(200, \"{\\\"message\\\":\\\"ok\\\"}\");\n");
        }
        try hw.writeAll("}\n\n");
    }
    try out_dir.writeFile(.{ .sub_path = "handlers.zig", .data = handlers_buf.items });

    // Generate routes.zig
    var routes_buf: std.ArrayList(u8) = .{};
    defer routes_buf.deinit(allocator);
    const rw = routes_buf.writer(allocator);

    try rw.writeAll("const std = @import(\"std\");\n");
    try rw.writeAll("const zigzero = @import(\"zigzero\");\n");
    try rw.writeAll("const api = zigzero.api;\n");
    try rw.writeAll("const handlers = @import(\"handlers.zig\");\n\n");
    try rw.writeAll("pub fn registerRoutes(server: *api.Server) !void {\n");

    for (def.routes) |route| {
        const method = std.ascii.lowerString(try allocator.alloc(u8, route.method.len), route.method);
        defer allocator.free(method);
        try rw.print("    try server.{s}(\"{s}\", handlers.{s}Handler);\n", .{ method, route.path, route.handler });
    }

    try rw.writeAll("}\n");
    try out_dir.writeFile(.{ .sub_path = "routes.zig", .data = routes_buf.items });
}

/// Generate OpenAPI 3.0 JSON from DSL definition
pub fn generateOpenApi(allocator: std.mem.Allocator, def: dsl.ApiDef, output_dir: []const u8) !void {
    const cwd = std.fs.cwd();
    var out_dir = try cwd.makeOpenPath(output_dir, .{});
    defer out_dir.close();

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("{\n");
    try w.print("  \"openapi\": \"3.0.0\",\n", .{});
    try w.print("  \"info\": {{\n    \"title\": \"{s}\",\n    \"version\": \"1.0.0\"\n  }},\n", .{def.name});
    try w.writeAll("  \"paths\": {\n");

    for (def.routes, 0..) |route, i| {
        const method_lower = std.ascii.lowerString(try allocator.alloc(u8, route.method.len), route.method);
        defer allocator.free(method_lower);
        try w.print("    \"{s}\": {{\n", .{route.path});
        try w.print("      \"{s}\": {{\n", .{method_lower});
        try w.print("        \"operationId\": \"{s}\",\n", .{route.handler});
        try w.writeAll("        \"responses\": {\n");
        try w.writeAll("          \"200\": {\n");
        try w.writeAll("            \"description\": \"OK\",\n");
        try w.writeAll("            \"content\": {\n");
        try w.writeAll("              \"application/json\": {\n");
        try w.writeAll("                \"schema\": {\n");
        if (route.resp_type) |resp| {
            try w.print("                  \"$ref\": \"#/components/schemas/{s}\"\n", .{resp});
        } else {
            try w.writeAll("                  \"type\": \"object\"\n");
        }
        try w.writeAll("                }\n");
        try w.writeAll("              }\n");
        try w.writeAll("            }\n");
        try w.writeAll("          }\n");
        try w.writeAll("        }\n");
        if (route.req_type) |_| {
            try w.writeAll(
                \\"        \"requestBody\": {\\n"
                \\"          \"content\": {\\n"
                \\"            \"application/json\": {\\n"
                \\"              \"schema\": {\\n"
            );
            try w.print("                \"$ref\": \"#/components/schemas/{s}\"\\n", .{route.req_type.?});
            try w.writeAll(
                \\"              }\\n"
                \\"            }\\n"
                \\"          }\\n"
                \\"        },\\n"
            );
        }
        try w.writeAll("      }\n");
        try w.writeAll("    }");
        if (i < def.routes.len - 1) try w.writeAll(",");
        try w.writeAll("\n");
    }

    try w.writeAll("  },\n");
    try w.writeAll("  \"components\": {\n");
    try w.writeAll("    \"schemas\": {\n");
    for (def.types, 0..) |t, i| {
        try w.print("      \"{s}\": {{\n", .{t.name});
        try w.writeAll("        \"type\": \"object\",\n");
        try w.writeAll("        \"properties\": {\n");
        for (t.fields, 0..) |f, j| {
            const json_type = switch (f.field_type) {
                .string => "string",
                .int => "integer",
                .bool => "boolean",
                .float => "number",
            };
            try w.print("          \"{s}\": {{ \"type\": \"{s}\" }}", .{ f.name, json_type });
            if (j < t.fields.len - 1) try w.writeAll(",");
            try w.writeAll("\n");
        }
        try w.writeAll("        }\n");
        try w.writeAll("      }");
        if (i < def.types.len - 1) try w.writeAll(",");
        try w.writeAll("\n");
    }
    try w.writeAll("    }\n");
    try w.writeAll("  }\n");
    try w.writeAll("}\n");

    try out_dir.writeFile(.{ .sub_path = "openapi.json", .data = buf.items });
}

/// Generate a new project scaffold
pub fn newProject(allocator: std.mem.Allocator, project_name: []const u8, output_dir: []const u8) !void {
    const cwd = std.fs.cwd();

    // Create project directory
    var project_dir = try cwd.makeOpenPath(output_dir, .{});
    defer project_dir.close();

    // Create src directory
    try project_dir.makePath("src");

    // Write build.zig
    const build_content = try std.fmt.allocPrint(allocator, template.project_build_zig, .{project_name});
    defer allocator.free(build_content);
    try project_dir.writeFile(.{ .sub_path = "build.zig", .data = build_content });

    // Write build.zig.zon
    const zon_content = try std.fmt.allocPrint(allocator, template.build_zon, .{project_name});
    defer allocator.free(zon_content);
    try project_dir.writeFile(.{ .sub_path = "build.zig.zon", .data = zon_content });

    // Write src/main.zig
    const main_content = try std.fmt.allocPrint(allocator, template.main_zig, .{ project_name, project_name });
    defer allocator.free(main_content);
    try project_dir.writeFile(.{ .sub_path = "src/main.zig", .data = main_content });

    // Write .gitignore
    const gitignore =
        \\zig-out/
        \\.zig-cache/
        \\
    ;
    try project_dir.writeFile(.{ .sub_path = ".gitignore", .data = gitignore });
}

/// API spec definition
pub const ApiSpec = struct {
    name: []const u8,
    routes: []const ApiRoute,
};

pub const ApiRoute = struct {
    method: []const u8,
    path: []const u8,
    handler: []const u8,
};

/// Generate API routes and handlers from spec
pub fn generateApi(allocator: std.mem.Allocator, spec: ApiSpec, output_dir: []const u8) !void {
    const cwd = std.fs.cwd();
    var out_dir = try cwd.makeOpenPath(output_dir, .{});
    defer out_dir.close();

    // Generate handlers.zig
    var handlers_buf = std.ArrayList(u8){};
    defer handlers_buf.deinit(allocator);
    const hw = handlers_buf.writer(allocator);

    try hw.writeAll("const std = @import(\"std\");\n");
    try hw.writeAll("const zigzero = @import(\"zigzero\");\n");
    try hw.writeAll("const api = zigzero.api;\n\n");

    for (spec.routes) |route| {
        try hw.print("pub fn {s}Handler(ctx: *api.Context) !void {{\n", .{route.handler});
        try hw.writeAll("    try ctx.json(200, \"{\\\"message\\\":\\\"ok\\\"}\");\n");
        try hw.writeAll("}\n\n");
    }

    try out_dir.writeFile(.{ .sub_path = "handlers.zig", .data = handlers_buf.items });

    // Generate routes.zig
    var routes_buf = std.ArrayList(u8){};
    defer routes_buf.deinit(allocator);
    const rw = routes_buf.writer(allocator);

    try rw.writeAll("const std = @import(\"std\");\n");
    try rw.writeAll("const zigzero = @import(\"zigzero\");\n");
    try rw.writeAll("const api = zigzero.api;\n");
    try rw.writeAll("const handlers = @import(\"handlers.zig\");\n\n");
    try rw.writeAll("pub fn registerRoutes(server: *api.Server) !void {\n");

    for (spec.routes) |route| {
        const method = std.ascii.lowerString(try allocator.alloc(u8, route.method.len), route.method);
        defer allocator.free(method);
        try rw.print("    try server.{s}(\"{s}\", handlers.{s}Handler);\n", .{ method, route.path, route.handler });
    }

    try rw.writeAll("}\n");

    try out_dir.writeFile(.{ .sub_path = "routes.zig", .data = routes_buf.items });
}

/// Parse a simple JSON API spec
pub fn parseApiSpec(allocator: std.mem.Allocator, content: []const u8) !ApiSpec {
    const json_value = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer json_value.deinit();

    const root = json_value.value;
    const name = root.object.get("name") orelse return error.InvalidSpec;
    const routes_arr = root.object.get("routes") orelse return error.InvalidSpec;

    var routes = std.ArrayList(ApiRoute){};
    defer routes.deinit(allocator);

    for (routes_arr.array.items) |item| {
        try routes.append(allocator, .{
            .method = try allocator.dupe(u8, item.object.get("method").?.string),
            .path = try allocator.dupe(u8, item.object.get("path").?.string),
            .handler = try allocator.dupe(u8, item.object.get("handler").?.string),
        });
    }

    return .{
        .name = try allocator.dupe(u8, name.string),
        .routes = try routes.toOwnedSlice(allocator),
    };
}

/// SQL column info
pub const ColumnInfo = struct {
    name: []const u8,
    zig_type: []const u8,
};

/// Generate model from SQL DDL
pub fn generateModel(allocator: std.mem.Allocator, table_name: []const u8, columns: []const ColumnInfo, primary_key: []const u8, output_dir: []const u8) !void {
    const cwd = std.fs.cwd();
    var out_dir = try cwd.makeOpenPath(output_dir, .{});
    defer out_dir.close();

    const struct_name = try camelCase(allocator, table_name);
    defer allocator.free(struct_name);

    var fields_buf = std.ArrayList(u8){};
    defer fields_buf.deinit(allocator);
    const fw = fields_buf.writer(allocator);

    for (columns) |col| {
        try fw.print("    {s}: {s},\n", .{ col.name, col.zig_type });
    }

    const model_content = try std.fmt.allocPrint(allocator, template.model_zig, .{ struct_name, table_name, primary_key, fields_buf.items });
    defer allocator.free(model_content);

    const filename = try std.fmt.allocPrint(allocator, "{s}.zig", .{table_name});
    defer allocator.free(filename);
    try out_dir.writeFile(.{ .sub_path = filename, .data = model_content });
}

/// Parse simple CREATE TABLE SQL
pub fn parseCreateTable(allocator: std.mem.Allocator, sql: []const u8) !struct { table_name: []const u8, columns: []const ColumnInfo, primary_key: []const u8 } {
    var table_name: []const u8 = "";
    var primary_key: []const u8 = "";
    var columns = std.ArrayList(ColumnInfo){};
    defer columns.deinit(allocator);

    // Very basic parser for: CREATE TABLE foo ( id INT PRIMARY KEY, name VARCHAR(255) )
    var lower_sql = try std.ascii.allocLowerString(allocator, sql);
    defer allocator.free(lower_sql);

    // Find table name
    const create_table_idx = std.mem.indexOf(u8, lower_sql, "create table") orelse return error.InvalidSql;
    const after_create = std.mem.trim(u8, lower_sql[create_table_idx + 12 ..], " \t\n");
    const name_end = std.mem.indexOfAny(u8, after_create, " (\n") orelse return error.InvalidSql;
    table_name = try allocator.dupe(u8, std.mem.trim(u8, after_create[0..name_end], " \t\n`\""));
    errdefer allocator.free(table_name);

    // Find columns block
    const paren_start = std.mem.indexOfScalar(u8, after_create, '(') orelse return error.InvalidSql;
    const paren_end = std.mem.lastIndexOfScalar(u8, after_create, ')') orelse return error.InvalidSql;
    const cols_block = after_create[paren_start + 1 .. paren_end];

    // Split by comma, but be naive about it
    var col_iter = std.mem.splitScalar(u8, cols_block, ',');
    while (col_iter.next()) |raw_col| {
        const col = std.mem.trim(u8, raw_col, " \t\n");
        if (col.len == 0) continue;

        // Check for PRIMARY KEY constraint
        if (std.mem.startsWith(u8, col, "primary key")) {
            const pk_start = std.mem.indexOfScalar(u8, col, '(') orelse continue;
            const pk_end = std.mem.indexOfScalar(u8, col, ')') orelse continue;
            const pk_col = std.mem.trim(u8, col[pk_start + 1 .. pk_end], " \t\n`\"");
            primary_key = try allocator.dupe(u8, pk_col);
            continue;
        }

        // Parse column definition
        var tokens = std.mem.splitScalar(u8, col, ' ');
        const raw_col_name = tokens.next() orelse continue;
        const col_name = std.mem.trim(u8, raw_col_name, " \t\n`\"");
        if (col_name.len == 0) continue;

        const raw_type = tokens.next() orelse continue;
        const col_type = std.mem.trim(u8, raw_type, " \t\n");
        if (col_type.len == 0) continue;

        const zig_type = sqlTypeToZig(col_type);
        try columns.append(allocator, .{ .name = try allocator.dupe(u8, col_name), .zig_type = zig_type });

        if (std.mem.indexOf(u8, col, "primary key") != null and primary_key.len == 0) {
            primary_key = try allocator.dupe(u8, col_name);
        }
    }

    if (primary_key.len == 0 and columns.items.len > 0) {
        primary_key = try allocator.dupe(u8, columns.items[0].name);
    }

    return .{
        .table_name = table_name,
        .columns = try columns.toOwnedSlice(allocator),
        .primary_key = primary_key,
    };
}

fn sqlTypeToZig(sql_type: []const u8) []const u8 {
    if (std.mem.startsWith(u8, sql_type, "int") or std.mem.eql(u8, sql_type, "integer") or std.mem.eql(u8, sql_type, "bigint") or std.mem.eql(u8, sql_type, "smallint") or std.mem.eql(u8, sql_type, "tinyint")) {
        return "i64";
    } else if (std.mem.startsWith(u8, sql_type, "varchar") or std.mem.startsWith(u8, sql_type, "char") or std.mem.startsWith(u8, sql_type, "text") or std.mem.eql(u8, sql_type, "string")) {
        return "[]const u8";
    } else if (std.mem.startsWith(u8, sql_type, "bool")) {
        return "bool";
    } else if (std.mem.startsWith(u8, sql_type, "float") or std.mem.startsWith(u8, sql_type, "double") or std.mem.startsWith(u8, sql_type, "decimal") or std.mem.startsWith(u8, sql_type, "numeric")) {
        return "f64";
    } else if (std.mem.startsWith(u8, sql_type, "datetime") or std.mem.startsWith(u8, sql_type, "timestamp") or std.mem.eql(u8, sql_type, "date")) {
        return "i64";
    }
    return "[]const u8";
}

fn camelCase(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var result = std.ArrayList(u8){};
    defer result.deinit(allocator);
    var upper_next = true;
    for (s) |c| {
        if (c == '_' or c == '-') {
            upper_next = true;
        } else if (upper_next) {
            try result.append(allocator, std.ascii.toUpper(c));
            upper_next = false;
        } else {
            try result.append(allocator, c);
        }
    }
    return result.toOwnedSlice(allocator);
}

test "generate openapi from dsl" {
    const allocator = std.testing.allocator;
    const def = dsl.ApiDef{
        .name = "test-api",
        .types = &[_]dsl.TypeDef{
            .{
                .name = "Req",
                .fields = &[_]dsl.StructField{
                    .{ .name = "id", .field_type = .int },
                },
            },
        },
        .routes = &[_]dsl.RouteDef{
            .{
                .method = "get",
                .path = "/users/:id",
                .req_type = null,
                .resp_type = null,
                .handler = "getUser",
            },
            .{
                .method = "post",
                .path = "/users",
                .req_type = "Req",
                .resp_type = null,
                .handler = "createUser",
            },
        },
    };

    try generateOpenApi(allocator, def, ".test-openapi");
    defer std.fs.cwd().deleteTree(".test-openapi") catch {};

    const content = try std.fs.cwd().readFileAlloc(allocator, ".test-openapi/openapi.json", 1024 * 1024);
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"/users/:id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"getUser\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"Req\"") != null);
}

test "parse api spec" {
    const allocator = std.testing.allocator;
    const spec_json =
        \\{
        \\  "name": "user-api",
        \\  "routes": [
        \\    { "method": "GET", "path": "/users", "handler": "listUsers" },
        \\    { "method": "POST", "path": "/users", "handler": "createUser" }
        \\  ]
        \\}
    ;
    const spec = try parseApiSpec(allocator, spec_json);
    defer {
        allocator.free(spec.routes);
    }
    try std.testing.expectEqualStrings("user-api", spec.name);
    try std.testing.expectEqual(@as(usize, 2), spec.routes.len);
}

test "parse create table" {
    const allocator = std.testing.allocator;
    const sql = "CREATE TABLE users ( id INT PRIMARY KEY, name VARCHAR(255), age INT )";
    const result = try parseCreateTable(allocator, sql);
    defer {
        allocator.free(result.table_name);
        allocator.free(result.primary_key);
        for (result.columns) |col| {
            allocator.free(col.name);
        }
        allocator.free(result.columns);
    }
    try std.testing.expectEqualStrings("users", result.table_name);
    try std.testing.expectEqualStrings("id", result.primary_key);
    try std.testing.expectEqual(@as(usize, 3), result.columns.len);
}
