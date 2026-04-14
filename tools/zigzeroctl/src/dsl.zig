//! .api DSL parser for zigzeroctl
//!
//! Supports a simplified go-zero-style API DSL:
//!
//!   name user-api
//!
//!   type LoginReq {
//!     username string
//!     password string
//!   }
//!
//!   get /users/info getUserInfo
//!   post /users/login LoginReq LoginResp login
//!
//! Supported field types: string, int, bool, float

const std = @import("std");

pub const FieldType = enum {
    string,
    int,
    bool,
    float,

    pub fn fromString(s: []const u8) ?FieldType {
        if (std.mem.eql(u8, s, "string")) return .string;
        if (std.mem.eql(u8, s, "int")) return .int;
        if (std.mem.eql(u8, s, "bool")) return .bool;
        if (std.mem.eql(u8, s, "float")) return .float;
        return null;
    }

    pub fn toZigType(self: FieldType) []const u8 {
        return switch (self) {
            .string => "[]const u8",
            .int => "i64",
            .bool => "bool",
            .float => "f64",
        };
    }
};

pub const StructField = struct {
    name: []const u8,
    field_type: FieldType,
};

pub const TypeDef = struct {
    name: []const u8,
    fields: []const StructField,

    pub fn deinit(self: *TypeDef, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.fields) |f| {
            allocator.free(f.name);
        }
        allocator.free(self.fields);
    }
};

pub const RouteDef = struct {
    method: []const u8,
    path: []const u8,
    req_type: ?[]const u8,
    resp_type: ?[]const u8,
    handler: []const u8,

    pub fn deinit(self: *RouteDef, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.path);
        if (self.req_type) |r| allocator.free(r);
        if (self.resp_type) |r| allocator.free(r);
        allocator.free(self.handler);
    }
};

pub const ApiDef = struct {
    name: []const u8,
    types: []TypeDef,
    routes: []RouteDef,

    pub fn deinit(self: *ApiDef, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.types) |*t| t.deinit(allocator);
        allocator.free(self.types);
        for (self.routes) |*r| r.deinit(allocator);
        allocator.free(self.routes);
    }
};

fn skipCommentsAndBlank(line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return "";
    if (std.mem.startsWith(u8, trimmed, "//")) return "";
    if (std.mem.startsWith(u8, trimmed, "#")) return "";
    return trimmed;
}

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !ApiDef {
    var types: std.ArrayList(TypeDef) = .{};
    errdefer {
        for (types.items) |*t| t.deinit(allocator);
        types.deinit(allocator);
    }

    var routes: std.ArrayList(RouteDef) = .{};
    errdefer {
        for (routes.items) |*r| r.deinit(allocator);
        routes.deinit(allocator);
    }

    var name: ?[]const u8 = null;
    errdefer if (name) |n| allocator.free(n);

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = skipCommentsAndBlank(raw_line);
        if (line.len == 0) continue;

        var tokens: std.ArrayList([]const u8) = .{};
        defer {
            for (tokens.items) |t| allocator.free(t);
            tokens.deinit(allocator);
        }

        var it = std.mem.splitScalar(u8, line, ' ');
        while (it.next()) |tok| {
            const trimmed = std.mem.trim(u8, tok, " \t\r\n");
            if (trimmed.len == 0) continue;
            try tokens.append(allocator, try allocator.dupe(u8, trimmed));
        }

        if (tokens.items.len == 0) continue;

        const keyword = tokens.items[0];

        if (std.mem.eql(u8, keyword, "name")) {
            if (tokens.items.len < 2) return error.InvalidSyntax;
            name = try allocator.dupe(u8, tokens.items[1]);
        } else if (std.mem.eql(u8, keyword, "type")) {
            if (tokens.items.len < 2) return error.InvalidSyntax;
            const type_name = tokens.items[1];

            // Collect fields until closing brace
            var fields: std.ArrayList(StructField) = .{};
            errdefer {
                for (fields.items) |f| allocator.free(f.name);
                fields.deinit(allocator);
            }

            // If the opening brace is on the same line: `type Foo {`
            // We need to read subsequent lines for fields.
            while (lines.next()) |field_raw| {
                const field_line = skipCommentsAndBlank(field_raw);
                if (field_line.len == 0) continue;
                if (std.mem.eql(u8, field_line, "}")) break;

                var fit = std.mem.splitScalar(u8, field_line, ' ');
                const f_name = fit.next() orelse return error.InvalidSyntax;
                const f_type_str = fit.next() orelse return error.InvalidSyntax;
                const f_type = FieldType.fromString(f_type_str) orelse return error.InvalidSyntax;
                try fields.append(allocator, .{
                    .name = try allocator.dupe(u8, f_name),
                    .field_type = f_type,
                });
            }

            try types.append(allocator, .{
                .name = try allocator.dupe(u8, type_name),
                .fields = try fields.toOwnedSlice(allocator),
            });
        }
    }

    return ApiDef{
        .name = name orelse "api",
        .types = try types.toOwnedSlice(allocator),
        .routes = try routes.toOwnedSlice(allocator),
    };
}

test "parse dsl" {
    const allocator = std.testing.allocator;
    const source =
        "name user-api\n" ++
        "\n" ++
        "type LoginReq {\n" ++
        "  username string\n" ++
        "  password string\n" ++
        "}\n" ++
        "\n" ++
        "type LoginResp {\n" ++
        "  token string\n" ++
        "}\n" ++
        "\n" ++
        "get /users/:id getUser\n" ++
        "post /users/login LoginReq LoginResp login\n";

    var def = try parse(allocator, source);
    defer def.deinit(allocator);

    try std.testing.expectEqualStrings("user-api", def.name);
    try std.testing.expectEqual(@as(usize, 2), def.types.len);
    try std.testing.expectEqual(@as(usize, 2), def.routes.len);

    try std.testing.expectEqualStrings("LoginReq", def.types[0].name);
    try std.testing.expectEqual(@as(usize, 2), def.types[0].fields.len);

    try std.testing.expectEqualStrings("get", def.routes[0].method);
    try std.testing.expectEqualStrings("/users/:id", def.routes[0].path);
    try std.testing.expect(def.routes[0].req_type == null);
    try std.testing.expect(def.routes[0].resp_type == null);
    try std.testing.expectEqualStrings("getUser", def.routes[0].handler);

    try std.testing.expectEqualStrings("post", def.routes[1].method);
    try std.testing.expectEqualStrings("/users/login", def.routes[1].path);
    try std.testing.expectEqualStrings("LoginReq", def.routes[1].req_type.?);
    try std.testing.expectEqualStrings("LoginResp", def.routes[1].resp_type.?);
    try std.testing.expectEqualStrings("login", def.routes[1].handler);
}
