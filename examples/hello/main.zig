const std = @import("std");
const zigzero = @import("zigzero");
const api = zigzero.api;
const compat = zigzero.compat;
const log = zigzero.log;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    compat.initIo(allocator);
    defer compat.deinitIo();

    const logger = log.Logger.new(.info, "hello");

    var server = api.Server.init(allocator, 8080, logger);
    defer server.deinit();

    // Hello endpoint
    try server.addRoute(.{
        .method = .GET,
        .path = "/hello",
        .handler = struct {
            fn handle(ctx: *api.Context) !void {
                try ctx.text(200, "Hello from zigzero!");
            }
        }.handle,
    });

    logger.info("Starting hello server on port 8080");
    try server.start();
}
