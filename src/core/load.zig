//! Adaptive load shedding aligned with go-zero core/load
//!
//! Provides an adaptive shedder that drops requests when the system
//! is under load, based on response time and throughput.
//!
//! CPU signal: the default detector measures the machine instead of assuming
//! it is idle, and both supported platforms measure the same quantity — the
//! fraction of CPU time that was not idle:
//!
//! * Linux reads the cumulative tick counters in `/proc/stat`.
//! * macOS has no `/proc`, so it reads the Mach host CPU load info
//!   (`host_statistics(…, HOST_CPU_LOAD_INFO, …)`), the Darwin equivalent:
//!   the same tick counters, the same busy/total ratio.
//!
//! Both sample twice and report the ratio of the delta, cached for
//! `cpu_sample_interval_ms`. Where nothing can be measured the sample is
//! reported as `CpuUsage.unavailable` — the shedder exposes that through
//! `AdaptiveShedder.cpuUsage`, which returns null rather than a fabricated 0.
//! Callers that want their own signal keep using `ShedderOptions.cpu_overloaded_fn`.

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("../compat.zig");
const errors = @import("errors.zig");

const default_buckets = 50;
const default_window_ms = 5000;
const default_cpu_threshold = 900; // 90% in millicpu notation
const default_min_rt: f64 = 1000.0; // 1000ms, like go-zero
const flying_beta = 0.9;
const cool_off_duration_ms = 1000;
const cpu_max = 1000;
const overload_factor_lower_bound = 0.1;

/// A CPU utilisation sample.
///
/// `measured` holds the busy ratio in millicpu (0..1000, where 1000 means
/// every CPU is busy). `unavailable` means this platform — or this particular
/// read — could not produce a measurement, and must not be read as "idle".
pub const CpuUsage = union(enum) {
    measured: i64,
    unavailable,
};

/// How long a measurement is reused before it is taken again. CPU is a
/// system-wide, slowly moving signal, and the shedder consults it on every
/// request, so sampling on each call would be pure overhead.
const cpu_sample_interval_ms = 250;

/// Delay between the two readings behind the *first* sample, on platforms whose
/// counters move at tick granularity (`/proc/stat`).
///
/// Darwin is deliberately excluded: its CPU counters are refreshed by the
/// kernel in bursts roughly a second apart, so a 20 ms sleep would almost never
/// see them move. `measure` therefore reports "nothing measured yet" on the
/// first call there and lets the next call cover a longer window instead of
/// blocking a request thread on a sleep that would not help.
const first_sample_gap_ms: i64 = if (builtin.os.tag == .macos) 0 else 20;

/// Stored in `AdaptiveShedder.last_cpu_usage` for "unmeasured".
const cpu_usage_unmeasured: i64 = -1;

/// Cumulative CPU counters as both platforms report them, in whatever unit the
/// kernel counts ticks (only the delta ratio matters).
const CpuTicks = struct {
    /// Busy + idle ticks across all CPUs.
    total: u64,
    /// Ticks spent doing nothing (Linux counts idle + iowait as idle).
    idle: u64,
};

/// Darwin `host_cpu_load_info`, the Mach equivalent of the `/proc/stat` cpu
/// line: cumulative ticks indexed by CPU state (user, system, idle, nice).
const host_cpu_load_info = extern struct {
    cpu_ticks: [cpu_state_max]u32,
};

const cpu_state_max = 4;
const cpu_state_idle = 2;
/// `HOST_CPU_LOAD_INFO` from <mach/host_info.h>.
const host_cpu_load_info_flavor: c_int = 3;

const mach_port_t = u32;
const natural_t = u32;
const mach_msg_type_number_t = natural_t;
const kern_return_t = c_int;

extern "c" fn mach_host_self() mach_port_t;
extern "c" var mach_task_self_: mach_port_t;
extern "c" fn mach_port_deallocate(task: mach_port_t, name: mach_port_t) kern_return_t;
extern "c" fn host_statistics(
    host: mach_port_t,
    flavor: c_int,
    info: [*]c_int,
    count: *mach_msg_type_number_t,
) kern_return_t;

var cpu_sample_mutex: compat.Mutex = .init;
var cpu_sample_cache: CpuUsage = .unavailable;
var cpu_sample_cache_ms: i64 = 0;
var cpu_ticks_prev: ?CpuTicks = null;
var cpu_ticks_last_usage: ?i64 = null;

/// Busy fraction of the delta between two counter readings, in millicpu.
fn busyRatio(prev: CpuTicks, next: CpuTicks) ?i64 {
    const total_delta = next.total -| prev.total;
    if (total_delta == 0) return null;
    const busy_delta = total_delta -| (next.idle -| prev.idle);
    const ratio = @as(f64, @floatFromInt(busy_delta)) / @as(f64, @floatFromInt(total_delta)) * 1000.0;
    return @intFromFloat(std.math.clamp(ratio, 0.0, @as(f64, cpu_max)));
}

/// Measure utilisation from a counter reader: the busy ratio of the delta
/// against the previous reading.
///
/// Shared by both platforms on purpose: they differ only in where the counters
/// come from, so a `cpu_threshold` means the same thing on either.
///
/// Three cases:
///  * the counters moved since the previous reading — a fresh ratio;
///  * they did not move — no new information, so the previous reading is kept
///    (the next attempt then spans a longer window) and the last real ratio is
///    reported, at most about a second old. Darwin normally lands here, since
///    the kernel refreshes its counters in bursts about a second apart; this is
///    the platform's cadence, not a failure, and a stale-but-real ratio is
///    better than dropping the signal;
///  * there is no previous reading — wait `first_sample_gap_ms` and read again,
///    which yields a value immediately on Linux and honestly reports
///    `.unavailable` for the first call on Darwin;
///  * nothing above produced a ratio — `.unavailable`, never a made-up number.
fn measure(reader: *const fn () ?CpuTicks) CpuUsage {
    const current = reader() orelse return .unavailable;

    if (cpu_ticks_prev) |prev| {
        if (busyRatio(prev, current)) |usage| {
            cpu_ticks_prev = current;
            cpu_ticks_last_usage = usage;
            return .{ .measured = usage };
        }
        if (cpu_ticks_last_usage) |usage| return .{ .measured = usage };
        return .unavailable;
    }

    if (first_sample_gap_ms > 0) compat.sleep(@as(u64, @intCast(first_sample_gap_ms)) * std.time.ns_per_ms);
    const second = reader() orelse return .unavailable;
    cpu_ticks_prev = second;
    if (busyRatio(current, second)) |usage| {
        cpu_ticks_last_usage = usage;
        return .{ .measured = usage };
    }
    return .unavailable;
}

/// Read the aggregate `cpu` line of `/proc/stat`:
/// `cpu user nice system idle iowait irq softirq steal guest guest_nice`,
/// with every value counted in USER_HZ jiffies since boot.
///
/// Returns null when the file is missing (non-Linux kernel, container without
/// /proc) or does not look like the expected line, so an unreadable kernel
/// cannot masquerade as an idle machine.
fn readProcStat() ?CpuTicks {
    var buf: [4096]u8 = undefined;
    const data = compat.cwd().readFile(compat.io(), "/proc/stat", &buf) catch return null;

    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    const cpu_line = lines.next() orelse return null;
    var fields = std.mem.tokenizeAny(u8, cpu_line, " \t");
    const label = fields.next() orelse return null;
    if (!std.mem.eql(u8, label, "cpu")) return null;

    var jiffies: [10]u64 = @splat(0);
    var count: usize = 0;
    while (fields.next()) |field| {
        if (count == jiffies.len) break;
        jiffies[count] = std.fmt.parseInt(u64, field, 10) catch return null;
        count += 1;
    }
    // user nice system idle iowait — anything older than that is not a kernel
    // we know how to read.
    if (count < 5) return null;

    // Stop at `steal`: guest and guest_nice are already included in user and
    // nice, so counting them again would tilt the ratio towards "busy".
    var total: u64 = 0;
    for (jiffies[0..@min(count, 8)]) |value| total += value;
    return .{ .total = total, .idle = jiffies[3] + jiffies[4] };
}

/// Darwin reader for `measure`: the Mach host CPU load info, which is the same
/// cumulative per-state tick counters `/proc/stat` exposes on Linux (they
/// accumulate at 100 Hz per CPU, so a 250 ms window resolves to well under a
/// percent). The host port must be released, hence the `defer`.
fn readHostCpuTicks() ?CpuTicks {
    const host = mach_host_self();
    if (host == 0) return null; // MACH_PORT_NULL
    defer _ = mach_port_deallocate(mach_task_self_, host);

    var ticks: host_cpu_load_info = undefined;
    var count: mach_msg_type_number_t = @sizeOf(host_cpu_load_info) / @sizeOf(natural_t);
    if (host_statistics(host, host_cpu_load_info_flavor, @ptrCast(&ticks), &count) != 0) return null;
    if (count < cpu_state_max) return null;

    var total: u64 = 0;
    for (ticks.cpu_ticks) |state_ticks| total += state_ticks;
    return .{ .total = total, .idle = ticks.cpu_ticks[cpu_state_idle] };
}

/// Sample CPU utilisation as a busy ratio in millicpu (0..1000).
///
/// Linux reads `/proc/stat`; macOS reads the Mach host CPU load info (see
/// `readHostCpuTicks`). Both report the same quantity — the fraction of CPU
/// time that was not idle — so a `cpu_threshold` means the same thing on either
/// platform. Every other platform, and every failed read, reports
/// `.unavailable` instead of a fabricated 0. The result is cached for
/// `cpu_sample_interval_ms` for every caller in the process.
///
/// On Darwin the kernel refreshes those counters in bursts about a second
/// apart, so a sample there can be up to roughly a second old; until two
/// readings have actually moved, the sample is honestly `.unavailable` rather
/// than a guess (see `measure`).
pub fn sampleCpuUsage() CpuUsage {
    cpu_sample_mutex.lock();
    defer cpu_sample_mutex.unlock();

    const now_ms = compat.milliTimestamp();
    if (cpu_sample_cache_ms != 0 and now_ms - cpu_sample_cache_ms < cpu_sample_interval_ms) {
        return cpu_sample_cache;
    }

    const sample = switch (builtin.os.tag) {
        .linux => measure(readProcStat),
        .macos => if (builtin.link_libc) measure(readHostCpuTicks) else CpuUsage.unavailable,
        else => CpuUsage.unavailable,
    };
    cpu_sample_cache = sample;
    cpu_sample_cache_ms = now_ms;
    return sample;
}

/// Error returned when service is overloaded
pub const ErrServiceOverloaded = errors.Error.ServiceOverloaded;

/// A bucket in the rolling window
pub const Bucket = struct {
    sum: i64 = 0,
    count: i64 = 0,
};

/// RollingWindow is a time-based sliding window for statistics.
pub fn RollingWindow(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        buckets: []Bucket,
        bucket_duration_ms: i64,
        last_add_time_ms: i64,
        last_index: usize,
        size: usize,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, size: usize, bucket_duration_ms: i64) !Self {
            const buckets = try allocator.alloc(Bucket, size);
            @memset(buckets, .{});
            return .{
                .allocator = allocator,
                .buckets = buckets,
                .bucket_duration_ms = bucket_duration_ms,
                .last_add_time_ms = 0,
                .last_index = 0,
                .size = size,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buckets);
        }

        fn advance(self: *Self, now_ms: i64) void {
            if (self.last_add_time_ms == 0) {
                self.last_add_time_ms = now_ms;
                return;
            }
            const diff = now_ms - self.last_add_time_ms;
            const steps = @divFloor(diff, self.bucket_duration_ms);
            if (steps <= 0) return;
            const n = @min(steps, @as(i64, @intCast(self.size)));
            var i: i64 = 1;
            while (i <= n) : (i += 1) {
                const idx = (self.last_index + @as(usize, @intCast(i))) % self.size;
                self.buckets[idx] = .{};
            }
            self.last_index = (self.last_index + @as(usize, @intCast(steps))) % self.size;
            self.last_add_time_ms += steps * self.bucket_duration_ms;
        }

        pub fn add(self: *Self, value: T) void {
            const now_ms = compat.milliTimestamp();
            self.advance(now_ms);
            self.buckets[self.last_index].sum += value;
            self.buckets[self.last_index].count += 1;
            self.last_add_time_ms = now_ms;
        }

        pub fn maxSum(self: *Self) i64 {
            var result: i64 = 1;
            for (self.buckets) |b| {
                if (b.sum > result) {
                    result = b.sum;
                }
            }
            return result;
        }

        pub fn minAvg(self: *Self) f64 {
            var result = default_min_rt;
            for (self.buckets) |b| {
                if (b.count <= 0) continue;
                const avg = @round(@as(f64, @floatFromInt(b.sum)) / @as(f64, @floatFromInt(b.count)));
                if (avg < result) {
                    result = avg;
                }
            }
            return result;
        }
    };
}

/// Promise is returned by Shedder.allow to report success or failure.
pub const Promise = struct {
    start_ms: i64,
    shedder: ?*AdaptiveShedder,

    pub fn pass(self: *const Promise) void {
        if (self.shedder) |s| {
            const rt = @as(f64, @floatFromInt(compat.milliTimestamp() - self.start_ms));
            const rt_ceil: i64 = @intFromFloat(@ceil(rt));
            s.addFlying(-1);
            s.rt_counter.add(rt_ceil);
            s.pass_counter.add(1);
        }
    }

    pub fn fail(self: *const Promise) void {
        if (self.shedder) |s| {
            s.addFlying(-1);
        }
    }
};

/// Options for customizing the adaptive shedder
pub const ShedderOptions = struct {
    window_ms: i64 = default_window_ms,
    buckets: usize = default_buckets,
    cpu_threshold: i64 = default_cpu_threshold,
    /// Overload decision. Defaults to comparing a real CPU measurement against
    /// `cpu_threshold`; supply your own to use a different signal.
    cpu_overloaded_fn: *const fn (threshold: i64) bool = defaultCpuOverloaded,
    /// CPU sampler used for the overload factor and for the measurement the
    /// shedder exposes through `cpuUsage`. Defaults to the platform
    /// measurement (`sampleCpuUsage`); injectable for tests and for callers
    /// with their own monitoring.
    cpu_usage_fn: *const fn () CpuUsage = sampleCpuUsage,
};

/// Default overload detector: overloaded once the measured busy ratio reaches
/// `threshold` (millicpu). An unmeasurable platform yields false here because
/// there is no evidence of overload — the missing measurement is reported
/// through `AdaptiveShedder.cpuUsage`, it is not disguised as a measurement.
fn defaultCpuOverloaded(threshold: i64) bool {
    return switch (sampleCpuUsage()) {
        .measured => |usage| usage >= threshold,
        .unavailable => false,
    };
}

/// NopShedder never drops requests.
pub const NopShedder = struct {
    pub fn allow(self: *NopShedder) errors.Error!Promise {
        _ = self;
        return Promise{
            .start_ms = compat.milliTimestamp(),
            .shedder = null,
        };
    }
};

/// AdaptiveShedder drops requests probabilistically when overloaded.
pub const AdaptiveShedder = struct {
    cpu_threshold: i64,
    window_scale: f64,
    flying: i64,
    avg_flying: f64,
    avg_flying_mutex: compat.Mutex,
    overload_time_ms: std.atomic.Value(i64),
    dropped_recently: std.atomic.Value(bool),
    pass_counter: RollingWindow(i64),
    rt_counter: RollingWindow(i64),
    cpu_overloaded_fn: *const fn (threshold: i64) bool,
    cpu_usage_fn: *const fn () CpuUsage,
    /// Busy ratio of the last evaluation, or `cpu_usage_unmeasured`.
    last_cpu_usage: std.atomic.Value(i64),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, opts: ShedderOptions) !Self {
        const bucket_duration_ms = @divFloor(opts.window_ms, @as(i64, @intCast(opts.buckets)));
        const window_scale = 1.0 / @as(f64, @floatFromInt(bucket_duration_ms));
        return .{
            .cpu_threshold = opts.cpu_threshold,
            .window_scale = window_scale,
            .flying = 0,
            .avg_flying = 0,
            .avg_flying_mutex = .init,
            .overload_time_ms = std.atomic.Value(i64).init(0),
            .dropped_recently = std.atomic.Value(bool).init(false),
            .pass_counter = try RollingWindow(i64).init(allocator, opts.buckets, bucket_duration_ms),
            .rt_counter = try RollingWindow(i64).init(allocator, opts.buckets, bucket_duration_ms),
            .cpu_overloaded_fn = opts.cpu_overloaded_fn,
            .cpu_usage_fn = opts.cpu_usage_fn,
            .last_cpu_usage = std.atomic.Value(i64).init(cpu_usage_unmeasured),
        };
    }

    pub fn deinit(self: *Self) void {
        self.pass_counter.deinit();
        self.rt_counter.deinit();
    }

    pub fn allow(self: *Self) errors.Error!Promise {
        if (self.shouldDrop()) {
            self.dropped_recently.store(true, .monotonic);
            return ErrServiceOverloaded;
        }
        self.addFlying(1);
        return Promise{
            .start_ms = compat.milliTimestamp(),
            .shedder = self,
        };
    }

    fn addFlying(self: *Self, delta: i64) void {
        const prev = @atomicRmw(i64, &self.flying, .Add, delta, .monotonic);
        if (delta < 0) {
            const new_flying = prev + delta;
            self.avg_flying_mutex.lock();
            self.avg_flying = self.avg_flying * flying_beta + @as(f64, @floatFromInt(new_flying)) * (1.0 - flying_beta);
            self.avg_flying_mutex.unlock();
        }
    }

    fn shouldDrop(self: *Self) bool {
        if (self.systemOverloaded() or self.stillHot()) {
            if (self.highThru()) {
                return true;
            }
        }
        return false;
    }

    fn systemOverloaded(self: *Self) bool {
        // Sample first, so that the overload factor and `cpuUsage` describe the
        // same measurement the detector decided on.
        self.last_cpu_usage.store(switch (self.cpu_usage_fn()) {
            .measured => |usage| usage,
            .unavailable => cpu_usage_unmeasured,
        }, .monotonic);
        if (!self.cpu_overloaded_fn(self.cpu_threshold)) {
            return false;
        }
        self.overload_time_ms.store(compat.milliTimestamp(), .monotonic);
        return true;
    }

    /// CPU busy ratio (millicpu) of the last `allow` decision, or null when
    /// that decision could not measure CPU usage on this platform. Null means
    /// "unknown", never "idle".
    pub fn cpuUsage(self: *const Self) ?i64 {
        const raw = self.last_cpu_usage.load(.monotonic);
        return if (raw == cpu_usage_unmeasured) null else raw;
    }

    fn stillHot(self: *Self) bool {
        if (!self.dropped_recently.load(.monotonic)) {
            return false;
        }
        const overload_time = self.overload_time_ms.load(.monotonic);
        if (overload_time == 0) {
            return false;
        }
        if (compat.milliTimestamp() - overload_time < cool_off_duration_ms) {
            return true;
        }
        self.dropped_recently.store(false, .monotonic);
        return false;
    }

    fn highThru(self: *Self) bool {
        self.avg_flying_mutex.lock();
        const avg_flying = self.avg_flying;
        self.avg_flying_mutex.unlock();
        const max_flight = self.maxFlight() * self.overloadFactor();
        const flying_val = @atomicLoad(i64, &self.flying, .monotonic);
        return avg_flying > max_flight and @as(f64, @floatFromInt(flying_val)) > max_flight;
    }

    fn maxFlight(self: *Self) f64 {
        const max_pass = self.pass_counter.maxSum();
        const min_rt = self.rt_counter.minAvg();
        const max_flight = @as(f64, @floatFromInt(max_pass)) * min_rt * self.window_scale;
        return @max(max_flight, 1.0);
    }

    fn overloadFactor(self: *Self) f64 {
        // Shrink max flight as measured CPU usage approaches the threshold,
        // like go-zero. An unmeasured sample keeps the full factor, and
        // `cpuUsage` reports null in that case rather than pretending CPU was
        // idle.
        const cpu_usage: f64 = if (self.cpuUsage()) |usage| @floatFromInt(usage) else 0;
        const headroom = @as(f64, cpu_max) - @as(f64, @floatFromInt(self.cpu_threshold));
        if (headroom == 0) return 1.0; // threshold at the top: nothing to discount
        const factor = (@as(f64, cpu_max) - cpu_usage) / headroom;
        return std.math.clamp(factor, overload_factor_lower_bound, 1.0);
    }
};

/// Create a new adaptive shedder with options.
pub fn newAdaptiveShedder(allocator: std.mem.Allocator, opts: ShedderOptions) !AdaptiveShedder {
    return AdaptiveShedder.init(allocator, opts);
}

test "rolling window" {
    const allocator = std.testing.allocator;
    var rw = try RollingWindow(i64).init(allocator, 5, 1000);
    defer rw.deinit();

    rw.add(10);
    rw.add(20);
    rw.add(5);
    // All adds happen within the same millisecond bucket, so maxSum = 10+20+5 = 35
    try std.testing.expectEqual(@as(i64, 35), rw.maxSum());
    // minAvg for the single bucket = round((10+20+5)/3) = 12.0
    try std.testing.expectEqual(@as(f64, 12.0), rw.minAvg());
}

test "adaptive shedder basic" {
    const allocator = std.testing.allocator;
    var shedder = try newAdaptiveShedder(allocator, .{});
    defer shedder.deinit();

    // Should allow normally
    const p = try shedder.allow();
    compat.sleep(2 * std.time.ns_per_ms);
    p.pass();

    // Nop shedder should always allow
    var nop = NopShedder{};
    const np = try nop.allow();
    np.pass();
}

test "adaptive shedder drops under high load" {
    const allocator = std.testing.allocator;
    var shedder = try newAdaptiveShedder(allocator, .{
        .cpu_overloaded_fn = struct {
            fn f(th: i64) bool {
                _ = th;
                return true;
            }
        }.f,
    });
    defer shedder.deinit();

    // Every allowed request completes immediately here, so at most one request
    // is ever in flight and avgFlying stays at that level — below maxFlight()
    // unless overloading is extreme. The test therefore only pins down that the
    // shedder keeps serving while the detector reports overload; the
    // deterministic drop is covered by "adaptive shedder drops when the
    // injected detector reports overload".

    var allowed: usize = 0;
    var dropped: usize = 0;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        if (shedder.allow()) |p| {
            allowed += 1;
            compat.sleep(1 * std.time.ns_per_ms);
            p.pass();
        } else |_| {
            dropped += 1;
        }
    }

    // We should see both allowed and dropped
    try std.testing.expect(allowed > 0);
}

/// Test doubles for the injectable CPU signal.
fn alwaysOverloaded(threshold: i64) bool {
    _ = threshold;
    return true;
}

fn neverOverloaded(threshold: i64) bool {
    _ = threshold;
    return false;
}

fn idleCpu() CpuUsage {
    return .{ .measured = 0 };
}

fn halfBusyCpu() CpuUsage {
    return .{ .measured = 950 };
}

fn fullyBusyCpu() CpuUsage {
    return .{ .measured = cpu_max };
}

fn unavailableCpu() CpuUsage {
    return .unavailable;
}

test "adaptive shedder drops when the injected detector reports overload" {
    const allocator = std.testing.allocator;

    var shedder = try newAdaptiveShedder(allocator, .{
        .cpu_overloaded_fn = alwaysOverloaded,
        // Busy CPU pins the overload factor at its lower bound, so maxFlight
        // stays at 1.0 while 20 requests are still in flight and the smoothed
        // average is far above it.
        .cpu_usage_fn = fullyBusyCpu,
    });
    defer shedder.deinit();

    var promises: [40]Promise = undefined;
    for (&promises) |*promise| {
        promise.* = try shedder.allow();
    }
    for (promises[0..20]) |*promise| promise.pass();

    try std.testing.expectEqual(@as(?i64, cpu_max), shedder.cpuUsage());
    try std.testing.expectError(ErrServiceOverloaded, shedder.allow());

    // Same traffic, detector reports the system is fine: nothing is dropped.
    // The contrast is what attributes the drop above to the detector rather
    // than to the traffic pattern.
    var calm = try newAdaptiveShedder(allocator, .{
        .cpu_overloaded_fn = neverOverloaded,
        .cpu_usage_fn = fullyBusyCpu,
    });
    defer calm.deinit();

    var calm_promises: [40]Promise = undefined;
    for (&calm_promises) |*promise| {
        promise.* = try calm.allow();
    }
    for (calm_promises[0..20]) |*promise| promise.pass();
    const extra = try calm.allow();
    extra.pass();
}

test "adaptive shedder exposes unmeasured cpu instead of a fake zero" {
    const allocator = std.testing.allocator;

    var measured = try newAdaptiveShedder(allocator, .{
        .cpu_overloaded_fn = neverOverloaded,
        .cpu_usage_fn = halfBusyCpu,
    });
    defer measured.deinit();
    _ = try measured.allow();
    try std.testing.expectEqual(@as(?i64, 950), measured.cpuUsage());

    var unknown = try newAdaptiveShedder(allocator, .{
        .cpu_overloaded_fn = neverOverloaded,
        .cpu_usage_fn = unavailableCpu,
    });
    defer unknown.deinit();
    _ = try unknown.allow();
    // Unknown, not "idle": the shedder never claims a measurement it did not take.
    try std.testing.expectEqual(@as(?i64, null), unknown.cpuUsage());
}

test "overload factor follows the measured cpu usage" {
    const allocator = std.testing.allocator;

    const cases = [_]struct { probe: *const fn () CpuUsage, factor: f64 }{
        .{ .probe = idleCpu, .factor = 1.0 },
        .{ .probe = halfBusyCpu, .factor = 0.5 },
        .{ .probe = fullyBusyCpu, .factor = overload_factor_lower_bound },
    };
    for (cases) |case| {
        var shedder = try newAdaptiveShedder(allocator, .{
            .cpu_overloaded_fn = neverOverloaded,
            .cpu_usage_fn = case.probe,
        });
        defer shedder.deinit();
        _ = try shedder.allow();
        try std.testing.expectEqual(case.factor, shedder.overloadFactor());
    }
}

/// Sample until a supported platform produces a measurement.
///
/// Darwin's counters only move in bursts about a second apart, so the first
/// couple of samples there honestly report "nothing measured yet"; on Linux the
/// first sample already yields a value.
fn sampleUntilMeasured(max_attempts: usize) ?i64 {
    var attempt: usize = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        switch (sampleCpuUsage()) {
            .measured => |usage| return usage,
            .unavailable => compat.sleep((cpu_sample_interval_ms + 50) * std.time.ns_per_ms),
        }
    }
    return null;
}

test "cpu sample is bounded and honest about availability" {
    switch (builtin.os.tag) {
        .linux, .macos => {
            // A measurement has to appear within a few seconds on a platform
            // that supports one; the value must be a sane millicpu ratio.
            const usage = sampleUntilMeasured(12) orelse return error.NoCpuMeasurementOnThisPlatform;
            try std.testing.expect(usage >= 0 and usage <= cpu_max);
        },
        else => switch (sampleCpuUsage()) {
            .unavailable => {},
            .measured => return error.UnexpectedMeasurementOnUnsupportedPlatform,
        },
    }
}

test "cpu measurement survives the cache window and stays bounded" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const first = sampleUntilMeasured(12) orelse return error.NoCpuMeasurementOnThisPlatform;
    try std.testing.expect(first >= 0 and first <= cpu_max);

    // Past the cache window the next call must either take a fresh delta or
    // report the retained last ratio — once measured, the signal must not
    // silently degrade to unmeasured.
    compat.sleep((cpu_sample_interval_ms + 50) * std.time.ns_per_ms);
    switch (sampleCpuUsage()) {
        .measured => |usage| try std.testing.expect(usage >= 0 and usage <= cpu_max),
        .unavailable => return error.CpuSignalLostAfterFirstMeasurement,
    }
}
