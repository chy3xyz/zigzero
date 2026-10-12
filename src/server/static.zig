//! Static file server for zigzero
//!
//! Provides static file serving with MIME type detection.

const std = @import("std");
const compat = @import("../compat.zig");
const errors = @import("../core/errors.zig");
const api = @import("../net/api.zig");

/// Static file server
pub const Server = struct {
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    index_file: []const u8,

    pub fn init(allocator: std.mem.Allocator, root_dir: []const u8) Server {
        return .{
            .allocator = allocator,
            .root_dir = root_dir,
            .index_file = "index.html",
        };
    }

    /// Create an API handler for serving static files.
    ///
    /// A handler function has no state of its own, so the route must carry this
    /// server as its `user_data`, and the path should end in a wildcard so the
    /// whole remainder reaches the handler:
    /// ```zig
    /// var statics = static.Server.init(allocator, "./public");
    /// try server.addRoute(.{
    ///     .method = .GET,
    ///     .path = "/*file",          // or "/static/*file" for a prefix
    ///     .handler = statics.handler(),
    ///     .user_data = &statics,
    /// });
    /// ```
    /// The captured name is unused: the handler serves `ctx.raw_path`.
    pub fn handler(self: *const Server) api.HandlerFn {
        _ = self;
        return serveStatic;
    }
};

fn serveStatic(ctx: *api.Context) !void {
    const s: *const Server = @ptrCast(@alignCast(ctx.user_data orelse {
        try ctx.sendError(500, "static server not attached to this route");
        return;
    }));

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&path_buf, "{s}{s}", .{ s.root_dir, ctx.raw_path });

    // Resolve to a canonical path so the traversal check below compares real
    // directories rather than the raw request string.
    var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved_len = compat.cwd().realPathFile(compat.io(), file_path, &resolved_buf) catch {
        try ctx.sendError(404, "not found");
        return;
    };
    const resolved = resolved_buf[0..resolved_len];

    // Ensure the resolved path is within root_dir
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = compat.cwd().realPathFile(compat.io(), s.root_dir, &root_buf) catch {
        try ctx.sendError(500, "server error");
        return;
    };
    const root_real = root_buf[0..root_len];

    // A plain prefix test would accept a sibling like "<root>-evil", so the
    // character after the prefix must be a separator (or the paths must match).
    const within_root = std.mem.eql(u8, resolved, root_real) or
        (std.mem.startsWith(u8, resolved, root_real) and
            resolved.len > root_real.len and
            resolved[root_real.len] == std.fs.path.sep);
    if (!within_root) {
        try ctx.sendError(403, "forbidden");
        return;
    }

    // Try to read file
    const content = compat.cwd().readFileAlloc(compat.io(), resolved, ctx.allocator, .limited(10 * 1024 * 1024)) catch {
        try ctx.sendError(404, "not found");
        return;
    };
    defer ctx.allocator.free(content);

    const content_type = guessMimeType(resolved);
    try ctx.setHeader("Content-Type", content_type);

    // Generate ETag based on file metadata
    const file_stat = compat.cwd().statFile(compat.io(), resolved, .{}) catch {
        try ctx.sendError(500, "server error");
        return;
    };
    var etag_buf: [64]u8 = undefined;
    const etag = try std.fmt.bufPrint(&etag_buf, "\"{x}-{x}\"", .{ file_stat.mtime.nanoseconds, file_stat.size });
    try ctx.setHeader("ETag", etag);
    try ctx.setHeader("Cache-Control", "public, max-age=3600");

    // Check If-None-Match for 304 response
    if (ctx.header("If-None-Match")) |client_etag| {
        if (std.mem.eql(u8, client_etag, etag)) {
            ctx.status_code = 304;
            ctx.responded = true;
            return;
        }
    }

    try ctx.response_body.appendSlice(ctx.allocator, content);
    ctx.responded = true;
}

/// Guess MIME type from file extension
pub fn guessMimeType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const map = .{
        .{ ".html", "text/html" },
        .{ ".htm", "text/html" },
        .{ ".css", "text/css" },
        .{ ".js", "application/javascript" },
        .{ ".json", "application/json" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".svg", "image/svg+xml" },
        .{ ".ico", "image/x-icon" },
        .{ ".txt", "text/plain" },
        .{ ".xml", "application/xml" },
        .{ ".pdf", "application/pdf" },
        .{ ".zip", "application/zip" },
        .{ ".wasm", "application/wasm" },
    };

    inline for (map) |entry| {
        if (std.mem.eql(u8, ext, entry[0])) return entry[1];
    }

    return "application/octet-stream";
}

test "static server serves a file and refuses traversal" {
    const allocator = std.testing.allocator;
    const root = ".test-static";
    compat.cwd().deleteTree(compat.io(), root) catch {};
    try compat.cwd().createDirPath(compat.io(), root);
    defer compat.cwd().deleteTree(compat.io(), root) catch {};
    try compat.cwd().writeFile(compat.io(), .{ .sub_path = root ++ "/hello.txt", .data = "static body" });

    try compat.cwd().createDirPath(compat.io(), root ++ "/assets/css");
    try compat.cwd().writeFile(compat.io(), .{ .sub_path = root ++ "/assets/css/app.css", .data = "body{}" });

    var server = Server.init(allocator, root);
    const handler = server.handler();

    const logger = @import("../infra/log.zig").Logger.new(.off, "test");
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    defer {
        arena.deinit();
        allocator.destroy(arena);
    }

    // A real file: 200 with the file's bytes.
    var ctx = try api.Context.init(arena.allocator(), .GET, "/hello.txt", logger);
    ctx.user_data = &server;
    try handler(&ctx);
    try std.testing.expectEqual(@as(u16, 200), ctx.status_code);
    try std.testing.expectEqualStrings("static body", ctx.response_body.items);

    // A traversal attempt must not escape the root: the target exists (it is
    // this repo's build.zig), so the rejection is 403, not 404.
    var escaped = try api.Context.init(arena.allocator(), .GET, "/../build.zig", logger);
    escaped.user_data = &server;
    try handler(&escaped);
    try std.testing.expectEqual(@as(u16, 403), escaped.status_code);

    // A nested file is served through the same handler (the route pattern is
    // "/*file", so the whole remainder arrives as raw_path).
    var nested = try api.Context.init(arena.allocator(), .GET, "/assets/css/app.css", logger);
    nested.user_data = &server;
    try handler(&nested);
    try std.testing.expectEqual(@as(u16, 200), nested.status_code);
    try std.testing.expectEqualStrings("body{}", nested.response_body.items);

    // A sibling directory sharing the root's prefix must not pass either.
    var sibling = try api.Context.init(arena.allocator(), .GET, "/../.test-static-evil/hello.txt", logger);
    sibling.user_data = &server;
    try handler(&sibling);
    try std.testing.expectEqual(@as(u16, 404), sibling.status_code);
}

test "mime type guessing" {
    try std.testing.expectEqualStrings("text/html", guessMimeType("index.html"));
    try std.testing.expectEqualStrings("application/json", guessMimeType("data.json"));
    try std.testing.expectEqualStrings("image/png", guessMimeType("logo.png"));
    try std.testing.expectEqualStrings("application/octet-stream", guessMimeType("unknown"));
}
