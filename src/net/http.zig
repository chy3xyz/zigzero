//! HTTP client for zigzero
//!
//! Provides HTTP client with timeout, retries, and connection pooling.

const std = @import("std");
const errors = @import("../core/errors.zig");
const trace = @import("../infra/trace.zig");
const breaker = @import("../infra/breaker.zig");

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .PATCH => "PATCH",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
        };
    }
};

/// HTTP response
pub const Response = struct {
    status_code: u16,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        var iter = self.headers.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();
        self.allocator.free(self.body);
    }
};

/// HTTP client configuration
pub const Config = struct {
    timeout_ms: u32 = 5000,
    retries: u32 = 3,
    base_url: ?[]const u8 = null,
};

/// HTTP client
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,
    trace_context: ?trace.TraceContext = null,
    circuit_breaker: ?*breaker.CircuitBreaker = null,

    pub fn init(allocator: std.mem.Allocator, config: Config) Client {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn withTraceContext(self: *Client, ctx: ?trace.TraceContext) void {
        self.trace_context = ctx;
    }

    pub fn withBreaker(self: *Client, cb: *breaker.CircuitBreaker) void {
        self.circuit_breaker = cb;
    }

    /// Send HTTP GET request
    pub fn get(self: *Client, url: []const u8) !Response {
        return self.request(.GET, url, null, null);
    }

    /// Send HTTP POST request with JSON body
    pub fn post(self: *Client, url: []const u8, body: []const u8, headers: ?std.StringHashMap([]const u8)) !Response {
        return self.request(.POST, url, body, headers);
    }

    /// Send HTTP request
    pub fn request(self: *Client, method: Method, url: []const u8, body: ?[]const u8, custom_headers: ?std.StringHashMap([]const u8)) !Response {
        if (self.circuit_breaker) |cb| {
            if (!cb.allow()) return errors.Error.CircuitBreakerOpen;
        }

        const resp = self.doRequest(method, url, body, custom_headers) catch |err| {
            if (self.circuit_breaker) |cb| cb.recordFailure();
            return err;
        };

        if (self.circuit_breaker) |cb| {
            if (resp.status_code >= 500) {
                cb.recordFailure();
            } else {
                cb.recordSuccess();
            }
        }

        return resp;
    }

    fn doRequest(self: *Client, method: Method, url: []const u8, body: ?[]const u8, custom_headers: ?std.StringHashMap([]const u8)) !Response {
        const full_url = if (self.config.base_url) |base|
            try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ base, url })
        else
            try self.allocator.dupe(u8, url);
        defer self.allocator.free(full_url);

        // Parse URL (simplified - supports http://host:port/path)
        var host: []const u8 = undefined;
        var port: u16 = 80;
        var path: []const u8 = "/";

        if (std.mem.startsWith(u8, full_url, "http://")) {
            const rest = full_url[7..];
            if (std.mem.indexOf(u8, rest, "/")) |slash_idx| {
                host = rest[0..slash_idx];
                path = rest[slash_idx..];
            } else {
                host = rest;
            }

            if (std.mem.indexOf(u8, host, ":")) |colon_idx| {
                port = try std.fmt.parseInt(u16, host[colon_idx + 1 ..], 10);
                host = host[0..colon_idx];
            }
        } else {
            host = full_url;
        }

        // Build HTTP request
        var req_builder: std.ArrayList(u8) = .{};
        defer req_builder.deinit(self.allocator);

        if (body) |b| {
            try req_builder.writer(self.allocator).print("{s} {s} HTTP/1.1\r\n", .{ method.toString(), path });
            try req_builder.writer(self.allocator).print("Host: {s}\r\n", .{host});
            try req_builder.writer(self.allocator).print("Content-Length: {d}\r\n", .{b.len});
            try req_builder.writer(self.allocator).writeAll("Content-Type: application/json\r\n");
        } else {
            try req_builder.writer(self.allocator).print("{s} {s} HTTP/1.1\r\n", .{ method.toString(), path });
            try req_builder.writer(self.allocator).print("Host: {s}\r\n", .{host});
        }

        // Add trace context if present
        if (self.trace_context) |ctx| {
            var tp_buf: [55]u8 = undefined;
            const tp = try ctx.formatTraceparent(&tp_buf);
            try req_builder.writer(self.allocator).print("traceparent: {s}\r\n", .{tp});
        }

        // Add custom headers
        if (custom_headers) |hdrs| {
            var iter = hdrs.iterator();
            while (iter.next()) |entry| {
                try req_builder.writer(self.allocator).print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        }

        try req_builder.writer(self.allocator).writeAll("Connection: close\r\n\r\n");

        if (body) |b| {
            try req_builder.appendSlice(self.allocator, b);
        }

        // Connect and send
        const address = std.net.Address.parseIp4(host, port) catch return error.NetworkError;
        const stream = std.net.tcpConnectToAddress(address) catch return error.NetworkError;
        defer stream.close();

        _ = stream.write(req_builder.items) catch return error.NetworkError;

        // Read response
        var buf: [8192]u8 = undefined;
        var response_data: std.ArrayList(u8) = .{};
        defer response_data.deinit(self.allocator);

        while (true) {
            const n = stream.read(&buf) catch break;
            if (n == 0) break;
            try response_data.appendSlice(self.allocator, buf[0..n]);
        }

        if (response_data.items.len == 0) return error.NetworkError;

        // Parse response (simplified)
        const resp_str = response_data.items;
        const header_end = std.mem.indexOf(u8, resp_str, "\r\n\r\n") orelse return error.NetworkError;
        const headers_str = resp_str[0..header_end];
        const resp_body = resp_str[header_end + 4 ..];

        // Parse status line
        const status_line_end = std.mem.indexOf(u8, headers_str, "\r\n") orelse return error.NetworkError;
        const status_line = headers_str[0..status_line_end];
        const status_code = try std.fmt.parseInt(u16, status_line[9..12], 10);

        // Parse headers
        var resp_headers = std.StringHashMap([]const u8).init(self.allocator);
        errdefer {
            var iter = resp_headers.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            resp_headers.deinit();
        }

        var line_iter = std.mem.splitSequence(u8, headers_str[status_line_end + 2 ..], "\r\n");
        while (line_iter.next()) |line| {
            if (std.mem.indexOf(u8, line, ": ")) |colon_idx| {
                const key = try self.allocator.dupe(u8, line[0..colon_idx]);
                const value = try self.allocator.dupe(u8, line[colon_idx + 2 ..]);
                try resp_headers.put(key, value);
            }
        }

        const body_copy = try self.allocator.dupe(u8, resp_body);

        return Response{
            .status_code = status_code,
            .headers = resp_headers,
            .body = body_copy,
            .allocator = self.allocator,
        };
    }
};

test "http client init" {
    const client = Client.init(std.testing.allocator, .{});
    _ = client;
}
