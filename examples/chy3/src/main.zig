//! chy3 — Creator Metaverse Platform
//!
//! Demonstrates ZigZero across three business domains:
//! 1. 问题域 (Problem Domain) — Creator pain point discovery
//! 2. 解决域 (Solution Domain) — Asset minting, marketplace, royalties
//! 3. 世界域 (World Domain) — Persistent narrative worlds with NPCs, quests
//!
//! Architecture:
//!   main.zig       — Server wiring, lifecycle, route registration
//!   context.zig    — AppContext: shared state + metric registry
//!   types.zig      — Request / response DTOs
//!   domain/
//!     problem.zig  — 问题域 handlers
//!     solution.zig — 解决域 handlers
//!     world.zig    — 世界域 handlers
//!   infra/
//!     metrics.zig   — Prometheus metric initialization
//!     middleware.zig — Middleware factory functions

const std = @import("std");
const zigzero = @import("zigzero");
const api = zigzero.api;
const log = zigzero.log;
const metric = zigzero.metric;
const health = zigzero.health;
const limiter = zigzero.limiter;
const lifecycle = zigzero.lifecycle;
const load = zigzero.load;

const context = @import("context.zig");
const AppContext = context.AppContext;

const problem = @import("domain/problem.zig");
const solution = @import("domain/solution.zig");
const world = @import("domain/world.zig");

const infra_middleware = @import("infra/middleware.zig");

// ============================================================================
// Observability handlers
// ============================================================================

fn handleHealth(ctx: *api.Context) !void {
    try ctx.jsonStruct(200, .{
        .status = "healthy",
        .uptime_seconds = 86400,
        .version = "0.1.0",
        .domains = .{
            .problem = "operational",
            .solution = "operational",
            .world = "operational",
        },
    });
}

fn handleMetrics(ctx: *api.Context) !void {
    const registry = @as(*metric.Registry, @ptrCast(@alignCast(ctx.user_data.?)));
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(ctx.allocator);
    try registry.exportPrometheus(buf.writer(ctx.allocator));
    try ctx.setHeader("Content-Type", "text/plain; version=0.0.4; charset=utf-8");
    try ctx.response_body.appendSlice(ctx.allocator, buf.items);
    ctx.responded = true;
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // --- Infrastructure: metrics -----------------------------------------
    var registry = metric.Registry.init(allocator);
    defer registry.deinit();

    // --- Infrastructure: health checks ------------------------------------
    var health_registry = health.Registry.init(allocator);
    defer health_registry.deinit();
    try health_registry.register("memory", health.checks.memory);
    try health_registry.register("disk", health.checks.disk);

    // --- Infrastructure: rate limiter -------------------------------------
    var ip_limiter = limiter.IpLimiter.init(allocator, 100.0, 10);
    defer ip_limiter.deinit();

    // --- Infrastructure: adaptive load shedder ----------------------------
    var shedder = try load.newAdaptiveShedder(allocator, .{
        .window_ms = 1000,
        .buckets = 10,
        .cpu_threshold = 80,
    });
    defer shedder.deinit();

    // --- Infrastructure: lifecycle manager --------------------------------
    var lc = lifecycle.Manager.init(allocator);
    defer lc.deinit();

    // --- App context: shared state ----------------------------------------
    var app = AppContext.init(allocator, &registry);

    // --- HTTP server -----------------------------------------------------
    const logger = log.Logger.new(.info, "chy3-server");
    var server = api.Server.init(allocator, 8080, logger);
    defer server.deinit();

    // Global middleware
    const global_mws = try infra_middleware.globalMiddleware(
        allocator,
        &registry,
        &ip_limiter,
        &shedder,
    );
    for (global_mws) |mw| {
        try server.addMiddleware(mw);
    }
    // Note: global_mws slice is heap-allocated; it lives for the
    // lifetime of main() and is implicitly deinit'd via defer.

    // Observability routes
    try server.addRoute(.{
        .method = .GET,
        .path = "/health",
        .handler = handleHealth,
    });
    try server.addRoute(.{
        .method = .GET,
        .path = "/metrics",
        .handler = handleMetrics,
        .user_data = &registry,
    });

    // Per-route middleware factories
    const mw_mint = try infra_middleware.mintAssetMiddleware(allocator);
    const mw_world_create = try infra_middleware.worldCreateMiddleware(allocator);
    const mw_npc_spawn = try infra_middleware.npcSpawnMiddleware(allocator);
    const mw_quest = try infra_middleware.questIssueMiddleware(allocator);
    const mw_subscribe = try infra_middleware.subscribeMiddleware(allocator);
    const mw_problem_submit = try infra_middleware.problemSubmitMiddleware(allocator);

    // ---- Domain 1: 问题域 (Problem Domain) -------------------------------
    {
        var g = server.group("/api/v1/problems");
        try server.addRoute(.{
            .method = .POST,
            .path = "/api/v1/problems/submit",
            .handler = problem.handleSubmitPainPoint,
            .middleware = mw_problem_submit,
            .user_data = &app,
        });
        try g.get("/heatmap", problem.handleGetHeatmap);
    }

    // ---- Domain 2: 解决域 (Solution Domain) -----------------------------
    {
        try server.addRoute(.{
            .method = .POST,
            .path = "/api/v1/assets/mint",
            .handler = solution.handleMintAsset,
            .middleware = mw_mint,
            .user_data = &app,
        });
    }
    {
        var g = server.group("/api/v1/marketplace");
        try g.get("/list", solution.handleListMarketplace);
    }
    {
        try server.addRoute(.{
            .method = .POST,
            .path = "/api/v1/subscriptions/subscribe",
            .handler = solution.handleSubscribe,
            .middleware = mw_subscribe,
            .user_data = &app,
        });
    }
    try server.addRoute(.{
        .method = .GET,
        .path = "/api/v1/royalties",
        .handler = solution.handleRoyalties,
    });

    // ---- Domain 3: 世界域 (World Domain) ---------------------------------
    {
        var g = server.group("/api/v1/worlds");
        try server.addRoute(.{
            .method = .POST,
            .path = "/api/v1/worlds/create",
            .handler = world.handleCreateWorld,
            .middleware = mw_world_create,
            .user_data = &app,
        });
        try server.addRoute(.{
            .method = .POST,
            .path = "/api/v1/worlds/:world_id/npcs",
            .handler = world.handleSpawnNPC,
            .middleware = mw_npc_spawn,
            .user_data = &app,
        });
        try g.post("/:world_id/events", world.handleTriggerEvent);
        try server.addRoute(.{
            .method = .POST,
            .path = "/api/v1/worlds/:world_id/quests",
            .handler = world.handleIssueQuest,
            .middleware = mw_quest,
            .user_data = &app,
        });
        try server.addRoute(.{
            .method = .GET,
            .path = "/api/v1/worlds/stats",
            .handler = world.handleWorldStats,
            .user_data = infra_middleware.metricsUserData(&registry),
        });
    }

    std.debug.print(
        \\
        \\chy3 — Creator Metaverse Platform
        \\============================================================
        \\  问题域 (Problem)  Pain point discovery → /api/v1/problems/*
        \\  解决域 (Solution) Creator tools      → /api/v1/assets/* /marketplace/* /subscriptions/*
        \\  世界域 (World)   Metaverse engine   → /api/v1/worlds/*
        \\  Observability                    → /health /metrics
        \\============================================================
        \\
    , .{});

    try server.start();
    lc.run();
    lc.shutdown();
}
