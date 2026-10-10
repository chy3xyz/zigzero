//! RPC framework for zigzero
//!
//! Provides RPC client and server functionality.
//! Aligned with go-zero's zrpc package.

const std = @import("std");
const compat = @import("../compat.zig");
const errors = @import("../core/errors.zig");
const breaker = @import("../infra/breaker.zig");
const loadbalancer = @import("../infra/loadbalancer.zig");

/// RPC client configuration
pub const ClientConfig = struct {
    /// Target address (e.g., "127.0.0.1")
    target: []const u8 = "127.0.0.1",
    /// Target port
    port: u16 = 8080,
    /// Timeout in milliseconds
    timeout_ms: u32 = 5000,
    /// Enable circuit breaker
    circuit_breaker: bool = true,
    /// Enable retries
    retries: u32 = 3,
};

/// RPC client
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: ClientConfig,
    breaker: breaker.CircuitBreaker,
    lb: loadbalancer.LoadBalancer,

    pub fn init(allocator: std.mem.Allocator, cfg: ClientConfig) Client {
        return Client{
            .allocator = allocator,
            .config = cfg,
            .breaker = breaker.CircuitBreaker.new(),
            .lb = loadbalancer.LoadBalancer.init(allocator, .round_robin),
        };
    }

    pub fn deinit(self: *Client) void {
        self.lb.deinit();
    }

    /// Add a server endpoint
    pub fn addEndpoint(self: *Client, address: []const u8) void {
        self.lb.addEndpoint(address);
    }

    /// Call a remote procedure.
    /// Returns the raw JSON response body, allocated with the client
    /// allocator (caller must free). Returns `error.RemoteError` when the
    /// server reported an application-level error (the method failed or the
    /// request body could not be decoded).
    pub fn call(self: *Client, method: []const u8, req: anytype) ![]u8 {
        // Check circuit breaker
        if (!self.breaker.allow()) {
            return error.ServiceUnavailable;
        }

        errdefer self.breaker.recordFailure();

        const result = try self.doCall(method, req);
        self.breaker.recordSuccess();
        return result;
    }

    fn doCall(self: *Client, method: []const u8, req: anytype) ![]u8 {
        // Build the request frame once; retries reuse the same bytes.
        var request: std.ArrayList(u8) = .empty;
        defer request.deinit(self.allocator);

        // Serialize request body as JSON.
        const body_json = try std.json.Stringify.valueAlloc(self.allocator, req, .{});
        defer self.allocator.free(body_json);

        // RPC header (body length patched in place below).
        var header = RpcHeader{
            .magic = RPC_MAGIC,
            .version = RPC_VERSION,
            .method_len = @intCast(method.len),
            .body_len = @intCast(body_json.len),
        };
        try request.appendSlice(self.allocator, std.mem.asBytes(&header));
        try request.appendSlice(self.allocator, method);
        try request.appendSlice(self.allocator, body_json);

        for (0..self.config.retries) |_| {
            const endpoint = self.lb.select() orelse return error.ServiceUnavailable;
            const result = self.doCallOnce(endpoint.address, request.items) catch |err| switch (err) {
                // A remote application error is deterministic; do not retry.
                error.RemoteError => return err,
                else => continue,
            };
            return result;
        }

        return error.NetworkError;
    }

    fn doCallOnce(self: *Client, host: []const u8, request: []const u8) ![]u8 {
        const address = try compat.net.IpAddress.parseIp4(host, self.config.port);
        const stream = try compat.net.tcpConnectToAddress(address);
        defer compat.net.streamClose(stream);

        try writeAllStream(stream, request);

        // One reader for the whole connection: `std.Io.net` readers buffer
        // reads, so recreating a reader per call would drop buffered bytes.
        var read_buf: [4096]u8 = undefined;
        var stream_reader = stream.reader(compat.io(), &read_buf);
        const reader = &stream_reader.interface;

        var resp_header: RpcHeader = undefined;
        try readFullIo(reader, std.mem.asBytes(&resp_header));

        if (resp_header.magic != RPC_MAGIC or resp_header.version != RPC_VERSION) {
            return error.ProtocolError;
        }

        const resp_body = try self.allocator.alloc(u8, resp_header.body_len);
        errdefer self.allocator.free(resp_body);
        try readFullIo(reader, resp_body);

        if (resp_header.reserved & RPC_STATUS_ERROR != 0) {
            // errdefer frees the body.
            return error.RemoteError;
        }

        return resp_body;
    }
};

// RPC protocol constants
const RPC_MAGIC: u32 = 0x52504330; // "RPC0"
const RPC_VERSION: u8 = 1;

/// Status flag stored in `RpcHeader.reserved`: the response body carries a
/// JSON error object of the form `{"error":"<message>"}` instead of the
/// method result.
const RPC_STATUS_ERROR: u8 = 1;

const RpcHeader = extern struct {
    magic: u32,
    version: u8,
    method_len: u16,
    body_len: u32,
    reserved: u8 = 0,
};

/// Writes all of `bytes` to the stream and flushes the write buffer, so the
/// peer receives the data before this returns.
fn writeAllStream(stream: compat.net.Stream, bytes: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var stream_writer = stream.writer(compat.io(), &buf);
    try stream_writer.interface.writeAll(bytes);
    try stream_writer.interface.flush();
}

/// Reads exactly `buf.len` bytes from a reader interface, returning
/// `error.ConnectionClosed` on EOF or read failure. The same reader must be
/// used for the whole connection: `std.Io.net` readers buffer reads, so a
/// fresh reader would drop any buffered bytes.
fn readFullIo(reader: *std.Io.Reader, buf: []u8) !void {
    var bytes_read: usize = 0;
    while (bytes_read < buf.len) {
        const n = reader.readSliceShort(buf[bytes_read..]) catch return error.ConnectionClosed;
        if (n == 0) return error.ConnectionClosed;
        bytes_read += n;
    }
}

/// Writes one response frame (header + body) and flushes, so a short response
/// is not left sitting in the write buffer. `is_error` marks the frame with
/// `RPC_STATUS_ERROR` so the client can tell the body is an error object.
fn writeResponse(writer: *std.Io.Writer, body: []const u8, is_error: bool) !void {
    const header = RpcHeader{
        .magic = RPC_MAGIC,
        .version = RPC_VERSION,
        .method_len = 0,
        .body_len = @intCast(body.len),
        .reserved = if (is_error) RPC_STATUS_ERROR else 0,
    };
    try writer.writeAll(std.mem.asBytes(&header));
    try writer.writeAll(body);
    try writer.flush();
}

/// Dispatches one RPC call: decodes the JSON request `body` into the request
/// parameter type of the service's `rpc_*` method, invokes the method on
/// `service`, and encodes the return value as the JSON response body.
///
/// The method must have the signature `fn (*ServiceType, Req) Resp` or
/// `fn (*ServiceType, Req) !Resp`, where `Req` is decodable from JSON with
/// `std.json`. A void result is encoded as `{}`. Decoding failures and
/// method errors propagate to the caller.
fn dispatchRpcCall(
    comptime ServiceType: type,
    comptime decl_name: []const u8,
    service: *ServiceType,
    body: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    const method = @field(ServiceType, decl_name);
    const fn_info = @typeInfo(@TypeOf(method)).@"fn";

    if (fn_info.param_types.len != 2) {
        @compileError("rpc method '" ++ decl_name ++ "' must have signature 'fn (*" ++ @typeName(ServiceType) ++ ", Req) !Resp'");
    }
    const self_param = fn_info.param_types[0] orelse
        @compileError("rpc method '" ++ decl_name ++ "' must have a concrete self parameter type");
    if (self_param != *ServiceType) {
        @compileError("rpc method '" ++ decl_name ++ "' must have signature 'fn (*" ++ @typeName(ServiceType) ++ ", Req) !Resp'");
    }
    const Req = fn_info.param_types[1] orelse
        @compileError("rpc method '" ++ decl_name ++ "' must have a concrete request parameter type");
    const ret_payload = switch (@typeInfo(fn_info.return_type.?)) {
        .error_union => |eu| eu.payload,
        else => fn_info.return_type.?,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const req = try std.json.parseFromSliceLeaky(Req, arena.allocator(), body, .{});

    const result: ret_payload = result: {
        if (@typeInfo(fn_info.return_type.?) == .error_union) {
            break :result try @call(.auto, method, .{ service, req });
        }
        break :result @call(.auto, method, .{ service, req });
    };

    if (ret_payload == void) {
        // JSON has no void; encode an empty object.
        return std.json.Stringify.valueAlloc(allocator, {}, .{});
    }
    return std.json.Stringify.valueAlloc(allocator, result, .{});
}

/// RPC Server
pub const Server = struct {
    allocator: std.mem.Allocator,
    config: ServerConfig,
    services: std.StringHashMap(*anyopaque),
    handler_map: std.StringHashMap(HandlerEntry),
    listener: ?compat.net.Server = null,
    running: std.atomic.Value(bool),
    accept_loop_active: std.atomic.Value(bool),
    conn_wg: compat.WaitGroup,

    const ServerConfig = struct {
        host: []const u8 = "0.0.0.0",
        port: u16 = 8080,
        max_connections: u32 = 1000,
    };

    /// A registered RPC method: the service instance to invoke it on plus the
    /// generated dispatcher that decodes the request body, calls the method,
    /// and encodes the result.
    const HandlerEntry = struct {
        ctx: *anyopaque,
        invoke: *const fn (ctx: *anyopaque, body: []const u8, allocator: std.mem.Allocator) anyerror![]u8,
    };

    pub fn init(allocator: std.mem.Allocator, cfg: ServerConfig) Server {
        return .{
            .allocator = allocator,
            .config = cfg,
            .services = std.StringHashMap(*anyopaque).init(allocator),
            .handler_map = std.StringHashMap(HandlerEntry).init(allocator),
            .listener = null,
            .running = std.atomic.Value(bool).init(false),
            .accept_loop_active = std.atomic.Value(bool).init(false),
            .conn_wg = compat.WaitGroup.init,
        };
    }

    pub fn deinit(self: *Server) void {
        var key_it = self.handler_map.keyIterator();
        while (key_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.handler_map.deinit();
        self.services.deinit();
    }

    /// Register a service with the server.
    ///
    /// Every `fn` declaration whose name starts with `rpc_` is registered as
    /// the RPC method `<fully-qualified-type-name>.<name-without-prefix>`.
    /// The method must have the signature `fn (*ServiceType, Req) !Resp`;
    /// request bodies are decoded from JSON into `Req` and results are
    /// encoded as JSON.
    pub fn registerService(self: *Server, comptime ServiceType: type, instance: *ServiceType) !void {
        const service_name = @typeName(ServiceType);
        try self.services.put(service_name, instance);

        // Auto-register RPC methods
        inline for (@typeInfo(ServiceType).@"struct".decl_names) |decl_name| {
            if (comptime std.mem.startsWith(u8, decl_name, "rpc_") and
                @typeInfo(@TypeOf(@field(ServiceType, decl_name))) == .@"fn")
            {
                const method_name = decl_name[4..]; // Remove "rpc_" prefix
                const full_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ service_name, method_name });

                const handler = struct {
                    fn handle(ctx: *anyopaque, body: []const u8, allocator: std.mem.Allocator) anyerror![]u8 {
                        const service: *ServiceType = @ptrCast(@alignCast(ctx));
                        return dispatchRpcCall(ServiceType, decl_name, service, body, allocator);
                    }
                }.handle;

                try self.handler_map.put(full_name, .{ .ctx = instance, .invoke = handler });
            }
        }
    }

    /// Start the RPC server. Blocks until `stop` is called, so run it on a
    /// dedicated thread.
    pub fn start(self: *Server) !void {
        const address = compat.net.IpAddress.parseIp4(self.config.host, self.config.port) catch return error.ServerError;

        var server = address.listen(compat.io(), .{
            .reuse_address = true,
            .kernel_backlog = 128,
        }) catch return error.ServerError;

        self.listener = server;
        self.running.store(true, .monotonic);
        self.accept_loop_active.store(true, .monotonic);

        std.log.info("RPC server listening on {s}:{d}", .{ self.config.host, self.config.port });

        while (self.running.load(.monotonic)) {
            const stream = server.accept(compat.io()) catch |err| {
                if (!self.running.load(.monotonic)) break;
                std.log.err("Accept error: {any}", .{err});
                continue;
            };

            if (!self.running.load(.monotonic)) {
                // Woken up by `stop`; the listener is closed there.
                compat.net.streamClose(stream);
                break;
            }

            const thread = std.Thread.spawn(.{}, handleConnection, .{ self, stream }) catch |err| {
                std.log.err("Failed to spawn thread: {any}", .{err});
                compat.net.streamClose(stream);
                continue;
            };
            thread.detach();
        }

        self.accept_loop_active.store(false, .release);
    }

    /// Returns the port the server socket is actually bound to, or null if
    /// the server is not running. Useful together with `port = 0` to
    /// discover the ephemeral port chosen by the kernel.
    pub fn boundPort(self: *const Server) ?u16 {
        if (self.listener) |*l| {
            return l.socket.address.getPort();
        }
        return null;
    }

    fn handleConnection(self: *Server, stream: compat.net.Stream) void {
        self.conn_wg.start();
        defer self.conn_wg.finish();
        defer compat.net.streamClose(stream);

        var read_buf: [4096]u8 = undefined;
        var stream_reader = stream.reader(compat.io(), &read_buf);
        const reader = &stream_reader.interface;

        var write_buf: [4096]u8 = undefined;
        var stream_writer = stream.writer(compat.io(), &write_buf);
        const writer = &stream_writer.interface;

        // Read request header
        var header: RpcHeader = undefined;
        readFullIo(reader, std.mem.asBytes(&header)) catch return;

        // Validate header
        if (header.magic != RPC_MAGIC or header.version != RPC_VERSION) {
            return;
        }

        // Read method name
        const method_name = self.allocator.alloc(u8, header.method_len) catch return;
        defer self.allocator.free(method_name);
        readFullIo(reader, method_name) catch return;

        // Read body
        const body = self.allocator.alloc(u8, header.body_len) catch return;
        defer self.allocator.free(body);
        readFullIo(reader, body) catch return;

        // Find handler
        const entry = self.handler_map.get(method_name) orelse {
            writeResponse(writer, "{\"error\":\"unknown method\"}", true) catch {};
            return;
        };

        // Call handler
        const response = entry.invoke(entry.ctx, body, self.allocator) catch |err| {
            // The failure is reported to the client in the response frame, so
            // no server-side logging here.
            const err_body = std.fmt.allocPrint(self.allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch return;
            defer self.allocator.free(err_body);
            writeResponse(writer, err_body, true) catch {};
            return;
        };
        defer self.allocator.free(response);

        // Send response
        writeResponse(writer, response, false) catch {};
    }

    /// Stop the server: unblock the accept loop, wait for in-flight
    /// connections to finish, and release the listening socket. Safe to call
    /// from another thread while `start` is blocked in `accept`.
    pub fn stop(self: *Server) void {
        self.running.store(false, .monotonic);
        if (self.listener) |*l| {
            // Wake the accept loop by connecting to ourselves; the loop
            // observes `running == false` and exits. Connecting to the
            // loopback address also works when bound to 0.0.0.0.
            const wake_addr = compat.net.IpAddress{ .ip4 = compat.net.Ip4Address.loopback(l.socket.address.getPort()) };
            if (compat.net.tcpConnectToAddress(wake_addr)) |wake_stream| {
                compat.net.streamClose(wake_stream);
            } else |_| {}
            // Wait until the accept loop has exited before closing the
            // listener it is polling.
            while (self.accept_loop_active.load(.acquire)) {
                std.Thread.yield() catch {};
            }
            l.deinit(compat.io());
            self.listener = null;
        }
        // Wait for handler threads so the server can be torn down safely.
        self.conn_wg.wait();
    }
};

/// Service registration helper
pub fn Service(comptime T: type) type {
    return struct {
        const Self = @This();

        pub fn getName() []const u8 {
            return @typeName(T);
        }

        pub fn getMethods() []const []const u8 {
            comptime var methods: []const []const u8 = &.{};
            inline for (@typeInfo(T).@"struct".decl_names) |decl_name| {
                if (comptime std.mem.startsWith(u8, decl_name, "rpc_")) {
                    methods = methods ++ .{decl_name[4..]};
                }
            }
            return methods;
        }
    };
}

const CalcService = struct {
    pub const AddRequest = struct {
        a: i64,
        b: i64,
    };

    pub const AddResponse = struct {
        sum: i64,
    };

    pub const EchoRequest = struct {
        msg: []const u8,
    };

    pub const EchoResponse = struct {
        msg: []const u8,
    };

    pub fn rpc_add(self: *CalcService, req: AddRequest) !AddResponse {
        _ = self;
        return .{ .sum = req.a + req.b };
    }

    pub fn rpc_echo(self: *CalcService, req: EchoRequest) !EchoResponse {
        _ = self;
        return .{ .msg = req.msg };
    }

    pub fn rpc_fail(self: *CalcService, req: AddRequest) !AddResponse {
        _ = self;
        _ = req;
        return error.InternalError;
    }
};

test "rpc dispatch decodes request and encodes response" {
    var service = CalcService{};

    const resp = try dispatchRpcCall(CalcService, "rpc_add", &service, "{\"a\":20,\"b\":22}", std.testing.allocator);
    defer std.testing.allocator.free(resp);
    try std.testing.expectEqualStrings("{\"sum\":42}", resp);

    // Method errors propagate to the caller.
    try std.testing.expectError(error.InternalError, dispatchRpcCall(CalcService, "rpc_fail", &service, "{\"a\":1,\"b\":2}", std.testing.allocator));

    // Malformed request bodies fail to decode.
    try std.testing.expectError(error.SyntaxError, dispatchRpcCall(CalcService, "rpc_add", &service, "{invalid", std.testing.allocator));
}

test "rpc client-server roundtrip" {
    const allocator = std.testing.allocator;

    var service = CalcService{};

    var server: Server = Server.init(allocator, .{
        .host = "127.0.0.1",
        .port = 0, // kernel-assigned ephemeral port
    });
    try server.registerService(CalcService, &service);

    const thread = try std.Thread.spawn(.{}, Server.start, .{&server});
    // Defers run LIFO: stop (waits for handler + accept threads) -> join -> deinit.
    defer server.deinit();
    defer thread.join();
    defer server.stop();

    // Wait until the accept loop is listening.
    var port: u16 = 0;
    var wait_iters: usize = 0;
    while (port == 0) {
        port = server.boundPort() orelse 0;
        if (port != 0) break;
        wait_iters += 1;
        if (wait_iters > 5000) return error.ServerStartTimeout;
        compat.sleep(1_000_000); // 1 ms
    }

    var client = Client.init(allocator, .{
        .target = "127.0.0.1",
        .port = port,
        .retries = 2,
    });
    defer client.deinit();
    client.addEndpoint("127.0.0.1");

    // Real computation: add two numbers.
    const add_method = comptime std.fmt.comptimePrint("{s}.add", .{@typeName(CalcService)});
    const add_bytes = try client.call(add_method, CalcService.AddRequest{ .a = 2, .b = 40 });
    defer allocator.free(add_bytes);
    const add_resp = try std.json.parseFromSliceLeaky(CalcService.AddResponse, allocator, add_bytes, .{});
    try std.testing.expectEqual(@as(i64, 42), add_resp.sum);

    // String echo.
    const echo_method = comptime std.fmt.comptimePrint("{s}.echo", .{@typeName(CalcService)});
    const echo_bytes = try client.call(echo_method, CalcService.EchoRequest{ .msg = "hello zigzero" });
    defer allocator.free(echo_bytes);
    const echo_resp = try std.json.parseFromSliceLeaky(CalcService.EchoResponse, allocator, echo_bytes, .{});
    try std.testing.expectEqualStrings("hello zigzero", echo_resp.msg);

    // Method returning an error is reported to the client as an error.
    const fail_method = comptime std.fmt.comptimePrint("{s}.fail", .{@typeName(CalcService)});
    try std.testing.expectError(error.RemoteError, client.call(fail_method, CalcService.AddRequest{ .a = 1, .b = 2 }));

    // Unknown methods are reported to the client as an error.
    const unknown_method = comptime std.fmt.comptimePrint("{s}.no_such_method", .{@typeName(CalcService)});
    try std.testing.expectError(error.RemoteError, client.call(unknown_method, CalcService.AddRequest{ .a = 1, .b = 2 }));
}

test "rpc protocol" {
    const header = RpcHeader{
        .magic = RPC_MAGIC,
        .version = RPC_VERSION,
        .method_len = 10,
        .body_len = 100,
    };

    try std.testing.expectEqual(@as(u32, 0x52504330), header.magic);
    try std.testing.expectEqual(@as(u8, 1), header.version);
}
