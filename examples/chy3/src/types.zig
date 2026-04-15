//! chy3 — Request / Response types
//!
//! Shared DTOs across all three business domains:
//! - 问题域 (Problem Domain)
//! - 解决域 (Solution Domain)
//! - 世界域 (World Domain)

const std = @import("std");

// ============================================================================
// 问题域 — Problem Domain
// ============================================================================

pub const ProblemSubmitReq = struct {
    creator_id: []const u8,
    category: []const u8,
    description: []const u8,
    severity: u8,
};

pub const ProblemSubmitResp = struct {
    problem_id: []const u8,
    category: []const u8,
    ai_insight: []const u8,
    total_pain_points: u64,
};

pub const HeatmapEntry = struct {
    category: []const u8,
    score: u32,
    count: u32,
};

pub const HeatmapResp = struct {
    heatmap: []const HeatmapEntry,
};

test "ProblemSubmitReq roundtrip" {
    const req = ProblemSubmitReq{
        .creator_id = "alice",
        .category = "monetization",
        .description = "hard to monetize",
        .severity = 5,
    };
    try std.testing.expectEqualStrings("alice", req.creator_id);
    try std.testing.expectEqualStrings("monetization", req.category);
}

// ============================================================================
// 解决域 — Solution Domain
// ============================================================================

pub const MintAssetReq = struct {
    creator_id: []const u8,
    asset_type: []const u8,
    metadata: []const u8,
    price: ?u64 = null,
};

pub const MintAssetResp = struct {
    asset_id: []const u8,
    asset_type: []const u8,
    status: []const u8,
    ipfs_cid: []const u8,
    royalty_bps: u32,
    blockchain: []const u8,
};

pub const AssetListingEntry = struct {
    id: []const u8,
    asset_type: []const u8,
    creator: []const u8,
    price: u64,
    currency: []const u8,
};

pub const MarketplaceListResp = struct {
    assets: []const AssetListingEntry,
    total: u32,
    page: u32,
};

pub const SubscribeReq = struct {
    subscriber_id: []const u8,
    creator_id: []const u8,
    tier: []const u8,
};

pub const SubscribeResp = struct {
    ok: bool,
    subscription_id: []const u8,
    next_billing: []const u8,
    access_level: []const u8,
    monthly_usd: u32,
};

pub const RoyaltyEntry = struct {
    creator: []const u8,
    amount: u64,
    currency: []const u8,
    assets_sold: u32,
};

pub const RoyaltiesResp = struct {
    period: []const u8,
    distributions: []const RoyaltyEntry,
    total_volume_usd: u64,
};

// ============================================================================
// 世界域 — World Domain
// ============================================================================

pub const CreateWorldReq = struct {
    creator_id: []const u8,
    name: []const u8,
    genre: []const u8,
    is_public: bool = true,
};

pub const CreateWorldResp = struct {
    world_id: []const u8,
    name: []const u8,
    genre: []const u8,
    status: []const u8,
    population: u32,
    narrative_arc: []const u8,
    chapter: u8,
};

pub const SpawnNPCReq = struct {
    world_id: []const u8,
    npc_type: []const u8,
    personality: []const u8,
    lore: ?[]const u8 = null,
};

pub const SpawnNPCResp = struct {
    npc_id: []const u8,
    world_id: []const u8,
    npc_type: []const u8,
    status: []const u8,
    location: []const u8,
    dialogue_tree: []const u8,
    ai_model: []const u8,
};

pub const TriggerEventReq = struct {
    world_id: []const u8,
    event_type: []const u8,
    magnitude: u8 = 5,
};

pub const TriggerEventResp = struct {
    event_id: []const u8,
    world_id: []const u8,
    status: []const u8,
    affected_npcs: u64,
    narrative_branch: []const u8,
    player_impact: []const u8,
};

pub const IssueQuestReq = struct {
    world_id: []const u8,
    quest_name: []const u8,
    reward_amount: u64,
    difficulty: u8,
};

pub const IssueQuestResp = struct {
    quest_id: []const u8,
    world_id: []const u8,
    quest_name: []const u8,
    status: []const u8,
    assigned_players: u32,
    difficulty: []const u8,
    reward_token: []const u8,
    reward_amount: u64,
};

pub const WorldStatsResp = struct {
    active_worlds: u64,
    total_npcs: u64,
    active_quests: u64,
    narrative_events_24h: u32,
    realtime_players: u32,
    avg_world_size_mb: u32,
};

// ============================================================================
// Observability
// ============================================================================

pub const HealthResp = struct {
    status: []const u8,
    uptime_seconds: u64,
    version: []const u8,
    domains: struct {
        problem: []const u8,
        solution: []const u8,
        world: []const u8,
    },
};
