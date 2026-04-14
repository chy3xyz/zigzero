//! SQL client abstraction for zigzero
//!
//! Aligned with go-zero's core/stores/sqlx package.
//! Supports SQLite, PostgreSQL, and MySQL via C bindings.

const std = @import("std");
const errors = @import("../core/errors.zig");
const sqlite3_c = @import("sqlite3_c.zig");
const libpq_c = @import("libpq_c.zig");
const libmysql_c = @import("libmysql_c.zig");

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
};

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

    pub fn toConn(self: *SQLiteConn) Conn {
        return .{
            .ptr = self,
            .vtable = &.{
                .query = queryFn,
                .exec = execFn,
                .close = closeFn,
                .ping = pingFn,
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

    pub fn toConn(self: *PostgresConn) Conn {
        return .{
            .ptr = self,
            .vtable = &.{
                .query = queryFn,
                .exec = execFn,
                .close = closeFn,
                .ping = pingFn,
            },
        };
    }
};

// ==================== MySQL Implementation ====================

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
                const field = libmysql_c.mysql_fetch_field(res) orelse continue;
                const name = std.mem.span(field.name);
                columns[c] = allocator.dupe(u8, name) catch return error.DatabaseError;
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

    pub fn toConn(self: *MySqlConn) Conn {
        return .{
            .ptr = self,
            .vtable = &.{
                .query = queryFn,
                .exec = execFn,
                .close = closeFn,
                .ping = pingFn,
            },
        };
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
};

/// SQLx client - unified SQL client
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,
    conn: ?Conn = null,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) Client {
        return .{
            .allocator = allocator,
            .config = cfg,
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.conn) |*c| c.close();
    }

    pub fn connect(self: *Client) !void {
        if (self.conn != null) return;
        switch (self.config.driver) {
            .sqlite => {
                const sqlite = try self.allocator.create(SQLiteConn);
                sqlite.* = try SQLiteConn.open(self.allocator, self.config.sqlite_path);
                self.conn = sqlite.toConn();
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
                pg.* = try PostgresConn.connect(self.allocator, info);
                self.conn = pg.toConn();
            },
            .mysql => {
                const mysql = try self.allocator.create(MySqlConn);
                mysql.* = try MySqlConn.connect(self.allocator, self.config.host, self.config.username, self.config.password, self.config.database, self.config.port);
                self.conn = mysql.toConn();
            },
        }
    }

    pub fn query(self: *Client, sql_str: []const u8, args: []const Value) !Rows {
        if (self.conn == null) try self.connect();
        return self.conn.?.query(self.allocator, sql_str, args);
    }

    pub fn exec(self: *Client, sql_str: []const u8, args: []const Value) !ExecResult {
        if (self.conn == null) try self.connect();
        return self.conn.?.exec(sql_str, args);
    }

    pub fn ping(self: *Client) !void {
        if (self.conn == null) try self.connect();
        return self.conn.?.ping();
    }

    pub fn beginTx(self: *Client) !Transaction {
        _ = self;
        return error.NotImplemented;
    }
};

/// SQL transaction (stub)
pub const Transaction = struct {
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

    pub fn commit(self: *Transaction) !void {
        _ = self;
        return error.NotImplemented;
    }

    pub fn rollback(self: *Transaction) !void {
        _ = self;
        return error.NotImplemented;
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

// ==================== Tests ====================

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
