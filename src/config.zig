//! Configuration management for zigzero
//!
//! Provides unified configuration loading from JSON and environment variables.
//! Aligned with go-zero's config patterns.

const std = @import("std");
const errors = @import("core/errors.zig");

/// Main configuration structure
pub const Config = struct {
    /// Service name
    name: []const u8,
    /// Service port
    port: u16,
    /// Log configuration
    log: LogConfig,
    /// Redis configuration
    redis: RedisConfig,
    /// MySQL configuration
    mysql: MysqlConfig,
    /// Etcd configuration
    etcd: EtcdConfig,
};

/// Log configuration
pub const LogConfig = struct {
    /// Service name for log prefix
    service_name: []const u8 = "zigzero",
    /// Log level (debug, info, warn, error)
    level: []const u8 = "info",
    /// Log mode (console, file, both)
    mode: []const u8 = "console",
    /// Log file path when mode is file or both
    path: ?[]const u8 = null,
    /// Max file size in MB before rotation
    max_size: u32 = 100,
    /// Max number of retained log files
    max_backups: u32 = 30,
    /// Max age of log files in days
    max_age: u32 = 7,
    /// Whether to compress rotated logs
    compress: bool = true,

    pub fn fromJson(allocator: std.mem.Allocator, json: std.json.Value) !LogConfig {
        var cfg = LogConfig{};

        if (json.object.get("service_name")) |v| {
            cfg.service_name = try allocator.dupe(u8, v.string);
        }
        if (json.object.get("level")) |v| {
            cfg.level = try allocator.dupe(u8, v.string);
        }
        if (json.object.get("mode")) |v| {
            cfg.mode = try allocator.dupe(u8, v.string);
        }
        if (json.object.get("path")) |v| {
            const path = try allocator.dupe(u8, v.string);
            cfg.path = path;
        }
        if (json.object.get("max_size")) |v| {
            cfg.max_size = @intCast(v.integer);
        }
        if (json.object.get("max_backups")) |v| {
            cfg.max_backups = @intCast(v.integer);
        }
        if (json.object.get("max_age")) |v| {
            cfg.max_age = @intCast(v.integer);
        }
        if (json.object.get("compress")) |v| {
            cfg.compress = v.bool;
        }

        return cfg;
    }
};

/// Redis configuration
pub const RedisConfig = struct {
    /// Redis host address
    host: []const u8 = "localhost",
    /// Redis port
    port: u16 = 6379,
    /// Redis password
    password: ?[]const u8 = null,
    /// Redis database number
    db: u32 = 0,
    /// Connection pool size
    pool_size: u32 = 100,
    /// Read timeout in milliseconds
    read_timeout_ms: u32 = 3000,
    /// Write timeout in milliseconds
    write_timeout_ms: u32 = 3000,

    pub fn fromJson(allocator: std.mem.Allocator, json: std.json.Value) !RedisConfig {
        var cfg = RedisConfig{};

        if (json.object.get("host")) |v| {
            cfg.host = try allocator.dupe(u8, v.string);
        }
        if (json.object.get("port")) |v| {
            cfg.port = @intCast(v.integer);
        }
        if (json.object.get("password")) |v| {
            const pwd = try allocator.dupe(u8, v.string);
            cfg.password = pwd;
        }
        if (json.object.get("db")) |v| {
            cfg.db = @intCast(v.integer);
        }
        if (json.object.get("pool_size")) |v| {
            cfg.pool_size = @intCast(v.integer);
        }
        if (json.object.get("read_timeout_ms")) |v| {
            cfg.read_timeout_ms = @intCast(v.integer);
        }
        if (json.object.get("write_timeout_ms")) |v| {
            cfg.write_timeout_ms = @intCast(v.integer);
        }

        return cfg;
    }
};

/// MySQL configuration
pub const MysqlConfig = struct {
    /// MySQL host
    host: []const u8 = "localhost",
    /// MySQL port
    port: u16 = 3306,
    /// MySQL database name
    database: []const u8 = "",
    /// MySQL username
    username: []const u8 = "root",
    /// MySQL password
    password: []const u8 = "",
    /// Maximum number of open connections
    max_open_conns: u32 = 100,
    /// Maximum number of idle connections
    max_idle_conns: u32 = 10,
    /// Maximum connection lifetime in seconds
    max_lifetime_sec: u32 = 3600,
    /// Connection max idle time in seconds
    conn_max_idle_time_sec: u32 = 900,

    pub fn fromJson(allocator: std.mem.Allocator, json: std.json.Value) !MysqlConfig {
        var cfg = MysqlConfig{};

        if (json.object.get("host")) |v| cfg.host = try allocator.dupe(u8, v.string);
        if (json.object.get("port")) |v| cfg.port = @intCast(v.integer);
        if (json.object.get("database")) |v| cfg.database = try allocator.dupe(u8, v.string);
        if (json.object.get("username")) |v| cfg.username = try allocator.dupe(u8, v.string);
        if (json.object.get("password")) |v| cfg.password = try allocator.dupe(u8, v.string);
        if (json.object.get("max_open_conns")) |v| cfg.max_open_conns = @intCast(v.integer);
        if (json.object.get("max_idle_conns")) |v| cfg.max_idle_conns = @intCast(v.integer);
        if (json.object.get("max_lifetime_sec")) |v| cfg.max_lifetime_sec = @intCast(v.integer);
        if (json.object.get("conn_max_idle_time_sec")) |v| cfg.conn_max_idle_time_sec = @intCast(v.integer);

        return cfg;
    }
};

/// Etcd configuration
pub const EtcdConfig = struct {
    /// Etcd endpoints (host:port)
    endpoints: [][]const u8 = &.{},
    /// Etcd username
    username: ?[]const u8 = null,
    /// Etcd password
    password: ?[]const u8 = null,
    /// Request timeout in seconds
    timeout_sec: u32 = 5,

    pub fn fromJson(allocator: std.mem.Allocator, json: std.json.Value) !EtcdConfig {
        var cfg = EtcdConfig{};

        if (json.object.get("endpoints")) |v| {
            const arr = v.array;
            cfg.endpoints = try allocator.alloc([]const u8, arr.items.len);
            for (arr.items, 0..) |item, i| {
                cfg.endpoints[i] = try allocator.dupe(u8, item.string);
            }
        }
        if (json.object.get("username")) |v| {
            const uname = try allocator.dupe(u8, v.string);
            cfg.username = uname;
        }
        if (json.object.get("password")) |v| {
            const pwd = try allocator.dupe(u8, v.string);
            cfg.password = pwd;
        }
        if (json.object.get("timeout_sec")) |v| cfg.timeout_sec = @intCast(v.integer);

        return cfg;
    }

    pub fn deinit(self: *EtcdConfig, allocator: std.mem.Allocator) void {
        for (self.endpoints) |ep| {
            allocator.free(ep);
        }
        allocator.free(self.endpoints);
        if (self.username) |u| allocator.free(u);
        if (self.password) |p| allocator.free(p);
    }
};

/// Config loader
pub const Loader = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Loader {
        return .{ .allocator = allocator };
    }

    /// Load configuration from JSON file
    pub fn loadJson(self: Loader, comptime T: type, path: []const u8) !T {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        return self.parseJson(T, content);
    }

    /// Load configuration from YAML file (simplified YAML subset)
    pub fn loadYaml(self: Loader, comptime T: type, path: []const u8) !T {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        return self.parseYaml(T, content);
    }

    /// Parse YAML content into config type (simplified subset)
    pub fn parseYaml(self: Loader, comptime T: type, content: []const u8) !T {
        const json_str = try yamlToJson(self.allocator, content);
        defer self.allocator.free(json_str);
        return self.parseJson(T, json_str);
    }

    /// Parse JSON content into config type
    pub fn parseJson(self: Loader, comptime T: type, content: []const u8) !T {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();

        var cfg: T = undefined;
        const json = parsed.value;

        inline for (@typeInfo(T).@"struct".fields) |field| {
            if (json.object.get(field.name)) |value| {
                @field(cfg, field.name) = try parseField(self.allocator, field.type, value);
            }
        }

        return cfg;
    }

    fn parseField(allocator: std.mem.Allocator, comptime T: type, value: std.json.Value) !T {
        return switch (@typeInfo(T)) {
            .int => @intCast(value.integer),
            .float => @floatCast(value.float),
            .bool => value.bool,
            .pointer => |p| switch (p.size) {
                .slice => if (p.child == u8) try allocator.dupe(u8, value.string) else @compileError("Unsupported slice type"),
                else => @compileError("Unsupported pointer type"),
            },
            .optional => |o| if (value == .null) null else try parseField(allocator, o.child, value),
            .@"struct" => try T.fromJson(allocator, value),
            else => @compileError("Unsupported field type"),
        };
    }

    /// Load configuration from environment variables
    pub fn loadEnv(self: Loader, comptime T: type, prefix: []const u8) !T {
        var cfg: T = undefined;
        var buf: [256]u8 = undefined;

        inline for (@typeInfo(T).@"struct".fields) |field| {
            const upper_name = std.ascii.upperString(&buf, field.name);
            const env_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, upper_name });
            defer self.allocator.free(env_name);

            if (std.process.getEnvVarOwned(self.allocator, env_name)) |value| {
                defer self.allocator.free(value);
                @field(cfg, field.name) = try parseEnvValue(self.allocator, field.type, value);
            } else |_| {}
        }

        return cfg;
    }

    fn parseEnvValue(allocator: std.mem.Allocator, comptime T: type, value: []const u8) !T {
        return switch (@typeInfo(T)) {
            .int => std.fmt.parseInt(T, value, 10),
            .float => std.fmt.parseFloat(T, value),
            .bool => std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1"),
            .pointer => |p| switch (p.size) {
                .slice => if (p.child == u8) try allocator.dupe(u8, value) else @compileError("Unsupported slice type"),
                else => @compileError("Unsupported pointer type"),
            },
            .optional => |o| try parseEnvValue(allocator, o.child, value),
            .@"struct" => @compileError("Nested structs not supported in env vars"),
            else => @compileError("Unsupported field type"),
        };
    }
};

/// Convert a simplified YAML subset to JSON string.
/// Supports: key: value, nested objects, arrays with '- ', strings, numbers, bools.
fn yamlToJson(allocator: std.mem.Allocator, yaml: []const u8) ![]u8 {
    var line_list: std.ArrayList([]const u8) = .{};
    defer line_list.deinit(allocator);

    var lines_iter = std.mem.splitScalar(u8, yaml, '\n');
    while (lines_iter.next()) |raw_line| {
        const line = stripComment(raw_line);
        if (line.len > 0) {
            try line_list.append(allocator, line);
        }
    }

    const yaml_lines = line_list.items;
    var line_idx: usize = 0;

    var stack: std.ArrayList(usize) = .{};
    defer stack.deinit(allocator);

    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "{");
    try stack.append(allocator, 0);

    var in_array = false;
    var first_item = true;

    while (line_idx < yaml_lines.len) {
        const line = yaml_lines[line_idx];
        line_idx += 1;

        const indent = countIndent(line);
        const trimmed = std.mem.trimLeft(u8, line, " ");

        // Handle array items
        if (std.mem.startsWith(u8, trimmed, "- ")) {
            if (!in_array) {
                in_array = true;
                first_item = true;
                try result.appendSlice(allocator, "[");
            }
            if (!first_item) try result.appendSlice(allocator, ",");
            first_item = false;

            const item = std.mem.trimLeft(u8, trimmed[2..], " ");
            try appendYamlValue(allocator, &result, item);
            continue;
        }

        // Close array if we were in one
        if (in_array) {
            try result.appendSlice(allocator, "]");
            in_array = false;
        }

        // Parse key: value (supports both "key: value" and "key:")
        if (std.mem.indexOf(u8, trimmed, ":")) |colon_pos| {
            const key = std.mem.trim(u8, trimmed[0..colon_pos], " \"");
            const value = std.mem.trimLeft(u8, trimmed[colon_pos + 1 ..], " ");

            // Adjust nesting based on indentation
            while (stack.items.len > 1 and indent <= stack.items[stack.items.len - 1]) {
                _ = stack.pop();
                try result.appendSlice(allocator, "}");
            }

            // Add comma if needed
            if (result.items.len > 1 and result.items[result.items.len - 1] != '{' and result.items[result.items.len - 1] != '[') {
                try result.appendSlice(allocator, ",");
            }

            try result.append(allocator, '"');
            try result.appendSlice(allocator, key);
            try result.appendSlice(allocator, "\":");

            if (value.len == 0) {
                // Peek ahead to detect if next line is an array item
                const is_array = blk: {
                    if (line_idx < yaml_lines.len) {
                        const next_trimmed = std.mem.trimLeft(u8, yaml_lines[line_idx], " ");
                        if (std.mem.startsWith(u8, next_trimmed, "- ")) break :blk true;
                    }
                    break :blk false;
                };

                if (is_array) {
                    // Start array immediately; items will follow on next lines
                    try result.appendSlice(allocator, "[");
                    in_array = true;
                    first_item = true;
                    // Don't push to stack; the array is closed when a non-array line appears
                } else {
                    // Nested object starts
                    try result.appendSlice(allocator, "{");
                    try stack.append(allocator, indent);
                }
            } else {
                try appendYamlValue(allocator, &result, value);
            }
        }
    }

    // Close remaining structures
    if (in_array) try result.appendSlice(allocator, "]");
    while (stack.items.len > 0) : (_ = stack.pop()) {
        try result.appendSlice(allocator, "}");
    }

    return result.toOwnedSlice(allocator);
}

fn stripComment(line: []const u8) []const u8 {
    if (std.mem.indexOf(u8, line, " #")) |pos| {
        return line[0..pos];
    }
    if (line.len > 0 and line[0] == '#') return "";
    return std.mem.trimRight(u8, line, "\r");
}

fn countIndent(line: []const u8) usize {
    var count: usize = 0;
    for (line) |c| {
        if (c == ' ') count += 1 else break;
    }
    return count;
}

fn appendYamlValue(allocator: std.mem.Allocator, result: *std.ArrayList(u8), value: []const u8) !void {
    const trimmed = std.mem.trim(u8, value, " \"");
    if (std.mem.eql(u8, trimmed, "true")) {
        try result.appendSlice(allocator, "true");
    } else if (std.mem.eql(u8, trimmed, "false")) {
        try result.appendSlice(allocator, "false");
    } else if (std.mem.eql(u8, trimmed, "null")) {
        try result.appendSlice(allocator, "null");
    } else {
        // Try to detect number
        const is_number = blk: {
            _ = std.fmt.parseInt(i64, trimmed, 10) catch {
                _ = std.fmt.parseFloat(f64, trimmed) catch {
                    break :blk false;
                };
            };
            break :blk trimmed.len > 0;
        };

        if (is_number) {
            try result.appendSlice(allocator, trimmed);
        } else {
            try result.append(allocator, '"');
            try result.appendSlice(allocator, trimmed);
            try result.append(allocator, '"');
        }
    }
}

/// Load configuration from JSON file
pub fn loadJson(comptime T: type, allocator: std.mem.Allocator, path: []const u8) !T {
    const loader = Loader.init(allocator);
    return loader.loadJson(T, path);
}

/// Load configuration from YAML file
pub fn loadYaml(comptime T: type, allocator: std.mem.Allocator, path: []const u8) !T {
    const loader = Loader.init(allocator);
    return loader.loadYaml(T, path);
}

/// Load configuration from environment variables
pub fn loadEnv(comptime T: type, allocator: std.mem.Allocator, prefix: []const u8) !T {
    const loader = Loader.init(allocator);
    return loader.loadEnv(T, prefix);
}

test "config json parsing" {
    const json_content =
        \\{
        \\  "name": "test-service",
        \\  "port": 8080,
        \\  "log": {
        \\    "level": "debug",
        \\    "service_name": "test"
        \\  },
        \\  "redis": {
        \\    "host": "localhost",
        \\    "port": 6379
        \\  },
        \\  "mysql": {
        \\    "host": "localhost",
        \\    "port": 3306,
        \\    "database": "testdb"
        \\  },
        \\  "etcd": {
        \\    "endpoints": ["localhost:2379"],
        \\    "timeout_sec": 10
        \\  }
        \\}
    ;

    const allocator = std.testing.allocator;
    const cfg = try Loader.init(allocator).parseJson(Config, json_content);
    defer {
        allocator.free(cfg.name);
        allocator.free(cfg.log.level);
        allocator.free(cfg.log.service_name);
        allocator.free(cfg.redis.host);
        allocator.free(cfg.mysql.host);
        allocator.free(cfg.mysql.database);
        for (cfg.etcd.endpoints) |ep| allocator.free(ep);
        allocator.free(cfg.etcd.endpoints);
    }

    try std.testing.expectEqualStrings("test-service", cfg.name);
    try std.testing.expectEqual(@as(u16, 8080), cfg.port);
    try std.testing.expectEqualStrings("debug", cfg.log.level);
    try std.testing.expectEqualStrings("localhost", cfg.redis.host);
    try std.testing.expectEqual(@as(u16, 6379), cfg.redis.port);
}

test "config yaml parsing" {
    const yaml_content =
        \\name: test-service
        \\port: 8080
        \\log:
        \\  level: debug
        \\  service_name: test
        \\redis:
        \\  host: localhost
        \\  port: 6379
        \\mysql:
        \\  host: localhost
        \\  port: 3306
        \\  database: testdb
        \\etcd:
        \\  endpoints:
        \\    - localhost:2379
        \\  timeout_sec: 10
    ;

    const allocator = std.testing.allocator;
    const cfg = try Loader.init(allocator).parseYaml(Config, yaml_content);
    defer {
        allocator.free(cfg.name);
        allocator.free(cfg.log.level);
        allocator.free(cfg.log.service_name);
        allocator.free(cfg.redis.host);
        allocator.free(cfg.mysql.host);
        allocator.free(cfg.mysql.database);
        for (cfg.etcd.endpoints) |ep| allocator.free(ep);
        allocator.free(cfg.etcd.endpoints);
    }

    try std.testing.expectEqualStrings("test-service", cfg.name);
    try std.testing.expectEqual(@as(u16, 8080), cfg.port);
    try std.testing.expectEqualStrings("debug", cfg.log.level);
    try std.testing.expectEqualStrings("localhost", cfg.redis.host);
    try std.testing.expectEqual(@as(u16, 6379), cfg.redis.port);
}

test "config env parsing" {
    const allocator = std.testing.allocator;
    // This test requires env vars to be set, skip in normal runs
    if (true) return error.SkipZigTest;
    _ = allocator;
}

test "config module" {
    try std.testing.expect(true);
}
