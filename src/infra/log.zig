//! Logging system for zigzero
//!
//! Provides structured logging with levels, rotation, and async support.

const std = @import("std");
const compat = @import("../compat.zig");
const config = @import("../config.zig");
const errors = @import("../core/errors.zig");

/// Log level enum
pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
    fatal = 4,

    pub fn fromString(s: []const u8) Level {
        return std.meta.stringToEnum(Level, s) orelse .info;
    }

    pub fn toString(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .fatal => "FATAL",
        };
    }
};

/// Log output mode
pub const Mode = enum {
    console,
    file,
    both,
};

/// Log encoding format
pub const Encoding = enum {
    plain,
    json,
};

/// Structured JSON log entry
pub const Entry = struct {
    timestamp: i64,
    level: []const u8,
    service: []const u8,
    message: []const u8,
    trace_id: ?[]const u8 = null,
    span_id: ?[]const u8 = null,
    fields: ?std.StringHashMap([]const u8) = null,
};

/// File logger with rotation
pub const FileLogger = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    max_size: u64,
    max_backups: u32,
    current_size: u64,
    file: ?std.Io.File,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, max_size: u64, max_backups: u32) !FileLogger {
        const file = compat.cwd().createFile(path, .{ .truncate = false, .read = true }) catch null;
        const current_size = if (file) |f| f.getEndPos() catch 0 else 0;

        return .{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .max_size = max_size,
            .max_backups = max_backups,
            .current_size = current_size,
            .file = file,
        };
    }

    pub fn deinit(self: *FileLogger) void {
        if (self.file) |f| f.close();
        self.allocator.free(self.path);
    }

    pub fn write(self: *FileLogger, msg: []const u8) !void {
        if (self.file == null or self.current_size + msg.len > self.max_size) {
            try self.rotate();
        }

        if (self.file) |f| {
            try compat.fileWrite(f, msg);
            self.current_size += msg.len;
            try f.sync(compat.io());
        }
    }

    fn rotate(self: *FileLogger) !void {
        if (self.file) |f| {
            f.close(compat.io());
            self.file = null;
        }

        // Rotate backups
        var i: u32 = self.max_backups;
        while (i > 0) : (i -= 1) {
            const old_path = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ self.path, i - 1 });
            defer self.allocator.free(old_path);
            const new_path = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ self.path, i });
            defer self.allocator.free(new_path);

            compat.cwd().rename(old_path, compat.cwd(), new_path, compat.io()) catch {};
        }

        const backup_path = try std.fmt.allocPrint(self.allocator, "{s}.1", .{self.path});
        defer self.allocator.free(backup_path);
        compat.cwd().rename(self.path, compat.cwd(), backup_path, compat.io()) catch {};

        self.file = try compat.cwd().createFile(compat.io(), self.path, .{});
        self.current_size = 0;
    }
};

/// Logger instance
pub const Logger = struct {
    level: Level,
    service_name: []const u8,
    mode: Mode,
    encoding: Encoding,
    file_logger: ?FileLogger,

    /// Create a new logger with console output
    pub fn new(level: Level, service_name: []const u8) Logger {
        return Logger{
            .level = level,
            .service_name = service_name,
            .mode = .console,
            .encoding = .plain,
            .file_logger = null,
        };
    }

    /// Create a logger with JSON encoding
    pub fn withJson(self: Logger) Logger {
        var logger = self;
        logger.encoding = .json;
        return logger;
    }

    /// Create a logger with file output
    pub fn withFile(self: Logger, allocator: std.mem.Allocator, path: []const u8, max_size: u64, max_backups: u32) !Logger {
        var logger = self;
        logger.mode = .both;
        logger.file_logger = try FileLogger.init(allocator, path, max_size, max_backups);
        return logger;
    }

    pub fn deinit(self: *Logger) void {
        if (self.file_logger) |*fl| {
            fl.deinit();
            self.file_logger = null;
        }
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
        if (@intFromEnum(self.level) <= @intFromEnum(Level.err)) {
            self.log(.err, msg);
        }
    }

    /// Internal log function. Uses a stack buffer for the common case to avoid
    /// page_allocator churn in the hot path.
    fn log(self: *const Logger, level: Level, msg: []const u8) void {
        const timestamp = compat.timestamp();

        // Fast path: try to format into a stack buffer to avoid allocation.
        var stack_buf: [4096]u8 = undefined;
        const result = if (self.encoding == .json)
            std.fmt.bufPrint(&stack_buf, "{{\"timestamp\":{d},\"level\":\"{s}\",\"service\":\"{s}\",\"message\":\"{s}\"}}\n", .{
                timestamp,
                level.toString(),
                self.service_name,
                msg,
            })
        else
            std.fmt.bufPrint(&stack_buf, "[{d}] [{s}] [{s}] {s}\n", .{ timestamp, self.service_name, level.toString(), msg });

        const formatted: []const u8 = result catch |fmt_err| switch (fmt_err) {
            error.NoSpaceLeft => blk: {
                // Slow path: message is huge, fall back to page_allocator.
                const alloced = if (self.encoding == .json)
                    formatJson(std.heap.page_allocator, timestamp, self.service_name, level, msg) catch return
                else
                    std.fmt.allocPrint(std.heap.page_allocator, "[{d}] [{s}] [{s}] {s}\n", .{ timestamp, self.service_name, level.toString(), msg }) catch return;
                break :blk alloced;
            },
        };
        defer if (@intFromPtr(formatted.ptr) != @intFromPtr(&stack_buf[0])) std.heap.page_allocator.free(formatted);

        if (self.mode == .console or self.mode == .both) {
            const stdout = compat.stdout();
            compat.fileWrite(stdout, formatted) catch return;
        }

        const fl_ptr = @constCast(&self.file_logger);
        if (fl_ptr.*) |*fl| {
            if (self.mode == .file or self.mode == .both) {
                fl.write(formatted) catch return;
            }
        }
    }
};

fn formatJson(allocator: std.mem.Allocator, timestamp: i64, service: []const u8, level: Level, msg: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"timestamp\":{d},\"level\":\"{s}\",\"service\":\"{s}\",\"message\":\"{s}\"}}\n", .{
        timestamp,
        level.toString(),
        service,
        msg,
    });
}

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
