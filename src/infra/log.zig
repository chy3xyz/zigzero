//! Logging system for zigzero
//!
//! Provides structured logging with levels, rotation, and async support.

const std = @import("std");
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
    file: ?std.fs.File,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, max_size: u64, max_backups: u32) !FileLogger {
        const file = std.fs.cwd().createFile(path, .{ .truncate = false, .read = true }) catch null;
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
            _ = try f.write(msg);
            self.current_size += msg.len;
            try f.sync();
        }
    }

    fn rotate(self: *FileLogger) !void {
        if (self.file) |f| {
            f.close();
            self.file = null;
        }

        // Rotate backups
        var i: u32 = self.max_backups;
        while (i > 0) : (i -= 1) {
            const old_path = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ self.path, i - 1 });
            defer self.allocator.free(old_path);
            const new_path = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ self.path, i });
            defer self.allocator.free(new_path);

            std.fs.cwd().rename(old_path, new_path) catch {};
        }

        const backup_path = try std.fmt.allocPrint(self.allocator, "{s}.1", .{self.path});
        defer self.allocator.free(backup_path);
        std.fs.cwd().rename(self.path, backup_path) catch {};

        self.file = try std.fs.cwd().createFile(self.path, .{});
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

    /// Internal log function
    fn log(self: *const Logger, level: Level, msg: []const u8) void {
        const timestamp = std.time.timestamp();
        const formatted = if (self.encoding == .json)
            formatJson(std.heap.page_allocator, timestamp, self.service_name, level, msg) catch return
        else
            std.fmt.allocPrint(std.heap.page_allocator, "[{d}] [{s}] [{s}] {s}\n", .{ timestamp, self.service_name, level.toString(), msg }) catch return;
        defer std.heap.page_allocator.free(formatted);

        if (self.mode == .console or self.mode == .both) {
            const stdout = std.fs.File.stdout();
            _ = stdout.write(formatted) catch return;
        }

        if (self.file_logger) |*fl| {
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
