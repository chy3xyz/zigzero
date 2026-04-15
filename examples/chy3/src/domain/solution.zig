//! 解决域 (Solution Domain) — Creator monetization tools
//!
//! Handles:
//! - POST /api/v1/assets/mint           — Mint creative assets
//! - GET  /api/v1/marketplace/list      — Browse marketplace
//! - POST /api/v1/subscriptions/subscribe — Subscribe to a creator
//! - GET  /api/v1/royalties            — View royalty distributions

const std = @import("std");
const api = zigzero.api;
const zigzero = @import("zigzero");
const context = @import("../context.zig");
const types = @import("../types.zig");

const MintAssetReq = types.MintAssetReq;
const SubscribeReq = types.SubscribeReq;
const AppContext = context.AppContext;

fn getApp(ctx: *api.Context) *AppContext {
    return @as(*AppContext, @ptrCast(@alignCast(ctx.user_data.?)));
}

// ---------------------------------------------------------------------------
// Asset Minting
// ---------------------------------------------------------------------------

pub fn handleMintAsset(ctx: *api.Context) !void {
    const app = getApp(ctx);
    const req = try ctx.bindJson(MintAssetReq);

    app.asset_count += 1;
    const asset_id = try std.fmt.allocPrint(
        ctx.allocator,
        "asset_{s}_{d}",
        .{ req.creator_id, app.asset_count },
    );
    defer ctx.allocator.free(asset_id);

    try ctx.jsonStruct(200, .{
        .asset_id = asset_id,
        .asset_type = req.asset_type,
        .status = "minted",
        .ipfs_cid = "QmTzQ1JRkWErjk39mryYw2WVaphAZNAREyMchXzYQ7c15n",
        .royalty_bps = 750,
        .blockchain = "ethereum",
    });
}

// ---------------------------------------------------------------------------
// Marketplace
// ---------------------------------------------------------------------------

pub fn handleListMarketplace(ctx: *api.Context) !void {
    try ctx.jsonStruct(200, .{
        .assets = &.{
            .{ .id = "a001", .asset_type = "image", .creator = "alice", .price = 299, .currency = "USD" },
            .{ .id = "a002", .asset_type = "music", .creator = "bob", .price = 499, .currency = "USD" },
            .{ .id = "a003", .asset_type = "3d_model", .creator = "carol", .price = 999, .currency = "USD" },
            .{ .id = "a004", .asset_type = "narrative", .creator = "dave", .price = 149, .currency = "USD" },
            .{ .id = "a005", .asset_type = "world_template", .creator = "eve", .price = 1999, .currency = "USD" },
        },
        .total = 5,
        .page = 1,
    });
}

// ---------------------------------------------------------------------------
// Subscriptions
// ---------------------------------------------------------------------------

pub fn handleSubscribe(ctx: *api.Context) !void {
    // Validate incoming subscription request (parse JSON body)
    _ = try ctx.bindJson(SubscribeReq);
    const sub_id = try std.fmt.allocPrint(
        ctx.allocator,
        "sub_{d}",
        .{std.time.timestamp()},
    );
    defer ctx.allocator.free(sub_id);

    try ctx.jsonStruct(200, .{
        .ok = true,
        .subscription_id = sub_id,
        .next_billing = "2026-05-15",
        .access_level = "founder",
        .monthly_usd = 9,
    });
}

// ---------------------------------------------------------------------------
// Royalties
// ---------------------------------------------------------------------------

pub fn handleRoyalties(ctx: *api.Context) !void {
    try ctx.jsonStruct(200, .{
        .period = "2026-04",
        .distributions = &.{
            .{ .creator = "alice", .amount = 45230, .currency = "USD", .assets_sold = 187 },
            .{ .creator = "bob", .amount = 38910, .currency = "USD", .assets_sold = 156 },
            .{ .creator = "carol", .amount = 52100, .currency = "USD", .assets_sold = 203 },
            .{ .creator = "dave", .amount = 28440, .currency = "USD", .assets_sold = 112 },
        },
        .total_volume_usd = 164680,
    });
}
