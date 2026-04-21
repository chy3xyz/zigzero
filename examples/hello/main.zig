const std = @import("std");
const zigzero = @import("zigzero");
const api = zigzero.api;
const log = zigzero.log;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    _ = allocator;
    // Initialize logger
    log.initFromConfig(.{
        .service_name = "hello-api",
        .level = "info",
    });
    const logger = log.Logger.new(.info, "hello-api");

    // Create server
    var server = api.Server.init(allocator, 8080, logger);
    defer server.deinit();

    // Add health check endpoint
    try server.addRoute(.{
        .method = .GET,
        .path = "/health",
        .handler = struct {
            fn handle(_: *api.Context) !void {
                std.debug.print("Health check called\n", .{});
            }
        }.handle,
    });

    // Add hello endpoint
    try server.addRoute(.{
        .method = .GET,
        .path = "/hello/:name",
        .handler = struct {
            fn handle(ctx: *api.Context) !void {
                const name = ctx.param("name") orelse "World";
                std.debug.print("Hello, {s}!\n", .{name});
            }
        }.handle,
    });

    // Add JSON POST endpoint
    try server.addRoute(.{
        .method = .POST,
        .path = "/echo",
        .handler = struct {
            fn handle(ctx: *api.Context) !void {
                if (ctx.body) |body| {
                    std.debug.print("Received: {s}\n", .{body});
                }
            }
        }.handle,
    });

    logger.info("Starting server on port 8080");
    try server.start();
}
