//! Logging system for zigzero
//!
//! Provides structured logging with levels, rotation, and async support.

const std = @import("std");
const config = @import("config");
const errors = @import("errors");

/// Log level enum
pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    error = 3,
    fatal = 4,

    pub fn fromString(s: []const u8) Level {
        return std.meta.stringToEnum(Level, s) orelse .info;
    }

    pub fn toString(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .error => "ERROR",
            .fatal => "FATAL",
        };
    }
};

/// Logger instance
pub const Logger = struct {
    level: Level,
    service_name: []const u8,
    writer: std.io.AnyWriter,

    /// Create a new logger with console output
    pub fn new(level: Level, service_name: []const u8) Logger {
        return Logger{
            .level = level,
            .service_name = service_name,
            .writer = std.io.getStdOut().writer().any(),
        };
    }

    /// Log a message at debug level
    pub fn debug(self: *const Logger, msg: []const u8) void {
        if (@intFromEnum(self.level) <= @intFromEnum(Level.debug)) {
            self.log(.debug, msg);
        }
    }

    /// Log a message at info level
    pub fn info(self: *const Logger, msg: []const u8) void {
        if (@intFromEnum(self.level) <= @intFromEnum(Level.info)) {
            self.log(.info, msg);
        }
    }

    /// Log a message at warn level
    pub fn warn(self: *const Logger, msg: []const u8) void {
        if (@intFromEnum(self.level) <= @intFromEnum(Level.warn)) {
            self.log(.warn, msg);
        }
    }

    /// Log a message at error level
    pub fn err(self: *const Logger, msg: []const u8) void {
        if (@intFromEnum(self.level) <= @intFromEnum(Level.error)) {
            self.log(.error, msg);
        }
    }

    /// Internal log function
    fn log(self: *const Logger, level: Level, msg: []const u8) void {
        const timestamp = std.time.timestamp();
        const formatted = std.fmt.allocPrint(std.heap.page_allocator, 
            "[{d}] [{s}] [{s}] {s}\n", .{
            timestamp, self.service_name, level.toString(), msg
        }) catch return;
        defer std.heap.page_allocator.free(formatted);
        self.writer.writeAll(formatted) catch return;
    }
};

/// Global default logger
var default_logger: Logger = Logger.new(.info, "zigzero");

/// Get the default logger
pub fn default() *Logger {
    return &default_logger;
}

/// Set the default logger
pub fn setDefault(logger: Logger) void {
    default_logger = logger;
}

/// Initialize logger from config
pub fn initFromConfig(cfg: config.LogConfig) void {
    const level = Level.fromString(cfg.level);
    default_logger = Logger.new(level, cfg.service_name);
}

test "log level" {
    try std.testing.expectEqualStrings("INFO", Level.info.toString());
    try std.testing.expectEqual(Level.debug, Level.fromString("debug"));
}
