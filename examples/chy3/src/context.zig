//! chy3 — Application state and dependency container
//!
//! Holds all shared state and infrastructure references.
//! Passed to handlers via `api.Context.user_data`.

const std = @import("std");
const zigzero = @import("zigzero");
const metric = zigzero.metric;

/// AppContext owns all shared application state and infrastructure references.
/// Handlers access it via `ctx.user_data`.
pub const AppContext = struct {
    allocator: std.mem.Allocator,
    registry: *metric.Registry,

    // 问题域 state
    problem_count: u64 = 0,

    // 解决域 state
    asset_count: u64 = 0,

    // 世界域 state
    world_count: u64 = 0,
    npc_count: u64 = 0,
    quest_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, registry: *metric.Registry) AppContext {
        return .{ .allocator = allocator, .registry = registry };
    }

    /// AI insight generator based on problem category.
    pub fn getProblemInsight(self: *AppContext, category: []const u8) []const u8 {
        _ = self;
        return switch (category[0]) {
            'm' => "Clusters with 847 monetization pain points",
            'd' => "Discovery gap: 94% of creators struggle here",
            'i' => "IP protection concern — on-chain rights registry recommended",
            'c' => "Collaboration friction — async workflows can help",
            else => "General tooling friction point",
        };
    }

    /// Narrative arc selector based on world genre.
    pub fn getNarrativeArc(self: *AppContext, genre: []const u8) []const u8 {
        _ = self;
        return switch (genre[0]) {
            'f' => "Chapter 1: The Iron Frontier",
            's' => "Chapter 1: Neon Requiem",
            'h' => "Chapter 1: Hallowed Grounds",
            'a' => "Chapter 1: Archipelago Awakens",
            else => "Chapter 1: The Awakening",
        };
    }

    /// NPC spawn location based on NPC type.
    pub fn getNpcLocation(self: *AppContext, npc_type: []const u8) []const u8 {
        _ = self;
        return switch (npc_type[0]) {
            'm' => "Market Square",
            'g' => "Guild Hall",
            't' => "Tavern",
            'k' => "Keep",
            'w' => "Wandering",
            else => "Village Center",
        };
    }

    /// Narrative branch based on event type.
    pub fn getNarrativeBranch(self: *AppContext, event_type: []const u8) []const u8 {
        _ = self;
        return switch (event_type[0]) {
            'w' => "war_arc",
            'f' => "festival_arc",
            'd' => "discovery_arc",
            'c' => "conflict_arc",
            'r' => "resolution_arc",
            else => "default_arc",
        };
    }

    /// Difficulty label from numeric value.
    pub fn getDifficultyLabel(self: *AppContext, difficulty: u8) []const u8 {
        _ = self;
        return switch (difficulty) {
            1...3 => "easy",
            4...6 => "medium",
            7...8 => "hard",
            else => "legendary",
        };
    }

    test "problem insight" {
        var ctx = AppContext.init(std.testing.allocator, undefined);
        try std.testing.expectEqualStrings("Clusters with 847 monetization pain points", ctx.getProblemInsight("monetization"));
        try std.testing.expectEqualStrings("Discovery gap: 94% of creators struggle here", ctx.getProblemInsight("discovery"));
    }

    test "narrative arc" {
        var ctx = AppContext.init(std.testing.allocator, undefined);
        try std.testing.expectEqualStrings("Chapter 1: The Iron Frontier", ctx.getNarrativeArc("fantasy"));
        try std.testing.expectEqualStrings("Chapter 1: Neon Requiem", ctx.getNarrativeArc("scifi"));
    }

    test "difficulty label" {
        var ctx = AppContext.init(std.testing.allocator, undefined);
        try std.testing.expectEqualStrings("easy", ctx.getDifficultyLabel(2));
        try std.testing.expectEqualStrings("medium", ctx.getDifficultyLabel(5));
        try std.testing.expectEqualStrings("hard", ctx.getDifficultyLabel(8));
        try std.testing.expectEqualStrings("legendary", ctx.getDifficultyLabel(10));
    }
};
