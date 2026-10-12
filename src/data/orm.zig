//! Simple ORM for zigzero
//!
//! Database access layer aligned with go-zero's model pattern, backed by the
//! real SQL client in `src/infra/sqlx.zig`. Every statement here is executed
//! against a real database; nothing is simulated.
//!
//! # Ownership
//!
//! * `Pool` owns one `sqlx.Client`; `Pool.deinit` releases the client and every
//!   connection it holds.
//! * `Pool.acquire` hands out a borrowed `Connection`. The handle is a view
//!   over the pool's client (which owns the real connection/pool), so it owns
//!   nothing, must not outlive the pool, and does not need to be released.
//! * `Connection.query` / `Transaction.query` return `[]T` allocated with the
//!   pool allocator; the string fields of each item are owned copies. Free with
//!   `Pool.deinitRows(T, rows)` / `Transaction.deinitRows(T, rows)`.
//! * `Crud(T).findById` returns `?T` whose string fields are owned by the
//!   caller; free with `Pool.freeScanned(T, value)`.
//! * `Crud(T).findAll` returns `[]T` owned by the caller; free with
//!   `Pool.deinitRows(T, rows)`.
//! * `Crud(T).create` / `Crud(T).update` return a copy of the caller's entity.
//!   Their string fields still alias the caller's memory and must NOT be passed
//!   to `freeScanned` / `deinitRows`.
//! * A `Transaction` must be finished with `commit` or `rollback`; otherwise the
//!   connection it holds is never returned to the pool.
//!
//! # Driver limitations (inherited from `src/infra/sqlx.zig`)
//!
//! * Typed scanning works on all three drivers: sqlite reports typed column
//!   values directly, and the postgres and mysql drivers build `i64` / `f64` /
//!   `bool` values from their column metadata (`PQftype` OIDs and
//!   `MYSQL_FIELD.type` / `flags`). Columns outside that set — timestamps, uuid,
//!   json, bytea, and any numeric text that fails to parse — still arrive as
//!   `.string` and scan into `[]const u8`. `numeric` / `DECIMAL` are exposed as
//!   `.float`, so a money column that needs exact decimals must be cast to text
//!   in the query and scanned into `[]const u8`.
//! # Mapping
//!
//! The table name comes from `pub const table_name` when the type declares one,
//! otherwise from the type name. The primary key comes from `pub const
//! primary_key` when declared (this is what `zgctl model` emits), otherwise from
//! a field named `id`; a type with neither fails with `error.NoPrimaryKey`.
//!
//! * `create` can fill a generated primary key only where sqlx reports
//!   `ExecResult.last_insert_id` — sqlite and mysql do, postgres does not (sqlx
//!   exposes no `RETURNING`). On postgres the caller must supply the key.

const std = @import("std");
const sqlx = @import("../infra/sqlx.zig");

/// Database connection configuration.
///
/// The field names of the original configuration are preserved (`host`, `port`,
/// `database`, `username`, `password`, `max_connections`); `driver` and
/// `sqlite_path` are additions. `driver` defaults to sqlite so a `Pool` can be
/// opened without any external service.
///
/// `max_connections` maps to the client's open/idle connection limits. Note
/// that sqlite's `:memory:` database is per-connection, so concurrent use of an
/// in-memory database requires `max_connections = 1`.
pub const Config = struct {
    driver: sqlx.Driver = .sqlite,
    host: []const u8 = "localhost",
    port: u16 = 3306,
    database: []const u8 = "",
    username: []const u8 = "",
    password: []const u8 = "",
    sqlite_path: []const u8 = ":memory:",
    /// Full libpq connection string. When set it takes precedence over the
    /// discrete host/port/database/username/password fields above.
    postgres_conninfo: []const u8 = "",
    max_connections: u32 = 10,
};

/// Database connection pool: owns the SQL client.
pub const Pool = struct {
    allocator: std.mem.Allocator,
    config: Config,
    client: sqlx.Client,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) Pool {
        return .{
            .allocator = allocator,
            .config = cfg,
            .client = sqlx.Client.init(allocator, .{
                .driver = cfg.driver,
                .host = cfg.host,
                .port = cfg.port,
                .database = cfg.database,
                .username = cfg.username,
                .password = cfg.password,
                .sqlite_path = cfg.sqlite_path,
                .postgres_conninfo = cfg.postgres_conninfo,
                .max_open_conns = cfg.max_connections,
                .max_idle_conns = cfg.max_connections,
            }),
        };
    }

    /// Release the client and close every connection it owns.
    pub fn deinit(self: *Pool) void {
        self.client.deinit();
    }

    /// Open the database connection eagerly. Optional: the client connects on
    /// demand on the first statement.
    pub fn connect(self: *Pool) !void {
        try self.client.connect();
    }

    /// Borrow a connection handle. The handle owns nothing (the client owns the
    /// real connection/pool) and stays valid only while `self` lives.
    pub fn acquire(self: *Pool) Connection {
        return .{ .client = &self.client };
    }

    /// Free rows returned by `Connection.query` / `Transaction.query`.
    pub fn deinitRows(self: *Pool, comptime T: type, rows: []T) void {
        self.client.deinitQueryRows(T, rows);
    }

    /// Free the owned string fields of a value returned by `Crud(T).findById`.
    pub fn freeScanned(self: *Pool, comptime T: type, value: T) void {
        sqlx.freeScanned(self.allocator, T, value);
    }
};

/// Borrowed handle onto the pool's SQL client.
pub const Connection = struct {
    client: *sqlx.Client,

    /// Run `sql_str` and scan every row into `[]T`.
    ///
    /// Ownership: the returned slice and the string fields of its items are
    /// allocated with the pool allocator; free the whole slice with
    /// `Pool.deinitRows(T, rows)`.
    pub fn query(self: *Connection, comptime T: type, sql_str: []const u8, args: anytype) ![]T {
        const allocator = self.client.allocator;
        const values = try toValues(allocator, args);
        defer allocator.free(values);
        return self.client.queryRows(T, sql_str, values);
    }

    /// Run `sql_str` and return the number of affected rows.
    pub fn execute(self: *Connection, sql_str: []const u8, args: anytype) !u64 {
        const allocator = self.client.allocator;
        const values = try toValues(allocator, args);
        defer allocator.free(values);
        return (try self.client.exec(sql_str, values)).rows_affected;
    }

    /// Start a transaction on the underlying connection.
    pub fn beginTransaction(self: *Connection) !Transaction {
        return .{
            .allocator = self.client.allocator,
            .tx = try self.client.beginTx(),
        };
    }
};

/// Database transaction. `commit` or `rollback` must be called exactly once.
pub const Transaction = struct {
    allocator: std.mem.Allocator,
    tx: sqlx.Transaction,
    active: bool = true,

    /// Run `sql_str` and scan every row into `[]T`.
    ///
    /// Ownership: identical to `Connection.query`; free with
    /// `Transaction.deinitRows(T, rows)`.
    pub fn query(self: *Transaction, comptime T: type, sql_str: []const u8, args: anytype) ![]T {
        const values = try toValues(self.allocator, args);
        defer self.allocator.free(values);

        var rows = try self.tx.query(self.allocator, sql_str, values);
        defer rows.deinit();

        const items = try self.allocator.alloc(T, rows.rows.len);
        errdefer {
            for (items) |item| sqlx.freeScanned(self.allocator, T, item);
            self.allocator.free(items);
        }
        for (rows.rows, 0..) |row, i| items[i] = try row.scan(self.allocator, T);
        return items;
    }

    /// Run `sql_str` and return the number of affected rows.
    pub fn execute(self: *Transaction, sql_str: []const u8, args: anytype) !u64 {
        const values = try toValues(self.allocator, args);
        defer self.allocator.free(values);
        return (try self.tx.exec(sql_str, values)).rows_affected;
    }

    /// Free rows returned by `Transaction.query`.
    pub fn deinitRows(self: *Transaction, comptime T: type, rows: []T) void {
        for (rows) |item| sqlx.freeScanned(self.allocator, T, item);
        self.allocator.free(rows);
    }

    pub fn commit(self: *Transaction) !void {
        if (!self.active) return error.TransactionNotActive;
        try self.tx.commit();
        self.active = false;
    }

    pub fn rollback(self: *Transaction) !void {
        if (!self.active) return error.TransactionNotActive;
        try self.tx.rollback();
        self.active = false;
    }
};

/// Model trait - types that can be used with ORM
pub fn Model(comptime T: type) type {
    return struct {
        pub const TableName = getTableName(T);
        pub const PrimaryKey = getPrimaryKey(T);
        pub const Fields = getFields(T);
    };
}

/// Get the table name for a type.
///
/// A type may pin its table name by declaring `pub const table_name = "...";`.
/// Otherwise the last path segment of the Zig type name is used, e.g. the type
/// `data.orm.User` maps to `User`. Generic instantiations (`Foo(u32)`) are not
/// valid SQL identifiers, so they should declare `table_name`.
fn getTableName(comptime T: type) []const u8 {
    if (@hasDecl(T, "table_name")) {
        return T.table_name;
    }
    const full_name = @typeName(T);
    if (std.mem.lastIndexOfScalar(u8, full_name, '.')) |dot| {
        return full_name[dot + 1 ..];
    }
    return full_name;
}

/// Get primary key field
fn getPrimaryKey(comptime T: type) []const u8 {
    // An explicit declaration wins — this is what `zgctl model` emits, and it
    // is the only way to describe a table whose key is not called `id`.
    if (@hasDecl(T, "primary_key")) return T.primary_key;
    // Otherwise fall back to the `id` convention.
    inline for (@typeInfo(T).@"struct".field_names) |field_name| {
        if (std.mem.eql(u8, field_name, "id")) {
            return "id";
        }
    }
    return "";
}

/// Get all field names
fn getFields(comptime T: type) []const []const u8 {
    comptime var fields: []const []const u8 = &[_][]const u8{};
    inline for (@typeInfo(T).@"struct".field_names) |field_name| {
        fields = fields ++ .{field_name};
    }
    return fields;
}

/// Query builder
pub const Query = struct {
    allocator: std.mem.Allocator,
    table: []const u8,
    select_fields: []const u8 = "*",
    where_clauses: std.ArrayList([]const u8),
    order_by: ?[]const u8 = null,
    limit_val: ?u32 = null,
    offset_val: ?u32 = null,

    pub fn init(allocator: std.mem.Allocator, table: []const u8) Query {
        return .{
            .allocator = allocator,
            .table = table,
            .where_clauses = .empty,
        };
    }

    pub fn deinit(self: *Query) void {
        self.where_clauses.deinit(self.allocator);
    }

    pub fn select(self: *Query, fields: []const u8) *Query {
        self.select_fields = fields;
        return self;
    }

    pub fn where(self: *Query, clause: []const u8) !*Query {
        try self.where_clauses.append(self.allocator, clause);
        return self;
    }

    pub fn order(self: *Query, field: []const u8) *Query {
        self.order_by = field;
        return self;
    }

    pub fn limit(self: *Query, n: u32) *Query {
        self.limit_val = n;
        return self;
    }

    pub fn offset(self: *Query, n: u32) *Query {
        self.offset_val = n;
        return self;
    }

    fn appendFmt(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt_str: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(allocator, fmt_str, args);
        defer allocator.free(s);
        try buf.appendSlice(allocator, s);
    }

    pub fn build(self: *const Query) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        try appendFmt(&buf, self.allocator, "SELECT {s} FROM {s}", .{ self.select_fields, self.table });

        if (self.where_clauses.items.len > 0) {
            try buf.appendSlice(self.allocator, " WHERE ");
            for (self.where_clauses.items, 0..) |clause, i| {
                if (i > 0) try buf.appendSlice(self.allocator, " AND ");
                try buf.appendSlice(self.allocator, clause);
            }
        }

        if (self.order_by) |order_field| {
            try appendFmt(&buf, self.allocator, " ORDER BY {s}", .{order_field});
        }

        if (self.limit_val) |n| {
            try appendFmt(&buf, self.allocator, " LIMIT {d}", .{n});
        }

        if (self.offset_val) |n| {
            try appendFmt(&buf, self.allocator, " OFFSET {d}", .{n});
        }

        return try self.allocator.dupe(u8, buf.items);
    }
};

// ==================== SQL helpers ====================

fn appendSqlFmt(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt_str: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(allocator, fmt_str, args);
    defer allocator.free(s);
    try buf.appendSlice(allocator, s);
}

/// Append the placeholder for the 1-based parameter `index`.
/// sqlite binds `?N`, postgres `$N`, mysql is positional `?`.
fn appendPlaceholder(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, driver: sqlx.Driver, index: usize) !void {
    switch (driver) {
        .sqlite => try appendSqlFmt(buf, allocator, "?{d}", .{index}),
        .postgres => try appendSqlFmt(buf, allocator, "${d}", .{index}),
        .mysql => try buf.append(allocator, '?'),
    }
}

fn appendFieldList(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, fields: []const []const u8) !void {
    for (fields, 0..) |field, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, field);
    }
}

fn isInteger(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => true,
        else => false,
    };
}

fn isU8Array(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .array => |arr| arr.child == u8,
        else => false,
    };
}

/// True when `field_name` is the primary key, is an integer, and holds `0` —
/// the "let the driver generate it" case that `create` omits from the INSERT.
fn isUnsetGeneratedKey(comptime FieldType: type, comptime field_name: []const u8, pk: []const u8, entity: anytype) bool {
    if (comptime isInteger(FieldType)) {
        if (std.mem.eql(u8, field_name, pk)) return @field(entity, field_name) == 0;
    }
    return false;
}

/// Convert a query argument or entity field into a `sqlx.Value`.
/// String literals (`*const [N:0]u8`) and slices (`[]const u8`) both become
/// `.string`; every other supported scalar maps to its natural variant.
fn toValue(v: anytype) sqlx.Value {
    const VT = @TypeOf(v);
    if (VT == sqlx.Value) return v;
    return switch (@typeInfo(VT)) {
        .comptime_int => .{ .int = v },
        .int => .{ .int = @intCast(v) },
        .comptime_float => .{ .float = v },
        .float => .{ .float = v },
        .bool => .{ .bool = v },
        .optional => if (v) |inner| toValue(inner) else .null,
        .pointer => |ptr| blk: {
            if (ptr.size == .slice and ptr.child == u8) break :blk .{ .string = v };
            if (ptr.size == .one) {
                if (comptime isU8Array(ptr.child)) break :blk .{ .string = v[0..] };
            }
            @compileError("orm: unsupported parameter type " ++ @typeName(VT));
        },
        else => @compileError("orm: unsupported parameter type " ++ @typeName(VT)),
    };
}

/// Convert a tuple of arguments (`.{ 1, "Alice" }` or `.{}`) into `[]sqlx.Value`.
/// The returned slice is allocated with `allocator` and belongs to the caller.
fn toValues(allocator: std.mem.Allocator, args: anytype) ![]sqlx.Value {
    const ArgsType = @TypeOf(args);
    switch (@typeInfo(ArgsType)) {
        .@"struct" => |s| {
            const values = try allocator.alloc(sqlx.Value, s.field_names.len);
            inline for (s.field_names, 0..) |field_name, i| {
                values[i] = toValue(@field(args, field_name));
            }
            return values;
        },
        else => @compileError("orm: query args must be a tuple, got " ++ @typeName(ArgsType)),
    }
}

/// Generic CRUD operations built from `Model(T)` metadata and executed against
/// the real database.
///
/// The primary key is the field named `id`. An integer primary key equal to `0`
/// on `create` is treated as "not set" and omitted from the INSERT so the
/// driver can generate it.
pub fn Crud(comptime T: type) type {
    const table = getTableName(T);
    const pk = getPrimaryKey(T);
    const fields = getFields(T);
    const field_count = fields.len;
    const s_info = @typeInfo(T).@"struct";

    return struct {
        pub const table_name = table;
        pub const primary_key = pk;

        /// `SELECT <fields> FROM <table> WHERE <pk> = ?`; `null` when absent.
        ///
        /// Ownership: the returned value's string fields are owned copies; free
        /// with `Pool.freeScanned(T, value)`.
        pub fn findById(pool: *Pool, id: anytype) !?T {
            if (pk.len == 0) return error.NoPrimaryKey;
            const allocator = pool.allocator;

            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);

            try buf.appendSlice(allocator, "SELECT ");
            try appendFieldList(&buf, allocator, fields);
            try appendSqlFmt(&buf, allocator, " FROM {s} WHERE {s} = ", .{ table, pk });
            try appendPlaceholder(&buf, allocator, pool.config.driver, 1);

            const values = [_]sqlx.Value{toValue(id)};
            var rows = try pool.client.query(buf.items, &values);
            defer rows.deinit();

            if (rows.rows.len == 0) return null;
            return try rows.rows[0].scan(allocator, T);
        }

        /// `SELECT <fields> FROM <table>`; scans every row into `[]T`.
        ///
        /// Ownership: free with `Pool.deinitRows(T, rows)`.
        pub fn findAll(pool: *Pool) ![]T {
            const allocator = pool.allocator;

            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);

            try buf.appendSlice(allocator, "SELECT ");
            try appendFieldList(&buf, allocator, fields);
            try appendSqlFmt(&buf, allocator, " FROM {s}", .{table});

            return pool.client.queryRows(T, buf.items, &.{});
        }

        /// `INSERT` the entity's fields and return the entity.
        ///
        /// The generated primary key is filled in from the driver's
        /// last-insert-id when the driver reports one: sqlite and mysql do,
        /// postgres does not (sqlx exposes no `RETURNING`), so on postgres the
        /// primary key is only meaningful if the caller supplied it.
        ///
        /// Ownership: the result is a copy of `entity`; its string fields still
        /// alias the caller's memory.
        pub fn create(pool: *Pool, entity: T) !T {
            const allocator = pool.allocator;

            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);

            var values: [field_count]sqlx.Value = undefined;
            var used: usize = 0;

            try appendSqlFmt(&buf, allocator, "INSERT INTO {s} (", .{table});
            inline for (s_info.field_names, s_info.field_types) |field_name, FieldType| {
                if (!isUnsetGeneratedKey(FieldType, field_name, pk, entity)) {
                    if (used > 0) try buf.appendSlice(allocator, ", ");
                    try buf.appendSlice(allocator, field_name);
                    values[used] = toValue(@field(entity, field_name));
                    used += 1;
                }
            }
            try buf.appendSlice(allocator, ") VALUES (");
            for (0..used) |i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try appendPlaceholder(&buf, allocator, pool.config.driver, i + 1);
            }
            try buf.appendSlice(allocator, ")");

            if (used == 0) return error.NoInsertableFields;
            const result = try pool.client.exec(buf.items, values[0..used]);

            var out = entity;
            if (result.last_insert_id) |insert_id| {
                if (insert_id != 0) {
                    inline for (s_info.field_names, s_info.field_types) |field_name, FieldType| {
                        if (comptime isInteger(FieldType)) {
                            if (std.mem.eql(u8, field_name, pk)) {
                                @field(out, field_name) = @intCast(insert_id);
                            }
                        }
                    }
                }
            }
            return out;
        }

        /// `UPDATE <table> SET <non-pk fields> WHERE <pk> = ?` and return the
        /// entity.
        ///
        /// The statement runs unconditionally: it reports no error when no row
        /// matches (use `findById` when existence matters).
        ///
        /// Ownership: the result is a copy of `entity`; its string fields still
        /// alias the caller's memory.
        pub fn update(pool: *Pool, entity: T) !T {
            if (pk.len == 0) return error.NoPrimaryKey;
            const allocator = pool.allocator;

            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);

            var values: [field_count]sqlx.Value = undefined;
            var used: usize = 0;

            try appendSqlFmt(&buf, allocator, "UPDATE {s} SET ", .{table});
            inline for (s_info.field_names) |field_name| {
                if (!std.mem.eql(u8, field_name, pk)) {
                    if (used > 0) try buf.appendSlice(allocator, ", ");
                    try appendSqlFmt(&buf, allocator, "{s} = ", .{field_name});
                    try appendPlaceholder(&buf, allocator, pool.config.driver, used + 1);
                    values[used] = toValue(@field(entity, field_name));
                    used += 1;
                }
            }
            if (used == 0) return error.NoUpdatableFields;

            try appendSqlFmt(&buf, allocator, " WHERE {s} = ", .{pk});
            try appendPlaceholder(&buf, allocator, pool.config.driver, used + 1);
            inline for (s_info.field_names) |field_name| {
                if (std.mem.eql(u8, field_name, pk)) {
                    values[used] = toValue(@field(entity, field_name));
                    used += 1;
                }
            }

            _ = try pool.client.exec(buf.items, values[0..used]);
            return entity;
        }

        /// `DELETE FROM <table> WHERE <pk> = ?`.
        pub fn delete(pool: *Pool, id: anytype) !void {
            if (pk.len == 0) return error.NoPrimaryKey;
            const allocator = pool.allocator;

            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);

            try appendSqlFmt(&buf, allocator, "DELETE FROM {s} WHERE {s} = ", .{ table, pk });
            try appendPlaceholder(&buf, allocator, pool.config.driver, 1);

            const values = [_]sqlx.Value{toValue(id)};
            _ = try pool.client.exec(buf.items, &values);
        }
    };
}

// ==================== Tests ====================

const OrmTestUser = struct {
    pub const table_name = "orm_test_users";
    id: i64,
    name: []const u8,
    email: []const u8,
};

const create_orm_test_users_sql =
    "CREATE TABLE orm_test_users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL)";

test "orm query builder" {
    const allocator = std.testing.allocator;

    var query = Query.init(allocator, "users");
    defer query.deinit();

    _ = try query.where("id = 1");
    _ = try query.where("status = 'active'");
    _ = query.limit(10);

    const sql = try query.build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "SELECT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "FROM users") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "LIMIT 10") != null);
}

test "model trait" {
    const User = struct {
        id: i64,
        name: []const u8,
        email: []const u8,
    };

    const userModel = Model(User);
    try std.testing.expectEqualStrings("id", userModel.PrimaryKey);
    try std.testing.expect(userModel.Fields.len == 3);
}

test "orm table name" {
    const Plain = struct { id: i64 };
    try std.testing.expectEqualStrings("Plain", getTableName(Plain));
    try std.testing.expectEqualStrings("orm_test_users", getTableName(OrmTestUser));
}

test "orm placeholders follow the driver" {
    const allocator = std.testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try appendPlaceholder(&buf, allocator, .sqlite, 1);
    try appendPlaceholder(&buf, allocator, .sqlite, 2);
    try std.testing.expectEqualStrings("?1?2", buf.items);

    buf.clearRetainingCapacity();
    try appendPlaceholder(&buf, allocator, .postgres, 3);
    try std.testing.expectEqualStrings("$3", buf.items);

    buf.clearRetainingCapacity();
    try appendPlaceholder(&buf, allocator, .mysql, 1);
    try appendPlaceholder(&buf, allocator, .mysql, 2);
    try std.testing.expectEqualStrings("??", buf.items);
}

test "orm connection executes and queries a real sqlite database" {
    const allocator = std.testing.allocator;

    var pool = Pool.init(allocator, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer pool.deinit();

    var conn = pool.acquire();
    _ = try conn.execute(create_orm_test_users_sql, .{});

    const affected = try conn.execute(
        "INSERT INTO orm_test_users (name, email) VALUES (?1, ?2)",
        .{ "Alice", "alice@example.com" },
    );
    try std.testing.expectEqual(@as(u64, 1), affected);

    const users = try conn.query(
        OrmTestUser,
        "SELECT id, name, email FROM orm_test_users ORDER BY id",
        .{},
    );
    defer pool.deinitRows(OrmTestUser, users);

    try std.testing.expectEqual(@as(usize, 1), users.len);
    try std.testing.expectEqual(@as(i64, 1), users[0].id);
    try std.testing.expectEqualStrings("Alice", users[0].name);
    try std.testing.expectEqualStrings("alice@example.com", users[0].email);
}

test "orm crud round trip against sqlite" {
    const allocator = std.testing.allocator;

    var pool = Pool.init(allocator, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer pool.deinit();

    var conn = pool.acquire();
    _ = try conn.execute(create_orm_test_users_sql, .{});

    const UserCrud = Crud(OrmTestUser);

    // Absent row and empty table.
    try std.testing.expect((try UserCrud.findById(&pool, 1)) == null);
    const empty = try UserCrud.findAll(&pool);
    defer pool.deinitRows(OrmTestUser, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    // create: the generated primary key is written back.
    const created = try UserCrud.create(&pool, .{ .id = 0, .name = "Alice", .email = "alice@example.com" });
    try std.testing.expectEqual(@as(i64, 1), created.id);

    const found = (try UserCrud.findById(&pool, created.id)).?;
    defer pool.freeScanned(OrmTestUser, found);
    try std.testing.expectEqualStrings("Alice", found.name);
    try std.testing.expectEqualStrings("alice@example.com", found.email);

    // update
    const updated_entity = try UserCrud.update(&pool, .{ .id = created.id, .name = "Bob", .email = "bob@example.com" });
    try std.testing.expectEqual(@as(i64, 1), updated_entity.id);

    const updated = (try UserCrud.findById(&pool, created.id)).?;
    defer pool.freeScanned(OrmTestUser, updated);
    try std.testing.expectEqualStrings("Bob", updated.name);
    try std.testing.expectEqualStrings("bob@example.com", updated.email);

    const all = try UserCrud.findAll(&pool);
    defer pool.deinitRows(OrmTestUser, all);
    try std.testing.expectEqual(@as(usize, 1), all.len);
    try std.testing.expectEqualStrings("Bob", all[0].name);

    // delete
    try UserCrud.delete(&pool, created.id);
    try std.testing.expect((try UserCrud.findById(&pool, created.id)) == null);

    const after_delete = try UserCrud.findAll(&pool);
    defer pool.deinitRows(OrmTestUser, after_delete);
    try std.testing.expectEqual(@as(usize, 0), after_delete.len);
}

test "orm transaction commit and rollback" {
    const allocator = std.testing.allocator;

    var pool = Pool.init(allocator, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer pool.deinit();

    var conn = pool.acquire();
    _ = try conn.execute(create_orm_test_users_sql, .{});

    const insert_sql = "INSERT INTO orm_test_users (name, email) VALUES (?1, ?2)";

    // commit persists
    var tx = try conn.beginTransaction();
    _ = try tx.execute(insert_sql, .{ "Committed", "committed@example.com" });

    const in_tx = try tx.query(OrmTestUser, "SELECT id, name, email FROM orm_test_users", .{});
    defer tx.deinitRows(OrmTestUser, in_tx);
    try std.testing.expectEqual(@as(usize, 1), in_tx.len);

    try tx.commit();
    try std.testing.expectError(error.TransactionNotActive, tx.commit());

    const persisted = (try Crud(OrmTestUser).findById(&pool, 1)).?;
    defer pool.freeScanned(OrmTestUser, persisted);
    try std.testing.expectEqualStrings("Committed", persisted.name);

    // rollback discards
    var tx2 = try conn.beginTransaction();
    _ = try tx2.execute(insert_sql, .{ "Rolled", "rolled@example.com" });
    try tx2.rollback();
    try std.testing.expectError(error.TransactionNotActive, tx2.rollback());

    try std.testing.expect((try Crud(OrmTestUser).findById(&pool, 2)) == null);
}
