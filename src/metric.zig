//! Metrics and monitoring for zigzero
//!
//! Provides Prometheus-compatible metrics.

const std = @import("std");
const log = @import("log.zig");

/// Counter metric
pub const Counter = struct {
    name: []const u8,
    help: []const u8,
    labels: std.StringHashMap([]const u8),
    value: std.atomic.Value(u64),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, help: []const u8) !Counter {
        return Counter{
            .name = try allocator.dupe(u8, name),
            .help = try allocator.dupe(u8, help),
            .labels = std.StringHashMap([]const u8).init(allocator),
            .value = std.atomic.Value(u64).init(0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Counter) void {
        self.allocator.free(self.name);
        self.allocator.free(self.help);

        var iter = self.labels.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.labels.deinit();
    }

    /// Increment counter
    pub fn inc(self: *Counter) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    /// Increment by value
    pub fn add(self: *Counter, value: u64) void {
        _ = self.value.fetchAdd(value, .monotonic);
    }

    /// Get current value
    pub fn get(self: *const Counter) u64 {
        return self.value.load(.monotonic);
    }

    /// Set label
    pub fn setLabel(self: *Counter, key: []const u8, value: []const u8) !void {
        const k = try self.allocator.dupe(u8, key);
        const v = try self.allocator.dupe(u8, value);
        try self.labels.put(k, v);
    }

    /// Export as Prometheus format
    pub fn exportPrometheus(self: *const Counter, writer: anytype) !void {
        try writer.print("# HELP {s} {s}\n", .{ self.name, self.help });
        try writer.print("# TYPE {s} counter\n", .{self.name});

        try writer.print("{s}", .{self.name});

        // Write labels
        if (self.labels.count() > 0) {
            try writer.writeAll("{");
            var iter = self.labels.iterator();
            var first = true;
            while (iter.next()) |entry| {
                if (!first) try writer.writeAll(",");
                try writer.print("{s}=\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
                first = false;
            }
            try writer.writeAll("}");
        }

        try writer.print(" {d}\n", .{self.get()});
    }
};

/// Gauge metric (can go up and down)
pub const Gauge = struct {
    name: []const u8,
    help: []const u8,
    labels: std.StringHashMap([]const u8),
    value: std.atomic.Value(i64),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, help: []const u8) !Gauge {
        return Gauge{
            .name = try allocator.dupe(u8, name),
            .help = try allocator.dupe(u8, help),
            .labels = std.StringHashMap([]const u8).init(allocator),
            .value = std.atomic.Value(i64).init(0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Gauge) void {
        self.allocator.free(self.name);
        self.allocator.free(self.help);

        var iter = self.labels.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.labels.deinit();
    }

    /// Set value
    pub fn set(self: *Gauge, value: i64) void {
        self.value.store(value, .monotonic);
    }

    /// Increment
    pub fn inc(self: *Gauge) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    /// Decrement
    pub fn dec(self: *Gauge) void {
        _ = self.value.fetchSub(1, .monotonic);
    }

    /// Add value
    pub fn add(self: *Gauge, value: i64) void {
        _ = self.value.fetchAdd(value, .monotonic);
    }

    /// Get current value
    pub fn get(self: *const Gauge) i64 {
        return self.value.load(.monotonic);
    }

    /// Set label
    pub fn setLabel(self: *Gauge, key: []const u8, value: []const u8) !void {
        const k = try self.allocator.dupe(u8, key);
        const v = try self.allocator.dupe(u8, value);
        try self.labels.put(k, v);
    }

    /// Export as Prometheus format
    pub fn exportPrometheus(self: *const Gauge, writer: anytype) !void {
        try writer.print("# HELP {s} {s}\n", .{ self.name, self.help });
        try writer.print("# TYPE {s} gauge\n", .{self.name});

        try writer.print("{s}", .{self.name});

        if (self.labels.count() > 0) {
            try writer.writeAll("{");
            var iter = self.labels.iterator();
            var first = true;
            while (iter.next()) |entry| {
                if (!first) try writer.writeAll(",");
                try writer.print("{s}=\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
                first = false;
            }
            try writer.writeAll("}");
        }

        try writer.print(" {d}\n", .{self.get()});
    }
};

/// Histogram metric
pub const Histogram = struct {
    name: []const u8,
    help: []const u8,
    buckets: []const f64,
    counts: []u64,
    sum: std.atomic.Value(f64),
    count: std.atomic.Value(u64),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, help: []const u8, buckets: []const f64) !Histogram {
        const counts = try allocator.alloc(u64, buckets.len);
        @memset(counts, 0);

        return Histogram{
            .name = try allocator.dupe(u8, name),
            .help = try allocator.dupe(u8, help),
            .buckets = try allocator.dupe(f64, buckets),
            .counts = counts,
            .sum = std.atomic.Value(f64).init(0),
            .count = std.atomic.Value(u64).init(0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Histogram) void {
        self.allocator.free(self.name);
        self.allocator.free(self.help);
        self.allocator.free(self.buckets);
        self.allocator.free(self.counts);
    }

    /// Observe a value
    pub fn observe(self: *Histogram, value: f64) void {
        _ = self.sum.fetchAdd(value, .monotonic);
        _ = self.count.fetchAdd(1, .monotonic);

        for (self.buckets, 0..) |bucket, i| {
            if (value <= bucket) {
                _ = @atomicRmw(u64, &self.counts[i], .Add, 1, .monotonic);
                break;
            }
        }
    }

    /// Export as Prometheus format
    pub fn exportPrometheus(self: *const Histogram, writer: anytype) !void {
        try writer.print("# HELP {s} {s}\n", .{ self.name, self.help });
        try writer.print("# TYPE {s} histogram\n", .{self.name});

        var cumulative: u64 = 0;
        for (self.buckets, 0..) |bucket, i| {
            cumulative += @atomicLoad(u64, &self.counts[i], .monotonic);
            try writer.print("{s}_bucket{{le=\"{d:.3}\"}} {d}\n", .{ self.name, bucket, cumulative });
        }
        try writer.print("{s}_bucket{{le=\"+Inf\"}} {d}\n", .{ self.name, self.count.load(.monotonic) });
        try writer.print("{s}_sum {d:.3}\n", .{ self.name, self.sum.load(.monotonic) });
        try writer.print("{s}_count {d}\n", .{ self.name, self.count.load(.monotonic) });
    }
};

/// Metrics registry
pub const Registry = struct {
    allocator: std.mem.Allocator,
    counters: std.StringHashMap(*Counter),
    gauges: std.StringHashMap(*Gauge),
    histograms: std.StringHashMap(*Histogram),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .counters = std.StringHashMap(*Counter).init(allocator),
            .gauges = std.StringHashMap(*Gauge).init(allocator),
            .histograms = std.StringHashMap(*Histogram).init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        var counters_iter = self.counters.iterator();
        while (counters_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.counters.deinit();

        var gauges_iter = self.gauges.iterator();
        while (gauges_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.gauges.deinit();

        var hist_iter = self.histograms.iterator();
        while (hist_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.histograms.deinit();
    }

    /// Create or get counter
    pub fn counter(self: *Registry, name: []const u8, help: []const u8) !*Counter {
        if (self.counters.get(name)) |c| return c;

        const c = try self.allocator.create(Counter);
        c.* = try Counter.init(self.allocator, name, help);
        try self.counters.put(try self.allocator.dupe(u8, name), c);
        return c;
    }

    /// Create or get gauge
    pub fn gauge(self: *Registry, name: []const u8, help: []const u8) !*Gauge {
        if (self.gauges.get(name)) |g| return g;

        const g = try self.allocator.create(Gauge);
        g.* = try Gauge.init(self.allocator, name, help);
        try self.gauges.put(try self.allocator.dupe(u8, name), g);
        return g;
    }

    /// Create or get histogram
    pub fn histogram(self: *Registry, name: []const u8, help: []const u8, buckets: []const f64) !*Histogram {
        if (self.histograms.get(name)) |h| return h;

        const h = try self.allocator.create(Histogram);
        h.* = try Histogram.init(self.allocator, name, help, buckets);
        try self.histograms.put(try self.allocator.dupe(u8, name), h);
        return h;
    }

    /// Export all metrics as Prometheus format
    pub fn exportPrometheus(self: *const Registry, writer: anytype) !void {
        var counters_iter = self.counters.iterator();
        while (counters_iter.next()) |entry| {
            try entry.value_ptr.*.exportPrometheus(writer);
        }

        var gauges_iter = self.gauges.iterator();
        while (gauges_iter.next()) |entry| {
            try entry.value_ptr.*.exportPrometheus(writer);
        }

        var hist_iter = self.histograms.iterator();
        while (hist_iter.next()) |entry| {
            try entry.value_ptr.*.exportPrometheus(writer);
        }
    }
};

test "metrics" {
    const allocator = std.testing.allocator;

    var registry = Registry.init(allocator);
    defer registry.deinit();

    const counter = try registry.counter("requests_total", "Total requests");
    counter.inc();
    counter.inc();
    try std.testing.expectEqual(@as(u64, 2), counter.get());

    const gauge = try registry.gauge("active_connections", "Active connections");
    gauge.set(10);
    gauge.inc();
    try std.testing.expectEqual(@as(i64, 11), gauge.get());
}

test "prometheus export" {
    const allocator = std.testing.allocator;

    var registry = Registry.init(allocator);
    defer registry.deinit();

    const counter = try registry.counter("test_counter", "Test counter");
    counter.inc();

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try registry.exportPrometheus(fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "test_counter") != null);
}
