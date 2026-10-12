//! Health check for zigzero
//!
//! Provides health check endpoints and probes.
//!
//! The built-in `checks.memory` and `checks.disk` measure this machine instead
//! of assuming health: RSS is compared against `MemoryOptions.limit_bytes` and
//! free space on `DiskOptions.path` against `DiskOptions.min_free_bytes`. Both
//! take an injectable probe, and when nothing can be measured they report
//! `.degraded` with the reason rather than a fabricated `.healthy`.

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("../compat.zig");

/// Health status
pub const Status = enum {
    healthy,
    unhealthy,
    degraded,
};

/// Health check result
pub const Result = struct {
    name: []const u8,
    status: Status,
    message: ?[]const u8,
    timestamp: i64,

    pub fn init(name: []const u8, status: Status) Result {
        return .{
            .name = name,
            .status = status,
            .message = null,
            .timestamp = compat.milliTimestamp(),
        };
    }

    pub fn withMessage(self: Result, msg: []const u8) Result {
        return .{
            .name = self.name,
            .status = self.status,
            .message = msg,
            .timestamp = self.timestamp,
        };
    }
};

/// Health checker function type
pub const CheckerFn = *const fn (std.mem.Allocator) anyerror!Result;

/// Health registry
pub const Registry = struct {
    allocator: std.mem.Allocator,
    checks: std.StringHashMap(CheckerFn),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .checks = std.StringHashMap(CheckerFn).init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        self.checks.deinit();
    }

    /// Register a health check
    pub fn register(self: *Registry, name: []const u8, checker: CheckerFn) !void {
        try self.checks.put(name, checker);
    }

    /// Run all health checks
    pub fn checkAll(self: *Registry) !std.StringHashMap(Result) {
        var results = std.StringHashMap(Result).init(self.allocator);
        errdefer results.deinit();

        var iter = self.checks.iterator();
        while (iter.next()) |entry| {
            const result = entry.value_ptr.*(self.allocator) catch |err| blk: {
                break :blk Result{
                    .name = entry.key_ptr.*,
                    .status = .unhealthy,
                    .message = @errorName(err),
                    .timestamp = compat.milliTimestamp(),
                };
            };
            try results.put(entry.key_ptr.*, result);
        }

        return results;
    }

    /// Get overall health status
    pub fn overall(self: *Registry) !Status {
        var results = try self.checkAll();
        defer results.deinit();

        var has_unhealthy = false;
        var iter = results.iterator();
        while (iter.next()) |entry| {
            switch (entry.value_ptr.status) {
                .unhealthy => has_unhealthy = true,
                .degraded => {},
                .healthy => {},
            }
        }

        if (has_unhealthy) return .unhealthy;
        return .healthy;
    }
};

/// Probe that reports the process' current resident memory in bytes.
pub const MemoryProbeFn = *const fn () anyerror!u64;

/// Probe that reports the bytes available to unprivileged writers on `path`.
pub const DiskProbeFn = *const fn (path: []const u8) anyerror!u64;

/// Longest disk path a caller may configure (the built-in `statvfs` probe
/// needs it NUL-terminated, and the configuration is kept in a static buffer).
pub const max_path_len = 1024;

/// Configuration of the built-in checks. `CheckerFn` only receives an
/// allocator, so the limit/path/probe live here: set once at startup via
/// `checks.configureMemory` / `checks.configureDisk`, before the health
/// endpoint serves traffic. Guarded by `config_mutex` because requests read it.
var config_mutex: std.atomic.Mutex = .unlocked;

var memory_limit_bytes: u64 = 0;
var memory_probe_fn: MemoryProbeFn = defaultMemoryProbe;

var disk_min_free_bytes: u64 = 0;
var disk_probe_fn: DiskProbeFn = defaultDiskProbe;
var disk_path_buf: [max_path_len]u8 = blk: {
    var buf: [max_path_len]u8 = @splat(0);
    buf[0] = '/';
    break :blk buf;
};
var disk_path_len: usize = 1;

/// `Result.message` points into one of these: `Registry.checkAll` hands
/// Results back in a hash map that is released with a plain `deinit()`, so a
/// checker cannot return heap memory without leaking it. A message stays
/// valid until the same check runs again.
var memory_message_buf: [160]u8 = undefined;
var disk_message_buf: [160]u8 = undefined;

fn lockConfig() void {
    while (!config_mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
}

fn formatMessage(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch "check message truncated";
}

/// A probe that could not measure leaves the check non-healthy with the
/// reason, rather than reporting a healthy service nobody verified.
fn unmeasuredResult(name: []const u8, buf: []u8, err: anyerror) Result {
    return Result.init(name, .degraded).withMessage(formatMessage(buf, "unmeasured: {s}", .{@errorName(err)}));
}

/// RSS of this process.
///
/// Linux: second field (resident pages) of `/proc/self/statm` times the page
/// size. macOS: `task_info(MACH_TASK_BASIC_INFO)`, which reports the current
/// resident size; failure is reported as an error rather than silently
/// swapping in a different metric. Other platforms cannot be measured.
fn defaultMemoryProbe() anyerror!u64 {
    return switch (builtin.os.tag) {
        .linux => readLinuxRssBytes(),
        .macos => if (builtin.link_libc) readMacosRssBytes() else error.Unsupported,
        else => error.Unsupported,
    };
}

fn readLinuxRssBytes() anyerror!u64 {
    // Page size comes from libc; without it the resident-page count cannot be
    // converted to bytes, so say so instead of guessing.
    if (!builtin.link_libc) return error.Unsupported;

    var buf: [256]u8 = undefined;
    const data = compat.cwd().readFile(compat.io(), "/proc/self/statm", &buf) catch return error.MeasurementFailed;

    var fields = std.mem.tokenizeAny(u8, data, " \t\n");
    _ = fields.next() orelse return error.MeasurementFailed; // total program size
    const resident_pages = std.fmt.parseInt(u64, fields.next() orelse return error.MeasurementFailed, 10) catch
        return error.MeasurementFailed;

    const page_size = std.c.sysconf(@backingInt(std.c._SC.PAGESIZE));
    if (page_size <= 0) return error.MeasurementFailed;
    return resident_pages * @as(u64, @intCast(page_size));
}

fn readMacosRssBytes() anyerror!u64 {
    var info: std.c.mach_task_basic_info = undefined;
    var count: std.c.mach_msg_type_number_t = std.c.MACH.TASK.BASIC.INFO_COUNT;
    const kern_return = std.c.task_info(
        std.c.mach_task_self(),
        std.c.MACH.TASK.BASIC.INFO,
        @ptrCast(&info),
        &count,
    );
    if (kern_return != 0) return error.MeasurementFailed; // KERN_SUCCESS
    return info.resident_size;
}

/// Bytes free on the filesystem holding `path`.
///
/// Linux and macOS via `statvfs(3)`. The fields read (`f_bsize`, `f_frsize`,
/// `f_bavail`) sit at the same offsets on every LP64 libc, but the struct's
/// total size differs between glibc/musl/Darwin, so it is declared as a buffer
/// large enough for all of them — `statvfs` must never write past it.
fn defaultDiskProbe(path: []const u8) anyerror!u64 {
    return switch (builtin.os.tag) {
        .linux, .macos => if (builtin.link_libc) statvfsFreeBytes(path) else error.Unsupported,
        else => error.Unsupported,
    };
}

/// The field offsets declared below are the LP64 ones; a 32-bit libc lays
/// `statvfs` out differently, so such targets report the check as unmeasured
/// instead of reading the wrong offsets.
const SupportsStatvfs = (builtin.os.tag == .linux or builtin.os.tag == .macos) and @sizeOf(usize) == 8;

/// Size of `StatvfsBuf`: bigger than every libc's `struct statvfs` (64 bytes on
/// Darwin, 120 on glibc, 136 on musl).
const statvfs_body_size = 256;

const StatvfsBuf = if (builtin.os.tag == .macos)
    extern struct {
        f_bsize: c_ulong,
        f_frsize: c_ulong,
        f_blocks: c_uint, // fsblkcnt_t is 32-bit on Darwin
        f_bfree: c_uint,
        f_bavail: c_uint,
        _tail: [statvfs_body_size - 28]u8,
    }
else
    extern struct {
        f_bsize: c_ulong,
        f_frsize: c_ulong,
        f_blocks: c_ulong,
        f_bfree: c_ulong,
        f_bavail: c_ulong,
        _tail: [statvfs_body_size - 40]u8,
    };

extern "c" fn statvfs(path: [*:0]const u8, buf: *StatvfsBuf) c_int;

fn statvfsFreeBytes(path: []const u8) anyerror!u64 {
    if (!SupportsStatvfs) return error.Unsupported;
    if (path.len > max_path_len) return error.NameTooLong;
    // Only meaningful where the LP64 layout above applies (see SupportsStatvfs).
    if (SupportsStatvfs and @sizeOf(StatvfsBuf) != statvfs_body_size)
        @compileError("StatvfsBuf must stay 256 bytes");

    var path_buf: [max_path_len + 1]u8 = undefined;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    var st: StatvfsBuf = std.mem.zeroes(StatvfsBuf);
    if (statvfs(path_buf[0..path.len :0], &st) != 0) return error.MeasurementFailed;

    const block_size = if (st.f_frsize != 0) st.f_frsize else st.f_bsize;
    if (block_size == 0) return error.MeasurementFailed;
    const bytes = @as(u128, st.f_bavail) * @as(u128, block_size);
    return @intCast(@min(bytes, std.math.maxInt(u64)));
}

/// Common health checks
pub const checks = struct {
    /// Options for the built-in memory check.
    pub const MemoryOptions = struct {
        /// Report `.unhealthy` when measured RSS exceeds this. 0 means "no
        /// limit configured": the check still measures and reports, but cannot
        /// fail on the limit.
        limit_bytes: u64 = 0,
        /// Measured RSS source. Defaults to the platform probe.
        probe: MemoryProbeFn = defaultMemoryProbe,
    };

    /// Options for the built-in disk check.
    pub const DiskOptions = struct {
        /// Filesystem to measure. Copied into a static buffer, so it need not
        /// outlive this call (at most `max_path_len` bytes).
        path: []const u8 = "/",
        /// Report `.unhealthy` when free space drops below this. 0 means "no
        /// minimum configured".
        min_free_bytes: u64 = 0,
        /// Free-space source. Defaults to the platform `statvfs` probe.
        probe: DiskProbeFn = defaultDiskProbe,
    };

    /// Configure the memory check. Call once at startup.
    pub fn configureMemory(opts: MemoryOptions) void {
        lockConfig();
        defer config_mutex.unlock();
        memory_limit_bytes = opts.limit_bytes;
        memory_probe_fn = opts.probe;
    }

    /// Configure the disk check. Call once at startup.
    ///
    /// Fails with `error.PathTooLong` when `opts.path` exceeds `max_path_len`,
    /// since the configuration is held in a fixed static buffer.
    pub fn configureDisk(opts: DiskOptions) !void {
        if (opts.path.len > max_path_len) return error.PathTooLong;
        lockConfig();
        defer config_mutex.unlock();
        @memcpy(disk_path_buf[0..opts.path.len], opts.path);
        disk_path_len = opts.path.len;
        disk_min_free_bytes = opts.min_free_bytes;
        disk_probe_fn = opts.probe;
    }

    /// Compare the process' resident memory against the configured limit.
    ///
    /// The allocator parameter belongs to `CheckerFn`; messages go into a
    /// static buffer (see `memory_message_buf`) so results stay freeable with
    /// a plain `deinit()`.
    pub fn memory(allocator: std.mem.Allocator) !Result {
        _ = allocator;
        lockConfig();
        const limit = memory_limit_bytes;
        const probe = memory_probe_fn;
        config_mutex.unlock();

        const usage = probe() catch |err| return unmeasuredResult("memory", &memory_message_buf, err);
        if (limit == 0) {
            return Result.init("memory", .healthy).withMessage(
                formatMessage(&memory_message_buf, "rss={d} bytes (no limit configured)", .{usage}),
            );
        }
        if (usage > limit) {
            return Result.init("memory", .unhealthy).withMessage(
                formatMessage(&memory_message_buf, "rss={d} bytes exceeds limit {d} bytes", .{ usage, limit }),
            );
        }
        return Result.init("memory", .healthy).withMessage(
            formatMessage(&memory_message_buf, "rss={d} bytes within limit {d} bytes", .{ usage, limit }),
        );
    }

    /// Compare free space on the configured filesystem against the configured
    /// minimum.
    pub fn disk(allocator: std.mem.Allocator) !Result {
        _ = allocator;
        lockConfig();
        var path: [max_path_len]u8 = undefined;
        const len = disk_path_len;
        @memcpy(path[0..len], disk_path_buf[0..len]);
        const min_free = disk_min_free_bytes;
        const probe = disk_probe_fn;
        config_mutex.unlock();

        const free = probe(path[0..len]) catch |err| return unmeasuredResult("disk", &disk_message_buf, err);
        if (min_free == 0) {
            return Result.init("disk", .healthy).withMessage(
                formatMessage(&disk_message_buf, "free={d} bytes (no minimum configured)", .{free}),
            );
        }
        if (free < min_free) {
            return Result.init("disk", .unhealthy).withMessage(
                formatMessage(&disk_message_buf, "free={d} bytes below minimum {d} bytes", .{ free, min_free }),
            );
        }
        return Result.init("disk", .healthy).withMessage(
            formatMessage(&disk_message_buf, "free={d} bytes at or above minimum {d} bytes", .{ free, min_free }),
        );
    }
};

test "health registry" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register("memory", checks.memory);
    try registry.register("disk", checks.disk);

    const status = try registry.overall();
    try std.testing.expectEqual(Status.healthy, status);
}

test "health check result with message" {
    var r = Result.init("test", .degraded);
    r = r.withMessage("high latency");
    try std.testing.expectEqualStrings("test", r.name);
    try std.testing.expectEqual(Status.degraded, r.status);
    try std.testing.expectEqualStrings("high latency", r.message.?);
    try std.testing.expect(r.timestamp > 0);
}

test "health registry catches checker errors" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const failingChecker = struct {
        fn check(allocator: std.mem.Allocator) !Result {
            _ = allocator;
            return error.SimulatedFailure;
        }
    }.check;

    try registry.register("failing", failingChecker);
    const status = try registry.overall();
    try std.testing.expectEqual(Status.unhealthy, status);
}

test "health registry empty is healthy" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const status = try registry.overall();
    try std.testing.expectEqual(Status.healthy, status);
}

/// Restore the built-in checks to their default configuration.
fn resetChecks() void {
    checks.configureMemory(.{});
    checks.configureDisk(.{}) catch unreachable;
}

test "memory check reports the over-limit path" {
    const within_limit = struct {
        fn probe() anyerror!u64 {
            return 1024;
        }
    }.probe;
    const over_limit = struct {
        fn probe() anyerror!u64 {
            return 8192;
        }
    }.probe;

    defer resetChecks();

    checks.configureMemory(.{ .limit_bytes = 4096, .probe = within_limit });
    var result = try checks.memory(std.testing.allocator);
    try std.testing.expectEqual(Status.healthy, result.status);
    try std.testing.expect(result.message != null);

    checks.configureMemory(.{ .limit_bytes = 4096, .probe = over_limit });
    result = try checks.memory(std.testing.allocator);
    try std.testing.expectEqual(Status.unhealthy, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.message.?, "8192") != null);
}

test "memory check reports unmeasured rather than healthy when the probe fails" {
    const failing = struct {
        fn probe() anyerror!u64 {
            return error.NoMeasurementAvailable;
        }
    }.probe;

    defer resetChecks();
    // A limit the process is certainly over: even then the check must not
    // claim health, because nothing was measured.
    checks.configureMemory(.{ .limit_bytes = 1, .probe = failing });

    const result = try checks.memory(std.testing.allocator);
    try std.testing.expectEqual(Status.degraded, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.message.?, "unmeasured") != null);
}

test "disk check reports the below-minimum path" {
    const plenty = struct {
        fn probe(path: []const u8) anyerror!u64 {
            _ = path;
            return 1 << 40;
        }
    }.probe;
    const scarce = struct {
        fn probe(path: []const u8) anyerror!u64 {
            _ = path;
            return 512;
        }
    }.probe;

    defer resetChecks();

    try checks.configureDisk(.{ .path = "/tmp", .min_free_bytes = 1024, .probe = plenty });
    var result = try checks.disk(std.testing.allocator);
    try std.testing.expectEqual(Status.healthy, result.status);
    try std.testing.expect(result.message != null);

    try checks.configureDisk(.{ .path = "/tmp", .min_free_bytes = 1024, .probe = scarce });
    result = try checks.disk(std.testing.allocator);
    try std.testing.expectEqual(Status.unhealthy, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.message.?, "512") != null);
}

const overlong_path: [max_path_len + 1]u8 = blk: {
    const buf: [max_path_len + 1]u8 = @splat('x');
    break :blk buf;
};

test "disk check rejects a path longer than it can store" {
    defer resetChecks();
    try std.testing.expectError(error.PathTooLong, checks.configureDisk(.{ .path = &overlong_path }));
}

test "disk check reports unmeasured for a path that does not exist" {
    defer resetChecks();
    try checks.configureDisk(.{ .path = "/zigzero/definitely/not/here" });

    const result = try checks.disk(std.testing.allocator);
    // Either the platform cannot measure or statvfs failed — both must be
    // reported as unknown, never as healthy.
    try std.testing.expectEqual(Status.degraded, result.status);
}

test "default probes measure this machine, or say that they cannot" {
    defer resetChecks();

    switch (builtin.os.tag) {
        .linux, .macos => {
            const rss = try defaultMemoryProbe();
            try std.testing.expect(rss > 0);
            try std.testing.expect(rss < 1 << 40);

            const free = try defaultDiskProbe("/");
            try std.testing.expect(free > 0);
        },
        else => {
            try std.testing.expectError(error.Unsupported, defaultMemoryProbe());
            try std.testing.expectError(error.Unsupported, defaultDiskProbe("/"));
        },
    }
}

test "registry reports real measurements per check" {
    defer resetChecks();

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register("memory", checks.memory);
    try registry.register("disk", checks.disk);

    var results = try registry.checkAll();
    defer results.deinit();

    const measurable = builtin.os.tag == .linux or builtin.os.tag == .macos;
    const expected: Status = if (measurable) .healthy else .degraded;
    try std.testing.expectEqual(expected, results.get("memory").?.status);
    try std.testing.expectEqual(expected, results.get("disk").?.status);
    try std.testing.expect(results.get("memory").?.message != null);
    try std.testing.expect(results.get("disk").?.message != null);
}
