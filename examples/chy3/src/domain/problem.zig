//! 问题域 (Problem Domain) — Creator pain point discovery
//!
//! Handles:
//! - POST /api/v1/problems/submit  — Submit a creator pain point with AI clustering
//! - GET  /api/v1/problems/heatmap — Aggregated problem heatmap

const std = @import("std");
const api = zigzero.api;
const zigzero = @import("zigzero");
const context = @import("../context.zig");
const types = @import("../types.zig");

const ProblemSubmitReq = types.ProblemSubmitReq;
const AppContext = context.AppContext;

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

fn getApp(ctx: *api.Context) *AppContext {
    return @as(*AppContext, @ptrCast(@alignCast(ctx.user_data.?)));
}

pub fn handleSubmitPainPoint(ctx: *api.Context) !void {
    const app = getApp(ctx);
    const req = try ctx.bindJson(ProblemSubmitReq);

    app.problem_count += 1;
    const pid = try std.fmt.allocPrint(ctx.allocator, "p{d}", .{app.problem_count});
    defer ctx.allocator.free(pid);

    try ctx.jsonStruct(200, .{
        .problem_id = pid,
        .category = req.category,
        .ai_insight = app.getProblemInsight(req.category),
        .total_pain_points = app.problem_count,
    });
}

pub fn handleGetHeatmap(ctx: *api.Context) !void {
    // Static heatmap — in production this would aggregate real submissions
    try ctx.jsonStruct(200, .{
        .heatmap = &.{
            .{ .category = "monetization", .score = 92, .count = 12847 },
            .{ .category = "discovery", .score = 87, .count = 9432 },
            .{ .category = "ip_protection", .score = 78, .count = 7234 },
            .{ .category = "collaboration", .score = 65, .count = 5102 },
            .{ .category = "tooling", .score = 54, .count = 3891 },
            .{ .category = "distribution", .score = 48, .count = 2934 },
            .{ .category = "analytics", .score = 41, .count = 2103 },
        },
    });
}
