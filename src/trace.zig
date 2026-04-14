//! Distributed tracing for zigzero
//!
//! Provides OpenTelemetry-compatible distributed tracing.

const std = @import("std");
const log = @import("log.zig");

/// Trace ID
pub const TraceId = [16]u8;

/// Span ID
pub const SpanId = [8]u8;

/// Span represents a single operation within a trace
pub const Span = struct {
    trace_id: TraceId,
    span_id: SpanId,
    parent_span_id: ?SpanId,
    name: []const u8,
    start_time: i64,
    end_time: ?i64 = null,
    attributes: std.StringHashMap([]const u8),
    status: Status = .unset,
    allocator: std.mem.Allocator,

    pub const Status = enum {
        unset,
        ok,
        err,
    };

    pub fn init(allocator: std.mem.Allocator, name: []const u8, trace_id: TraceId, parent_id: ?SpanId) !Span {
        const span_id = generateSpanId();

        return Span{
            .trace_id = trace_id,
            .span_id = span_id,
            .parent_span_id = parent_id,
            .name = try allocator.dupe(u8, name),
            .start_time = std.time.milliTimestamp(),
            .attributes = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Span) void {
        self.allocator.free(self.name);

        var iter = self.attributes.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.attributes.deinit();
    }

    /// Set span attribute
    pub fn setAttribute(self: *Span, key: []const u8, value: []const u8) !void {
        const k = try self.allocator.dupe(u8, key);
        const v = try self.allocator.dupe(u8, value);
        try self.attributes.put(k, v);
    }

    /// End the span
    pub fn end(self: *Span) void {
        self.end_time = std.time.milliTimestamp();
    }

    /// Set span status
    pub fn setStatus(self: *Span, status: Status) void {
        self.status = status;
    }

    /// Get duration in milliseconds
    pub fn getDurationMs(self: *const Span) i64 {
        const end_time = self.end_time orelse std.time.milliTimestamp();
        return end_time - self.start_time;
    }

    /// Format trace ID as hex string
    pub fn formatTraceId(self: *const Span, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{x}", .{self.trace_id}) catch "";
    }

    /// Format span ID as hex string
    pub fn formatSpanId(self: *const Span, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{x}", .{self.span_id}) catch "";
    }
};

/// Tracer creates and manages spans
pub const Tracer = struct {
    allocator: std.mem.Allocator,
    service_name: []const u8,
    spans: std.ArrayList(*Span),
    current_span: ?*Span = null,

    pub fn init(allocator: std.mem.Allocator, service_name: []const u8) !Tracer {
        return Tracer{
            .allocator = allocator,
            .service_name = try allocator.dupe(u8, service_name),
            .spans = .{},
        };
    }

    pub fn deinit(self: *Tracer) void {
        self.allocator.free(self.service_name);

        for (self.spans.items) |span| {
            span.deinit();
            self.allocator.destroy(span);
        }
        self.spans.deinit(self.allocator);
    }

    /// Start a new trace
    pub fn startTrace(self: *Tracer, operation_name: []const u8) !*Span {
        const trace_id = generateTraceId();
        return try self.startSpan(operation_name, trace_id, null);
    }

    /// Start a new span within current trace
    pub fn startSpan(self: *Tracer, operation_name: []const u8, trace_id: TraceId, parent_id: ?SpanId) !*Span {
        const span = try self.allocator.create(Span);
        span.* = try Span.init(self.allocator, operation_name, trace_id, parent_id);

        try self.spans.append(self.allocator, span);
        self.current_span = span;

        return span;
    }

    /// Get current span
    pub fn getCurrentSpan(self: *const Tracer) ?*Span {
        return self.current_span;
    }

    /// Export spans as JSON
    pub fn exportJson(self: *const Tracer, writer: anytype) !void {
        try writer.writeAll("[");

        for (self.spans.items, 0..) |span, i| {
            if (i > 0) try writer.writeAll(",");

            var trace_buf: [33]u8 = undefined;
            var span_buf: [17]u8 = undefined;

            try writer.writeAll("{");
            try writer.print("\"trace_id\":\"{s}\",", .{span.formatTraceId(&trace_buf)});
            try writer.print("\"span_id\":\"{s}\",", .{span.formatSpanId(&span_buf)});
            try writer.print("\"name\":\"{s}\",", .{span.name});
            try writer.print("\"start_time\":{d},", .{span.start_time});
            try writer.print("\"duration_ms\":{d}", .{span.getDurationMs()});
            try writer.writeAll("}");
        }

        try writer.writeAll("]");
    }
};

/// Generate random trace ID
fn generateTraceId() TraceId {
    var id: TraceId = undefined;
    std.crypto.random.bytes(&id);
    return id;
}

/// Generate random span ID
fn generateSpanId() SpanId {
    var id: SpanId = undefined;
    std.crypto.random.bytes(&id);
    return id;
}

/// Parse trace ID from hex string
pub fn parseTraceId(hex: []const u8) !TraceId {
    var id: TraceId = undefined;
    _ = try std.fmt.hexToBytes(&id, hex);
    return id;
}

/// Parse span ID from hex string
pub fn parseSpanId(hex: []const u8) !SpanId {
    var id: SpanId = undefined;
    _ = try std.fmt.hexToBytes(&id, hex);
    return id;
}

test "tracing" {
    const allocator = std.testing.allocator;

    var tracer = try Tracer.init(allocator, "test-service");
    defer tracer.deinit();

    const span = try tracer.startTrace("test-operation");
    try span.setAttribute("key", "value");
    span.end();

    try std.testing.expectEqualStrings("test-operation", span.name);
    try std.testing.expectEqualStrings("value", span.attributes.get("key").?);
}

test "trace id generation" {
    const trace_id = generateTraceId();
    const span_id = generateSpanId();

    try std.testing.expectEqual(@as(usize, 16), trace_id.len);
    try std.testing.expectEqual(@as(usize, 8), span_id.len);
}
