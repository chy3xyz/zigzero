//! SQL client abstraction for zigzero
//!
//! Aligned with go-zero's core/stores/sqlx package.

const std = @import("std");
const errors = @import("../core/errors.zig");
const pool = @import("pool.zig");

/// SQL configuration
pub const Config = struct {
    host: []const u8 = "localhost",
    port: u16 = 3306,
    database: []const u8,
    username: []const u8,
    password: []const u8,
    max_connections: u32 = 10,
    max_idle_time_sec: u32 = 3600,
};

/// SQL connection interface (to be implemented by specific drivers)
pub const Connection = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        query: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, sql: []const u8, args: []const Value) errors.ResultT(Rows),
        exec: *const fn (ptr: *anyopaque, sql: []const u8, args: []const Value) errors.ResultT(ExecResult),
        close: *const fn (ptr: *anyopaque) void,
        ping: *const fn (ptr: *anyopaque) errors.Result,
    };

    pub fn query(self: Connection, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) errors.ResultT(Rows) {
        return self.vtable.query(self.ptr, allocator, sql_str, args);
    }

    pub fn exec(self: Connection, sql_str: []const u8, args: []const Value) errors.ResultT(ExecResult) {
        return self.vtable.exec(self.ptr, sql_str, args);
    }

    pub fn close(self: Connection) void {
        return self.vtable.close(self.ptr);
    }

    pub fn ping(self: Connection) errors.Result {
        return self.vtable.ping(self.ptr);
    }
};

/// SQL value types for parameterized queries
pub const Value = union(enum) {
    null,
    int: i64,
    float: f64,
    string: []const u8,
    bool: bool,
};

/// Row of query results
pub const Row = struct {
    columns: []const []const u8,
    values: []const ?Value,

    pub fn get(self: Row, column: []const u8) ?Value {
        for (self.columns, 0..) |col, i| {
            if (std.mem.eql(u8, col, column)) return self.values[i];
        }
        return null;
    }
};

/// Query results
pub const Rows = struct {
    allocator: std.mem.Allocator,
    rows: []const Row,

    pub fn deinit(self: *Rows) void {
        for (self.rows) |row| {
            self.allocator.free(row.columns);
            for (row.values) |v| {
                if (v) |val| {
                    switch (val) {
                        .string => |s| self.allocator.free(s),
                        else => {},
                    }
                }
            }
            self.allocator.free(row.values);
        }
        self.allocator.free(self.rows);
    }
};

/// Execution result
pub const ExecResult = struct {
    last_insert_id: ?i64 = null,
    rows_affected: u64 = 0,
};

/// SQLx client - unified SQL client
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,
    conn_pool: pool.Pool(Connection),

    pub fn init(allocator: std.mem.Allocator, cfg: Config) Client {
        return .{
            .allocator = allocator,
            .config = cfg,
            .conn_pool = pool.Pool(Connection).init(allocator, cfg.max_connections),
        };
    }

    pub fn deinit(self: *Client) void {
        self.conn_pool.deinit();
    }

    /// Register a connection factory
    pub fn registerFactory(self: *Client, factory: *const fn (std.mem.Allocator, Config) errors.ResultT(Connection)) !void {
        _ = self;
        _ = factory;
    }

    /// Query with auto-return to pool
    pub fn query(self: *Client, sql_str: []const u8, args: []const Value) !Rows {
        _ = self;
        _ = sql_str;
        _ = args;
        return error.NotImplemented;
    }

    /// Execute with auto-return to pool
    pub fn exec(self: *Client, sql_str: []const u8, args: []const Value) !ExecResult {
        _ = self;
        _ = sql_str;
        _ = args;
        return error.NotImplemented;
    }

    /// Ping database
    pub fn ping(self: *Client) errors.Result {
        _ = self;
    }

    /// Begin transaction
    pub fn beginTx(self: *Client) !Transaction {
        return Transaction.init(self.allocator);
    }
};

/// SQL transaction
pub const Transaction = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Transaction {
        return .{ .allocator = allocator };
    }

    pub fn query(self: *Transaction, sql_str: []const u8, args: []const Value) !Rows {
        _ = self;
        _ = sql_str;
        _ = args;
        return error.NotImplemented;
    }

    pub fn exec(self: *Transaction, sql_str: []const u8, args: []const Value) !ExecResult {
        _ = self;
        _ = sql_str;
        _ = args;
        return error.NotImplemented;
    }

    pub fn commit(self: *Transaction) errors.Result {
        _ = self;
    }

    pub fn rollback(self: *Transaction) errors.Result {
        _ = self;
    }
};

/// SQL builder for common operations
pub const Builder = struct {
    allocator: std.mem.Allocator,
    table: []const u8,

    pub fn init(allocator: std.mem.Allocator, table: []const u8) Builder {
        return .{
            .allocator = allocator,
            .table = table,
        };
    }

    pub fn select(self: *const Builder, columns: []const []const u8) ![]u8 {
        var buf: [1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();

        try writer.writeAll("SELECT ");
        for (columns, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll(col);
        }
        try writer.print(" FROM {s}", .{self.table});

        return self.allocator.dupe(u8, fbs.getWritten());
    }

    pub fn insert(self: *const Builder, columns: []const []const u8) ![]u8 {
        var buf: [1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();

        try writer.print("INSERT INTO {s} (", .{self.table});
        for (columns, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll(col);
        }
        try writer.writeAll(") VALUES (");
        for (0..columns.len) |i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("?{d}", .{i + 1});
        }
        try writer.writeAll(")");

        return self.allocator.dupe(u8, fbs.getWritten());
    }

    pub fn update(self: *const Builder) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "UPDATE {s} SET ", .{self.table});
    }

    pub fn delete(self: *const Builder) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "DELETE FROM {s}", .{self.table});
    }
};

test "sqlx builder" {
    const allocator = std.testing.allocator;
    const b = Builder.init(allocator, "users");

    const select_sql = try b.select(&.{ "id", "name", "email" });
    defer allocator.free(select_sql);
    try std.testing.expectEqualStrings("SELECT id, name, email FROM users", select_sql);

    const insert_sql = try b.insert(&.{ "name", "email" });
    defer allocator.free(insert_sql);
    try std.testing.expectEqualStrings("INSERT INTO users (name, email) VALUES (?1, ?2)", insert_sql);
}

test "sqlx value" {
    const v = Value{ .int = 42 };
    try std.testing.expectEqual(@as(i64, 42), v.int);
}
