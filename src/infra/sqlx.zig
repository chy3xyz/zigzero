//! SQL client abstraction for zigzero
//!
//! Aligned with go-zero's core/stores/sqlx package.
//! Supports SQLite, PostgreSQL, and MySQL via C bindings.

const std = @import("std");
const errors = @import("../core/errors.zig");
const sqlite3_c = @import("sqlite3_c.zig");
const libpq_c = @import("libpq_c.zig");
const libmysql_c = @import("libmysql_c.zig");
const breaker = @import("breaker.zig");

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

    pub fn scan(self: Row, allocator: std.mem.Allocator, comptime T: type) !T {
        return scanStruct(allocator, T, self, false);
    }

    pub fn scanPartial(self: Row, allocator: std.mem.Allocator, comptime T: type) !T {
        return scanStruct(allocator, T, self, true);
    }
};

/// Query results
pub const Rows = struct {
    allocator: std.mem.Allocator,
    rows: []const Row,

    pub fn deinit(self: *Rows) void {
        for (self.rows) |row| {
            for (row.columns) |col| {
                self.allocator.free(col);
            }
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

/// Database driver type
pub const Driver = enum {
    sqlite,
    postgres,
    mysql,
};

/// SQL connection interface
pub const Conn = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        query: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) errors.ResultT(Rows),
        exec: *const fn (ptr: *anyopaque, sql_str: []const u8, args: []const Value) errors.ResultT(ExecResult),
        close: *const fn (ptr: *anyopaque) void,
        ping: *const fn (ptr: *anyopaque) errors.Result,
        begin: *const fn (ptr: *anyopaque) errors.Result,
        commit: *const fn (ptr: *anyopaque) errors.Result,
        rollback: *const fn (ptr: *anyopaque) errors.Result,
    };

    pub fn query(self: Conn, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) errors.ResultT(Rows) {
        return self.vtable.query(self.ptr, allocator, sql_str, args);
    }

    pub fn exec(self: Conn, sql_str: []const u8, args: []const Value) errors.ResultT(ExecResult) {
        return self.vtable.exec(self.ptr, sql_str, args);
    }

    pub fn close(self: Conn) void {
        self.vtable.close(self.ptr);
    }

    pub fn ping(self: Conn) errors.Result {
        return self.vtable.ping(self.ptr);
    }

    pub fn begin(self: Conn) errors.Result {
        return self.vtable.begin(self.ptr);
    }

    pub fn commit(self: Conn) errors.Result {
        return self.vtable.commit(self.ptr);
    }

    pub fn rollback(self: Conn) errors.Result {
        return self.vtable.rollback(self.ptr);
    }
};

// ==================== Struct Scanning ====================

fn scanStruct(allocator: std.mem.Allocator, comptime T: type, row: Row, partial: bool) !T {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("scanStruct only supports structs, got " ++ @typeName(T));

    var result: T = undefined;
    inline for (info.@"struct".fields) |field| {
        const val = row.get(field.name);
        const FieldType = field.type;

        if (@typeInfo(FieldType) == .optional) {
            const ChildType = @typeInfo(FieldType).optional.child;
            if (val == null or val.? == .null) {
                @field(result, field.name) = null;
            } else {
                @field(result, field.name) = try valueToType(allocator, ChildType, val.?);
            }
        } else {
            if (val == null or val.? == .null) {
                if (partial) {
                    @field(result, field.name) = std.mem.zeroes(FieldType);
                } else {
                    return error.NotFound;
                }
            } else {
                @field(result, field.name) = try valueToType(allocator, FieldType, val.?);
            }
        }
    }
    return result;
}

fn valueToType(allocator: std.mem.Allocator, comptime T: type, val: Value) !T {
    return switch (T) {
        i64 => if (val == .int) val.int else error.DatabaseError,
        i32 => if (val == .int) @intCast(val.int) else error.DatabaseError,
        u64 => if (val == .int) @intCast(val.int) else error.DatabaseError,
        u32 => if (val == .int) @intCast(val.int) else error.DatabaseError,
        f64 => if (val == .float) val.float else if (val == .int) @floatFromInt(val.int) else error.DatabaseError,
        f32 => if (val == .float) @floatCast(val.float) else if (val == .int) @floatFromInt(val.int) else error.DatabaseError,
        bool => if (val == .bool) val.bool else if (val == .int) val.int != 0 else error.DatabaseError,
        []const u8 => if (val == .string) (allocator.dupe(u8, val.string) catch return error.DatabaseError) else error.DatabaseError,
        else => @compileError("Unsupported scan type: " ++ @typeName(T)),
    };
}

pub fn freeScanned(allocator: std.mem.Allocator, comptime T: type, val: T) void {
    const info = @typeInfo(T);
    if (info != .@"struct") return;
    inline for (info.@"struct".fields) |field| {
        const FieldType = field.type;
        if (FieldType == []const u8) {
            allocator.free(@field(val, field.name));
        } else if (@typeInfo(FieldType) == .optional and @typeInfo(FieldType).optional.child == []const u8) {
            if (@field(val, field.name)) |s| allocator.free(s);
        }
    }
}

// ==================== SQLite Implementation ====================

pub const SQLiteConn = struct {
    db: ?*sqlite3_c.sqlite3,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !SQLiteConn {
        var db: ?*sqlite3_c.sqlite3 = null;
        const c_path = allocator.dupeZ(u8, path) catch return error.DatabaseError;
        defer allocator.free(c_path);
        const rc = sqlite3_c.sqlite3_open(c_path.ptr, &db);
        if (rc != sqlite3_c.SQLITE_OK or db == null) {
            if (db) |d| {
                _ = sqlite3_c.sqlite3_errmsg(d);
                _ = sqlite3_c.sqlite3_close(d);
                return error.DatabaseError;
            }
            return error.DatabaseError;
        }
        return .{ .db = db, .allocator = allocator };
    }

    fn queryFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) errors.ResultT(Rows) {
        _ = allocator;
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        var stmt: ?*sqlite3_c.sqlite3_stmt = null;
        const rc = sqlite3_c.sqlite3_prepare_v2(self.db, @ptrCast(sql_str.ptr), @intCast(sql_str.len), &stmt, null);
        if (rc != sqlite3_c.SQLITE_OK or stmt == null) return error.DatabaseError;
        defer _ = sqlite3_c.sqlite3_finalize(stmt);

        try bindSQLite(stmt.?, args);

        const col_count = sqlite3_c.sqlite3_column_count(stmt);
        var rows_list: std.ArrayList(Row) = .{};
        var success = false;
        defer {
            if (!success) {
                for (rows_list.items) |row| {
                    for (row.columns) |col| {
                        self.allocator.free(col);
                    }
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
            }
            rows_list.deinit(self.allocator);
        }

        while (sqlite3_c.sqlite3_step(stmt) == sqlite3_c.SQLITE_ROW) {
            const columns = self.allocator.alloc([]const u8, @intCast(col_count)) catch return error.DatabaseError;
            const values = self.allocator.alloc(?Value, @intCast(col_count)) catch return error.DatabaseError;
            for (0..@intCast(col_count)) |i| {
                const raw_name = sqlite3_c.sqlite3_column_name(stmt, @intCast(i));
                const name_len = std.mem.len(raw_name);
                const name = raw_name[0..name_len];
                columns[i] = self.allocator.dupe(u8, name) catch return error.DatabaseError;
                values[i] = readSQLiteValue(self.allocator, stmt, @intCast(i));
            }
            rows_list.append(self.allocator, .{ .columns = columns, .values = values }) catch return error.DatabaseError;
        }

        const rows_slice = self.allocator.alloc(Row, rows_list.items.len) catch return error.DatabaseError;
        @memcpy(rows_slice, rows_list.items);
        success = true;
        return Rows{ .allocator = self.allocator, .rows = rows_slice };
    }

    fn execFn(ptr: *anyopaque, sql_str: []const u8, args: []const Value) errors.ResultT(ExecResult) {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        var stmt: ?*sqlite3_c.sqlite3_stmt = null;
        const rc = sqlite3_c.sqlite3_prepare_v2(self.db, @ptrCast(sql_str.ptr), @intCast(sql_str.len), &stmt, null);
        if (rc != sqlite3_c.SQLITE_OK or stmt == null) return error.DatabaseError;
        defer _ = sqlite3_c.sqlite3_finalize(stmt);

        try bindSQLite(stmt.?, args);

        const step_rc = sqlite3_c.sqlite3_step(stmt);
        if (step_rc != sqlite3_c.SQLITE_DONE and step_rc != sqlite3_c.SQLITE_ROW) return error.DatabaseError;

        return ExecResult{
            .last_insert_id = sqlite3_c.sqlite3_last_insert_rowid(self.db),
            .rows_affected = @intCast(sqlite3_c.sqlite3_changes(self.db)),
        };
    }

    fn closeFn(ptr: *anyopaque) void {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        if (self.db) |db| {
            _ = sqlite3_c.sqlite3_close(db);
            self.db = null;
        }
        self.allocator.destroy(self);
    }

    fn pingFn(ptr: *anyopaque) errors.Result {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        if (self.db == null) return error.DatabaseError;
    }

    fn beginFn(ptr: *anyopaque) errors.Result {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        const rc = sqlite3_c.sqlite3_exec(self.db, "BEGIN", null, null, null);
        if (rc != sqlite3_c.SQLITE_OK) return error.DatabaseError;
    }

    fn commitFn(ptr: *anyopaque) errors.Result {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        const rc = sqlite3_c.sqlite3_exec(self.db, "COMMIT", null, null, null);
        if (rc != sqlite3_c.SQLITE_OK) return error.DatabaseError;
    }

    fn rollbackFn(ptr: *anyopaque) errors.Result {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        const rc = sqlite3_c.sqlite3_exec(self.db, "ROLLBACK", null, null, null);
        if (rc != sqlite3_c.SQLITE_OK) return error.DatabaseError;
    }

    pub fn toConn(self: *SQLiteConn) Conn {
        return .{
            .ptr = self,
            .vtable = &.{
                .query = queryFn,
                .exec = execFn,
                .close = closeFn,
                .ping = pingFn,
                .begin = beginFn,
                .commit = commitFn,
                .rollback = rollbackFn,
            },
        };
    }
};

const SQLITE_TRANSIENT: ?*const anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

fn bindSQLite(stmt: ?*sqlite3_c.sqlite3_stmt, args: []const Value) !void {
    for (args, 0..) |arg, i| {
        const idx: c_int = @intCast(i + 1);
        const rc = switch (arg) {
            .null => sqlite3_c.sqlite3_bind_null(stmt, idx),
            .int => |v| sqlite3_c.sqlite3_bind_int64(stmt, idx, v),
            .float => |v| sqlite3_c.sqlite3_bind_double(stmt, idx, v),
            .string => |v| sqlite3_c.sqlite3_bind_text(stmt, idx, @ptrCast(v.ptr), @intCast(v.len), @ptrCast(SQLITE_TRANSIENT)),
            .bool => |v| sqlite3_c.sqlite3_bind_int64(stmt, idx, if (v) 1 else 0),
        };
        if (rc != sqlite3_c.SQLITE_OK) return error.DatabaseError;
    }
}

fn readSQLiteValue(allocator: std.mem.Allocator, stmt: ?*sqlite3_c.sqlite3_stmt, col: c_int) ?Value {
    const t = sqlite3_c.sqlite3_column_type(stmt, col);
    return switch (t) {
        sqlite3_c.SQLITE_INTEGER => Value{ .int = sqlite3_c.sqlite3_column_int64(stmt, col) },
        sqlite3_c.SQLITE_FLOAT => Value{ .float = sqlite3_c.sqlite3_column_double(stmt, col) },
        sqlite3_c.SQLITE_TEXT => blk: {
            const raw_text = sqlite3_c.sqlite3_column_text(stmt, col);
            const text_len = std.mem.len(raw_text);
            const text = raw_text[0..text_len];
            break :blk Value{ .string = allocator.dupe(u8, text) catch return null };
        },
        sqlite3_c.SQLITE_NULL => null,
        else => null,
    };
}

// ==================== PostgreSQL Implementation ====================

pub const PostgresConn = struct {
    conn: ?*libpq_c.PGconn,
    allocator: std.mem.Allocator,

    pub fn connect(allocator: std.mem.Allocator, conninfo: []const u8) !PostgresConn {
        const conn = libpq_c.PQconnectdb(@ptrCast(conninfo.ptr));
        if (conn == null or libpq_c.PQstatus(conn) != libpq_c.ConnStatusType.CONNECTION_OK) {
            if (conn) |c| libpq_c.PQfinish(c);
            return error.DatabaseError;
        }
        return .{ .conn = conn, .allocator = allocator };
    }

    fn queryFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) errors.ResultT(Rows) {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        const res = execParams(self, sql_str, args) orelse return error.DatabaseError;
        defer libpq_c.PQclear(res);

        if (libpq_c.PQresultStatus(res) != libpq_c.ExecStatusType.PGRES_TUPLES_OK) return error.DatabaseError;

        const n_rows = libpq_c.PQntuples(res);
        const n_cols = libpq_c.PQnfields(res);

        var rows_list: std.ArrayList(Row) = .{};
        var success = false;
        defer {
            if (!success) {
                for (rows_list.items) |row| {
                    for (row.columns) |col| {
                        allocator.free(col);
                    }
                    allocator.free(row.columns);
                    for (row.values) |v| {
                        if (v) |val| {
                            switch (val) {
                                .string => |s| allocator.free(s),
                                else => {},
                            }
                        }
                    }
                    allocator.free(row.values);
                }
            }
            rows_list.deinit(allocator);
        }

        for (0..@intCast(n_rows)) |r| {
            const columns = allocator.alloc([]const u8, @intCast(n_cols)) catch return error.DatabaseError;
            const values = allocator.alloc(?Value, @intCast(n_cols)) catch return error.DatabaseError;
            for (0..@intCast(n_cols)) |c| {
                const name = std.mem.span(libpq_c.PQfname(res, @intCast(c)));
                columns[c] = allocator.dupe(u8, name) catch return error.DatabaseError;
                if (libpq_c.PQgetisnull(res, @intCast(r), @intCast(c)) == 1) {
                    values[c] = null;
                } else {
                    const val = std.mem.span(libpq_c.PQgetvalue(res, @intCast(r), @intCast(c)));
                    values[c] = .{ .string = allocator.dupe(u8, val) catch return error.DatabaseError };
                }
            }
            rows_list.append(allocator, .{ .columns = columns, .values = values }) catch return error.DatabaseError;
        }

        const rows_slice = allocator.alloc(Row, rows_list.items.len) catch return error.DatabaseError;
        @memcpy(rows_slice, rows_list.items);
        success = true;
        return Rows{ .allocator = allocator, .rows = rows_slice };
    }

    fn execFn(ptr: *anyopaque, sql_str: []const u8, args: []const Value) errors.ResultT(ExecResult) {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        const res = execParams(self, sql_str, args) orelse return error.DatabaseError;
        defer libpq_c.PQclear(res);

        const status = libpq_c.PQresultStatus(res);
        if (status != libpq_c.ExecStatusType.PGRES_COMMAND_OK and status != libpq_c.ExecStatusType.PGRES_TUPLES_OK) return error.DatabaseError;

        const cmd = std.mem.span(libpq_c.PQcmdTuples(res));
        const affected = std.fmt.parseInt(u64, cmd, 10) catch 0;
        return ExecResult{ .rows_affected = affected };
    }

    fn execParams(self: *PostgresConn, sql_str: []const u8, args: []const Value) ?*libpq_c.PGresult {
        if (self.conn == null) return null;
        const paramValues = self.allocator.alloc(?[*]const u8, args.len) catch return null;
        // Note: int/float string dupes may leak in this simplified implementation.
        for (args, 0..) |arg, i| {
            paramValues[i] = switch (arg) {
                .null => null,
                .int => |v| blk: {
                    const s = std.fmt.allocPrint(self.allocator, "{d}", .{v}) catch {
                        self.allocator.free(paramValues);
                        return null;
                    };
                    break :blk @ptrCast(s.ptr);
                },
                .float => |v| blk: {
                    const s = std.fmt.allocPrint(self.allocator, "{d}", .{v}) catch {
                        self.allocator.free(paramValues);
                        return null;
                    };
                    break :blk @ptrCast(s.ptr);
                },
                .string => |v| @ptrCast(v.ptr),
                .bool => |v| if (v) @ptrCast("t") else @ptrCast("f"),
            };
        }
        const res = libpq_c.PQexecParams(self.conn, @ptrCast(sql_str.ptr), @intCast(args.len), null, @ptrCast(paramValues.ptr), null, null, 0);
        self.allocator.free(paramValues);
        return res;
    }

    fn closeFn(ptr: *anyopaque) void {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        if (self.conn) |conn| {
            libpq_c.PQfinish(conn);
            self.conn = null;
        }
        self.allocator.destroy(self);
    }

    fn pingFn(ptr: *anyopaque) errors.Result {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        if (self.conn == null or libpq_c.PQstatus(self.conn) != libpq_c.ConnStatusType.CONNECTION_OK) return error.DatabaseError;
    }

    fn beginFn(ptr: *anyopaque) errors.Result {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        const res = libpq_c.PQexec(self.conn, "BEGIN");
        defer libpq_c.PQclear(res);
        if (libpq_c.PQresultStatus(res) != libpq_c.ExecStatusType.PGRES_COMMAND_OK) return error.DatabaseError;
    }

    fn commitFn(ptr: *anyopaque) errors.Result {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        const res = libpq_c.PQexec(self.conn, "COMMIT");
        defer libpq_c.PQclear(res);
        if (libpq_c.PQresultStatus(res) != libpq_c.ExecStatusType.PGRES_COMMAND_OK) return error.DatabaseError;
    }

    fn rollbackFn(ptr: *anyopaque) errors.Result {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        const res = libpq_c.PQexec(self.conn, "ROLLBACK");
        defer libpq_c.PQclear(res);
        if (libpq_c.PQresultStatus(res) != libpq_c.ExecStatusType.PGRES_COMMAND_OK) return error.DatabaseError;
    }

    pub fn toConn(self: *PostgresConn) Conn {
        return .{
            .ptr = self,
            .vtable = &.{
                .query = queryFn,
                .exec = execFn,
                .close = closeFn,
                .ping = pingFn,
                .begin = beginFn,
                .commit = commitFn,
                .rollback = rollbackFn,
            },
        };
    }
};

// ==================== MySQL Implementation ====================

fn formatQuery(allocator: std.mem.Allocator, sql: []const u8, args: []const Value) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    var arg_idx: usize = 0;
    for (sql) |c| {
        if (c == '?') {
            if (arg_idx >= args.len) return error.DatabaseError;
            const arg = args[arg_idx];
            arg_idx += 1;
            switch (arg) {
                .null => try buf.appendSlice(allocator, "NULL"),
                .int => |v| try std.fmt.format(buf.writer(allocator), "{d}", .{v}),
                .float => |v| try std.fmt.format(buf.writer(allocator), "{d}", .{v}),
                .string => |v| {
                    try buf.append(allocator, '\'');
                    try buf.appendSlice(allocator, v);
                    try buf.append(allocator, '\'');
                },
                .bool => |v| try buf.appendSlice(allocator, if (v) "1" else "0"),
            }
        } else {
            try buf.append(allocator, c);
        }
    }
    return allocator.dupe(u8, buf.items);
}

pub const MySqlConn = struct {
    mysql: ?*libmysql_c.MYSQL,
    allocator: std.mem.Allocator,

    pub fn connect(allocator: std.mem.Allocator, host: []const u8, user: []const u8, password: []const u8, db: []const u8, port: u32) !MySqlConn {
        const mysql = libmysql_c.mysql_init(null);
        if (mysql == null) return error.DatabaseError;
        const conn = libmysql_c.mysql_real_connect(mysql, @ptrCast(host.ptr), @ptrCast(user.ptr), @ptrCast(password.ptr), @ptrCast(db.ptr), @intCast(port), null, 0);
        if (conn == null) {
            libmysql_c.mysql_close(mysql);
            return error.DatabaseError;
        }
        return .{ .mysql = mysql, .allocator = allocator };
    }

    fn queryFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) errors.ResultT(Rows) {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        const query = formatQuery(self.allocator, sql_str, args) catch return error.DatabaseError;
        defer self.allocator.free(query);

        if (libmysql_c.mysql_real_query(self.mysql, @ptrCast(query.ptr), @intCast(query.len)) != 0) return error.DatabaseError;

        const res = libmysql_c.mysql_store_result(self.mysql) orelse return error.DatabaseError;
        defer libmysql_c.mysql_free_result(res);

        const n_cols = libmysql_c.mysql_num_fields(res);
        const n_rows = libmysql_c.mysql_num_rows(res);

        const field_names = allocator.alloc([]const u8, n_cols) catch return error.DatabaseError;
        defer {
            for (field_names) |f| allocator.free(f);
            allocator.free(field_names);
        }
        for (0..n_cols) |c| {
            const field = libmysql_c.mysql_fetch_field(res) orelse return error.DatabaseError;
            const name = std.mem.span(field.name);
            field_names[c] = allocator.dupe(u8, name) catch return error.DatabaseError;
        }

        var rows_list: std.ArrayList(Row) = .{};
        var success = false;
        defer {
            if (!success) {
                for (rows_list.items) |row| {
                    for (row.columns) |col| {
                        allocator.free(col);
                    }
                    allocator.free(row.columns);
                    for (row.values) |v| {
                        if (v) |val| {
                            switch (val) {
                                .string => |s| allocator.free(s),
                                else => {},
                            }
                        }
                    }
                    allocator.free(row.values);
                }
            }
            rows_list.deinit(allocator);
        }

        for (0..n_rows) |_| {
            const row_data = libmysql_c.mysql_fetch_row(res);
            const lengths = libmysql_c.mysql_fetch_lengths(res);
            const columns = allocator.alloc([]const u8, n_cols) catch return error.DatabaseError;
            const values = allocator.alloc(?Value, n_cols) catch return error.DatabaseError;
            for (0..n_cols) |c| {
                columns[c] = allocator.dupe(u8, field_names[c]) catch return error.DatabaseError;
                if (row_data == null or row_data.?[c] == null) {
                    values[c] = null;
                } else {
                    const len = lengths[c];
                    const val = row_data.?[c].?[0..len];
                    values[c] = .{ .string = allocator.dupe(u8, val) catch return error.DatabaseError };
                }
            }
            rows_list.append(allocator, .{ .columns = columns, .values = values }) catch return error.DatabaseError;
        }

        const rows_slice = allocator.alloc(Row, rows_list.items.len) catch return error.DatabaseError;
        @memcpy(rows_slice, rows_list.items);
        success = true;
        return Rows{ .allocator = allocator, .rows = rows_slice };
    }

    fn execFn(ptr: *anyopaque, sql_str: []const u8, args: []const Value) errors.ResultT(ExecResult) {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        const query = formatQuery(self.allocator, sql_str, args) catch return error.DatabaseError;
        defer self.allocator.free(query);

        if (libmysql_c.mysql_real_query(self.mysql, @ptrCast(query.ptr), @intCast(query.len)) != 0) return error.DatabaseError;
        _ = libmysql_c.mysql_store_result(self.mysql);
        libmysql_c.mysql_free_result(libmysql_c.mysql_store_result(self.mysql));

        return ExecResult{
            .rows_affected = libmysql_c.mysql_affected_rows(self.mysql),
            .last_insert_id = @intCast(libmysql_c.mysql_insert_id(self.mysql)),
        };
    }

    fn closeFn(ptr: *anyopaque) void {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        if (self.mysql) |mysql| {
            libmysql_c.mysql_close(mysql);
            self.mysql = null;
        }
        self.allocator.destroy(self);
    }

    fn pingFn(ptr: *anyopaque) errors.Result {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        if (self.mysql == null) return error.DatabaseError;
    }

    fn beginFn(ptr: *anyopaque) errors.Result {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        if (libmysql_c.mysql_real_query(self.mysql, "START TRANSACTION", 17) != 0) return error.DatabaseError;
        _ = libmysql_c.mysql_store_result(self.mysql);
        libmysql_c.mysql_free_result(libmysql_c.mysql_store_result(self.mysql));
    }

    fn commitFn(ptr: *anyopaque) errors.Result {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        if (libmysql_c.mysql_real_query(self.mysql, "COMMIT", 6) != 0) return error.DatabaseError;
        _ = libmysql_c.mysql_store_result(self.mysql);
        libmysql_c.mysql_free_result(libmysql_c.mysql_store_result(self.mysql));
    }

    fn rollbackFn(ptr: *anyopaque) errors.Result {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        if (libmysql_c.mysql_real_query(self.mysql, "ROLLBACK", 8) != 0) return error.DatabaseError;
        _ = libmysql_c.mysql_store_result(self.mysql);
        libmysql_c.mysql_free_result(libmysql_c.mysql_store_result(self.mysql));
    }

    pub fn toConn(self: *MySqlConn) Conn {
        return .{
            .ptr = self,
            .vtable = &.{
                .query = queryFn,
                .exec = execFn,
                .close = closeFn,
                .ping = pingFn,
                .begin = beginFn,
                .commit = commitFn,
                .rollback = rollbackFn,
            },
        };
    }
};

// ==================== Prepared Statements ====================

pub const Stmt = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    conn: ?Conn = null,

    pub const VTable = struct {
        query: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) errors.ResultT(Rows),
        exec: *const fn (ptr: *anyopaque, args: []const Value) errors.ResultT(ExecResult),
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn query(self: Stmt, allocator: std.mem.Allocator, args: []const Value) errors.ResultT(Rows) {
        return self.vtable.query(self.ptr, allocator, args);
    }

    pub fn exec(self: Stmt, args: []const Value) errors.ResultT(ExecResult) {
        return self.vtable.exec(self.ptr, args);
    }

    pub fn close(self: Stmt) void {
        self.vtable.close(self.ptr);
        if (self.conn) |c| c.close();
    }
};

pub const SQLiteStmt = struct {
    db: ?*sqlite3_c.sqlite3,
    stmt: ?*sqlite3_c.sqlite3_stmt,
    allocator: std.mem.Allocator,

    pub fn prepare(db: ?*sqlite3_c.sqlite3, allocator: std.mem.Allocator, sql: []const u8) !SQLiteStmt {
        var stmt: ?*sqlite3_c.sqlite3_stmt = null;
        const rc = sqlite3_c.sqlite3_prepare_v2(db, @ptrCast(sql.ptr), @intCast(sql.len), &stmt, null);
        if (rc != sqlite3_c.SQLITE_OK or stmt == null) return error.DatabaseError;
        return .{ .db = db, .stmt = stmt, .allocator = allocator };
    }

    fn queryFn(ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) errors.ResultT(Rows) {
        const self = @as(*SQLiteStmt, @ptrCast(@alignCast(ptr)));
        _ = sqlite3_c.sqlite3_reset(self.stmt);
        try bindSQLite(self.stmt.?, args);

        const col_count = sqlite3_c.sqlite3_column_count(self.stmt);
        var rows_list: std.ArrayList(Row) = .{};
        var success = false;
        defer {
            if (!success) {
                for (rows_list.items) |row| {
                    for (row.columns) |col| allocator.free(col);
                    allocator.free(row.columns);
                    for (row.values) |v| {
                        if (v) |val| {
                            switch (val) {
                                .string => |s| allocator.free(s),
                                else => {},
                            }
                        }
                    }
                    allocator.free(row.values);
                }
            }
            rows_list.deinit(allocator);
        }

        while (sqlite3_c.sqlite3_step(self.stmt) == sqlite3_c.SQLITE_ROW) {
            const columns = allocator.alloc([]const u8, @intCast(col_count)) catch return error.DatabaseError;
            const values = allocator.alloc(?Value, @intCast(col_count)) catch return error.DatabaseError;
            for (0..@intCast(col_count)) |i| {
                const raw_name = sqlite3_c.sqlite3_column_name(self.stmt, @intCast(i));
                const name_len = std.mem.len(raw_name);
                const name = raw_name[0..name_len];
                columns[i] = allocator.dupe(u8, name) catch return error.DatabaseError;
                values[i] = readSQLiteValue(allocator, self.stmt, @intCast(i));
            }
            rows_list.append(allocator, .{ .columns = columns, .values = values }) catch return error.DatabaseError;
        }

        const rows_slice = allocator.alloc(Row, rows_list.items.len) catch return error.DatabaseError;
        @memcpy(rows_slice, rows_list.items);
        success = true;
        return Rows{ .allocator = allocator, .rows = rows_slice };
    }

    fn execFn(ptr: *anyopaque, args: []const Value) errors.ResultT(ExecResult) {
        const self = @as(*SQLiteStmt, @ptrCast(@alignCast(ptr)));
        _ = sqlite3_c.sqlite3_reset(self.stmt);
        try bindSQLite(self.stmt.?, args);
        const step_rc = sqlite3_c.sqlite3_step(self.stmt);
        if (step_rc != sqlite3_c.SQLITE_DONE and step_rc != sqlite3_c.SQLITE_ROW) return error.DatabaseError;
        return ExecResult{
            .last_insert_id = sqlite3_c.sqlite3_last_insert_rowid(self.db),
            .rows_affected = @intCast(sqlite3_c.sqlite3_changes(self.db)),
        };
    }

    fn closeFn(ptr: *anyopaque) void {
        const self = @as(*SQLiteStmt, @ptrCast(@alignCast(ptr)));
        if (self.stmt) |s| {
            _ = sqlite3_c.sqlite3_finalize(s);
            self.stmt = null;
        }
        self.allocator.destroy(self);
    }

    pub fn toStmt(self: *SQLiteStmt) Stmt {
        return .{
            .ptr = self,
            .vtable = &.{
                .query = queryFn,
                .exec = execFn,
                .close = closeFn,
            },
        };
    }
};

pub const PostgresStmt = struct {
    conn: ?*libpq_c.PGconn,
    name: []const u8,
    allocator: std.mem.Allocator,

    pub fn prepare(conn: ?*libpq_c.PGconn, allocator: std.mem.Allocator, sql: []const u8) !PostgresStmt {
        var name_buf: [32]u8 = undefined;
        const stmt_name = try std.fmt.bufPrint(&name_buf, "stmt_{x}", .{@intFromPtr(sql.ptr)});
        const name_copy = try allocator.dupe(u8, stmt_name);
        const res = libpq_c.PQprepare(conn, @ptrCast(name_copy.ptr), @ptrCast(sql.ptr), 0, null);
        if (res == null) return error.DatabaseError;
        defer libpq_c.PQclear(res);
        if (libpq_c.PQresultStatus(res) != libpq_c.ExecStatusType.PGRES_COMMAND_OK) return error.DatabaseError;
        return .{ .conn = conn, .name = name_copy, .allocator = allocator };
    }

    fn execParamsPrepared(self: *PostgresStmt, args: []const Value) ?*libpq_c.PGresult {
        if (self.conn == null) return null;
        const paramValues = self.allocator.alloc(?[*]const u8, args.len) catch return null;
        for (args, 0..) |arg, i| {
            paramValues[i] = switch (arg) {
                .null => null,
                .int => |v| blk: {
                    const s = std.fmt.allocPrint(self.allocator, "{d}", .{v}) catch {
                        self.allocator.free(paramValues);
                        return null;
                    };
                    break :blk @ptrCast(s.ptr);
                },
                .float => |v| blk: {
                    const s = std.fmt.allocPrint(self.allocator, "{d}", .{v}) catch {
                        self.allocator.free(paramValues);
                        return null;
                    };
                    break :blk @ptrCast(s.ptr);
                },
                .string => |v| @ptrCast(v.ptr),
                .bool => |v| if (v) @ptrCast("t") else @ptrCast("f"),
            };
        }
        const res = libpq_c.PQexecPrepared(self.conn, @ptrCast(self.name.ptr), @intCast(args.len), @ptrCast(paramValues.ptr), null, null, 0);
        self.allocator.free(paramValues);
        return res;
    }

    fn queryFn(ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) errors.ResultT(Rows) {
        const self = @as(*PostgresStmt, @ptrCast(@alignCast(ptr)));
        const res = execParamsPrepared(self, args) orelse return error.DatabaseError;
        defer libpq_c.PQclear(res);
        if (libpq_c.PQresultStatus(res) != libpq_c.ExecStatusType.PGRES_TUPLES_OK) return error.DatabaseError;

        const n_rows = libpq_c.PQntuples(res);
        const n_cols = libpq_c.PQnfields(res);
        var rows_list: std.ArrayList(Row) = .{};
        var success = false;
        defer {
            if (!success) {
                for (rows_list.items) |row| {
                    for (row.columns) |col| allocator.free(col);
                    allocator.free(row.columns);
                    for (row.values) |v| {
                        if (v) |val| {
                            switch (val) {
                                .string => |s| allocator.free(s),
                                else => {},
                            }
                        }
                    }
                    allocator.free(row.values);
                }
            }
            rows_list.deinit(allocator);
        }
        for (0..@intCast(n_rows)) |r| {
            const columns = allocator.alloc([]const u8, @intCast(n_cols)) catch return error.DatabaseError;
            const values = allocator.alloc(?Value, @intCast(n_cols)) catch return error.DatabaseError;
            for (0..@intCast(n_cols)) |c| {
                const name = std.mem.span(libpq_c.PQfname(res, @intCast(c)));
                columns[c] = allocator.dupe(u8, name) catch return error.DatabaseError;
                if (libpq_c.PQgetisnull(res, @intCast(r), @intCast(c)) == 1) {
                    values[c] = null;
                } else {
                    const val = std.mem.span(libpq_c.PQgetvalue(res, @intCast(r), @intCast(c)));
                    values[c] = .{ .string = allocator.dupe(u8, val) catch return error.DatabaseError };
                }
            }
            rows_list.append(allocator, .{ .columns = columns, .values = values }) catch return error.DatabaseError;
        }
        const rows_slice = allocator.alloc(Row, rows_list.items.len) catch return error.DatabaseError;
        @memcpy(rows_slice, rows_list.items);
        success = true;
        return Rows{ .allocator = allocator, .rows = rows_slice };
    }

    fn execFn(ptr: *anyopaque, args: []const Value) errors.ResultT(ExecResult) {
        const self = @as(*PostgresStmt, @ptrCast(@alignCast(ptr)));
        const res = execParamsPrepared(self, args) orelse return error.DatabaseError;
        defer libpq_c.PQclear(res);
        const status = libpq_c.PQresultStatus(res);
        if (status != libpq_c.ExecStatusType.PGRES_COMMAND_OK and status != libpq_c.ExecStatusType.PGRES_TUPLES_OK) return error.DatabaseError;
        const cmd = std.mem.span(libpq_c.PQcmdTuples(res));
        const affected = std.fmt.parseInt(u64, cmd, 10) catch 0;
        return ExecResult{ .rows_affected = affected };
    }

    fn closeFn(ptr: *anyopaque) void {
        const self = @as(*PostgresStmt, @ptrCast(@alignCast(ptr)));
        const dealloc_sql = std.fmt.allocPrint(self.allocator, "DEALLOCATE {s}", .{self.name}) catch {
            self.allocator.free(self.name);
            self.allocator.destroy(self);
            return;
        };
        const res = libpq_c.PQexec(self.conn, @ptrCast(dealloc_sql.ptr));
        if (res) |r| libpq_c.PQclear(r);
        self.allocator.free(dealloc_sql);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    pub fn toStmt(self: *PostgresStmt) Stmt {
        return .{
            .ptr = self,
            .vtable = &.{
                .query = queryFn,
                .exec = execFn,
                .close = closeFn,
            },
        };
    }
};

pub const MySqlStmt = struct {
    mysql: ?*libmysql_c.MYSQL,
    sql: []const u8,
    allocator: std.mem.Allocator,

    pub fn prepare(mysql: ?*libmysql_c.MYSQL, allocator: std.mem.Allocator, sql: []const u8) !MySqlStmt {
        const sql_copy = try allocator.dupe(u8, sql);
        return .{ .mysql = mysql, .sql = sql_copy, .allocator = allocator };
    }

    fn queryFn(ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) errors.ResultT(Rows) {
        const self = @as(*MySqlStmt, @ptrCast(@alignCast(ptr)));
        const query = formatQuery(self.allocator, self.sql, args) catch return error.DatabaseError;
        defer self.allocator.free(query);
        if (libmysql_c.mysql_real_query(self.mysql, @ptrCast(query.ptr), @intCast(query.len)) != 0) return error.DatabaseError;
        const res = libmysql_c.mysql_store_result(self.mysql) orelse return error.DatabaseError;
        defer libmysql_c.mysql_free_result(res);

        const n_cols = libmysql_c.mysql_num_fields(res);
        const n_rows = libmysql_c.mysql_num_rows(res);
        const field_names = allocator.alloc([]const u8, n_cols) catch return error.DatabaseError;
        defer {
            for (field_names) |f| allocator.free(f);
            allocator.free(field_names);
        }
        for (0..n_cols) |c| {
            const field = libmysql_c.mysql_fetch_field(res) orelse return error.DatabaseError;
            const name = std.mem.span(field.name);
            field_names[c] = allocator.dupe(u8, name) catch return error.DatabaseError;
        }
        var rows_list: std.ArrayList(Row) = .{};
        var success = false;
        defer {
            if (!success) {
                for (rows_list.items) |row| {
                    for (row.columns) |col| allocator.free(col);
                    allocator.free(row.columns);
                    for (row.values) |v| {
                        if (v) |val| {
                            switch (val) {
                                .string => |s| allocator.free(s),
                                else => {},
                            }
                        }
                    }
                    allocator.free(row.values);
                }
            }
            rows_list.deinit(allocator);
        }
        for (0..n_rows) |_| {
            const row_data = libmysql_c.mysql_fetch_row(res);
            const lengths = libmysql_c.mysql_fetch_lengths(res);
            const columns = allocator.alloc([]const u8, n_cols) catch return error.DatabaseError;
            const values = allocator.alloc(?Value, n_cols) catch return error.DatabaseError;
            for (0..n_cols) |c| {
                columns[c] = allocator.dupe(u8, field_names[c]) catch return error.DatabaseError;
                if (row_data == null or row_data.?[c] == null) {
                    values[c] = null;
                } else {
                    const len = lengths[c];
                    const val = row_data.?[c].?[0..len];
                    values[c] = .{ .string = allocator.dupe(u8, val) catch return error.DatabaseError };
                }
            }
            rows_list.append(allocator, .{ .columns = columns, .values = values }) catch return error.DatabaseError;
        }
        const rows_slice = allocator.alloc(Row, rows_list.items.len) catch return error.DatabaseError;
        @memcpy(rows_slice, rows_list.items);
        success = true;
        return Rows{ .allocator = allocator, .rows = rows_slice };
    }

    fn execFn(ptr: *anyopaque, args: []const Value) errors.ResultT(ExecResult) {
        const self = @as(*MySqlStmt, @ptrCast(@alignCast(ptr)));
        const query = formatQuery(self.allocator, self.sql, args) catch return error.DatabaseError;
        defer self.allocator.free(query);
        if (libmysql_c.mysql_real_query(self.mysql, @ptrCast(query.ptr), @intCast(query.len)) != 0) return error.DatabaseError;
        _ = libmysql_c.mysql_store_result(self.mysql);
        libmysql_c.mysql_free_result(libmysql_c.mysql_store_result(self.mysql));
        return ExecResult{
            .rows_affected = libmysql_c.mysql_affected_rows(self.mysql),
            .last_insert_id = @intCast(libmysql_c.mysql_insert_id(self.mysql)),
        };
    }

    fn closeFn(ptr: *anyopaque) void {
        const self = @as(*MySqlStmt, @ptrCast(@alignCast(ptr)));
        self.allocator.free(self.sql);
        self.allocator.destroy(self);
    }

    pub fn toStmt(self: *MySqlStmt) Stmt {
        return .{
            .ptr = self,
            .vtable = &.{
                .query = queryFn,
                .exec = execFn,
                .close = closeFn,
            },
        };
    }
};

// ==================== Connection Pool ====================

const ConnPool = struct {
    allocator: std.mem.Allocator,
    client: *Client,
    max_open: u32,
    max_idle: u32,
    active: std.atomic.Value(u32),
    idle: std.ArrayList(Conn),
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    closed: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, client: *Client, max_open: u32, max_idle: u32) ConnPool {
        return .{
            .allocator = allocator,
            .client = client,
            .max_open = max_open,
            .max_idle = max_idle,
            .active = std.atomic.Value(u32).init(0),
            .idle = .{},
            .mutex = .{},
            .cond = .{},
            .closed = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *ConnPool) void {
        self.closed.store(true, .monotonic);
        self.cond.broadcast();
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.idle.items) |*conn| {
            conn.close();
        }
        self.idle.deinit(self.allocator);
    }

    pub fn acquire(self: *ConnPool) !Conn {
        if (self.closed.load(.monotonic)) return error.DatabaseError;
        self.mutex.lock();
        while (self.idle.items.len > 0) {
            const conn = self.idle.pop().?;
            self.mutex.unlock();
            conn.ping() catch {
                conn.close();
                _ = self.active.fetchSub(1, .monotonic);
                self.mutex.lock();
                continue;
            };
            return conn;
        }
        const current_active = self.active.load(.monotonic);
        if (current_active < self.max_open) {
            self.mutex.unlock();
            const conn = try self.client.newConn();
            _ = self.active.fetchAdd(1, .monotonic);
            return conn;
        }
        const wait_until = std.time.milliTimestamp() + @as(i64, @intCast(self.client.config.max_wait_ms));
        while (self.idle.items.len == 0 and std.time.milliTimestamp() < wait_until) {
            self.cond.timedWait(&self.mutex, @intCast(wait_until - std.time.milliTimestamp())) catch break;
        }
        if (self.idle.items.len > 0) {
            const conn = self.idle.pop().?;
            self.mutex.unlock();
            return conn;
        }
        self.mutex.unlock();
        return error.Timeout;
    }

    pub fn release(self: *ConnPool, conn: Conn) void {
        if (self.closed.load(.monotonic)) {
            conn.close();
            _ = self.active.fetchSub(1, .monotonic);
            return;
        }
        self.mutex.lock();
        if (self.idle.items.len < self.max_idle) {
            self.idle.append(self.allocator, conn) catch {
                self.mutex.unlock();
                conn.close();
                _ = self.active.fetchSub(1, .monotonic);
                return;
            };
            self.mutex.unlock();
            self.cond.signal();
        } else {
            self.mutex.unlock();
            conn.close();
            _ = self.active.fetchSub(1, .monotonic);
        }
    }
};

// ==================== Unified Client ====================

/// SQL configuration
pub const Config = struct {
    driver: Driver,
    host: []const u8 = "localhost",
    port: u16 = 3306,
    database: []const u8 = "",
    username: []const u8 = "",
    password: []const u8 = "",
    sqlite_path: []const u8 = ":memory:",
    postgres_conninfo: []const u8 = "",
    max_open_conns: u32 = 1,
    max_idle_conns: u32 = 1,
    max_wait_ms: u32 = 5000,
};

/// SQL option function type aligned with go-zero's SqlOption
pub const SqlOption = *const fn (*Client) void;

/// Default acceptable error filter: NotFound is acceptable
pub fn defaultAcceptable(err: anyerror) bool {
    return err == error.NotFound;
}

/// SQLx client - unified SQL client
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,
    conn: ?Conn = null,
    pool: ?ConnPool = null,
    cb: ?breaker.CircuitBreaker = null,
    acceptable: ?*const fn (anyerror) bool = null,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) Client {
        return .{
            .allocator = allocator,
            .config = cfg,
            .conn = null,
            .pool = null,
            .cb = null,
            .acceptable = null,
        };
    }

    pub fn withOptions(self: *Client, opts: []const SqlOption) void {
        for (opts) |opt| {
            opt(self);
        }
    }

    fn isAcceptable(self: *Client, err: anyerror) bool {
        if (self.acceptable) |f| {
            return f(err);
        }
        return defaultAcceptable(err);
    }

    pub fn deinit(self: *Client) void {
        if (self.pool) |*p| {
            p.deinit();
            self.pool = null;
        }
        if (self.conn) |*c| c.close();
    }

    fn ensurePool(self: *Client) void {
        if (self.config.max_open_conns > 1 and self.pool == null) {
            self.pool = ConnPool.init(self.allocator, self, self.config.max_open_conns, self.config.max_idle_conns);
        }
    }

    fn newConn(self: *Client) !Conn {
        switch (self.config.driver) {
            .sqlite => {
                const sqlite = try self.allocator.create(SQLiteConn);
                errdefer self.allocator.destroy(sqlite);
                sqlite.* = try SQLiteConn.open(self.allocator, self.config.sqlite_path);
                return sqlite.toConn();
            },
            .postgres => {
                const info = if (self.config.postgres_conninfo.len > 0)
                    self.config.postgres_conninfo
                else
                    try std.fmt.allocPrint(self.allocator, "host={s} port={d} dbname={s} user={s} password={s}", .{
                        self.config.host,
                        self.config.port,
                        self.config.database,
                        self.config.username,
                        self.config.password,
                    });
                defer if (self.config.postgres_conninfo.len == 0) self.allocator.free(info);
                const pg = try self.allocator.create(PostgresConn);
                errdefer self.allocator.destroy(pg);
                pg.* = try PostgresConn.connect(self.allocator, info);
                return pg.toConn();
            },
            .mysql => {
                const mysql = try self.allocator.create(MySqlConn);
                errdefer self.allocator.destroy(mysql);
                mysql.* = try MySqlConn.connect(self.allocator, self.config.host, self.config.username, self.config.password, self.config.database, self.config.port);
                return mysql.toConn();
            },
        }
    }

    pub fn connect(self: *Client) !void {
        if (self.conn != null) return;
        self.conn = try self.newConn();
    }

    pub fn prepare(self: *Client, sql_str: []const u8) !Stmt {
        self.ensureBreaker();
        if (!self.cb.?.allow()) return error.CircuitBreakerOpen;
        const conn = try self.newConn();
        errdefer conn.close();
        var stmt = self.newStmt(conn, sql_str) catch |err| {
            if (!self.isAcceptable(err)) self.cb.?.recordFailure();
            return err;
        };
        stmt.conn = conn;
        self.cb.?.recordSuccess();
        return stmt;
    }

    pub fn withAcceptable(f: *const fn (anyerror) bool) SqlOption {
        return struct {
            fn apply(client: *Client) void {
                client.acceptable = f;
            }
        }.apply;
    }

    fn newStmt(self: *Client, conn: Conn, sql_str: []const u8) !Stmt {
        switch (self.config.driver) {
            .sqlite => {
                const sqlite_conn = @as(*SQLiteConn, @ptrCast(@alignCast(conn.ptr)));
                const stmt = try self.allocator.create(SQLiteStmt);
                errdefer self.allocator.destroy(stmt);
                stmt.* = try SQLiteStmt.prepare(sqlite_conn.db, self.allocator, sql_str);
                return stmt.toStmt();
            },
            .postgres => {
                const pg_conn = @as(*PostgresConn, @ptrCast(@alignCast(conn.ptr)));
                const stmt = try self.allocator.create(PostgresStmt);
                errdefer self.allocator.destroy(stmt);
                stmt.* = try PostgresStmt.prepare(pg_conn.conn, self.allocator, sql_str);
                return stmt.toStmt();
            },
            .mysql => {
                const mysql_conn = @as(*MySqlConn, @ptrCast(@alignCast(conn.ptr)));
                const stmt = try self.allocator.create(MySqlStmt);
                errdefer self.allocator.destroy(stmt);
                stmt.* = try MySqlStmt.prepare(mysql_conn.mysql, self.allocator, sql_str);
                return stmt.toStmt();
            },
        }
    }

    fn ensureBreaker(self: *Client) void {
        if (self.cb == null) {
            self.cb = breaker.CircuitBreaker.new();
        }
    }

    fn doQuery(self: *Client, sql_str: []const u8, args: []const Value) !Rows {
        self.ensurePool();
        if (self.pool) |*p| {
            const conn = try p.acquire();
            defer p.release(conn);
            return conn.query(self.allocator, sql_str, args);
        }
        if (self.conn == null) try self.connect();
        return self.conn.?.query(self.allocator, sql_str, args);
    }

    pub fn query(self: *Client, sql_str: []const u8, args: []const Value) !Rows {
        self.ensureBreaker();
        if (!self.cb.?.allow()) return error.CircuitBreakerOpen;
        const result = self.doQuery(sql_str, args) catch |err| {
            if (!self.isAcceptable(err)) self.cb.?.recordFailure();
            return err;
        };
        self.cb.?.recordSuccess();
        return result;
    }

    fn doExec(self: *Client, sql_str: []const u8, args: []const Value) !ExecResult {
        self.ensurePool();
        if (self.pool) |*p| {
            const conn = try p.acquire();
            defer p.release(conn);
            return conn.exec(sql_str, args);
        }
        if (self.conn == null) try self.connect();
        return self.conn.?.exec(sql_str, args);
    }

    pub fn exec(self: *Client, sql_str: []const u8, args: []const Value) !ExecResult {
        self.ensureBreaker();
        if (!self.cb.?.allow()) return error.CircuitBreakerOpen;
        const result = self.doExec(sql_str, args) catch |err| {
            if (!self.isAcceptable(err)) self.cb.?.recordFailure();
            return err;
        };
        self.cb.?.recordSuccess();
        return result;
    }

    fn doPing(self: *Client) !void {
        self.ensurePool();
        if (self.pool) |*p| {
            const conn = try p.acquire();
            defer p.release(conn);
            return conn.ping();
        }
        if (self.conn == null) try self.connect();
        return self.conn.?.ping();
    }

    pub fn ping(self: *Client) !void {
        self.ensureBreaker();
        if (!self.cb.?.allow()) return error.CircuitBreakerOpen;
        self.doPing() catch |err| {
            if (!self.isAcceptable(err)) self.cb.?.recordFailure();
            return err;
        };
        self.cb.?.recordSuccess();
    }

    pub fn beginTx(self: *Client) !Transaction {
        self.ensureBreaker();
        if (!self.cb.?.allow()) return error.CircuitBreakerOpen;
        self.ensurePool();
        if (self.pool) |*p| {
            const conn = try p.acquire();
            errdefer p.release(conn);
            conn.begin() catch |err| {
                if (!self.isAcceptable(err)) self.cb.?.recordFailure();
                return err;
            };
            return Transaction{ .conn = conn, .pool = p };
        }
        if (self.conn == null) try self.connect();
        self.conn.?.begin() catch |err| {
            if (!self.isAcceptable(err)) self.cb.?.recordFailure();
            return err;
        };
        return Transaction{ .conn = self.conn.? };
    }

    pub fn transact(self: *Client, comptime T: type, fn_tx: *const fn (*Transaction) errors.ResultT(T)) errors.ResultT(T) {
        var tx = try self.beginTx();
        errdefer {
            tx.rollback() catch {};
            if (tx.pool) |p| p.release(tx.conn);
        }
        const result = try fn_tx(&tx);
        try tx.commit();
        return result;
    }

    pub fn queryRow(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        var rows = try self.query(sql_str, args);
        defer rows.deinit();
        if (rows.rows.len == 0) return error.NotFound;
        return try rows.rows[0].scan(self.allocator, T);
    }

    pub fn queryRowPartial(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        var rows = try self.query(sql_str, args);
        defer rows.deinit();
        if (rows.rows.len == 0) return error.NotFound;
        return try rows.rows[0].scanPartial(self.allocator, T);
    }

    pub fn queryRows(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) ![]T {
        var rows = try self.query(sql_str, args);
        defer rows.deinit();
        const result = try self.allocator.alloc(T, rows.rows.len);
        errdefer {
            for (result) |item| freeScanned(self.allocator, T, item);
            self.allocator.free(result);
        }
        for (rows.rows, 0..) |row, i| {
            result[i] = try row.scan(self.allocator, T);
        }
        return result;
    }

    pub fn queryRowsPartial(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) ![]T {
        var rows = try self.query(sql_str, args);
        defer rows.deinit();
        const result = try self.allocator.alloc(T, rows.rows.len);
        errdefer {
            for (result) |item| freeScanned(self.allocator, T, item);
            self.allocator.free(result);
        }
        for (rows.rows, 0..) |row, i| {
            result[i] = try row.scanPartial(self.allocator, T);
        }
        return result;
    }

    pub fn deinitQueryRows(self: *Client, comptime T: type, items: []T) void {
        for (items) |item| freeScanned(self.allocator, T, item);
        self.allocator.free(items);
    }

    pub fn findOne(self: *Client, comptime T: type, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s} LIMIT 1", .{ table, where_clause });
        defer self.allocator.free(sql);
        return self.queryRow(T, sql, args);
    }

    pub fn findOnePartial(self: *Client, comptime T: type, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s} LIMIT 1", .{ table, where_clause });
        defer self.allocator.free(sql);
        return self.queryRowPartial(T, sql, args);
    }

    pub fn findAll(self: *Client, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) ![]T {
        const sql = if (where_clause) |w|
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s}", .{ table, w })
        else
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s}", .{table});
        defer self.allocator.free(sql);
        return self.queryRows(T, sql, args);
    }

    pub fn findAllPartial(self: *Client, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) ![]T {
        const sql = if (where_clause) |w|
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s}", .{ table, w })
        else
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s}", .{table});
        defer self.allocator.free(sql);
        return self.queryRowsPartial(T, sql, args);
    }
};

/// SQL transaction
pub const Transaction = struct {
    conn: Conn,
    pool: ?*ConnPool = null,

    pub fn query(self: *Transaction, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) !Rows {
        return self.conn.query(allocator, sql_str, args);
    }

    pub fn exec(self: *Transaction, sql_str: []const u8, args: []const Value) !ExecResult {
        return self.conn.exec(sql_str, args);
    }

    pub fn commit(self: *Transaction) !void {
        try self.conn.commit();
        if (self.pool) |p| {
            p.release(self.conn);
            self.pool = null;
        }
    }

    pub fn rollback(self: *Transaction) !void {
        try self.conn.rollback();
        if (self.pool) |p| {
            p.release(self.conn);
            self.pool = null;
        }
    }
};

fn deepCopyStruct(allocator: std.mem.Allocator, comptime T: type, src: T) !T {
    var dst = src;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const FieldType = field.type;
        if (FieldType == []const u8) {
            @field(dst, field.name) = try allocator.dupe(u8, @field(src, field.name));
        } else if (@typeInfo(FieldType) == .optional and @typeInfo(FieldType).optional.child == []const u8) {
            if (@field(src, field.name)) |s| {
                @field(dst, field.name) = try allocator.dupe(u8, s);
            }
        }
    }
    return dst;
}

/// Simple string cache for testing CachedConn
pub const StringCache = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) StringCache {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *StringCache) void {
        var iter = self.map.valueIterator();
        while (iter.next()) |v| self.allocator.free(v.*);
        var key_iter = self.map.keyIterator();
        while (key_iter.next()) |k| self.allocator.free(k.*);
        self.map.deinit();
    }

    pub fn get(self: *StringCache, key: []const u8) ?[]const u8 {
        const val = self.map.get(key) orelse return null;
        return self.allocator.dupe(u8, val) catch null;
    }

    pub fn set(self: *StringCache, key: []const u8, value: []const u8, ttl_sec: u32) !void {
        _ = ttl_sec;
        const k = try self.allocator.dupe(u8, key);
        const v = try self.allocator.dupe(u8, value);
        const entry = self.map.getEntry(k);
        if (entry) |e| {
            self.allocator.free(e.value_ptr.*);
            e.value_ptr.* = v;
            self.allocator.free(k);
        } else {
            try self.map.put(k, v);
        }
    }

    pub fn del(self: *StringCache, key: []const u8) void {
        if (self.map.fetchRemove(key)) |entry| {
            self.allocator.free(entry.value);
            self.allocator.free(entry.key);
        }
    }
};

const redis = @import("redis.zig");

/// Cached SQL connection aligned with go-zero's CachedConn
pub const CachedConn = struct {
    allocator: std.mem.Allocator,
    client: *Client,
    redis: ?*redis.Redis = null,
    local_cache: ?*StringCache = null,
    ttl_sec: u32 = 60,

    pub fn queryRow(self: *CachedConn, comptime T: type, cache_key: []const u8, sql_str: []const u8, args: []const Value) !T {
        if (self.getCache(cache_key)) |cached| {
            defer self.allocator.free(cached);
            var parsed = std.json.parseFromSlice(T, self.allocator, cached, .{}) catch return error.DatabaseError;
            defer parsed.deinit();
            return try deepCopyStruct(self.allocator, T, parsed.value);
        }
        const result = try self.client.queryRow(T, sql_str, args);
        const json = std.json.Stringify.valueAlloc(self.allocator, result, .{}) catch {
            return result;
        };
        defer self.allocator.free(json);
        self.setCache(cache_key, json, self.ttl_sec) catch {};
        return result;
    }

    pub fn queryRowNoCache(self: *CachedConn, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        return self.client.queryRow(T, sql_str, args);
    }

    pub fn queryRowPartial(self: *CachedConn, comptime T: type, cache_key: []const u8, sql_str: []const u8, args: []const Value) !T {
        if (self.getCache(cache_key)) |cached| {
            defer self.allocator.free(cached);
            var parsed = std.json.parseFromSlice(T, self.allocator, cached, .{}) catch return error.DatabaseError;
            defer parsed.deinit();
            return try deepCopyStruct(self.allocator, T, parsed.value);
        }
        const result = try self.client.queryRowPartial(T, sql_str, args);
        const json = std.json.Stringify.valueAlloc(self.allocator, result, .{}) catch {
            return result;
        };
        defer self.allocator.free(json);
        self.setCache(cache_key, json, self.ttl_sec) catch {};
        return result;
    }

    pub fn queryRowPartialNoCache(self: *CachedConn, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        return self.client.queryRowPartial(T, sql_str, args);
    }

    pub fn queryRows(self: *CachedConn, comptime T: type, cache_key: []const u8, sql_str: []const u8, args: []const Value) ![]T {
        if (self.getCache(cache_key)) |cached| {
            defer self.allocator.free(cached);
            var parsed = std.json.parseFromSlice([]T, self.allocator, cached, .{}) catch return error.DatabaseError;
            defer parsed.deinit();
            const result = try self.allocator.alloc(T, parsed.value.len);
            errdefer {
                for (result) |item| freeScanned(self.allocator, T, item);
                self.allocator.free(result);
            }
            for (parsed.value, 0..) |item, i| {
                result[i] = try deepCopyStruct(self.allocator, T, item);
            }
            return result;
        }
        const result = try self.client.queryRows(T, sql_str, args);
        const json = std.json.Stringify.valueAlloc(self.allocator, result, .{}) catch {
            return result;
        };
        defer self.allocator.free(json);
        self.setCache(cache_key, json, self.ttl_sec) catch {};
        return result;
    }

    pub fn queryRowsNoCache(self: *CachedConn, comptime T: type, sql_str: []const u8, args: []const Value) ![]T {
        return self.client.queryRows(T, sql_str, args);
    }

    pub fn queryRowsPartial(self: *CachedConn, comptime T: type, cache_key: []const u8, sql_str: []const u8, args: []const Value) ![]T {
        if (self.getCache(cache_key)) |cached| {
            defer self.allocator.free(cached);
            var parsed = std.json.parseFromSlice([]T, self.allocator, cached, .{}) catch return error.DatabaseError;
            defer parsed.deinit();
            const result = try self.allocator.alloc(T, parsed.value.len);
            errdefer {
                for (result) |item| freeScanned(self.allocator, T, item);
                self.allocator.free(result);
            }
            for (parsed.value, 0..) |item, i| {
                result[i] = try deepCopyStruct(self.allocator, T, item);
            }
            return result;
        }
        const result = try self.client.queryRowsPartial(T, sql_str, args);
        const json = std.json.Stringify.valueAlloc(self.allocator, result, .{}) catch {
            return result;
        };
        defer self.allocator.free(json);
        self.setCache(cache_key, json, self.ttl_sec) catch {};
        return result;
    }

    pub fn queryRowsPartialNoCache(self: *CachedConn, comptime T: type, sql_str: []const u8, args: []const Value) ![]T {
        return self.client.queryRowsPartial(T, sql_str, args);
    }

    pub fn exec(self: *CachedConn, cache_keys: []const []const u8, sql_str: []const u8, args: []const Value) !ExecResult {
        const result = try self.client.exec(sql_str, args);
        for (cache_keys) |key| {
            self.delCache(key) catch {};
        }
        return result;
    }

    pub fn execNoCache(self: *CachedConn, sql_str: []const u8, args: []const Value) !ExecResult {
        return self.client.exec(sql_str, args);
    }

    pub fn findOne(self: *CachedConn, comptime T: type, cache_key: []const u8, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s} LIMIT 1", .{ table, where_clause });
        defer self.allocator.free(sql);
        return self.queryRow(T, cache_key, sql, args);
    }

    pub fn findOneNoCache(self: *CachedConn, comptime T: type, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s} LIMIT 1", .{ table, where_clause });
        defer self.allocator.free(sql);
        return self.queryRowNoCache(T, sql, args);
    }

    pub fn findAll(self: *CachedConn, comptime T: type, cache_key: []const u8, table: []const u8, where_clause: ?[]const u8, args: []const Value) ![]T {
        const sql = if (where_clause) |w|
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s}", .{ table, w })
        else
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s}", .{table});
        defer self.allocator.free(sql);
        return self.queryRows(T, cache_key, sql, args);
    }

    pub fn findAllNoCache(self: *CachedConn, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) ![]T {
        const sql = if (where_clause) |w|
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s}", .{ table, w })
        else
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s}", .{table});
        defer self.allocator.free(sql);
        return self.queryRowsNoCache(T, sql, args);
    }

    fn getCache(self: *CachedConn, key: []const u8) ?[]const u8 {
        if (self.local_cache) |lc| {
            return lc.get(key);
        }
        if (self.redis) |r| {
            return r.get(key) catch null;
        }
        return null;
    }

    fn setCache(self: *CachedConn, key: []const u8, value: []const u8, ttl: u32) !void {
        if (self.local_cache) |lc| {
            try lc.set(key, value, ttl);
            return;
        }
        if (self.redis) |r| {
            _ = r.set(key, value, ttl) catch {};
        }
    }

    fn delCache(self: *CachedConn, key: []const u8) !void {
        if (self.local_cache) |lc| {
            lc.del(key);
            return;
        }
        if (self.redis) |r| {
            _ = r.del(&.{key}) catch {};
        }
    }
};

/// SQL builder for common operations
pub const Builder = struct {
    allocator: std.mem.Allocator,
    table: []const u8,
    select_columns: ?[][]const u8 = null,
    where_clauses: ?[][]const u8 = null,
    order_by_clause: ?[]const u8 = null,
    limit_val: ?usize = null,
    offset_val: ?usize = null,

    pub fn init(allocator: std.mem.Allocator, table: []const u8) Builder {
        return .{
            .allocator = allocator,
            .table = table,
        };
    }

    pub fn deinit(self: *Builder) void {
        if (self.select_columns) |cols| self.allocator.free(cols);
        if (self.where_clauses) |wheres| {
            for (wheres) |clause| self.allocator.free(clause);
            self.allocator.free(wheres);
        }
        if (self.order_by_clause) |o| self.allocator.free(o);
    }

    pub fn selectColumns(self: *Builder, columns: []const []const u8) *Builder {
        if (self.select_columns) |cols| self.allocator.free(cols);
        self.select_columns = self.allocator.dupe([]const u8, columns) catch null;
        return self;
    }

    pub fn where(self: *Builder, clause: []const u8) *Builder {
        const new_clause = self.allocator.dupe(u8, clause) catch return self;
        if (self.where_clauses) |wheres| {
            const new_w = self.allocator.realloc(wheres, wheres.len + 1) catch {
                self.allocator.free(new_clause);
                return self;
            };
            new_w[new_w.len - 1] = new_clause;
            self.where_clauses = new_w;
        } else {
            self.where_clauses = self.allocator.alloc([]const u8, 1) catch {
                self.allocator.free(new_clause);
                return self;
            };
            self.where_clauses.?[0] = new_clause;
        }
        return self;
    }

    pub fn orderBy(self: *Builder, clause: []const u8) *Builder {
        if (self.order_by_clause) |o| self.allocator.free(o);
        self.order_by_clause = self.allocator.dupe(u8, clause) catch null;
        return self;
    }

    pub fn limit(self: *Builder, n: usize) *Builder {
        self.limit_val = n;
        return self;
    }

    pub fn offset(self: *Builder, n: usize) *Builder {
        self.offset_val = n;
        return self;
    }

    pub fn toSql(self: *const Builder) ![]u8 {
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);

        if (self.select_columns) |cols| {
            try w.writeAll("SELECT ");
            for (cols, 0..) |col, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(col);
            }
            try std.fmt.format(w, " FROM {s}", .{self.table});
        } else {
            try std.fmt.format(w, "SELECT * FROM {s}", .{self.table});
        }

        if (self.where_clauses) |wheres| {
            try w.writeAll(" WHERE ");
            for (wheres, 0..) |clause, i| {
                if (i > 0) try w.writeAll(" AND ");
                try w.writeAll(clause);
            }
        }

        if (self.order_by_clause) |o| {
            try std.fmt.format(w, " ORDER BY {s}", .{o});
        }

        if (self.limit_val) |n| {
            try std.fmt.format(w, " LIMIT {d}", .{n});
        }

        if (self.offset_val) |n| {
            try std.fmt.format(w, " OFFSET {d}", .{n});
        }

        return self.allocator.dupe(u8, buf.items);
    }

    pub fn select(self: *const Builder, columns: []const []const u8) ![]u8 {
        var b = Builder.init(self.allocator, self.table);
        b.select_columns = self.allocator.dupe([]const u8, columns) catch return error.DatabaseError;
        defer b.deinit();
        return b.toSql();
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

    pub fn count(self: *const Builder, where_clause: ?[]const u8) ![]u8 {
        if (where_clause) |w| {
            return std.fmt.allocPrint(self.allocator, "SELECT COUNT(*) FROM {s} WHERE {s}", .{ self.table, w });
        }
        return std.fmt.allocPrint(self.allocator, "SELECT COUNT(*) FROM {s}", .{self.table});
    }
};

// ==================== Tests ====================

test "cached conn queryRow and exec" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});

    const User = struct {
        id: i64,
        name: []const u8,
    };

    var cache = StringCache.init(allocator);
    defer cache.deinit();

    var cached = CachedConn{
        .allocator = allocator,
        .client = &client,
        .local_cache = &cache,
        .ttl_sec = 60,
    };

    // First query should hit DB and populate cache
    const user1 = try cached.queryRow(User, "user:1", "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 1 }});
    defer freeScanned(allocator, User, user1);
    try std.testing.expectEqual(@as(i64, 1), user1.id);
    try std.testing.expectEqualStrings("Alice", user1.name);

    // Second query should hit cache
    const user2 = try cached.queryRow(User, "user:1", "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 999 }});
    defer freeScanned(allocator, User, user2);
    try std.testing.expectEqualStrings("Alice", user2.name);

    // Exec with cache invalidation
    _ = try cached.exec(&.{"user:1"}, "UPDATE users SET name = ?1 WHERE id = ?2", &.{ .{ .string = "Bob" }, .{ .int = 1 } });

    // After invalidation, query should hit DB again
    const user3 = try cached.queryRow(User, "user:1", "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 1 }});
    defer freeScanned(allocator, User, user3);
    try std.testing.expectEqualStrings("Bob", user3.name);
}

test "sqlite acceptable error does not trip breaker" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});

    // queryRow on empty table should return NotFound
    const User = struct { id: i64, name: []const u8 };
    const err = client.queryRow(User, "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 999 }}) catch |e| e;
    try std.testing.expectEqual(errors.Error.NotFound, err);

    // NotFound is acceptable, so breaker should still allow requests
    try client.ping();
}

test "sqlite builder count" {
    const allocator = std.testing.allocator;
    const b = Builder.init(allocator, "users");
    const count_sql = try b.count("id > ?1");
    defer allocator.free(count_sql);
    try std.testing.expectEqualStrings("SELECT COUNT(*) FROM users WHERE id > ?1", count_sql);

    const count_all = try b.count(null);
    defer allocator.free(count_all);
    try std.testing.expectEqualStrings("SELECT COUNT(*) FROM users", count_all);
}

test "client findOne and findAll" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Bob" }});

    const User = struct {
        id: i64,
        name: []const u8,
    };

    const user = try client.findOne(User, "users", "name = ?1", &.{.{ .string = "Alice" }});
    defer freeScanned(allocator, User, user);
    try std.testing.expectEqual(@as(i64, 1), user.id);

    const users = try client.findAll(User, "users", null, &.{});
    defer client.deinitQueryRows(User, users);
    try std.testing.expectEqual(@as(usize, 2), users.len);
}

test "cached conn findOne" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});

    const User = struct {
        id: i64,
        name: []const u8,
    };

    var cache = StringCache.init(allocator);
    defer cache.deinit();

    var cached = CachedConn{
        .allocator = allocator,
        .client = &client,
        .local_cache = &cache,
        .ttl_sec = 60,
    };

    const user1 = try cached.findOne(User, "user:1", "users", "name = ?1", &.{.{ .string = "Alice" }});
    defer freeScanned(allocator, User, user1);

    const user2 = try cached.findOne(User, "user:1", "users", "name = ?1", &.{.{ .string = "WRONG" }});
    defer freeScanned(allocator, User, user2);
    try std.testing.expectEqualStrings("Alice", user2.name);
}

test "sqlite in-memory query and exec" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();

    const create = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    try std.testing.expectEqual(@as(u64, 0), create.rows_affected);

    const insert = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});
    try std.testing.expectEqual(@as(i64, 1), insert.last_insert_id.?);

    var rows = try client.query("SELECT id, name FROM users WHERE name = ?1", &.{.{ .string = "Alice" }});
    defer rows.deinit();

    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    try std.testing.expectEqual(@as(i64, 1), rows.rows[0].get("id").?.int);
    try std.testing.expectEqualStrings("Alice", rows.rows[0].get("name").?.string);
}

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

test "sqlx builder chainable" {
    const allocator = std.testing.allocator;
    var b = Builder.init(allocator, "users");
    defer b.deinit();

    const sql = try b.selectColumns(&.{ "id", "name" })
        .where("id = ?1")
        .where("name = ?2")
        .orderBy("id DESC")
        .limit(10)
        .offset(20)
        .toSql();
    defer allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT id, name FROM users WHERE id = ?1 AND name = ?2 ORDER BY id DESC LIMIT 10 OFFSET 20", sql);
}

test "sqlite transaction commit" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();
    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});

    var tx = try client.beginTx();
    const insert = try tx.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Bob" }});
    try std.testing.expectEqual(@as(u64, 1), insert.rows_affected);
    try tx.commit();

    var rows = try client.query("SELECT name FROM users WHERE name = ?1", &.{.{ .string = "Bob" }});
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
}

test "sqlite transaction rollback" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();
    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});

    var tx = try client.beginTx();
    _ = try tx.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Charlie" }});
    try tx.rollback();

    var rows = try client.query("SELECT name FROM users WHERE name = ?1", &.{.{ .string = "Charlie" }});
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 0), rows.rows.len);
}

test "sqlite queryRowPartial struct scan" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();
    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name, email) VALUES (?1, ?2)", &.{ .{ .string = "Alice" }, .{ .string = "alice@example.com" } });

    const PartialUser = struct {
        id: i64,
        name: []const u8,
        bio: []const u8, // missing in DB, should be zeroed
    };

    const user = try client.queryRowPartial(PartialUser, "SELECT id, name FROM users WHERE name = ?1", &.{.{ .string = "Alice" }});
    defer freeScanned(allocator, PartialUser, user);
    try std.testing.expectEqual(@as(i64, 1), user.id);
    try std.testing.expectEqualStrings("Alice", user.name);
    try std.testing.expectEqual(@as(usize, 0), user.bio.len);
}

test "sqlite queryRow and queryRows struct scan" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();
    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Bob" }});

    const User = struct {
        id: i64,
        name: []const u8,
    };

    const user = try client.queryRow(User, "SELECT id, name FROM users WHERE name = ?1", &.{.{ .string = "Alice" }});
    defer freeScanned(allocator, User, user);
    try std.testing.expectEqual(@as(i64, 1), user.id);
    try std.testing.expectEqualStrings("Alice", user.name);

    const users = try client.queryRows(User, "SELECT id, name FROM users ORDER BY id", &.{});
    defer client.deinitQueryRows(User, users);
    try std.testing.expectEqual(@as(usize, 2), users.len);
    try std.testing.expectEqualStrings("Alice", users[0].name);
    try std.testing.expectEqualStrings("Bob", users[1].name);
}

test "sqlite transact helper" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();
    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});

    const affected = try client.transact(u64, struct {
        fn doTx(tx: *Transaction) errors.ResultT(u64) {
            const r = try tx.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "TxUser" }});
            return r.rows_affected;
        }
    }.doTx);
    try std.testing.expectEqual(@as(u64, 1), affected);

    var rows = try client.query("SELECT name FROM users WHERE name = ?1", &.{.{ .string = "TxUser" }});
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
}

test "sqlite circuit breaker" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, .{ .driver = .sqlite, .sqlite_path = "/nonexistent/path/bad.db" });
    defer client.deinit();

    var failures: u32 = 0;
    for (0..15) |_| {
        _ = client.query("SELECT 1", &.{}) catch {
            failures += 1;
        };
    }
    try std.testing.expectEqual(@as(u32, 15), failures);

    // After enough failures, circuit breaker should be open
    const err = client.query("SELECT 1", &.{}) catch |e| e;
    try std.testing.expectEqual(errors.Error.CircuitBreakerOpen, err);
}

test "sqlite connection pool" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, .{ .driver = .sqlite, .sqlite_path = ":memory:", .max_open_conns = 3, .max_idle_conns = 2 });
    defer client.deinit();

    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Bob" }});

    const User = struct {
        id: i64,
        name: []const u8,
    };

    const users = try client.queryRows(User, "SELECT id, name FROM users ORDER BY id", &.{});
    defer client.deinitQueryRows(User, users);
    try std.testing.expectEqual(@as(usize, 2), users.len);

    // Transaction through pool
    const affected = try client.transact(u64, struct {
        fn doTx(tx: *Transaction) errors.ResultT(u64) {
            const r = try tx.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Charlie" }});
            return r.rows_affected;
        }
    }.doTx);
    try std.testing.expectEqual(@as(u64, 1), affected);
}

test "sqlite prepared statement" {
    const allocator = std.testing.allocator;
    const db_path = "/tmp/zigzero_sqlx_stmt_test.db";
    std.fs.cwd().deleteFile(db_path) catch {};
    var client = Client.init(allocator, .{ .driver = .sqlite, .sqlite_path = db_path });
    defer {
        client.deinit();
        std.fs.cwd().deleteFile(db_path) catch {};
    }

    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});

    var stmt = try client.prepare("INSERT INTO users (name) VALUES (?1)");
    defer stmt.close();

    const r1 = try stmt.exec(&.{.{ .string = "Alice" }});
    try std.testing.expectEqual(@as(u64, 1), r1.rows_affected);
    try std.testing.expectEqual(@as(i64, 1), r1.last_insert_id.?);

    const r2 = try stmt.exec(&.{.{ .string = "Bob" }});
    try std.testing.expectEqual(@as(u64, 1), r2.rows_affected);
    try std.testing.expectEqual(@as(i64, 2), r2.last_insert_id.?);

    var select_stmt = try client.prepare("SELECT id, name FROM users WHERE name = ?1");
    defer select_stmt.close();

    const User = struct {
        id: i64,
        name: []const u8,
    };

    var rows = try select_stmt.query(allocator, &.{.{ .string = "Alice" }});
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    const user = try rows.rows[0].scan(allocator, User);
    defer freeScanned(allocator, User, user);
    try std.testing.expectEqual(@as(i64, 1), user.id);
    try std.testing.expectEqualStrings("Alice", user.name);
}

test "sqlx value" {
    const v = Value{ .int = 42 };
    try std.testing.expectEqual(@as(i64, 42), v.int);
}

test "postgres config init" {
    const cfg = Config{
        .driver = .postgres,
        .host = "localhost",
        .port = 5432,
        .database = "test",
        .username = "user",
        .password = "pass",
    };
    try std.testing.expectEqual(Driver.postgres, cfg.driver);
    try std.testing.expectEqual(@as(u16, 5432), cfg.port);
}

test "mysql config init" {
    const cfg = Config{
        .driver = .mysql,
        .host = "localhost",
        .port = 3306,
        .database = "test",
        .username = "user",
        .password = "pass",
    };
    try std.testing.expectEqual(Driver.mysql, cfg.driver);
    try std.testing.expectEqual(@as(u16, 3306), cfg.port);
}

test "postgres live connection" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, .{
        .driver = .postgres,
        .host = "localhost",
        .port = 5432,
        .database = "postgres",
        .username = "cborli",
        .password = "",
    });
    defer client.deinit();

    try client.connect();
    try client.ping();

    _ = client.exec("DROP TABLE IF EXISTS zigzero_test_users", &.{}) catch {};
    _ = try client.exec("CREATE TABLE zigzero_test_users (id SERIAL PRIMARY KEY, name TEXT)", &.{});

    const insert = try client.exec("INSERT INTO zigzero_test_users (name) VALUES ($1)", &.{.{ .string = "Alice" }});
    try std.testing.expectEqual(@as(u64, 1), insert.rows_affected);

    var rows = try client.query("SELECT id, name FROM zigzero_test_users WHERE name = $1", &.{.{ .string = "Alice" }});
    defer rows.deinit();

    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    try std.testing.expectEqualStrings("Alice", rows.rows[0].get("name").?.string);

    _ = try client.exec("DROP TABLE IF EXISTS zigzero_test_users", &.{});
}

test "mysql live connection" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, .{
        .driver = .mysql,
        .host = "localhost",
        .port = 3306,
        .database = "mysql",
        .username = "root",
        .password = "",
    });
    defer client.deinit();

    try client.connect();
    try client.ping();

    _ = client.exec("DROP TABLE IF EXISTS zigzero_test_users", &.{}) catch {};
    _ = try client.exec("CREATE TABLE zigzero_test_users (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255))", &.{});

    const insert = try client.exec("INSERT INTO zigzero_test_users (name) VALUES (?)", &.{.{ .string = "Alice" }});
    try std.testing.expectEqual(@as(u64, 1), insert.rows_affected);

    var rows = try client.query("SELECT id, name FROM zigzero_test_users WHERE name = ?", &.{.{ .string = "Alice" }});
    defer rows.deinit();

    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    try std.testing.expectEqualStrings("Alice", rows.rows[0].get("name").?.string);

    _ = try client.exec("DROP TABLE IF EXISTS zigzero_test_users", &.{});
}
