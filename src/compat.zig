//! Compatibility shim for Zig 0.16.0
//!
//! Provides wrappers around std.Io APIs so that the rest of the codebase
//! can use a synchronous-style API similar to Zig 0.15.2.

const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// Global Io
// ============================================================================

var global_threaded: ?std.Io.Threaded = null;
var global_io_initialized: std.atomic.Value(bool) = .init(false);
var test_io_instance: ?std.Io.Threaded = null;
var test_io_mutex: std.atomic.Mutex = .unlocked;

/// Initialize the global Io backend. Must be called once before any I/O.
/// In production, this creates a std.Io.Threaded instance.
pub fn initIo(gpa: std.mem.Allocator) void {
    global_threaded = std.Io.Threaded.init(gpa, .{});
    global_io_initialized.store(true, .release);
}

/// Clean up the global Io backend.
pub fn deinitIo() void {
    if (global_threaded) |*t| {
        t.deinit();
        global_threaded = null;
    }
    global_io_initialized.store(false, .release);
}

fn ensureTestIo() std.Io {
    if (test_io_mutex.tryLock()) {
        // We hold the lock
        if (test_io_instance == null) {
            test_io_instance = std.Io.Threaded.init(std.testing.allocator, .{});
        }
        test_io_mutex.unlock();
    } else {
        // Another thread is initializing, spin-wait
        while (test_io_instance == null) {
            std.Thread.yield() catch {};
        }
    }
    return test_io_instance.?.io();
}

pub fn io() std.Io {
    if (builtin.is_test) {
        return ensureTestIo();
    }
    if (!global_io_initialized.load(.acquire)) {
        @panic("compat.io() called before initIo()");
    }
    return global_threaded.?.io();
}

/// For test code that needs an Io.
pub fn testIo() std.Io {
    return ensureTestIo();
}

// ============================================================================
// Thread Primitives
// ============================================================================

pub const Mutex = struct {
    inner: std.Io.Mutex,

    pub const init: Mutex = .{ .inner = .init };

    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(io());
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(io());
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.inner.tryLock();
    }
};

pub const RwLock = struct {
    inner: std.Io.RwLock,

    pub const init: RwLock = .{ .inner = .init };

    pub fn lock(self: *RwLock) void {
        self.inner.lock(io()) catch unreachable;
    }

    pub fn unlock(self: *RwLock) void {
        self.inner.unlock(io());
    }

    pub fn lockShared(self: *RwLock) void {
        self.inner.lockShared(io()) catch unreachable;
    }

    pub fn unlockShared(self: *RwLock) void {
        self.inner.unlockShared(io());
    }
};

pub const Condition = struct {
    inner: std.Io.Condition,

    pub const init: Condition = .{ .inner = .init };

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        self.inner.wait(io(), &mutex.inner) catch unreachable;
    }

    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
        const io_handle = io();
        var epoch = self.inner.epoch.load(.acquire);
        {
            const prev_state = self.inner.state.fetchAdd(.{ .waiters = 1, .signals = 0 }, .monotonic);
            std.debug.assert(prev_state.waiters < std.math.maxInt(u16));
        }
        mutex.inner.unlock(io_handle);
        defer mutex.inner.lockUncancelable(io_handle);

        const now = std.Io.Clock.real.now(io_handle);
        const deadline = std.Io.Clock.Timestamp{
            .raw = .{ .nanoseconds = now.nanoseconds + @as(i96, @intCast(timeout_ns)) },
            .clock = .real,
        };
        io_handle.futexWaitTimeout(u32, &self.inner.epoch.raw, epoch, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Canceled => {},
        };

        epoch = self.inner.epoch.load(.acquire);

        // Try to consume a pending signal.
        var prev_state = self.inner.state.load(.monotonic);
        while (prev_state.signals > 0) {
            prev_state = self.inner.state.cmpxchgWeak(prev_state, .{
                .waiters = prev_state.waiters - 1,
                .signals = prev_state.signals - 1,
            }, .acquire, .monotonic) orelse return;
        }

        // No signal available — timeout or spurious wakeup.
        const ps = self.inner.state.fetchSub(.{ .waiters = 1, .signals = 0 }, .monotonic);
        std.debug.assert(ps.waiters > 0);
        return error.Timeout;
    }

    pub fn signal(self: *Condition) void {
        self.inner.signal(io());
    }

    pub fn broadcast(self: *Condition) void {
        self.inner.broadcast(io());
    }
};

/// Simple WaitGroup built on atomic counters (no Io required).
pub const WaitGroup = struct {
    count: std.atomic.Value(usize),

    pub const init: WaitGroup = .{ .count = .init(0) };

    pub fn start(self: *WaitGroup) void {
        _ = self.count.fetchAdd(1, .monotonic);
    }

    pub fn finish(self: *WaitGroup) void {
        _ = self.count.fetchSub(1, .release);
    }

    pub fn wait(self: *WaitGroup) void {
        while (self.count.load(.acquire) != 0) {
            std.Thread.yield() catch {};
        }
    }
};

// ============================================================================
// Time
// ============================================================================

pub fn milliTimestamp() i64 {
    return std.Io.Clock.real.now(io()).toMilliseconds();
}

pub fn nanoTimestamp() i128 {
    return std.Io.Clock.real.now(io()).toNanoseconds();
}

pub fn timestamp() i64 {
    return std.Io.Clock.real.now(io()).toSeconds();
}

// ============================================================================
// Filesystem
// ============================================================================

pub fn stdout() std.Io.File {
    return std.Io.File.stdout();
}

pub fn fileWrite(file: std.Io.File, data: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io(), &buf);
    try writer.interface.writeAll(data);
}

pub fn fileRead(file: std.Io.File, buf: []u8) !usize {
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io(), &read_buf);
    return reader.interface.readSliceShort(buf);
}

pub fn stderr() std.Io.File {
    return std.Io.File.stderr();
}

pub fn cwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}

pub fn deleteTree(path: []const u8) void {
    cwd().deleteTree(io(), path) catch {};
}

pub const ArrayListWriter = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn writeAll(self: ArrayListWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }

    pub fn print(self: ArrayListWriter, comptime fmt_str: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.allocator, fmt_str, args);
        defer self.allocator.free(s);
        try self.list.appendSlice(self.allocator, s);
    }
};

pub fn arrayListWriter(list: *std.ArrayList(u8), allocator: std.mem.Allocator) ArrayListWriter {
    return .{ .list = list, .allocator = allocator };
}

var global_prng: ?std.Random.DefaultPrng = null;
var global_prng_mutex: std.atomic.Mutex = .unlocked;

pub fn randomInt(comptime T: type) T {
    if (global_prng_mutex.tryLock()) {
        if (global_prng == null) {
            global_prng = std.Random.DefaultPrng.init(@intCast(std.Io.Clock.real.now(io()).toSeconds()));
        }
        const result = global_prng.?.random().int(T);
        global_prng_mutex.unlock();
        return result;
    }
    while (true) {
        std.Thread.yield() catch {};
        if (global_prng_mutex.tryLock()) {
            const result = global_prng.?.random().int(T);
            global_prng_mutex.unlock();
            return result;
        }
    }
}

pub fn randomBytes(buf: []u8) void {
    if (global_prng_mutex.tryLock()) {
        if (global_prng == null) {
            global_prng = std.Random.DefaultPrng.init(@intCast(std.Io.Clock.real.now(io()).toSeconds()));
        }
        global_prng.?.random().bytes(buf);
        global_prng_mutex.unlock();
        return;
    }
    while (true) {
        std.Thread.yield() catch {};
        if (global_prng_mutex.tryLock()) {
            global_prng.?.random().bytes(buf);
            global_prng_mutex.unlock();
            return;
        }
    }
}

pub fn sleep(ns: u64) void {
    std.Io.sleep(io(), .{ .nanoseconds = ns }, .real) catch unreachable;
}

pub fn trimStart(comptime T: type, slice: []const T, values_to_strip: []const T) []const T {
    return std.mem.trimStart(T, slice, values_to_strip);
}

pub fn trimEnd(comptime T: type, slice: []const T, values_to_strip: []const T) []const T {
    return std.mem.trimEnd(T, slice, values_to_strip);
}

pub const Semaphore = struct {
    count: std.atomic.Value(u32),

    pub fn initWithPermits(permits: u32) Semaphore {
        return .{ .count = .init(permits) };
    }

    pub fn wait(self: *Semaphore) void {
        while (true) {
            const current = self.count.load(.acquire);
            if (current > 0) {
                if (self.count.cmpxchgWeak(current, current - 1, .acquire, .monotonic) == null) {
                    return;
                }
                continue;
            }
            std.Thread.yield() catch {};
        }
    }

    pub fn post(self: *Semaphore) void {
        _ = self.count.fetchAdd(1, .release);
    }
};

// ============================================================================
// Networking
// ============================================================================

pub const net = struct {
    pub const Stream = std.Io.net.Stream;
    pub const Server = std.Io.net.Server;
    pub const IpAddress = std.Io.net.IpAddress;
    pub const Ip4Address = std.Io.net.Ip4Address;

    pub fn tcpConnectToAddress(addr: IpAddress) !Stream {
        return std.Io.net.IpAddress.connect(&addr, io(), .{ .mode = .stream });
    }

    pub fn listen(address: *const IpAddress, options: std.Io.net.IpAddress.ListenOptions) !Server {
        return std.Io.net.IpAddress.listen(address, io(), options);
    }

    pub fn streamClose(s: Stream) void {
        s.close(io());
    }

    pub fn streamWrite(stream: Stream, data: []const u8) !void {
        var buf: [4096]u8 = undefined;
        var writer = stream.writer(io(), &buf);
        try writer.interface.writeAll(data);
    }

    pub fn streamRead(stream: Stream, buf: []u8) !usize {
        var read_buf: [4096]u8 = undefined;
        var reader = stream.reader(io(), &read_buf);
        return reader.interface.readSliceShort(buf);
    }

    pub fn streamReadAll(stream: Stream, buf: []u8) !usize {
        var read_buf: [4096]u8 = undefined;
        var reader = stream.reader(io(), &read_buf);
        var total: usize = 0;
        while (total < buf.len) {
            const n = try reader.interface.readSliceShort(buf[total..]);
            if (n == 0) break;
            total += n;
        }
        return total;
    }
};

// ============================================================================
// Collections helpers
// ============================================================================

pub fn arrayListEmpty(comptime T: type) std.ArrayList(T) {
    return .empty;
}

pub fn hashMapUnmanagedEmpty(comptime K: type, comptime V: type) std.HashMapUnmanaged(K, V, std.hash_map.defaultContext(K), 80) {
    return .empty;
}

// ============================================================================
// Process helpers
// ============================================================================

pub fn argsIterator(init: std.process.Init.Minimal) std.process.Args.Iterator {
    return std.process.Args.Iterator.init(init.args);
}

// ============================================================================
// Filesystem helpers
// ============================================================================

pub fn makePath(path: []const u8) !void {
    return std.Io.Dir.cwd().createDirPath(io(), path);
}

pub fn deleteFile(path: []const u8) !void {
    return std.Io.Dir.cwd().deleteFile(io(), path);
}
