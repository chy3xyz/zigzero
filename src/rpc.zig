    for (0..config.retries) |_| {
        // Get next endpoint from load balancer
        const endpoint = self.lb.select() orelse return error.ServiceUnavailable;

        // Build request
        var request_builder = std.ArrayList(u8).init(self.allocator);
        defer request_builder.deinit();

        // RPC header
        const header = RpcHeader{
            .magic = RPC_MAGIC,
            .version = RPC_VERSION,
            .method_len = @intCast(method.len),
            .body_len = 0, // TODO: serialize request body
        };
        try request_builder.appendSlice(std.mem.asBytes(&header));
        try request_builder.appendSlice(method);

        // Serialize request body (simplified - just JSON for now)
        const body_json = try std.json.stringifyAlloc(self.allocator, req, .{});
        defer self.allocator.free(body_json);
        try request_builder.appendSlice(body_json);

        // Update body length in header
        const final_header = RpcHeader{
            .magic = RPC_MAGIC,
            .version = RPC_VERSION,
            .method_len = @intCast(method.len),
            .body_len = @intCast(body_json.len),
        };
        std.mem.copyForwards(u8, request_builder.items[0..@sizeOf(RpcHeader)], std.mem.asBytes(&final_header));

        // Connect to endpoint
        const address = std.net.Address.parseIp4(endpoint.address, self.config.port) catch continue;
        const stream = std.net.tcpConnectToAddress(address) catch continue;
        defer stream.close();

        // Send request
        _ = stream.write(request_builder.items) catch continue;

        // Read response header
        var resp_header: RpcHeader = undefined;
        const header_bytes = std.mem.asBytes(&resp_header);
        var bytes_read: usize = 0;
        while (bytes_read < @sizeOf(RpcHeader)) {
            const n = stream.read(header_bytes[bytes_read..]) catch break;
            if (n == 0) break;
            bytes_read += n;
        }

        if (bytes_read < @sizeOf(RpcHeader)) continue;

        // Validate response
        if (resp_header.magic != RPC_MAGIC) continue;
        if (resp_header.version != RPC_VERSION) continue;

        // Read response body
        const resp_body = try self.allocator.alloc(u8, resp_header.body_len);
        errdefer self.allocator.free(resp_body);

        bytes_read = 0;
        while (bytes_read < resp_body.len) {
            const n = stream.read(resp_body[bytes_read..]) catch break;
            if (n == 0) break;
            bytes_read += n;
        }

        if (bytes_read < resp_body.len) {
            self.allocator.free(resp_body);
            continue;
        }

        return resp_body;
    }

    return error.NetworkError;
}

// RPC protocol constants
const RPC_MAGIC: u32 = 0x52504330; // "RPC0"
const RPC_VERSION: u8 = 1;

const RpcHeader = extern struct {
    magic: u32,
    version: u8,
    method_len: u16,
    body_len: u32,
    reserved: u8 = 0,
};

/// RPC Server
pub const Server = struct {
    allocator: std.mem.Allocator,
    config: ServerConfig,
    services: std.StringHashMap(*anyopaque),
    handler_map: std.StringHashMap(HandlerFn),
    listener: ?std.net.Server = null,
    running: std.atomic.Value(bool),

    const ServerConfig = struct {
        host: []const u8 = "0.0.0.0",
        port: u16 = 8080,
        max_connections: u32 = 1000,
    };

    const HandlerFn = *const fn (*anyopaque, []const u8, []const u8) anyerror![]u8;

    pub fn init(allocator: std.mem.Allocator, cfg: ServerConfig) Server {
        return .{
            .allocator = allocator,
            .config = cfg,
            .services = std.StringHashMap(*anyopaque).init(allocator),
            .handler_map = std.StringHashMap(HandlerFn).init(allocator),
            .listener = null,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Server) void {
        self.services.deinit();
        self.handler_map.deinit();
    }

    /// Register a service with the server
    pub fn registerService(self: *Server, comptime ServiceType: type, instance: *ServiceType) !void {
        const service_name = @typeName(ServiceType);
        try self.services.put(service_name, instance);

        // Auto-register RPC methods
        inline for (@typeInfo(ServiceType).Struct.decls) |decl| {
            if (comptime std.mem.startsWith(u8, decl.name, "rpc_")) {
                const method_name = decl.name[4..]; // Remove "rpc_" prefix
                const full_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ service_name, method_name });
                
                const handler = struct {
                    fn handle(svc: *anyopaque, method: []const u8, body: []const u8) ![]u8 {
                        _ = method;
                        const service = @as(*ServiceType, @ptrCast(@alignCast(svc)));
                        
                        // Deserialize request
                        const RequestType = @TypeOf(@field(service, decl.name)).params[0].type.?;
                        const req = try std.json.parseFromSlice(RequestType, std.heap.page_allocator, body, .{});
                        defer std.json.parseFree(RequestType, std.heap.page_allocator, req);
                        
                        // Call method
                        const ResponseType = @typeInfo(@typeInfo(@TypeOf(@field(service, decl.name)).return_type.?).error_union.payload).pointer.child;
                        const resp = try @field(service, decl.name)(req);
                        
                        // Serialize response
                        return std.json.stringifyAlloc(std.heap.page_allocator, resp, .{});
                    }
                }.handle;

                try self.handler_map.put(full_name, handler);
            }
        }
    }

    /// Start the RPC server
    pub fn start(self: *Server) !void {
        const address = std.net.Address.parseIp4(self.config.host, self.config.port) catch return error.ServerError;
        
        var server = address.listen(.{
            .reuse_address = true,
            .kernel_backlog = 128,
        }) catch return error.ServerError;
        
        self.listener = server;
        self.running.store(true, .monotonic);
        
        std.log.info("RPC server listening on {s}:{d}", .{ self.config.host, self.config.port });
        
        while (self.running.load(.monotonic)) {
            const conn = server.accept() catch |err| {
                if (!self.running.load(.monotonic)) break;
                std.log.err("Accept error: {any}", .{err});
                continue;
            };
            
            const conn_ptr = try self.allocator.create(std.net.Server.Connection);
            conn_ptr.* = conn;
            
            const thread = std.Thread.spawn(.{}, handleConnection, .{ self, conn_ptr }) catch |err| {
                std.log.err("Failed to spawn thread: {any}", .{err});
                conn_ptr.stream.close();
                self.allocator.destroy(conn_ptr);
                continue;
            };
            thread.detach();
        }
    }

    fn handleConnection(self: *Server, conn: *std.net.Server.Connection) void {
        defer {
            conn.stream.close();
            self.allocator.destroy(conn);
        }
        
        const reader = conn.stream.reader();
        const writer = conn.stream.writer();
        
        // Read request header
        var header: RpcHeader = undefined;
        const header_bytes = std.mem.asBytes(&header);
        var bytes_read: usize = 0;
        
        while (bytes_read < @sizeOf(RpcHeader)) {
            const n = reader.read(header_bytes[bytes_read..]) catch return;
            if (n == 0) return;
            bytes_read += n;
        }
        
        // Validate header
        if (header.magic != RPC_MAGIC or header.version != RPC_VERSION) {
            return;
        }
        
        // Read method name
        const method_name = self.allocator.alloc(u8, header.method_len) catch return;
        defer self.allocator.free(method_name);
        
        bytes_read = 0;
        while (bytes_read < method_name.len) {
            const n = reader.read(method_name[bytes_read..]) catch return;
            if (n == 0) return;
            bytes_read += n;
        }
        
        // Read body
        const body = self.allocator.alloc(u8, header.body_len) catch return;
        defer self.allocator.free(body);
        
        bytes_read = 0;
        while (bytes_read < body.len) {
            const n = reader.read(body[bytes_read..]) catch return;
            if (n == 0) return;
            bytes_read += n;
        }
        
        // Find handler
        const handler = self.handler_map.get(method_name) orelse {
            // Send error response
            const error_header = RpcHeader{
                .magic = RPC_MAGIC,
                .version = RPC_VERSION,
                .method_len = 0,
                .body_len = 0,
            };
            _ = writer.write(std.mem.asBytes(&error_header)) catch {};
            return;
        };
        
        // Extract service name and method
        const dot_idx = std.mem.indexOf(u8, method_name, ".") orelse return;
        const service_name = method_name[0..dot_idx];
        
        const service = self.services.get(service_name) orelse return;
        
        // Call handler
        const response = handler(service, method_name, body) catch |err| {
            std.log.err("Handler error: {any}", .{err});
            return;
        };
        defer self.allocator.free(response);
        
        // Send response
        const resp_header = RpcHeader{
            .magic = RPC_MAGIC,
            .version = RPC_VERSION,
            .method_len = 0,
            .body_len = @intCast(response.len),
        };
        
        _ = writer.write(std.mem.asBytes(&resp_header)) catch {};
        _ = writer.write(response) catch {};
    }

    /// Stop the server
    pub fn stop(self: *Server) void {
        self.running.store(false, .monotonic);
        if (self.listener) |*l| {
            l.deinit();
            self.listener = null;
        }
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
            inline for (@typeInfo(T).Struct.decls) |decl| {
                if (comptime std.mem.startsWith(u8, decl.name, "rpc_")) {
                    methods = methods ++ .{decl.name[4..]};
                }
            }
            return methods;
        }
    };
}

test "rpc client" {
    const cfg = ClientConfig{
        .target = "127.0.0.1",
        .port = 18080,
    };
    
    var client = Client.init(std.testing.allocator, cfg);
    defer client.deinit();

    // Note: This test requires a running RPC server
    // Skip in CI environment
    if (true) return error.SkipZigTest;
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