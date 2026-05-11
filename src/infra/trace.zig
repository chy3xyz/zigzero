//! Distributed tracing for zigzero
//!
//! Provides OpenTelemetry-compatible distributed tracing.

const std = @import("std");
const compat = @import("../compat.zig");
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
            .start_time = compat.milliTimestamp(),
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
        self.end_time = compat.milliTimestamp();
    }

    /// Set span status
    pub fn setStatus(self: *Span, status: Status) void {
        self.status = status;
    }

    /// Get duration in milliseconds
    pub fn getDurationMs(self: *const Span) i64 {
        const end_time = self.end_time orelse compat.milliTimestamp();
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
            .spans = .empty,
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
    compat.randomBytes(&id);
    return id;
}

/// Generate random span ID
fn generateSpanId() SpanId {
    var id: SpanId = undefined;
    compat.randomBytes(&id);
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

/// Trace flags
pub const TraceFlags = struct {
    pub const sampled: u8 = 0x01;
};

/// TraceContext holds propagated tracing state (W3C TraceContext)
pub const TraceContext = struct {
    trace_id: TraceId,
    span_id: SpanId,
    flags: u8,
    trace_state: ?[]const u8 = null,

    /// Format traceparent header value: 00-<trace_id>-<span_id>-<flags>
    pub fn formatTraceparent(self: *const TraceContext, buf: []u8) ![]const u8 {
        var i: usize = 0;
        @memcpy(buf[i..][0..3], "00-");
        i += 3;
        for (self.trace_id) |b| {
            const hex = try std.fmt.bufPrint(buf[i..][0..2], "{x:0>2}", .{b});
            i += hex.len;
        }
        buf[i] = '-';
        i += 1;
        for (self.span_id) |b| {
            const hex = try std.fmt.bufPrint(buf[i..][0..2], "{x:0>2}", .{b});
            i += hex.len;
        }
        buf[i] = '-';
        i += 1;
        const flags_hex = try std.fmt.bufPrint(buf[i..][0..2], "{x:0>2}", .{self.flags});
        i += flags_hex.len;
        return buf[0..i];
    }

    /// Parse traceparent header value
    pub fn parseTraceparent(allocator: std.mem.Allocator, value: []const u8) !?TraceContext {
        _ = allocator;
        var parts = std.mem.splitScalar(u8, value, '-');
        const version = parts.next() orelse return null;
        const trace_id_hex = parts.next() orelse return null;
        const span_id_hex = parts.next() orelse return null;
        const flags_hex = parts.next() orelse return null;

        if (!std.mem.eql(u8, version, "00")) return null;
        if (trace_id_hex.len != 32) return null;
        if (span_id_hex.len != 16) return null;
        if (flags_hex.len != 2) return null;

        const trace_id = try parseTraceId(trace_id_hex);
        const span_id = try parseSpanId(span_id_hex);
        const flags = try std.fmt.parseInt(u8, flags_hex, 16);

        return TraceContext{
            .trace_id = trace_id,
            .span_id = span_id,
            .flags = flags,
        };
    }

    /// Check if trace is sampled
    pub fn isSampled(self: *const TraceContext) bool {
        return (self.flags & TraceFlags.sampled) != 0;
    }
};

/// Inject trace context into HTTP headers
pub fn injectHttpHeaders(ctx: TraceContext, headers: *std.StringHashMap([]const u8)) !void {
    var buf: [55]u8 = undefined;
    const traceparent = try ctx.formatTraceparent(&buf);
    const key = try headers.allocator.dupe(u8, "traceparent");
    const value = try headers.allocator.dupe(u8, traceparent);
    try headers.put(key, value);
}

/// Extract trace context from HTTP headers
pub fn extractHttpHeaders(allocator: std.mem.Allocator, headers: std.StringHashMap([]const u8)) !?TraceContext {
    if (headers.get("traceparent")) |value| {
        return try TraceContext.parseTraceparent(allocator, value);
    }
    return null;
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

test "tracecontext format and parse" {
    const allocator = std.testing.allocator;
    var ctx = TraceContext{
        .trace_id = try parseTraceId("0af7651916cd43dd8448eb211c80319c"),
        .span_id = try parseSpanId("b7ad6b7169203331"),
        .flags = TraceFlags.sampled,
    };

    var buf: [55]u8 = undefined;
    const tp = try ctx.formatTraceparent(&buf);
    try std.testing.expectEqualStrings("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01", tp);

    const parsed = try TraceContext.parseTraceparent(allocator, tp);
    try std.testing.expect(parsed != null);
    try std.testing.expect(parsed.?.isSampled());
}

test "tracecontext extract and inject headers" {
    const allocator = std.testing.allocator;
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = headers.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        headers.deinit();
    }

    const ctx = TraceContext{
        .trace_id = try parseTraceId("0af7651916cd43dd8448eb211c80319c"),
        .span_id = try parseSpanId("b7ad6b7169203331"),
        .flags = TraceFlags.sampled,
    };

    try injectHttpHeaders(ctx, &headers);
    const extracted = try extractHttpHeaders(allocator, headers);
    try std.testing.expect(extracted != null);
    try std.testing.expect(extracted.?.isSampled());
}
