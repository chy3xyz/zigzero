//! Static file server for zigzero
//!
//! Provides static file serving with MIME type detection.

const std = @import("std");
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

    /// Create an API handler for serving static files
    pub fn handler(self: *const Server) api.HandlerFn {
        const s = self;
        return struct {
            fn handle(ctx: *api.Context) !void {
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const file_path = try std.fmt.bufPrint(&path_buf, "{s}{s}", .{ s.root_dir, ctx.raw_path });

                // Security: prevent directory traversal
                const resolved = std.fs.cwd().realpath(file_path, &path_buf) catch {
                    try ctx.sendError(404, "not found");
                    return;
                };

                // Ensure the resolved path is within root_dir
                var root_buf: [std.fs.max_path_bytes]u8 = undefined;
                const root_real = std.fs.cwd().realpath(s.root_dir, &root_buf) catch {
                    try ctx.sendError(500, "server error");
                    return;
                };

                if (!std.mem.startsWith(u8, resolved, root_real)) {
                    try ctx.sendError(403, "forbidden");
                    return;
                }

                // Try to read file
                const file = std.fs.cwd().openFile(resolved, .{}) catch {
                    try ctx.sendError(404, "not found");
                    return;
                };
                defer file.close();

                const content = file.readToEndAlloc(ctx.allocator, 10 * 1024 * 1024) catch {
                    try ctx.sendError(500, "server error");
                    return;
                };
                defer ctx.allocator.free(content);

                const content_type = guessMimeType(resolved);
                try ctx.setHeader("Content-Type", content_type);

                // Generate ETag based on file metadata
                const file_stat = file.stat() catch {
                    try ctx.sendError(500, "server error");
                    return;
                };
                var etag_buf: [64]u8 = undefined;
                const etag = try std.fmt.bufPrint(&etag_buf, "\"{x}-{x}\"", .{ file_stat.mtime, file_stat.size });
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
        }.handle;
    }
};

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

test "mime type guessing" {
    try std.testing.expectEqualStrings("text/html", guessMimeType("index.html"));
    try std.testing.expectEqualStrings("application/json", guessMimeType("data.json"));
    try std.testing.expectEqualStrings("image/png", guessMimeType("logo.png"));
    try std.testing.expectEqualStrings("application/octet-stream", guessMimeType("unknown"));
}
