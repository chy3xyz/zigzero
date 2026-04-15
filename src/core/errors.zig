//! Error handling for zigzero
//!
//! Provides unified error types aligned with go-zero error patterns.

const std = @import("std");

/// SQLState code type
pub const SqlState = []const u8;

/// Structured SQL error with SQLState code
pub const SqlError = struct {
    kind: DatabaseError,
    sql_state: SqlState,
    message: []const u8,
};

/// Database-specific error types aligned with SQLState codes
pub const DatabaseError = error{
    /// Connection failed or lost
    ConnectionFailed,

    /// Query execution failed
    QueryFailed,

    /// Data manipulation (INSERT/UPDATE/DELETE) failed
    ExecFailed,

    /// Operation timed out
    Timeout,

    /// Record not found (mapped from SQLState 02000 "no data")
    NotFound,

    /// Constraint violation (unique, check, not null, etc.)
    ConstraintViolation,

    /// Serialization failure (deadlock or lock timeout)
    SerializationFailure,

    /// Read-only transaction or connection
    ReadOnlyViolation,

    /// Too many connections
    TooManyConnections,

    /// Other/unclassified database error
    Other,
};

/// Core error types for zigzero
pub const Error = error{
    /// Generic server error (maps to go-zero's ErrServer)
    ServerError,

    /// Not found error (maps to go-zero's NotFound)
    NotFound,

    /// Invalid parameter error (maps to go-zero's InvalidParameter)
    InvalidParameter,

    /// Unauthorized error (maps to go-zero's Unauthorized)
    Unauthorized,

    /// Forbidden error (maps to go-zero's Forbidden)
    Forbidden,

    /// Rate limit exceeded (maps to go-zero's ErrRateLimit)
    RateLimitExceeded,

    /// Circuit breaker is open (maps to go-zero's ErrCircuitBreaker)
    CircuitBreakerOpen,

    /// Service unavailable (maps to go-zero's ServiceUnavailable)
    ServiceUnavailable,

    /// Service overloaded (maps to go-zero's ErrServiceOverloaded)
    ServiceOverloaded,

    /// Database error
    DatabaseError,

    /// Redis error
    RedisError,

    /// Configuration error
    ConfigError,

    /// Network error
    NetworkError,

    /// Timeout error
    Timeout,

    /// Validation error
    ValidationError,

    /// Out of memory
    OutOfMemory,

    /// Pool unhealthy or exhausted
    PoolUnhealthy,
};

/// Result type alias
pub const Result = Error!void;

/// Result type with value
pub fn ResultT(comptime T: type) type {
    return Error!T;
}

/// Error code constants (aligned with go-zero)
pub const Code = enum(i32) {
    OK = 0,
    BadRequest = 400,
    Unauthorized = 401,
    Forbidden = 403,
    NotFound = 404,
    RequestTimeout = 408,
    ServerError = 500,
    ServiceUnavailable = 503,
    RateLimit = 429,
};

/// Convert Error to Code
pub fn toCode(err: Error) Code {
    return switch (err) {
        Error.ServerError => .ServerError,
        Error.NotFound => .NotFound,
        Error.InvalidParameter => .BadRequest,
        Error.Unauthorized => .Unauthorized,
        Error.Forbidden => .Forbidden,
        Error.RateLimitExceeded => .RateLimit,
        Error.CircuitBreakerOpen => .ServiceUnavailable,
        Error.ServiceUnavailable => .ServiceUnavailable,
        Error.ServiceOverloaded => .ServiceUnavailable,
        Error.DatabaseError => .ServerError,
        Error.RedisError => .ServerError,
        Error.ConfigError => .BadRequest,
        Error.NetworkError => .ServerError,
        Error.Timeout => .RequestTimeout,
        Error.ValidationError => .BadRequest,
        Error.OutOfMemory => .ServerError,
        Error.PoolUnhealthy => .ServiceUnavailable,
    };
}

/// Map SQLState code to DatabaseError kind
pub fn sqlStateToError(sql_state: SqlState) DatabaseError {
    // PostgreSQL SQLState codes
    if (std.mem.eql(u8, sql_state, "08000")) return error.ConnectionFailed; // connection exception
    if (std.mem.eql(u8, sql_state, "08003")) return error.ConnectionFailed; // connection does not exist
    if (std.mem.eql(u8, sql_state, "08006")) return error.ConnectionFailed; // connection failure
    if (std.mem.eql(u8, sql_state, "40001")) return error.SerializationFailure; // serialization failure
    if (std.mem.eql(u8, sql_state, "40P01")) return error.SerializationFailure; // deadlock
    if (std.mem.eql(u8, sql_state, "25000")) return error.ReadOnlyViolation; // invalid transaction state
    if (std.mem.eql(u8, sql_state, "25001")) return error.ReadOnlyViolation; // active sql transaction
    if (std.mem.eql(u8, sql_state, "25002")) return error.ReadOnlyViolation; // read only sql transaction

    // MySQL SQLState codes
    if (std.mem.eql(u8, sql_state, "23000")) return error.ConstraintViolation; // integrity constraint violation
    if (std.mem.eql(u8, sql_state, "23505")) return error.ConstraintViolation; // unique violation (PostgreSQL)
    if (std.mem.eql(u8, sql_state, "23503")) return error.ConstraintViolation; // foreign key violation
    if (std.mem.eql(u8, sql_state, "23514")) return error.ConstraintViolation; // check constraint violation
    if (std.mem.eql(u8, sql_state, "08004")) return error.ConnectionFailed; // connection refused
    if (std.mem.eql(u8, sql_state, "08001")) return error.ConnectionFailed; // sqlclient unable to connect

    // Common SQLState codes
    if (std.mem.eql(u8, sql_state, "02000")) return error.NotFound; // no data
    if (std.mem.eql(u8, sql_state, "42P01")) return error.QueryFailed; // undefined table
    if (std.mem.eql(u8, sql_state, "42601")) return error.QueryFailed; // syntax error
    if (std.mem.eql(u8, sql_state, "42703")) return error.QueryFailed; // undefined column
    if (std.mem.eql(u8, sql_state, "42S02")) return error.QueryFailed; // base table not found (MySQL)
    if (std.mem.eql(u8, sql_state, "42S22")) return error.QueryFailed; // column not found (MySQL)

    return error.Other;
}

/// Check if a DatabaseError is acceptable (should not trip circuit breaker)
pub fn isAcceptableDbError(err: DatabaseError) bool {
    return switch (err) {
        error.NotFound, error.SerializationFailure, error.ReadOnlyViolation => true,
        else => false,
    };
}

test "sql state to error mapping" {
    try std.testing.expect(sqlStateToError("23000") == error.ConstraintViolation);
    try std.testing.expect(sqlStateToError("23505") == error.ConstraintViolation);
    try std.testing.expect(sqlStateToError("02000") == error.NotFound);
    try std.testing.expect(sqlStateToError("08000") == error.ConnectionFailed);
    try std.testing.expect(sqlStateToError("00000") == error.Other);
}

test "acceptable db error" {
    try std.testing.expect(isAcceptableDbError(error.NotFound));
    try std.testing.expect(isAcceptableDbError(error.SerializationFailure));
    try std.testing.expect(!isAcceptableDbError(error.QueryFailed));
    try std.testing.expect(!isAcceptableDbError(error.ConnectionFailed));
}

/// Standardized JSON error response aligned with go-zero
pub const ErrorResponse = struct {
    code: i32,
    message: []const u8,
    details: ?[]const u8 = null,
};

/// Build a JSON error response string. Caller owns returned memory.
pub fn toJson(allocator: std.mem.Allocator, err: ErrorResponse) ![]u8 {
    if (err.details) |details| {
        return std.fmt.allocPrint(allocator, "{{\"code\":{d},\"message\":\"{s}\",\"details\":\"{s}\"}}", .{ err.code, err.message, details });
    } else {
        return std.fmt.allocPrint(allocator, "{{\"code\":{d},\"message\":\"{s}\"}}", .{ err.code, err.message });
    }
}

/// Convenience: create JSON from Error + message
pub fn fromError(allocator: std.mem.Allocator, err: Error, message: []const u8) ![]u8 {
    const resp = ErrorResponse{
        .code = @intFromEnum(toCode(err)),
        .message = message,
    };
    return toJson(allocator, resp);
}

test "error to code" {
    try std.testing.expectEqual(Code.ServerError, toCode(Error.ServerError));
    try std.testing.expectEqual(Code.NotFound, toCode(Error.NotFound));
    try std.testing.expectEqual(Code.RateLimit, toCode(Error.RateLimitExceeded));
}
