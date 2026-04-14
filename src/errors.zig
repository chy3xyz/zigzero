//! Error handling for zigzero
//!
//! Provides unified error types aligned with go-zero error patterns.

const std = @import("std");

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
        Error.DatabaseError => .ServerError,
        Error.RedisError => .ServerError,
        Error.ConfigError => .BadRequest,
        Error.NetworkError => .ServerError,
        Error.Timeout => .RequestTimeout,
        Error.ValidationError => .BadRequest,
    };
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
