//! 世界域 (World Domain) — Persistent narrative metaverse engine
//!
//! Handles:
//! - POST /api/v1/worlds/create          — Create a persistent narrative world
//! - POST /api/v1/worlds/:id/npcs       — Spawn AI-driven NPCs
//! - POST /api/v1/worlds/:id/events     — Trigger narrative events
//! - POST /api/v1/worlds/:id/quests    — Issue quests to players
//! - GET  /api/v1/worlds/stats          — World-wide statistics

const std = @import("std");
const api = zigzero.api;
const zigzero = @import("zigzero");
const context = @import("../context.zig");
const types = @import("../types.zig");

const CreateWorldReq = types.CreateWorldReq;
const SpawnNPCReq = types.SpawnNPCReq;
const TriggerEventReq = types.TriggerEventReq;
const IssueQuestReq = types.IssueQuestReq;
const AppContext = context.AppContext;

fn getApp(ctx: *api.Context) *AppContext {
    return @as(*AppContext, @ptrCast(@alignCast(ctx.user_data.?)));
}

// ---------------------------------------------------------------------------
// World Creation
// ---------------------------------------------------------------------------

pub fn handleCreateWorld(ctx: *api.Context) !void {
    const app = getApp(ctx);
    const req = try ctx.bindJson(CreateWorldReq);

    app.world_count += 1;
    const world_id = try std.fmt.allocPrint(
        ctx.allocator,
        "world_{s}_{d}",
        .{ req.name, app.world_count },
    );
    defer ctx.allocator.free(world_id);

    try ctx.jsonStruct(200, .{
        .world_id = world_id,
        .name = req.name,
        .genre = req.genre,
        .status = "active",
        .population = 0,
        .narrative_arc = app.getNarrativeArc(req.genre),
        .chapter = 1,
    });
}

// ---------------------------------------------------------------------------
// NPC Spawning
// ---------------------------------------------------------------------------

pub fn handleSpawnNPC(ctx: *api.Context) !void {
    const app = getApp(ctx);
    const req = try ctx.bindJson(SpawnNPCReq);

    app.npc_count += 1;
    const npc_id = try std.fmt.allocPrint(ctx.allocator, "npc_{d}", .{app.npc_count});
    defer ctx.allocator.free(npc_id);

    try ctx.jsonStruct(200, .{
        .npc_id = npc_id,
        .world_id = req.world_id,
        .npc_type = req.npc_type,
        .status = "alive",
        .location = app.getNpcLocation(req.npc_type),
        .dialogue_tree = "root_greeting",
        .ai_model = "narrative-gpt-4",
    });
}

// ---------------------------------------------------------------------------
// Narrative Events
// ---------------------------------------------------------------------------

pub fn handleTriggerEvent(ctx: *api.Context) !void {
    const app = getApp(ctx);
    const req = try ctx.bindJson(TriggerEventReq);

    const event_id = try std.fmt.allocPrint(
        ctx.allocator,
        "evt_{d}",
        .{std.time.timestamp()},
    );
    defer ctx.allocator.free(event_id);

    try ctx.jsonStruct(200, .{
        .event_id = event_id,
        .world_id = req.world_id,
        .status = "triggered",
        .affected_npcs = 47 + @as(u64, req.magnitude) * 10,
        .narrative_branch = app.getNarrativeBranch(req.event_type),
        .player_impact = "positive",
    });
}

// ---------------------------------------------------------------------------
// Quests
// ---------------------------------------------------------------------------

pub fn handleIssueQuest(ctx: *api.Context) !void {
    const app = getApp(ctx);
    const req = try ctx.bindJson(IssueQuestReq);

    app.quest_count += 1;
    const quest_id = try std.fmt.allocPrint(ctx.allocator, "quest_{d}", .{app.quest_count});
    defer ctx.allocator.free(quest_id);

    try ctx.jsonStruct(200, .{
        .quest_id = quest_id,
        .world_id = req.world_id,
        .quest_name = req.quest_name,
        .status = "published",
        .assigned_players = 234,
        .difficulty = app.getDifficultyLabel(req.difficulty),
        .reward_token = "CHY3",
        .reward_amount = req.reward_amount,
    });
}

// ---------------------------------------------------------------------------
// World Statistics
// ---------------------------------------------------------------------------

pub fn handleWorldStats(ctx: *api.Context) !void {
    const app = getApp(ctx);
    try ctx.jsonStruct(200, .{
        .active_worlds = app.world_count,
        .total_npcs = app.npc_count,
        .active_quests = app.quest_count,
        .narrative_events_24h = 8921,
        .realtime_players = 4823,
        .avg_world_size_mb = 128,
    });
}
