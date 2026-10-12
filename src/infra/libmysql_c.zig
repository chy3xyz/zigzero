//! MariaDB/MySQL C bindings (connection + text protocol + prepared statements)
//!
//! `build.zig` prefers MariaDB Connector/C on macOS, so `MYSQL_BIND` is declared
//! with that library's layout (`mariadb_stmt.h`); the members this repo sets sit
//! at the same offsets in MySQL 8's client.

pub const MYSQL = opaque {};
pub const MYSQL_RES = opaque {};
pub const MYSQL_STMT = opaque {};
pub const MYSQL_ROW = ?[*]?[*]u8;
pub const MYSQL_FIELD = extern struct {
    name: [*c]u8,
    org_name: [*c]u8,
    table: [*c]u8,
    org_table: [*c]u8,
    db: [*c]u8,
    catalog: [*c]u8,
    def: [*c]u8,
    length: c_ulong,
    max_length: c_ulong,
    name_length: c_uint,
    org_name_length: c_uint,
    table_length: c_uint,
    org_table_length: c_uint,
    db_length: c_uint,
    catalog_length: c_uint,
    def_length: c_uint,
    flags: c_uint,
    decimals: c_uint,
    charsetnr: c_uint,
    type: c_int,
    /// Both MariaDB Connector/C and MySQL 8 end the struct with a pointer here.
    /// Declaring it is what makes `@sizeOf(MYSQL_FIELD)` match the linked
    /// library (128 on libmariadb; 120 without it), so a `MYSQL_FIELD` array can
    /// be indexed with the right stride. The prepared-statement path reads its
    /// metadata through `mysql_fetch_field`'s cursor rather than an array index.
    extension: ?*anyopaque,
};

pub const enum_field_types = c_int;
pub const MYSQL_TYPE_DECIMAL = 0;
pub const MYSQL_TYPE_TINY = 1;
pub const MYSQL_TYPE_SHORT = 2;
pub const MYSQL_TYPE_LONG = 3;
pub const MYSQL_TYPE_FLOAT = 4;
pub const MYSQL_TYPE_DOUBLE = 5;
pub const MYSQL_TYPE_NULL = 6;
pub const MYSQL_TYPE_LONGLONG = 8;
pub const MYSQL_TYPE_INT24 = 9;
pub const MYSQL_TYPE_VARCHAR = 15;
pub const MYSQL_TYPE_NEWDECIMAL = 246;
pub const MYSQL_TYPE_TINY_BLOB = 249;
pub const MYSQL_TYPE_MEDIUM_BLOB = 250;
pub const MYSQL_TYPE_LONG_BLOB = 251;
pub const MYSQL_TYPE_BLOB = 252;
pub const MYSQL_TYPE_VAR_STRING = 253;
pub const MYSQL_TYPE_STRING = 254;

/// Set in `MYSQL_FIELD.flags` for an unsigned numeric column.
pub const UNSIGNED_FLAG: c_uint = 32;

/// MariaDB's `my_bool` is a C `char` — one byte, not Zig's `bool`.
pub const my_bool = u8;

/// `mysql_stmt_fetch` result: no more rows.
pub const MYSQL_NO_DATA: c_int = 100;
/// `mysql_stmt_fetch` result: a bound buffer was too small for the column.
pub const MYSQL_DATA_TRUNCATED: c_int = 101;

/// Bind descriptor for parameters and result columns (`MYSQL_BIND`).
pub const MYSQL_BIND = extern struct {
    length: ?*c_ulong = null,
    is_null: ?*my_bool = null,
    buffer: ?*anyopaque = null,
    @"error": ?*my_bool = null,
    u: extern union {
        row_ptr: ?[*]u8,
        indicator: ?[*]u8,
    } = .{ .row_ptr = null },
    store_param_func: ?*anyopaque = null,
    fetch_result: ?*anyopaque = null,
    skip_result: ?*anyopaque = null,
    buffer_length: c_ulong = 0,
    offset: c_ulong = 0,
    length_value: c_ulong = 0,
    flags: c_uint = 0,
    pack_length: c_uint = 0,
    buffer_type: c_int = 0,
    error_value: my_bool = 0,
    is_unsigned: my_bool = 0,
    long_data_used: my_bool = 0,
    is_null_value: my_bool = 0,
    extension: ?*anyopaque = null,
};

pub extern "c" fn mysql_init(mysql: ?*MYSQL) ?*MYSQL;
pub extern "c" fn mysql_real_connect(mysql: ?*MYSQL, host: [*c]const u8, user: [*c]const u8, passwd: [*c]const u8, db: [*c]const u8, port: c_uint, unix_socket: [*c]const u8, clientflag: c_ulong) ?*MYSQL;
pub extern "c" fn mysql_close(sock: ?*MYSQL) void;
pub extern "c" fn mysql_query(mysql: ?*MYSQL, q: [*c]const u8) c_int;
pub extern "c" fn mysql_real_query(mysql: ?*MYSQL, q: [*c]const u8, length: c_ulong) c_int;
pub extern "c" fn mysql_store_result(mysql: ?*MYSQL) ?*MYSQL_RES;
pub extern "c" fn mysql_free_result(res: ?*MYSQL_RES) void;
pub extern "c" fn mysql_fetch_row(res: ?*MYSQL_RES) MYSQL_ROW;
pub extern "c" fn mysql_fetch_lengths(res: ?*MYSQL_RES) [*c]c_ulong;
pub extern "c" fn mysql_num_fields(res: ?*MYSQL_RES) c_uint;
pub extern "c" fn mysql_num_rows(res: ?*MYSQL_RES) c_ulonglong;
pub extern "c" fn mysql_fetch_field(res: ?*MYSQL_RES) ?*MYSQL_FIELD;
pub extern "c" fn mysql_affected_rows(mysql: ?*MYSQL) c_ulonglong;
pub extern "c" fn mysql_insert_id(mysql: ?*MYSQL) c_ulonglong;
pub extern "c" fn mysql_error(mysql: ?*MYSQL) [*c]const u8;
pub extern "c" fn mysql_errno(mysql: ?*MYSQL) c_uint;
pub extern "c" fn mysql_autocommit(mysql: ?*MYSQL, auto_mode: bool) c_int;
pub extern "c" fn mysql_commit(mysql: ?*MYSQL) c_int;
pub extern "c" fn mysql_rollback(mysql: ?*MYSQL) c_int;

// ---- Prepared statements (mariadb_stmt.h) ----
pub extern "c" fn mysql_stmt_init(mysql: ?*MYSQL) ?*MYSQL_STMT;
pub extern "c" fn mysql_stmt_prepare(stmt: ?*MYSQL_STMT, query: [*c]const u8, length: c_ulong) c_int;
pub extern "c" fn mysql_stmt_bind_param(stmt: ?*MYSQL_STMT, bnd: [*]MYSQL_BIND) my_bool;
pub extern "c" fn mysql_stmt_bind_result(stmt: ?*MYSQL_STMT, bnd: [*]MYSQL_BIND) my_bool;
pub extern "c" fn mysql_stmt_execute(stmt: ?*MYSQL_STMT) c_int;
pub extern "c" fn mysql_stmt_store_result(stmt: ?*MYSQL_STMT) c_int;
pub extern "c" fn mysql_stmt_fetch(stmt: ?*MYSQL_STMT) c_int;
pub extern "c" fn mysql_stmt_fetch_column(stmt: ?*MYSQL_STMT, bind: [*c]MYSQL_BIND, column: c_uint, offset: c_ulong) c_int;
pub extern "c" fn mysql_stmt_free_result(stmt: ?*MYSQL_STMT) my_bool;
pub extern "c" fn mysql_stmt_close(stmt: ?*MYSQL_STMT) my_bool;
pub extern "c" fn mysql_stmt_reset(stmt: ?*MYSQL_STMT) my_bool;
pub extern "c" fn mysql_stmt_param_count(stmt: ?*MYSQL_STMT) c_ulong;
pub extern "c" fn mysql_stmt_field_count(stmt: ?*MYSQL_STMT) c_uint;
pub extern "c" fn mysql_stmt_affected_rows(stmt: ?*MYSQL_STMT) c_ulonglong;
pub extern "c" fn mysql_stmt_insert_id(stmt: ?*MYSQL_STMT) c_ulonglong;
pub extern "c" fn mysql_stmt_errno(stmt: ?*MYSQL_STMT) c_uint;
pub extern "c" fn mysql_stmt_error(stmt: ?*MYSQL_STMT) [*c]const u8;
pub extern "c" fn mysql_stmt_result_metadata(stmt: ?*MYSQL_STMT) ?*MYSQL_RES;
pub extern "c" fn mysql_stmt_num_rows(stmt: ?*MYSQL_STMT) c_ulonglong;
