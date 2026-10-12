//! HTTP API server for zigzero
//!
//! Provides HTTP server with routing, middleware, and handlers.
//! Aligned with go-zero's rest package.

const std = @import("std");
const compat = @import("../compat.zig");
const errors = @import("../core/errors.zig");
const log = @import("../infra/log.zig");
const trace = @import("../infra/trace.zig");
const validate = @import("../data/validate.zig");

/// HTTP method
pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,

    pub fn fromString(s: []const u8) Method {
        if (std.mem.eql(u8, s, "GET")) return .GET;
        if (std.mem.eql(u8, s, "POST")) return .POST;
        if (std.mem.eql(u8, s, "PUT")) return .PUT;
        if (std.mem.eql(u8, s, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, s, "PATCH")) return .PATCH;
        if (std.mem.eql(u8, s, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, s, "OPTIONS")) return .OPTIONS;
        return .GET;
    }

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

/// HTTP handler function type
pub const HandlerFn = *const fn (*Context) anyerror!void;

/// Middleware function type with optional user data
pub const MiddlewareFn = *const fn (*Context, HandlerFn, ?*anyopaque) anyerror!void;

/// Middleware wrapper with optional state
pub const Middleware = struct {
    func: MiddlewareFn,
    user_data: ?*anyopaque = null,
};

/// Route definition
pub const Route = struct {
    method: Method,
    path: []const u8,
    handler: HandlerFn,
    middleware: []const Middleware = &.{},
    user_data: ?*anyopaque = null,
};

/// Field source for auto parameter binding
pub const FieldSource = enum {
    path,
    query,
    form,
    header,
};

/// HTTP context - holds request/response data
pub const Context = struct {
    allocator: std.mem.Allocator,
    method: Method,
    path: []const u8,
    raw_path: []const u8,
    query: std.StringHashMap([]const u8),
    params: std.StringHashMap([]const u8),
    headers: std.StringHashMap([]const u8),
    form: std.StringHashMap([]const u8),
    body: ?[]const u8 = null,
    response_body: std.ArrayList(u8),
    status_code: u16 = 200,
    response_headers: std.StringHashMap([]const u8),
    responded: bool = false,
    logger: log.Logger,
    user_data: ?*anyopaque = null,
    trace_context: ?trace.TraceContext = null,
    validation_error_message: ?[]const u8 = null,
    stream: ?compat.net.Stream = null,
    upgraded: bool = false,
    /// Wall-clock millisecond deadline set by `middleware.requestTimeout`, for
    /// handlers that want to stop early. Nothing preempts a running handler.
    deadline_ms: ?i64 = null,

    // Middleware chain fields
    chain_middlewares: []const Middleware = &.{},
    chain_handler: *const fn (*Context) anyerror!void = undefined,
    chain_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator, method: Method, path: []const u8, logger: log.Logger) !Context {
        return Context{
            .allocator = allocator,
            .method = method,
            .path = path,
            .raw_path = path,
            .query = std.StringHashMap([]const u8).init(allocator),
            .params = std.StringHashMap([]const u8).init(allocator),
            .headers = std.StringHashMap([]const u8).init(allocator),
            .form = std.StringHashMap([]const u8).init(allocator),
            .response_body = std.ArrayList(u8).empty,
            .response_headers = std.StringHashMap([]const u8).init(allocator),
            .logger = logger,
        };
    }

    pub fn deinit(self: *Context) void {
        var query_iter = self.query.iterator();
        while (query_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.query.deinit();

        var params_iter = self.params.iterator();
        while (params_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.params.deinit();

        var headers_iter = self.headers.iterator();
        while (headers_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();

        var form_iter = self.form.iterator();
        while (form_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.form.deinit();

        self.response_body.deinit(self.allocator);

        var resp_headers_iter = self.response_headers.iterator();
        while (resp_headers_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.response_headers.deinit();

        if (self.validation_error_message) |msg| {
            self.allocator.free(msg);
        }
    }

    /// Get query parameter
    pub fn queryParam(self: *const Context, key: []const u8) ?[]const u8 {
        return self.query.get(key);
    }

    /// Get path parameter
    pub fn param(self: *const Context, key: []const u8) ?[]const u8 {
        return self.params.get(key);
    }

    /// Get header
    pub fn header(self: *const Context, key: []const u8) ?[]const u8 {
        return self.headers.get(key);
    }

    /// Get form value
    pub fn formValue(self: *const Context, key: []const u8) ?[]const u8 {
        return self.form.get(key);
    }

    /// Set response header
    pub fn setHeader(self: *Context, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.response_headers.put(key_copy, value_copy);
    }

    /// Set JSON response
    pub fn json(self: *Context, status: u16, data: []const u8) !void {
        self.status_code = status;
        try self.setHeader("Content-Type", "application/json");
        try self.response_body.appendSlice(self.allocator, data);
        self.responded = true;
    }

    /// Set plain text response
    pub fn text(self: *Context, status: u16, data: []const u8) !void {
        self.status_code = status;
        try self.setHeader("Content-Type", "text/plain");
        try self.response_body.appendSlice(self.allocator, data);
        self.responded = true;
    }

    /// Send error response
    pub fn sendError(self: *Context, status: u16, message: []const u8) !void {
        self.status_code = status;
        try self.setHeader("Content-Type", "application/json");
        const err_json = try std.fmt.allocPrint(self.allocator, "{{\"code\":{d},\"message\":\"{s}\"}}", .{ status, message });
        defer self.allocator.free(err_json);
        try self.response_body.appendSlice(self.allocator, err_json);
        self.responded = true;
    }

    /// Send structured error response
    pub fn sendErrorResponse(self: *Context, status: u16, resp: errors.ErrorResponse) !void {
        self.status_code = status;
        try self.setHeader("Content-Type", "application/json");
        const err_json = try errors.toJson(self.allocator, resp);
        defer self.allocator.free(err_json);
        try self.response_body.appendSlice(self.allocator, err_json);
        self.responded = true;
    }

    /// Parse JSON body into type T
    ///
    /// The value is parsed into the request arena (`self.allocator`), which the
    /// server tears down when the request ends — `parseFromSlice` would free its
    /// own arena before returning and leave every slice inside T dangling.
    pub fn bindJson(self: *const Context, comptime T: type) !T {
        if (self.body == null) return error.NoBody;
        return std.json.parseFromSliceLeaky(T, self.allocator, self.body.?, .{ .allocate = .alloc_always }) catch return error.InvalidJson;
    }

    /// Parse JSON body into type T and validate against comptime rules.
    /// On validation failure, stores the error message in `validation_error_message`
    /// and returns `error.ValidationError`. Caller should free `validation_error_message`.
    pub fn bindJsonAndValidate(self: *Context, comptime T: type, comptime rules: anytype) !T {
        const value = try self.bindJson(T);
        if (try validate.validateStruct(self.allocator, value, rules)) |msg| {
            self.validation_error_message = msg;
            return error.ValidationError;
        }
        return value;
    }

    /// Send JSON from struct
    pub fn jsonStruct(self: *Context, status: u16, value: anytype) !void {
        self.status_code = status;
        try self.setHeader("Content-Type", "application/json");
        const json_str = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(value, .{})});
        defer self.allocator.free(json_str);
        try self.response_body.appendSlice(self.allocator, json_str);
        self.responded = true;
    }

    /// Auto-bind request parameters into a struct.
    /// `sources` maps struct field names to their HTTP source locations.
    /// Example: `const req = try ctx.parseReq(MyReq, .{ .id = .path, .page = .query });`
    pub fn parseReq(self: *Context, comptime T: type, sources: anytype) !T {
        const SourcesType = @TypeOf(sources);
        const sources_info = @typeInfo(SourcesType);
        if (sources_info != .@"struct") @compileError("sources must be a struct literal");

        var req: T = undefined;
        const t_info = @typeInfo(T);
        if (t_info != .@"struct") @compileError("T must be a struct");

        const s_info = t_info.@"struct";
        inline for (s_info.field_names, s_info.field_types) |field_name, FieldType| {
            const has_source = @hasField(SourcesType, field_name);
            if (!has_source) continue;

            const source: FieldSource = @field(sources, field_name);
            const value_str: ?[]const u8 = switch (source) {
                .path => self.params.get(field_name),
                .query => self.query.get(field_name),
                .form => self.form.get(field_name),
                .header => self.headers.get(field_name),
            };

            if (value_str) |v| {
                @field(req, field_name) = try parseValue(FieldType, v);
            } else {
                // If field is optional, leave as null
                if (@typeInfo(FieldType) == .optional) {
                    @field(req, field_name) = null;
                } else {
                    return error.MissingParameter;
                }
            }
        }

        return req;
    }
};

fn parseValue(comptime T: type, value: []const u8) !T {
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, value, 10),
        .float => std.fmt.parseFloat(T, value),
        .bool => std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1"),
        .pointer => |ptr| switch (ptr.size) {
            .slice => if (ptr.child == u8) value else @compileError("Unsupported slice type in parseValue"),
            else => @compileError("Unsupported pointer type in parseValue"),
        },
        .optional => |opt| if (value.len == 0) null else try parseValue(opt.child, value),
        else => @compileError("Unsupported field type in parseValue"),
    };
}

fn parseFormBody(allocator: std.mem.Allocator, body: []const u8) !std.StringHashMap([]const u8) {
    var form = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var iter = form.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        form.deinit();
    }

    var iter = std.mem.splitScalar(u8, body, '&');
    while (iter.next()) |param| {
        if (param.len == 0) continue;
        if (std.mem.indexOf(u8, param, "=")) |eq_pos| {
            const key = try allocator.dupe(u8, param[0..eq_pos]);
            const value = try allocator.dupe(u8, param[eq_pos + 1 ..]);
            try form.put(key, value);
        }
    }

    return form;
}

/// Simple stream reader wrapper for HTTP parsing
const StreamReader = struct {
    stream: compat.net.Stream,
    buf: [8192]u8 = undefined,
    pos: usize = 0,
    end: usize = 0,

    fn readByte(self: *StreamReader) !?u8 {
        if (self.pos >= self.end) {
            const n = try compat.net.streamRead(self.stream, &self.buf);
            if (n == 0) return null;
            self.pos = 0;
            self.end = n;
        }
        const b = self.buf[self.pos];
        self.pos += 1;
        return b;
    }

    fn readUntilDelimiterOrEof(self: *StreamReader, out: []u8, delimiter: u8) !?[]u8 {
        var i: usize = 0;
        while (i < out.len) {
            const b = try self.readByte() orelse return if (i == 0) null else out[0..i];
            out[i] = b;
            i += 1;
            if (b == delimiter) return out[0..i];
        }
        return error.LineTooLong;
    }

    fn readAll(self: *StreamReader, out: []u8) !usize {
        var total: usize = 0;
        while (total < out.len) {
            // First, drain any buffered bytes
            if (self.pos < self.end) {
                const avail = self.end - self.pos;
                const to_copy = @min(avail, out.len - total);
                @memcpy(out[total..][0..to_copy], self.buf[self.pos..][0..to_copy]);
                self.pos += to_copy;
                total += to_copy;
                continue;
            }
            const n = try compat.net.streamRead(self.stream, out[total..]);
            if (n == 0) break;
            total += n;
        }
        return total;
    }
};

/// HTTP request parser
const RequestParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RequestParser {
        return .{ .allocator = allocator };
    }

    pub fn parse(self: *RequestParser, reader: *StreamReader, max_body_size: usize) !ParsedRequest {
        var buffer: [8192]u8 = undefined;

        // Read request line
        const request_line = try reader.readUntilDelimiterOrEof(&buffer, '\n') orelse return error.InvalidRequest;
        if (request_line.len < 14) return error.InvalidRequest; // Minimum: "GET / HTTP/1.1"

        // Parse method
        const method_end = std.mem.indexOf(u8, request_line, " ") orelse return error.InvalidRequest;
        const method_str = request_line[0..method_end];
        const method = Method.fromString(method_str);

        // Parse path
        const path_start = method_end + 1;
        const path_end = std.mem.indexOfPos(u8, request_line, path_start, " ") orelse return error.InvalidRequest;
        const raw_path = request_line[path_start..path_end];

        // Parse query string
        var path = raw_path;
        var query_map = std.StringHashMap([]const u8).init(self.allocator);

        if (std.mem.indexOf(u8, raw_path, "?")) |query_start| {
            path = raw_path[0..query_start];
            const query_str = raw_path[query_start + 1 ..];

            var qiter = std.mem.splitScalar(u8, query_str, '&');
            while (qiter.next()) |param| {
                if (param.len == 0) continue;
                if (std.mem.indexOf(u8, param, "=")) |eq_pos| {
                    const key = try self.allocator.dupe(u8, param[0..eq_pos]);
                    const value = try self.allocator.dupe(u8, param[eq_pos + 1 ..]);
                    try query_map.put(key, value);
                }
            }
        }

        // `path` and `raw_path` point into `buffer`, which the header loop
        // below reuses; copy them out before headers overwrite the buffer.
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const owned_raw_path = try self.allocator.dupe(u8, raw_path);
        errdefer self.allocator.free(owned_raw_path);

        // Parse headers
        var headers = std.StringHashMap([]const u8).init(self.allocator);
        while (true) {
            const raw = try reader.readUntilDelimiterOrEof(&buffer, '\n') orelse return error.InvalidRequest;
            // The returned line includes the '\n' delimiter unless EOF cut it
            // short; strip it, then strip a trailing CR for CRLF line endings.
            const line = if (raw.len > 0 and raw[raw.len - 1] == '\n') raw[0 .. raw.len - 1] else raw;
            const header_line = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
            if (header_line.len == 0) break; // empty line terminates headers

            if (std.mem.indexOf(u8, header_line, ": ")) |colon_pos| {
                const key = try self.allocator.dupe(u8, header_line[0..colon_pos]);
                const value = try self.allocator.dupe(u8, header_line[colon_pos + 2 ..]);
                try headers.put(key, value);
            }
        }

        // Read body if Content-Length present
        var body: ?[]const u8 = null;
        if (headers.get("Content-Length")) |len_str| {
            const content_len = std.fmt.parseInt(usize, len_str, 10) catch 0;
            if (content_len > max_body_size) return error.BodyTooLarge;
            if (content_len > 0) {
                const body_buf = try self.allocator.alloc(u8, content_len);
                const bytes_read = try reader.readAll(body_buf);
                if (bytes_read == content_len) {
                    body = body_buf;
                } else {
                    self.allocator.free(body_buf);
                }
            }
        }

        return ParsedRequest{
            .method = method,
            .path = owned_path,
            .raw_path = owned_raw_path,
            .query = query_map,
            .headers = headers,
            .body = body,
        };
    }
};

const ParsedRequest = struct {
    method: Method,
    path: []const u8,
    raw_path: []const u8,
    query: std.StringHashMap([]const u8),
    headers: std.StringHashMap([]const u8),
    body: ?[]const u8,

    pub fn deinit(self: *ParsedRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.raw_path);

        var query_iter = self.query.iterator();
        while (query_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.query.deinit();

        var headers_iter = self.headers.iterator();
        while (headers_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();

        if (self.body) |b| allocator.free(b);
    }
};

/// Extract the parameter name from a path segment written as `{name}` or `:name`.
fn parseParamName(segment: []const u8) ?[]const u8 {
    if (segment.len >= 2) {
        if (std.mem.startsWith(u8, segment, "{")) {
            // Tolerate a missing closing brace, e.g. "{id"
            return if (std.mem.endsWith(u8, segment, "}"))
                segment[1 .. segment.len - 1]
            else
                segment[1..];
        }
        if (std.mem.startsWith(u8, segment, ":")) {
            return segment[1..];
        }
    }
    return null;
}

/// Name of a trailing wildcard segment: `*name`, or `*` (bound as "*").
///
/// A wildcard consumes the rest of the path, separators included, so it is only
/// valid as the last segment of a route pattern.
fn parseWildcardName(segment: []const u8) ?[]const u8 {
    if (segment.len >= 1 and segment[0] == '*') {
        return if (segment.len == 1) "*" else segment[1..];
    }
    return null;
}

/// Trie node for the router
const TrieNode = struct {
    segment: []const u8,
    is_param: bool,
    param_name: ?[]const u8,
    is_wildcard: bool,
    wildcard_name: ?[]const u8,
    route: ?Route,
    children: std.ArrayList(*TrieNode),

    pub fn init(allocator: std.mem.Allocator, segment: []const u8) !*TrieNode {
        const node = try allocator.create(TrieNode);
        errdefer allocator.destroy(node);
        node.segment = try allocator.dupe(u8, segment);
        errdefer allocator.free(node.segment);
        node.is_param = false;
        node.param_name = null;
        node.is_wildcard = false;
        node.wildcard_name = null;
        node.route = null;
        node.children = .empty;
        if (parseWildcardName(segment)) |name| {
            node.is_wildcard = true;
            node.wildcard_name = try allocator.dupe(u8, name);
        } else if (parseParamName(segment)) |name| {
            node.is_param = true;
            node.param_name = try allocator.dupe(u8, name);
        }
        return node;
    }

    pub fn deinit(self: *TrieNode, allocator: std.mem.Allocator) void {
        allocator.free(self.segment);
        if (self.param_name) |name| allocator.free(name);
        if (self.wildcard_name) |name| allocator.free(name);
        if (self.route) |route| allocator.free(route.path);
        for (self.children.items) |child| {
            child.deinit(allocator);
        }
        self.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn findChild(self: *const TrieNode, segment: []const u8) ?*TrieNode {
        for (self.children.items) |child| {
            if (std.mem.eql(u8, child.segment, segment)) return child;
        }
        return null;
    }

    pub fn findParamChild(self: *const TrieNode) ?*TrieNode {
        for (self.children.items) |child| {
            if (child.is_param) return child;
        }
        return null;
    }

    pub fn findWildcardChild(self: *const TrieNode) ?*TrieNode {
        for (self.children.items) |child| {
            if (child.is_wildcard) return child;
        }
        return null;
    }

    /// The node's wildcard child, created on demand.
    fn getOrCreateWildcard(self: *TrieNode, allocator: std.mem.Allocator, segment: []const u8) !*TrieNode {
        if (self.findWildcardChild()) |child| return child;
        const child = try TrieNode.init(allocator, segment);
        errdefer child.deinit(allocator);
        try self.children.append(allocator, child);
        return child;
    }
};

/// Router for matching routes using a trie
const Router = struct {
    allocator: std.mem.Allocator,
    roots: std.AutoHashMap(Method, *TrieNode),

    pub fn init(allocator: std.mem.Allocator) Router {
        return .{
            .allocator = allocator,
            .roots = std.AutoHashMap(Method, *TrieNode).init(allocator),
        };
    }

    pub fn deinit(self: *Router) void {
        var iter = self.roots.valueIterator();
        while (iter.next()) |root| {
            root.*.deinit(self.allocator);
        }
        self.roots.deinit();
    }

    pub fn addRoute(self: *Router, route: Route) !void {
        const root = try self.getOrCreateRoot(route.method);

        var parts = std.mem.splitScalar(u8, route.path, '/');
        var current = root;

        while (parts.next()) |part| {
            if (part.len == 0) continue;

            if (parseWildcardName(part) != null) {
                // A wildcard swallows the rest of the path, so a segment after
                // it could never be reached — reject the pattern instead of
                // silently registering something unreachable.
                while (parts.next()) |rest| {
                    if (rest.len != 0) return error.InvalidRoute;
                }
                // A wildcard and a single-segment parameter at the same node
                // match overlapping paths with no way to choose between them.
                if (current.findParamChild() != null) return error.InvalidRoute;
                current = try current.getOrCreateWildcard(self.allocator, part);
                break;
            }

            if (current.findChild(part)) |child| {
                current = child;
            } else {
                if (parseParamName(part) != null and current.findWildcardChild() != null) return error.InvalidRoute;
                const child = try TrieNode.init(self.allocator, part);
                try current.children.append(self.allocator, child);
                current = child;
            }
        }

        // Store route at the endpoint node
        const path_copy = try self.allocator.dupe(u8, route.path);
        var r = route;
        r.path = path_copy;
        current.route = r;
    }

    fn getOrCreateRoot(self: *Router, method: Method) !*TrieNode {
        if (self.roots.get(method)) |root| return root;
        const root = try TrieNode.init(self.allocator, "");
        try self.roots.put(method, root);
        return root;
    }

    pub fn match(self: *const Router, method: Method, path: []const u8) ?MatchedRoute {
        const root = self.roots.get(method) orelse return null;

        var params = std.StringHashMap([]const u8).init(self.allocator);
        errdefer freeParams(self.allocator, &params);

        var parts = std.mem.splitScalar(u8, path, '/');
        var current = root;

        while (parts.next()) |part| {
            if (part.len == 0) continue;

            // Precedence: literal segment, then a single-segment parameter, then
            // a wildcard swallowing this segment and everything after it.
            if (current.findChild(part)) |child| {
                current = child;
                continue;
            }

            if (current.findParamChild()) |param_child| {
                if (!bindParam(self.allocator, &params, param_child.param_name.?, part)) {
                    freeParams(self.allocator, &params);
                    return null;
                }
                current = param_child;
                continue;
            }

            if (current.findWildcardChild()) |wild| {
                // `part` points into `path`, so its offset gives the remainder.
                const offset = @intFromPtr(part.ptr) - @intFromPtr(path.ptr);
                if (!bindParam(self.allocator, &params, wild.wildcard_name.?, path[offset..])) {
                    freeParams(self.allocator, &params);
                    return null;
                }
                current = wild;
                break;
            }

            freeParams(self.allocator, &params);
            return null;
        }

        // `/static/*` also matches the bare `/static` — the wildcard captures "".
        if (current.route == null) {
            if (current.findWildcardChild()) |wild| {
                if (!bindParam(self.allocator, &params, wild.wildcard_name.?, "")) {
                    freeParams(self.allocator, &params);
                    return null;
                }
                current = wild;
            }
        }

        if (current.route) |route| {
            return MatchedRoute{
                .route = route,
                .params = params,
            };
        }

        freeParams(self.allocator, &params);
        return null;
    }
};

/// Release the keys and values captured so far and the map itself.
fn freeParams(allocator: std.mem.Allocator, params: *std.StringHashMap([]const u8)) void {
    var iter = params.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    params.deinit();
}

/// Duplicate `value` into `params` under `name`; false when allocation fails.
fn bindParam(allocator: std.mem.Allocator, params: *std.StringHashMap([]const u8), name: []const u8, value: []const u8) bool {
    const key = allocator.dupe(u8, name) catch return false;
    const val = allocator.dupe(u8, value) catch {
        allocator.free(key);
        return false;
    };
    params.put(key, val) catch {
        allocator.free(key);
        allocator.free(val);
        return false;
    };
    return true;
}

const MatchedRoute = struct {
    route: Route,
    params: std.StringHashMap([]const u8),

    /// Release the captured parameter keys and values.
    pub fn deinit(self: *MatchedRoute, allocator: std.mem.Allocator) void {
        var iter = self.params.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.params.deinit();
    }
};

fn getStatusText(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}

/// HTTP response writer
const ResponseWriter = struct {
    pub fn write(allocator: std.mem.Allocator, stream: compat.net.Stream, status: u16, headers: *const std.StringHashMap([]const u8), body: []const u8) !void {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        const status_text = getStatusText(status);
        try buf.print(allocator, "HTTP/1.1 {d} {s}\r\n", .{ status, status_text });

        var iter = headers.iterator();
        while (iter.next()) |entry| {
            try buf.print(allocator, "{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        try buf.print(allocator, "Content-Length: {d}\r\n", .{body.len});
        try buf.appendSlice(allocator, "\r\n");
        try buf.appendSlice(allocator, body);

        compat.net.streamWrite(stream, buf.items) catch {};
    }
};

/// Route group for organizing routes with common prefix and middleware
pub const RouteGroup = struct {
    prefix: []const u8,
    middleware: []const Middleware,
    server: *Server,
    /// Attached to every route this group registers, so grouped handlers can
    /// reach their state the same way `Server.addRoute` handlers do.
    user_data: ?*anyopaque = null,

    pub fn init(server: *Server, prefix: []const u8) RouteGroup {
        return .{
            .prefix = prefix,
            .middleware = &.{},
            .server = server,
        };
    }

    pub fn withMiddleware(self: RouteGroup, mws: []const Middleware) RouteGroup {
        var group = self;
        group.middleware = mws;
        return group;
    }

    pub fn withUserData(self: RouteGroup, data: ?*anyopaque) RouteGroup {
        var group = self;
        group.user_data = data;
        return group;
    }

    fn fullPath(self: *const RouteGroup, path: []const u8) ![]u8 {
        if (self.prefix.len == 0 or std.mem.eql(u8, path, "/")) {
            return self.server.allocator.dupe(u8, self.prefix);
        }
        // Ensure no double slash
        if (std.mem.endsWith(u8, self.prefix, "/") and std.mem.startsWith(u8, path, "/")) {
            return std.fmt.allocPrint(self.server.allocator, "{s}{s}", .{ self.prefix, path[1..] });
        }
        if (!std.mem.endsWith(u8, self.prefix, "/") and !std.mem.startsWith(u8, path, "/")) {
            return std.fmt.allocPrint(self.server.allocator, "{s}/{s}", .{ self.prefix, path });
        }
        return std.fmt.allocPrint(self.server.allocator, "{s}{s}", .{ self.prefix, path });
    }

    pub fn get(self: *RouteGroup, path: []const u8, handler: HandlerFn) !void {
        try self.handle(.GET, path, handler);
    }

    pub fn post(self: *RouteGroup, path: []const u8, handler: HandlerFn) !void {
        try self.handle(.POST, path, handler);
    }

    pub fn put(self: *RouteGroup, path: []const u8, handler: HandlerFn) !void {
        try self.handle(.PUT, path, handler);
    }

    pub fn delete(self: *RouteGroup, path: []const u8, handler: HandlerFn) !void {
        try self.handle(.DELETE, path, handler);
    }

    pub fn patch(self: *RouteGroup, path: []const u8, handler: HandlerFn) !void {
        try self.handle(.PATCH, path, handler);
    }

    pub fn handle(self: *RouteGroup, method: Method, path: []const u8, handler: HandlerFn) !void {
        const fp = try self.fullPath(path);
        defer self.server.allocator.free(fp);

        // Combine group middleware + any empty per-route middleware
        const mws = try self.server.allocator.alloc(Middleware, self.middleware.len);
        errdefer self.server.allocator.free(mws);
        @memcpy(mws, self.middleware);

        try self.server.addRoute(.{
            .method = method,
            .path = fp,
            .handler = handler,
            .middleware = mws,
            .user_data = self.user_data,
        });
    }
};

/// Server configuration
pub const ServerConfig = struct {
    port: u16 = 8080,
    max_body_size: usize = 8 * 1024 * 1024, // 8MB
    request_timeout_ms: u32 = 30000, // 30s
    worker_threads: u32 = 0, // 0 = CPU count
    max_queue_size: usize = 1024,
};

/// Worker pool for handling connections with bounded queue.
/// Replaces thread-per-connection to prevent thread explosion under load.
const WorkerPool = struct {
    allocator: std.mem.Allocator,
    workers: []std.Thread,
    queue: std.ArrayList(compat.net.Stream),
    mutex: compat.Mutex,
    cond: compat.Condition,
    running: std.atomic.Value(bool),
    max_queue_size: usize,
    server: *Server,
    started_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, server: *Server, worker_count: u32, max_queue_size: usize) !WorkerPool {
        const count = if (worker_count == 0)
            @max(2, std.Thread.getCpuCount() catch 2)
        else
            worker_count;

        const workers = try allocator.alloc(std.Thread, count);
        errdefer allocator.free(workers);

        return WorkerPool{
            .allocator = allocator,
            .workers = workers,
            .queue = std.ArrayList(compat.net.Stream).empty,
            .mutex = .init,
            .cond = .init,
            .running = std.atomic.Value(bool).init(true),
            .max_queue_size = max_queue_size,
            .server = server,
        };
    }

    pub fn start(self: *WorkerPool) !void {
        for (0..self.workers.len) |i| {
            self.workers[i] = try std.Thread.spawn(.{}, workerLoop, .{self});
            self.started_count += 1;
        }
    }

    pub fn deinit(self: *WorkerPool) void {
        self.mutex.lock();
        self.running.store(false, .monotonic);
        self.cond.broadcast();
        self.mutex.unlock();
        for (self.workers[0..self.started_count]) |worker| {
            worker.join();
        }
        self.allocator.free(self.workers);
        self.queue.deinit(self.allocator);
    }

    /// Submit a connection to the pool. Returns false if queue is full (server overloaded).
    pub fn submit(self: *WorkerPool, stream: compat.net.Stream) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.queue.items.len >= self.max_queue_size) {
            return false;
        }

        self.queue.append(self.allocator, stream) catch return false;
        self.cond.signal();
        return true;
    }

    fn workerLoop(self: *WorkerPool) void {
        while (self.running.load(.monotonic)) {
            self.mutex.lock();
            while (self.queue.items.len == 0 and self.running.load(.monotonic)) {
                self.cond.wait(&self.mutex);
            }
            if (!self.running.load(.monotonic)) {
                self.mutex.unlock();
                break;
            }
            const stream = self.queue.orderedRemove(0);
            self.mutex.unlock();

            self.server.handleConnection(stream);
        }
    }
};

/// HTTP server
pub const Server = struct {
    allocator: std.mem.Allocator,
    port: u16,
    router: Router,
    global_middleware: std.ArrayList(Middleware),
    name: []const u8,
    running: std.atomic.Value(bool),
    server_socket: ?compat.net.Server = null,
    logger: log.Logger,
    max_body_size: usize,
    request_timeout_ms: u32,
    worker_pool: ?WorkerPool = null,

    pub fn init(allocator: std.mem.Allocator, port: u16, logger: log.Logger) Server {
        return initWithConfig(allocator, logger, .{ .port = port });
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, logger: log.Logger, config: ServerConfig) Server {
        return .{
            .allocator = allocator,
            .port = config.port,
            .router = Router.init(allocator),
            .global_middleware = std.ArrayList(Middleware).empty,
            .name = "zigzero-api",
            .running = std.atomic.Value(bool).init(false),
            .server_socket = null,
            .logger = logger,
            .max_body_size = config.max_body_size,
            .request_timeout_ms = config.request_timeout_ms,
            .worker_pool = null,
        };
    }

    pub fn deinit(self: *Server) void {
        self.stop();
        if (self.worker_pool) |*pool| {
            pool.deinit();
            self.worker_pool = null;
        }
        self.router.deinit();
        self.global_middleware.deinit(self.allocator);
        if (self.server_socket) |*ss| {
            ss.deinit(compat.io());
        }
    }

    /// Add a route
    pub fn addRoute(self: *Server, route: Route) !void {
        try self.router.addRoute(route);
    }

    /// Create a route group
    pub fn group(self: *Server, prefix: []const u8) RouteGroup {
        return RouteGroup.init(self, prefix);
    }

    /// Add global middleware
    pub fn addMiddleware(self: *Server, mw: Middleware) !void {
        try self.global_middleware.append(self.allocator, mw);
    }

    /// Start the server with worker pool
    pub fn start(self: *Server) !void {
        const addr = compat.net.IpAddress.parseIp4("0.0.0.0", self.port) catch |err| {
            self.logger.err(try std.fmt.allocPrint(self.allocator, "Failed to parse bind address: {any}", .{err}));
            return error.ServerError;
        };

        var server = addr.listen(compat.io(), .{
            .reuse_address = true,
            .kernel_backlog = 128,
        }) catch |err| {
            self.logger.err(try std.fmt.allocPrint(self.allocator, "Failed to listen on port {d}: {any}", .{ self.port, err }));
            return error.ServerError;
        };

        self.server_socket = server;
        self.running.store(true, .monotonic);

        // Initialize worker pool (default: CPU count threads, 1024 queue)
        const pool_config = ServerConfig{};
        self.worker_pool = try WorkerPool.init(self.allocator, self, pool_config.worker_threads, pool_config.max_queue_size);
        try self.worker_pool.?.start();

        self.logger.info(try std.fmt.allocPrint(self.allocator, "Server listening on port {d} with {d} workers", .{
            self.port,
            self.worker_pool.?.workers.len,
        }));

        while (self.running.load(.monotonic)) {
            const stream = server.accept(compat.io()) catch |err| {
                if (!self.running.load(.monotonic)) break;
                self.logger.err(try std.fmt.allocPrint(self.allocator, "Accept error: {any}", .{err}));
                continue;
            };

            if (self.worker_pool) |*pool| {
                if (!pool.submit(stream)) {
                    self.logger.warn(try std.fmt.allocPrint(self.allocator, "Server overloaded, rejecting connection", .{}));
                    const reject_response = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 21\r\n\r\nService Unavailable\r\n";
                    compat.net.streamWrite(stream, reject_response) catch {};
                    compat.net.streamClose(stream);
                }
            } else {
                // Fallback (should never happen)
                compat.net.streamClose(stream);
            }
        }
    }

    /// Stop the server
    pub fn stop(self: *Server) void {
        self.running.store(false, .monotonic);
        if (self.worker_pool) |*pool| {
            pool.cond.broadcast();
        }
        if (self.server_socket) |*ss| {
            ss.deinit(compat.io());
            self.server_socket = null;
        }
    }

    fn handleConnection(self: *Server, stream: compat.net.Stream) void {
        var close_stream = true;
        defer {
            if (close_stream) compat.net.streamClose(stream);
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var stream_reader = StreamReader{ .stream = stream };

        const start_time = compat.milliTimestamp();

        var parser = RequestParser.init(arena_alloc);
        var request = parser.parse(&stream_reader, self.max_body_size) catch |err| {
            const err_msg = std.fmt.allocPrint(arena_alloc, "Parse error: {any}", .{err}) catch "Parse error";
            self.logger.err(err_msg);
            const status: u16 = if (err == error.BodyTooLarge) 413 else 400;
            const msg = if (err == error.BodyTooLarge) "Payload Too Large" else "Bad Request";
            const response = std.fmt.allocPrint(arena_alloc, "HTTP/1.1 {d} {s}\r\n\r\n", .{ status, msg }) catch return;
            compat.net.streamWrite(stream, response) catch {};
            return;
        };
        defer request.deinit(arena_alloc);

        // Find matching route
        const matched = self.router.match(request.method, request.path);

        var ctx = Context.init(arena_alloc, request.method, request.path, self.logger) catch |err| {
            self.logger.err(try std.fmt.allocPrint(arena_alloc, "Context init error: {any}", .{err}));
            return;
        };
        defer ctx.deinit();
        ctx.stream = stream;

        // Copy query params
        var query_iter = request.query.iterator();
        while (query_iter.next()) |entry| {
            const key = arena_alloc.dupe(u8, entry.key_ptr.*) catch continue;
            const value = arena_alloc.dupe(u8, entry.value_ptr.*) catch continue;
            ctx.query.put(key, value) catch {};
        }

        // Copy headers
        var headers_iter = request.headers.iterator();
        while (headers_iter.next()) |entry| {
            const key = arena_alloc.dupe(u8, entry.key_ptr.*) catch continue;
            const value = arena_alloc.dupe(u8, entry.value_ptr.*) catch continue;
            ctx.headers.put(key, value) catch {};
        }

        ctx.body = request.body;
        ctx.raw_path = request.raw_path;

        // Extract trace context from traceparent header
        if (request.headers.get("traceparent")) |tp| {
            if (trace.TraceContext.parseTraceparent(arena_alloc, tp)) |maybe_ctx| {
                ctx.trace_context = maybe_ctx;
            } else |_| {}
        }

        // Parse form body if content-type is application/x-www-form-urlencoded
        if (request.body) |body| {
            const content_type = request.headers.get("Content-Type") orelse "";
            if (std.mem.startsWith(u8, content_type, "application/x-www-form-urlencoded")) {
                ctx.form = parseFormBody(arena_alloc, body) catch ctx.form;
            }
        }

        if (matched) |m| {
            // Copy path params
            var params_iter = m.params.iterator();
            while (params_iter.next()) |entry| {
                const key = arena_alloc.dupe(u8, entry.key_ptr.*) catch continue;
                const value = arena_alloc.dupe(u8, entry.value_ptr.*) catch continue;
                ctx.params.put(key, value) catch {};
            }

            ctx.user_data = m.route.user_data;

            // Execute handler with middleware chain
            self.executeWithMiddleware(&ctx, m.route.handler, m.route.middleware) catch |err| {
                if (!ctx.responded) {
                    ctx.sendError(500, @errorName(err)) catch {};
                }
            };
        } else {
            ctx.sendError(404, "Not Found") catch {};
        }

        // Request timeout: the handler has already run by now, so this can only
        // report the overrun. Answer 408 unless a response is already prepared.
        const elapsed = compat.milliTimestamp() - start_time;
        if (elapsed > self.request_timeout_ms) {
            const timeout_msg = std.fmt.allocPrint(arena_alloc, "Request timeout: {s} {s} took {d}ms", .{ request.method.toString(), request.path, elapsed }) catch "Request timeout";
            self.logger.warn(timeout_msg);
            if (!ctx.responded) {
                ctx.response_body.clearRetainingCapacity();
                ctx.status_code = 408;
                ctx.responded = true;
            }
        }

        if (ctx.upgraded) {
            close_stream = false;
            return;
        }

        // Send response
        ResponseWriter.write(arena_alloc, stream, ctx.status_code, &ctx.response_headers, ctx.response_body.items) catch {};
    }

    fn executeWithMiddleware(self: *Server, ctx: *Context, final_handler: HandlerFn, route_middleware: []const Middleware) !void {
        // Build combined middleware list: global + route-specific
        const total_mw = self.global_middleware.items.len + route_middleware.len;
        const combined = try self.allocator.alloc(Middleware, total_mw);
        defer self.allocator.free(combined);

        @memcpy(combined[0..self.global_middleware.items.len], self.global_middleware.items);
        @memcpy(combined[self.global_middleware.items.len..], route_middleware);

        ctx.chain_middlewares = combined;
        ctx.chain_handler = final_handler;
        ctx.chain_index = 0;

        try runMiddlewareChain(ctx);
    }
};

fn runMiddlewareChain(ctx: *Context) anyerror!void {
    if (ctx.chain_index < ctx.chain_middlewares.len) {
        const mw = ctx.chain_middlewares[ctx.chain_index];
        ctx.chain_index += 1;
        try mw.func(ctx, runMiddlewareChain, mw.user_data);
    } else {
        try ctx.chain_handler(ctx);
    }
}

// Request/Response type wrapper
pub fn Request(comptime T: type) type {
    return struct {
        body: T,
    };
}

pub fn Response(comptime T: type) type {
    return struct {
        status: u16 = 200,
        body: T,
    };
}

/// JSON request/response wrapper
pub fn Json(comptime T: type) type {
    return struct {
        json: T,
    };
}

test "api server" {
    const allocator = std.testing.allocator;
    const logger = log.Logger.new(.info, "test");
    var server = Server.init(allocator, 0, logger);
    defer server.deinit();

    const route = Route{
        .method = .GET,
        .path = "/health",
        .handler = struct {
            fn handle(ctx: *Context) anyerror!void {
                try ctx.json(200, "{\"status\":\"ok\"}");
            }
        }.handle,
    };

    try server.addRoute(route);
    try std.testing.expect(server.port == 0);
}

test "path matching" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    const route = Route{
        .method = .GET,
        .path = "/users/{id}",
        .handler = struct {
            fn handle(ctx: *Context) anyerror!void {
                _ = ctx;
            }
        }.handle,
    };

    try router.addRoute(route);

    var matched = router.match(.GET, "/users/123");
    if (matched) |*m| {
        defer {
            var iter = m.params.iterator();
            while (iter.next()) |entry| {
                std.testing.allocator.free(entry.key_ptr.*);
                std.testing.allocator.free(entry.value_ptr.*);
            }
            m.params.deinit();
        }
        try std.testing.expectEqualStrings("123", m.params.get("id").?);
    } else {
        try std.testing.expect(false);
    }

    const no_match = router.match(.GET, "/posts/123");
    try std.testing.expect(no_match == null);
}

test "path params both syntaxes" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try router.addRoute(.{
        .method = .GET,
        .path = "/users/{id}",
        .handler = struct {
            fn handle(ctx: *Context) anyerror!void {
                _ = ctx;
            }
        }.handle,
    });
    try router.addRoute(.{
        .method = .GET,
        .path = "/posts/:id",
        .handler = struct {
            fn handle(ctx: *Context) anyerror!void {
                _ = ctx;
            }
        }.handle,
    });

    var brace_match = router.match(.GET, "/users/123");
    if (brace_match) |*m| {
        defer {
            var iter = m.params.iterator();
            while (iter.next()) |entry| {
                std.testing.allocator.free(entry.key_ptr.*);
                std.testing.allocator.free(entry.value_ptr.*);
            }
            m.params.deinit();
        }
        try std.testing.expectEqualStrings("123", m.params.get("id").?);
    } else {
        try std.testing.expect(false);
    }

    var colon_match = router.match(.GET, "/posts/456");
    if (colon_match) |*m| {
        defer {
            var iter = m.params.iterator();
            while (iter.next()) |entry| {
                std.testing.allocator.free(entry.key_ptr.*);
                std.testing.allocator.free(entry.value_ptr.*);
            }
            m.params.deinit();
        }
        try std.testing.expectEqualStrings("456", m.params.get("id").?);
    } else {
        try std.testing.expect(false);
    }
}

test "http methods" {
    try std.testing.expectEqual(Method.GET, Method.fromString("GET"));
    try std.testing.expectEqualStrings("POST", Method.POST.toString());
}

test "parse req binding" {
    const allocator = std.testing.allocator;
    const logger = log.Logger.new(.info, "test");
    var ctx = try Context.init(allocator, .GET, "/users/42", logger);
    defer ctx.deinit();

    try ctx.params.put(try allocator.dupe(u8, "id"), try allocator.dupe(u8, "42"));
    try ctx.query.put(try allocator.dupe(u8, "page"), try allocator.dupe(u8, "3"));

    const Req = struct {
        id: u32,
        page: u32,
    };

    const req = try ctx.parseReq(Req, .{ .id = .path, .page = .query });
    try std.testing.expectEqual(@as(u32, 42), req.id);
    try std.testing.expectEqual(@as(u32, 3), req.page);
}

test "route group" {
    const allocator = std.testing.allocator;
    const logger = log.Logger.new(.info, "test");
    var server = Server.init(allocator, 0, logger);
    defer server.deinit();

    var api_group = server.group("/api/v1");
    try api_group.get("/users", struct {
        fn handle(ctx: *Context) anyerror!void {
            try ctx.json(200, "{\"users\":[]}");
        }
    }.handle);

    // Route should exist at /api/v1/users
    const matched = server.router.match(.GET, "/api/v1/users");
    try std.testing.expect(matched != null);
}

test "worker pool queue limits" {
    const allocator = std.testing.allocator;
    const logger = log.Logger.new(.info, "test");
    var server = Server.initWithConfig(allocator, logger, .{
        .port = 0,
        .worker_threads = 2,
        .max_queue_size = 3,
    });
    defer server.deinit();

    // WorkerPool should be initializable even without starting the server
    var pool = try WorkerPool.init(allocator, &server, 2, 3);
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 2), pool.workers.len);
    try std.testing.expectEqual(@as(usize, 3), pool.max_queue_size);

    // Queue bounds are verified by WorkerPool.init parameters;
    // actual stream submission requires a valid connection.
}

test "wildcard route captures the remaining path" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    const noop = struct {
        fn handle(ctx: *Context) anyerror!void {
            _ = ctx;
        }
    }.handle;

    try router.addRoute(.{ .method = .GET, .path = "/static/*file", .handler = noop });

    // Nested paths are captured whole, separators included.
    var nested = router.match(.GET, "/static/css/app.css") orelse return error.TestUnexpectedResult;
    defer nested.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("css/app.css", nested.params.get("file").?);

    var single = router.match(.GET, "/static/logo.png") orelse return error.TestUnexpectedResult;
    defer single.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("logo.png", single.params.get("file").?);

    // The bare prefix matches too, with an empty capture.
    var bare = router.match(.GET, "/static") orelse return error.TestUnexpectedResult;
    defer bare.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", bare.params.get("file").?);

    // A different prefix must not match.
    try std.testing.expect(router.match(.GET, "/public/logo.png") == null);
}

test "literal routes win over the wildcard" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    const noop = struct {
        fn handle(ctx: *Context) anyerror!void {
            _ = ctx;
        }
    }.handle;

    try router.addRoute(.{ .method = .GET, .path = "/static/*rest", .handler = noop });
    try router.addRoute(.{ .method = .GET, .path = "/static/health", .handler = noop });

    // An exact segment is preferred, and captures nothing.
    var exact = router.match(.GET, "/static/health") orelse return error.TestUnexpectedResult;
    defer exact.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), exact.params.count());

    // Everything else falls to the wildcard.
    var other = router.match(.GET, "/static/report.json") orelse return error.TestUnexpectedResult;
    defer other.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("report.json", other.params.get("rest").?);
}

test "a wildcard and a parameter cannot share a node" {
    const noop = struct {
        fn handle(ctx: *Context) anyerror!void {
            _ = ctx;
        }
    }.handle;

    // A wildcard matches the same single segment a parameter would, with no way
    // to choose between them, so the second registration is rejected.
    var with_wildcard = Router.init(std.testing.allocator);
    defer with_wildcard.deinit();
    try with_wildcard.addRoute(.{ .method = .GET, .path = "/files/*rest", .handler = noop });
    try std.testing.expectError(error.InvalidRoute, with_wildcard.addRoute(.{ .method = .GET, .path = "/files/:name", .handler = noop }));

    var with_param = Router.init(std.testing.allocator);
    defer with_param.deinit();
    try with_param.addRoute(.{ .method = .GET, .path = "/files/:name", .handler = noop });
    try std.testing.expectError(error.InvalidRoute, with_param.addRoute(.{ .method = .GET, .path = "/files/*rest", .handler = noop }));
}

test "a wildcard must be the last segment" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try std.testing.expectError(error.InvalidRoute, router.addRoute(.{
        .method = .GET,
        .path = "/static/*rest/more",
        .handler = struct {
            fn handle(ctx: *Context) anyerror!void {
                _ = ctx;
            }
        }.handle,
    }));
}

test "server config defaults" {
    const cfg = ServerConfig{};
    try std.testing.expectEqual(@as(u16, 8080), cfg.port);
    try std.testing.expectEqual(@as(usize, 8 * 1024 * 1024), cfg.max_body_size);
    try std.testing.expectEqual(@as(u32, 30000), cfg.request_timeout_ms);
    try std.testing.expectEqual(@as(u32, 0), cfg.worker_threads);
    try std.testing.expectEqual(@as(usize, 1024), cfg.max_queue_size);
}

test "bindJson keeps slice fields alive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var ctx = try Context.init(arena.allocator(), .POST, "/users", log.Logger.new(.off, "test"));
    defer ctx.deinit();
    ctx.body = "{\"name\":\"zigzero\",\"age\":3}";

    const User = struct { name: []const u8, age: u32 };
    const user = try ctx.bindJson(User);

    // Used to read freed memory: the parse arena was torn down on return.
    try std.testing.expectEqualStrings("zigzero", user.name);
    try std.testing.expectEqual(@as(u32, 3), user.age);
}
