//! HTTP client for zigzero
//!
//! HTTP/1.1 client with real timeouts, retries, and a circuit-breaker hook.
//!
//! HTTPS is deliberately not supported: this project has no TLS implementation
//! (`src/net/tls.zig` is a stub that only reads certificate files), so an
//! `https://` URL is rejected with `error.HttpsNotSupported` instead of being
//! silently downgraded to plaintext.

const std = @import("std");
const compat = @import("../compat.zig");
const errors = @import("../core/errors.zig");
const trace = @import("../infra/trace.zig");
const breaker = @import("../infra/breaker.zig");
const retry = @import("../infra/retry.zig");

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

/// Errors reported by `Client.request` and its wrappers: the framework-wide
/// `errors.Error` plus the failures only the response parser can detect.
pub const Error = errors.Error || error{
    /// The status line was not `HTTP/<version> <code>`.
    InvalidStatusLine,
    /// The response had no `\r\n\r\n` separating headers from body.
    MalformedResponse,
    /// The URL was `https://`; see the module comment.
    HttpsNotSupported,
};

/// HTTP client configuration
pub const Config = struct {
    /// Budget for a single attempt, covering connect, request write and the
    /// read of the whole response. Enforced with `poll(2)`, so the granularity
    /// is one millisecond.
    timeout_ms: u32 = 5000,
    /// Total number of attempts, *not* additional retries: `1` disables
    /// retrying. Same convention as `rpc.ClientConfig.retries`.
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
    pub fn get(self: *Client, url: []const u8) Error!Response {
        return self.request(.GET, url, null, null);
    }

    /// Send HTTP POST request with JSON body
    pub fn post(self: *Client, url: []const u8, body: []const u8, headers: ?std.StringHashMap([]const u8)) Error!Response {
        return self.request(.POST, url, body, headers);
    }

    /// Send HTTP request
    pub fn request(self: *Client, method: Method, url: []const u8, body: ?[]const u8, custom_headers: ?std.StringHashMap([]const u8)) Error!Response {
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

    /// Resolves the URL, retries the transport exchange, then parses the bytes
    /// of the attempt that succeeded.
    ///
    /// Only the exchange is retried: it is the part that fails transiently.
    /// Parsing runs once, on the last attempt's bytes, because a malformed
    /// response is deterministic and retrying it would just repeat the failure.
    fn doRequest(self: *Client, method: Method, url: []const u8, body: ?[]const u8, custom_headers: ?std.StringHashMap([]const u8)) Error!Response {
        const full_url = if (self.config.base_url) |base|
            try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ base, url })
        else
            try self.allocator.dupe(u8, url);
        defer self.allocator.free(full_url);

        // No TLS: reject the scheme here rather than treating "https://host"
        // as a host name and retrying a call that can never succeed.
        if (std.mem.startsWith(u8, full_url, "https://")) return error.HttpsNotSupported;

        const target = try parseUrl(full_url);

        var attempt = Attempt{
            .client = self,
            .method = method,
            .target = target,
            .body = body,
            .headers = custom_headers,
        };
        current_attempt = &attempt;
        defer current_attempt = null;

        const raw = try retry.retry(RawResponse, .{
            .max_attempts = @max(self.config.retries, 1),
        }, attemptFn);
        defer self.allocator.free(raw.bytes);

        return parseResponse(self.allocator, raw.bytes);
    }

    /// One bounded connect/write/read round trip. The whole attempt shares a
    /// single deadline so that a peer dribbling bytes cannot stretch the
    /// request past `config.timeout_ms`.
    fn exchange(self: *Client, method: Method, target: Target, body: ?[]const u8, custom_headers: ?std.StringHashMap([]const u8)) errors.ResultT(RawResponse) {
        const timeout = attemptDeadline(self.config.timeout_ms);

        // Build HTTP request
        var req_builder: std.ArrayList(u8) = .empty;
        defer req_builder.deinit(self.allocator);

        if (body) |b| {
            try req_builder.print(self.allocator, "{s} {s} HTTP/1.1\r\n", .{ method.toString(), target.path });
            try req_builder.print(self.allocator, "Host: {s}\r\n", .{target.host});
            try req_builder.print(self.allocator, "Content-Length: {d}\r\n", .{b.len});
            try req_builder.appendSlice(self.allocator, "Content-Type: application/json\r\n");
        } else {
            try req_builder.print(self.allocator, "{s} {s} HTTP/1.1\r\n", .{ method.toString(), target.path });
            try req_builder.print(self.allocator, "Host: {s}\r\n", .{target.host});
        }

        // Add trace context if present
        if (self.trace_context) |ctx| {
            var tp_buf: [55]u8 = undefined;
            // 55 bytes is exactly the size of a traceparent value, so the only
            // possible failure is a sizing bug on our side.
            const tp = ctx.formatTraceparent(&tp_buf) catch return error.ServerError;
            try req_builder.print(self.allocator, "traceparent: {s}\r\n", .{tp});
        }

        // Add custom headers
        if (custom_headers) |hdrs| {
            var iter = hdrs.iterator();
            while (iter.next()) |entry| {
                try req_builder.print(self.allocator, "{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        }

        try req_builder.appendSlice(self.allocator, "Connection: close\r\n\r\n");

        if (body) |b| {
            try req_builder.appendSlice(self.allocator, b);
        }

        // Connect and send
        const stream = try connectBounded(target.host, target.port, timeout);
        defer compat.net.streamClose(stream);

        try writeAllBounded(stream, req_builder.items, timeout);

        // Read response
        var buf: [8192]u8 = undefined;
        var response_data: std.ArrayList(u8) = .empty;
        errdefer response_data.deinit(self.allocator);

        while (true) {
            const n = try readBounded(stream, &buf, timeout);
            if (n == 0) break;
            try response_data.appendSlice(self.allocator, buf[0..n]);
        }

        if (response_data.items.len == 0) return error.NetworkError;

        return .{ .bytes = try response_data.toOwnedSlice(self.allocator) };
    }
};

/// One address, resolved once and reused by every retry.
const Target = struct {
    host: []const u8,
    port: u16 = 80,
    path: []const u8 = "/",
};

/// Splits `http://host[:port]/path` into its parts. Only literal IPv4 hosts
/// are supported (no DNS resolution), matching the original implementation.
fn parseUrl(full_url: []const u8) errors.Error!Target {
    var target = Target{ .host = full_url };

    if (std.mem.startsWith(u8, full_url, "http://")) {
        const rest = full_url[7..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            target.host = rest[0..slash];
            target.path = rest[slash..];
        } else {
            target.host = rest;
        }

        if (std.mem.indexOfScalar(u8, target.host, ':')) |colon| {
            target.port = std.fmt.parseInt(u16, target.host[colon + 1 ..], 10) catch return error.InvalidParameter;
            target.host = target.host[0..colon];
        }
    }

    return target;
}

/// The bytes of one exchange, owned by the caller.
const RawResponse = struct {
    bytes: []u8,
};

/// In-flight attempt for `attemptFn`.
const Attempt = struct {
    client: *Client,
    method: Method,
    target: Target,
    body: ?[]const u8,
    headers: ?std.StringHashMap([]const u8),
};

/// `retry.retry` takes a bare `fn ()` pointer, which cannot carry the request,
/// so the in-flight attempt is handed over through thread-local storage. That
/// is safe here because `attemptFn` runs synchronously on the caller's thread
/// and never calls back into `Client.request`.
threadlocal var current_attempt: ?*const Attempt = null;

fn attemptFn() errors.ResultT(RawResponse) {
    const attempt = current_attempt orelse return error.ServerError;
    return attempt.client.exchange(attempt.method, attempt.target, attempt.body, attempt.headers);
}

/// The deadline shared by the connect, write and read of one attempt.
///
/// `std.Io`'s Threaded backend implements `operateTimeout` (and the equivalent
/// wait inside `operateTimeout`'s batch) with `poll(2)`, whose timeout is an
/// integer number of milliseconds, so that is the granularity of
/// `Config.timeout_ms`.
///
/// `SO_RCVTIMEO` / `SO_SNDTIMEO` are deliberately not used instead: the
/// Threaded backend calls `recvmsg`/`sendmsg` directly and treats `EAGAIN` as a
/// programmer bug (`errnoBug`), which panics in debug builds.
fn attemptDeadline(timeout_ms: u32) std.Io.Timeout {
    return .{ .deadline = std.Io.Clock.Timestamp.fromNow(compat.io(), .{
        .raw = .fromMilliseconds(@intCast(timeout_ms)),
        .clock = .awake,
    }) };
}

/// Maps a `std.Io` failure onto the client's error set, keeping `error.Timeout`
/// distinguishable from a plain transport failure.
fn mapIoError(err: anyerror) errors.Error {
    return switch (err) {
        error.Timeout => error.Timeout,
        else => error.NetworkError,
    };
}

/// Connects to `host:port`, giving up after `timeout`.
///
/// `std.Io.net.ConnectOptions.timeout` is not usable: the Threaded backend
/// panics with "TODO implement netConnectIpPosix with timeout". Instead the
/// socket is opened non-blocking, `connect` is allowed to return `EINPROGRESS`
/// and completion is waited for with a `poll` deadline; the socket is switched
/// back to blocking mode afterwards because the read/write helpers expect the
/// syscalls themselves not to fail with `EAGAIN`.
fn connectBounded(host: []const u8, port: u16, timeout: std.Io.Timeout) errors.Error!compat.net.Stream {
    const posix = std.posix;

    const ip4 = compat.net.Ip4Address.parse(host, port) catch return error.NetworkError;

    // `std.Io.net` has no raw-socket constructor, so the socket is created
    // through the platform layer and wrapped in a `Stream` afterwards.
    const sock_rc = posix.system.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    if (posix.errno(sock_rc) != .SUCCESS) return error.NetworkError;
    const fd: posix.fd_t = @intCast(sock_rc);
    errdefer _ = posix.system.close(fd);

    // Do not leak the descriptor into a child process.
    if (posix.errno(posix.system.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC))) != .SUCCESS) {
        return error.NetworkError;
    }

    const flags_rc = posix.system.fcntl(fd, posix.F.GETFL, @as(c_int, 0));
    if (posix.errno(flags_rc) != .SUCCESS) return error.NetworkError;
    const blocking_flags: u32 = @intCast(flags_rc);
    const nonblocking = blocking_flags | (1 << @bitOffsetOf(posix.O, "NONBLOCK"));
    if (posix.errno(posix.system.fcntl(fd, posix.F.SETFL, @as(c_int, @intCast(nonblocking)))) != .SUCCESS) {
        return error.NetworkError;
    }

    var address: posix.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, ip4.port),
        .addr = @bitCast(ip4.bytes),
    };
    const address_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);

    switch (posix.errno(posix.system.connect(fd, @ptrCast(&address), address_len))) {
        .SUCCESS => {},
        // The kernel accepted the connection attempt; the handshake continues
        // in the background and is waited for below.
        .INPROGRESS, .AGAIN => {
            var fds = [_]posix.pollfd{.{
                .fd = fd,
                .events = posix.POLL.OUT,
                .revents = 0,
            }};
            if (try pollBounded(&fds, timeout) == 0) return error.Timeout;

            // A ready socket may still carry a failed handshake (refused,
            // unreachable, ...); SO_ERROR reports it.
            var sock_error: c_int = 0;
            var sock_error_len: posix.socklen_t = @sizeOf(c_int);
            const opt_rc = posix.system.getsockopt(
                fd,
                posix.SOL.SOCKET,
                posix.SO.ERROR,
                @as(?*anyopaque, @ptrCast(&sock_error)),
                &sock_error_len,
            );
            if (posix.errno(opt_rc) != .SUCCESS) return error.NetworkError;
            if (sock_error != 0) return error.NetworkError;
        },
        else => return error.NetworkError,
    }

    if (posix.errno(posix.system.fcntl(fd, posix.F.SETFL, @as(c_int, @intCast(blocking_flags)))) != .SUCCESS) {
        return error.NetworkError;
    }

    return .{ .socket = .{ .handle = fd, .address = .{ .ip4 = ip4 } } };
}

/// `poll` over `fds`, bounded by whatever is left of `timeout`; returns 0 when
/// the deadline expires first.
fn pollBounded(fds: []std.posix.pollfd, timeout: std.Io.Timeout) errors.Error!u32 {
    const io = compat.io();
    const deadline = timeout.toTimestamp(io) orelse return error.NetworkError;
    const remaining_ms = deadline.durationFromNow(io).raw.toMilliseconds();
    const clamped = std.math.clamp(remaining_ms, 0, std.math.maxInt(i32));

    const ready = std.posix.poll(fds, @intCast(clamped)) catch return error.NetworkError;
    return @intCast(ready);
}

/// Writes all of `bytes`, giving up after `timeout`.
///
/// `operateTimeout` waits for the socket to become writable with the deadline
/// and then performs one blocking write, so each iteration only has to make
/// progress rather than fit the whole body into the socket buffer.
fn writeAllBounded(stream: compat.net.Stream, bytes: []const u8, timeout: std.Io.Timeout) errors.Error!void {
    var written: usize = 0;
    while (written < bytes.len) {
        const chunks = [_][]const u8{bytes[written..]};
        const result = compat.io().operateTimeout(.{ .net_write = .{
            .socket_handle = stream.socket.handle,
            .data = &chunks,
        } }, timeout) catch |err| return mapIoError(err);

        const n = result.net_write catch |err| return mapIoError(err);
        if (n == 0) return error.NetworkError;
        written += n;
    }
}

/// Reads up to `buf.len` bytes, giving up after `timeout`. Returns 0 at end of
/// stream. Single read only: the response is parsed incrementally, so a short
/// read must not be padded out.
fn readBounded(stream: compat.net.Stream, buf: []u8, timeout: std.Io.Timeout) errors.Error!usize {
    var data: [1][]u8 = .{buf};
    const result = compat.io().operateTimeout(.{ .net_read = .{
        .socket_handle = stream.socket.handle,
        .data = &data,
    } }, timeout) catch |err| return mapIoError(err);

    const read_result = result.net_read catch |err| return mapIoError(err);
    return read_result.data_len;
}

/// Parses a complete HTTP/1.x response.
fn parseResponse(allocator: std.mem.Allocator, raw: []const u8) Error!Response {
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.MalformedResponse;
    const headers_str = raw[0..header_end];
    const body_str = raw[header_end + 4 ..];

    const status_line_end = std.mem.indexOf(u8, headers_str, "\r\n") orelse headers_str.len;
    const status_code = try parseStatusCode(headers_str[0..status_line_end]);

    var resp_headers = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var iter = resp_headers.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        resp_headers.deinit();
    }

    const header_lines = if (status_line_end + 2 <= headers_str.len) headers_str[status_line_end + 2 ..] else "";
    var line_iter = std.mem.splitSequence(u8, header_lines, "\r\n");
    while (line_iter.next()) |line| {
        if (std.mem.indexOf(u8, line, ": ")) |colon_idx| {
            const key = try allocator.dupe(u8, line[0..colon_idx]);
            const value = try allocator.dupe(u8, line[colon_idx + 2 ..]);
            try resp_headers.put(key, value);
        }
    }

    const body_copy = try allocator.dupe(u8, body_str);

    return Response{
        .status_code = status_code,
        .headers = resp_headers,
        .body = body_copy,
        .allocator = allocator,
    };
}

/// Extracts the status code from a status line of the form
/// `HTTP/<version> <code>[ <reason>]`.
///
/// The line is tokenized instead of being sliced at a fixed offset: a fixed
/// `[9..12]` silently misreads any header whose version string is not exactly
/// `HTTP/1.1`, and panics on a line shorter than 12 bytes.
fn parseStatusCode(status_line: []const u8) error{InvalidStatusLine}!u16 {
    var tokens = std.mem.tokenizeAny(u8, status_line, " \t");

    const version = tokens.next() orelse return error.InvalidStatusLine;
    if (!std.mem.startsWith(u8, version, "HTTP/")) return error.InvalidStatusLine;
    if (version.len <= "HTTP/".len or !std.ascii.isDigit(version["HTTP/".len])) {
        return error.InvalidStatusLine;
    }

    const code_text = tokens.next() orelse return error.InvalidStatusLine;
    if (code_text.len != 3) return error.InvalidStatusLine;
    return std.fmt.parseInt(u16, code_text, 10) catch return error.InvalidStatusLine;
}

test "http client init" {
    const client = Client.init(std.testing.allocator, .{});
    _ = client;
}

test "status line parsing" {
    try std.testing.expectEqual(@as(u16, 200), try parseStatusCode("HTTP/1.1 200 OK"));
    try std.testing.expectEqual(@as(u16, 404), try parseStatusCode("HTTP/1.1 404 Not Found"));
    // No reason phrase, and an `HTTP/2` line (the version is only used for the
    // prefix check).
    try std.testing.expectEqual(@as(u16, 204), try parseStatusCode("HTTP/1.1 204"));
    try std.testing.expectEqual(@as(u16, 500), try parseStatusCode("HTTP/2 500 Oops With Spaces"));

    // Malformed lines are rejected instead of being read at a fixed offset.
    try std.testing.expectError(error.InvalidStatusLine, parseStatusCode(""));
    try std.testing.expectError(error.InvalidStatusLine, parseStatusCode("BOGUS 200 OK"));
    try std.testing.expectError(error.InvalidStatusLine, parseStatusCode("HTTP/"));
    try std.testing.expectError(error.InvalidStatusLine, parseStatusCode("HTTP/1.1"));
    try std.testing.expectError(error.InvalidStatusLine, parseStatusCode("HTTP/1.1 OK"));
    try std.testing.expectError(error.InvalidStatusLine, parseStatusCode("HTTP/1.1 20 OK"));
    try std.testing.expectError(error.InvalidStatusLine, parseStatusCode("HTTP/1.1 2000 OK"));
    try std.testing.expectError(error.InvalidStatusLine, parseStatusCode("HTTP/x.1 200 OK"));
}

test "http client rejects https" {
    var client = Client.init(std.testing.allocator, .{ .retries = 1 });
    try std.testing.expectError(error.HttpsNotSupported, client.get("https://127.0.0.1:1/"));
}

/// A listener bound to an ephemeral loopback port.
const TestServer = struct {
    server: compat.net.Server,
    port: u16,
};

fn startTestServer() !TestServer {
    const address: compat.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
    const server = try compat.net.listen(&address, .{ .reuse_address = true, .kernel_backlog = 16 });
    return .{ .server = server, .port = server.socket.address.getPort() };
}

/// Accepts one connection and then never sends a byte, so the client can only
/// finish by hitting its own deadline. It exits when the client gives up and
/// closes the connection (the read returns end of stream).
fn stalledServer(server: *compat.net.Server) void {
    const io = compat.io();
    const stream = server.accept(io) catch return;
    defer compat.net.streamClose(stream);

    var buf: [1024]u8 = undefined;
    while (true) {
        const n = compat.net.streamRead(stream, &buf) catch break;
        if (n == 0) break;
    }
}

/// Accepts two connections: the first is closed without a response (an
/// immediately failed attempt), the second gets a well-formed 200.
fn flakyServer(server: *compat.net.Server, accepted: *std.atomic.Value(u32)) void {
    const io = compat.io();

    if (server.accept(io)) |first| {
        _ = accepted.fetchAdd(1, .release);
        first.close(io);
    } else |_| return;

    if (server.accept(io)) |second| {
        _ = accepted.fetchAdd(1, .release);
        defer compat.net.streamClose(second);

        var buf: [1024]u8 = undefined;
        _ = compat.net.streamRead(second, &buf) catch 0;

        const body = "hello zigzero";
        var resp_buf: [128]u8 = undefined;
        const resp = std.fmt.bufPrint(
            &resp_buf,
            "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ body.len, body },
        ) catch return;
        compat.net.streamWrite(second, resp) catch {};
    } else |_| {}
}

/// Accepts one connection and answers with the given raw bytes.
fn cannedResponseServer(server: *compat.net.Server, response: []const u8) void {
    const io = compat.io();
    const stream = server.accept(io) catch return;
    defer compat.net.streamClose(stream);

    var buf: [1024]u8 = undefined;
    _ = compat.net.streamRead(stream, &buf) catch 0;
    compat.net.streamWrite(stream, response) catch {};
}

test "http client times out on a stalled server" {
    const allocator = std.testing.allocator;
    const io = compat.io();

    var srv = try startTestServer();
    defer srv.server.deinit(io);

    const thread = try std.Thread.spawn(.{}, stalledServer, .{&srv.server});
    defer thread.join();

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/stall", .{srv.port});
    defer allocator.free(url);

    var client = Client.init(allocator, .{ .timeout_ms = 50, .retries = 1 });

    const started_ms = compat.milliTimestamp();
    const result = client.get(url);
    const elapsed_ms = compat.milliTimestamp() - started_ms;

    try std.testing.expectError(error.Timeout, result);
    // The whole point: bounded, not "whenever the peer feels like it".
    try std.testing.expect(elapsed_ms < 2000);
}

test "http client retries a failed attempt" {
    const allocator = std.testing.allocator;
    const io = compat.io();

    var srv = try startTestServer();
    defer srv.server.deinit(io);

    var accepted = std.atomic.Value(u32).init(0);
    const thread = try std.Thread.spawn(.{}, flakyServer, .{ &srv.server, &accepted });
    defer thread.join();

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/flaky", .{srv.port});
    defer allocator.free(url);

    var client = Client.init(allocator, .{ .timeout_ms = 2000, .retries = 2 });
    var resp = try client.get(url);
    defer resp.deinit();

    // Both accepts happen before the second response is written, and the client
    // only returns after reading that response, so the count is final here.
    try std.testing.expectEqual(@as(u32, 2), accepted.load(.acquire));
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expectEqualStrings("hello zigzero", resp.body);
}

test "http client reports malformed status lines" {
    const allocator = std.testing.allocator;
    const io = compat.io();

    const cases = [_][]const u8{
        "HTTP/1.1 20 OK\r\n\r\n", // code too short
        "BOGUS 200 OK\r\n\r\n", // no HTTP/ prefix
    };

    for (cases) |case| {
        var srv = try startTestServer();
        defer srv.server.deinit(io);

        const thread = try std.Thread.spawn(.{}, cannedResponseServer, .{ &srv.server, case });
        defer thread.join();

        const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/malformed", .{srv.port});
        defer allocator.free(url);

        var client = Client.init(allocator, .{ .timeout_ms = 2000, .retries = 1 });
        try std.testing.expectError(error.InvalidStatusLine, client.get(url));
    }
}

test "http client parses a valid response" {
    const allocator = std.testing.allocator;
    const io = compat.io();

    var srv = try startTestServer();
    defer srv.server.deinit(io);

    const response = "HTTP/1.1 201 Created\r\nContent-Type: text/plain\r\nX-Test: yes\r\nConnection: close\r\n\r\nmade it";
    const thread = try std.Thread.spawn(.{}, cannedResponseServer, .{ &srv.server, response });
    defer thread.join();

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/ok", .{srv.port});
    defer allocator.free(url);

    var client = Client.init(allocator, .{ .timeout_ms = 2000, .retries = 1 });
    var resp = try client.get(url);
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 201), resp.status_code);
    try std.testing.expectEqualStrings("made it", resp.body);
    try std.testing.expectEqualStrings("text/plain", resp.headers.get("Content-Type").?);
    try std.testing.expectEqualStrings("yes", resp.headers.get("X-Test").?);
}
