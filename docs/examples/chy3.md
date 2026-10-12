# chy3 — Creator Metaverse Platform

完整的 ZigZero 实战案例，展示如何用 ZigZero 构建元宇宙叙事驱动的创作者变现平台。

## 业务背景

**chy3** 围绕「创作者在元宇宙中的创意变现」这一核心叙事，拆分为三个业务域：

```
问题域 (Problem Domain)  →  创作者痛点发现
    ↓
解决域 (Solution Domain)  →  创作者工具（资产铸造、市场、订阅、版权费）
    ↓
世界域 (World Domain)      →  持久叙事元宇宙引擎（世界、NPC、事件、任务）
```

## 项目结构

```
examples/chy3/
├── chy3.zig              ← 兼容层（重新导出 src.main）
└── src/
    ├── main.zig           ← 入口：生命周期、路由注册、依赖注入
    ├── context.zig        ← AppContext：共享状态 + Metric 注册表指针
    ├── types.zig          ← 所有 DTO（请求/响应结构体）
    ├── domain/
    │   ├── problem.zig    ← 问题域处理器
    │   ├── solution.zig   ← 解决域处理器
    │   └── world.zig      ← 世界域处理器
    └── infra/
        ├── middleware.zig ← 中间件工厂函数（唯一被 main.zig 引用的 infra 文件）
```

示例的指标直接通过 `AppContext.registry` 创建（`metric.Registry`），没有单独的 metrics 模块。

## 架构设计原则

### 1. 依赖注入

通过 `ctx.user_data` 注入 `AppContext`，避免全局变量：

```zig
fn getApp(ctx: *api.Context) *AppContext {
    return @as(*AppContext, @ptrCast(@alignCast(ctx.user_data.?)));
}

pub fn handleMintAsset(ctx: *api.Context) !void {
    const app = getApp(ctx);
    app.asset_count += 1;
    // ...
}
```

### 2. 分层架构

```
infra/     → 基础设施（中间件工厂）
    ↓
domain/    → 业务逻辑（三个领域处理器）
    ↓
main.zig   → 接线层（路由注册、服务组装）
```

### 3. 状态封装

`AppContext` 的真实定义（`src/context.zig`）：

```zig
pub const AppContext = struct {
    allocator: std.mem.Allocator,
    registry: *metric.Registry,

    // 问题域状态
    problem_count: u64 = 0,

    // 解决域状态
    asset_count: u64 = 0,

    // 世界域状态
    world_count: u64 = 0,
    npc_count: u64 = 0,
    quest_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, registry: *metric.Registry) AppContext { ... }

    // 业务辅助方法
    pub fn getProblemInsight(self: *AppContext, category: []const u8) []const u8
    pub fn getNarrativeArc(self: *AppContext, genre: []const u8) []const u8
    pub fn getNpcLocation(self: *AppContext, npc_type: []const u8) []const u8
    pub fn getNarrativeBranch(self: *AppContext, event_type: []const u8) []const u8
    pub fn getDifficultyLabel(self: *AppContext, difficulty: u8) []const u8
};
```

## 中间件栈

中间件由 `src/infra/middleware.zig` 的工厂函数统一创建，启动时组装（`main.zig`）：

```zig
// 全局中间件（所有路由）：requestId → logging → cors → observability → loadShedding → rateLimitByIp
const global_mws = try infra_middleware.globalMiddleware(allocator, &registry, &ip_limiter, &shedder);
for (global_mws) |mw| {
    try server.addMiddleware(mw);
}

// 路由级中间件工厂返回已 dupe 的切片，可安全交给 addRoute
const mw_mint = try infra_middleware.mintAssetMiddleware(allocator); // jwt + maxBodySize(10MB)
try server.addRoute(.{
    .method = .POST,
    .path = "/api/v1/assets/mint",
    .handler = solution.handleMintAsset,
    .middleware = mw_mint,
    .user_data = &app,
});
```

所有 JWT 中间件使用同一个密钥 `"chy3-secret-key"`。

## API 端点

### 问题域

| 方法 | 路径 | 中间件 | 功能 |
|------|------|--------|------|
| POST | `/api/v1/problems/submit` | maxBodySize(64KB) | 提交创作者痛点 |
| GET | `/api/v1/problems/heatmap` | — | 获取痛点热力图 |

### 解决域

| 方法 | 路径 | 中间件 | 功能 |
|------|------|--------|------|
| POST | `/api/v1/assets/mint` | JWT + 10MB | 铸造创意资产 |
| GET | `/api/v1/marketplace/list` | — | 浏览市场 |
| POST | `/api/v1/subscriptions/subscribe` | JWT | 订阅创作者 |
| GET | `/api/v1/royalties` | — | 版权费分布 |

### 世界域

| 方法 | 路径 | 中间件 | 功能 |
|------|------|--------|------|
| POST | `/api/v1/worlds/create` | JWT | 创建叙事世界 |
| POST | `/api/v1/worlds/:world_id/npcs` | JWT | 生成 AI NPC |
| POST | `/api/v1/worlds/:world_id/events` | — | 触发叙事事件 |
| POST | `/api/v1/worlds/:world_id/quests` | JWT | 发布任务 |
| GET | `/api/v1/worlds/stats` | — | 世界统计 |

`world_id` 虽然出现在路径里，但世界域的三个处理器都从 JSON body 的 `world_id` 字段取值，路径参数目前不参与业务逻辑。

### 可观测性

| 方法 | 路径 | 功能 |
|------|------|------|
| GET | `/health` | 健康检查（返回固定 JSON） |
| GET | `/metrics` | Prometheus 指标（由 `handleMetrics` 导出注册表） |

## 运行

```bash
zig build chy3
./zig-out/bin/chy3

# 输出
chy3 — Creator Metaverse Platform
============================================================
  问题域 (Problem)  Pain point discovery → /api/v1/problems/*
  解决域 (Solution) Creator tools      → /api/v1/assets/* /marketplace/* /subscriptions/*
  世界域 (World)   Metaverse engine   → /api/v1/worlds/*
  Observability                    → /health /metrics
============================================================
[1776254157] [chy3-server] [INFO] Server listening on port 8080 with 10 workers
```

worker 数量取决于机器的 CPU 核数（`Server.start()` 在 `worker_threads = 0` 时取 CPU 核数）。`lc.run()` 会一直阻塞，而本示例没有安装信号处理器，用 Ctrl-C 结束进程。

## 获取 Token

chy3 **没有登录端点**，所以不能像某些示例那样 `POST /api/v1/auth/login` 换 token（该路径会 404）。JWT 中间件校验的密钥是硬编码的 `"chy3-secret-key"`，用同一个密钥通过 `middleware.generateToken` 签发即可：

```zig
const token = try middleware.generateToken(ctx.allocator, .{
    .sub = "admin",
    .username = "admin",
    .exp = compat.timestamp() + 3600,
}, "chy3-secret-key");
```

把它作为 `Authorization: Bearer <token>` 发出，`jwt()` 中间件就会放行。下面的示例用 `$TOKEN` 代表这样一个已签发的临时 token。

## 测试端点

```bash
# 健康检查
curl http://localhost:8080/health

# 提交痛点
curl -X POST http://localhost:8080/api/v1/problems/submit \
  -H "Content-Type: application/json" \
  -d '{"creator_id":"alice","category":"monetization","description":"hard to monetize","severity":5}'

# 铸造资产（需 JWT）
curl -X POST http://localhost:8080/api/v1/assets/mint \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"creator_id":"alice","asset_type":"narrative","metadata":"story_ch1"}'

# 订阅创作者（需 JWT）
curl -X POST http://localhost:8080/api/v1/subscriptions/subscribe \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"subscriber_id":"bob","creator_id":"alice","tier":"founder"}'

# 创建元宇宙世界（需 JWT）
curl -X POST http://localhost:8080/api/v1/worlds/create \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"creator_id":"alice","name":"IronRealms","genre":"fantasy"}'

# 生成 NPC（需 JWT，body 里带 world_id）
curl -X POST http://localhost:8080/api/v1/worlds/world_IronRealms_1/npcs \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"world_id":"world_IronRealms_1","npc_type":"merchant","personality":"greedy"}'

# 触发叙事事件（无需 JWT）
curl -X POST http://localhost:8080/api/v1/worlds/world_IronRealms_1/events \
  -H "Content-Type: application/json" \
  -d '{"world_id":"world_IronRealms_1","event_type":"war","magnitude":8}'

# 发布任务（需 JWT）
curl -X POST http://localhost:8080/api/v1/worlds/world_IronRealms_1/quests \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"world_id":"world_IronRealms_1","quest_name":"Retrieve the Ember Blade","reward_amount":500,"difficulty":7}'

# 查看 Prometheus 指标
curl http://localhost:8080/metrics
```

## 展示的 ZigZero 特性

| 特性 | 用例 |
|------|------|
| `api.Server` | HTTP 服务器 |
| `RouteGroup` | 路由分组 |
| `middleware.requestId()` | 请求 ID 生成 |
| `middleware.logging()` | 结构化日志 |
| `middleware.cors()` | CORS 支持 |
| `middleware.jwt()` | JWT 认证 |
| `middleware.maxBodySize()` | 请求体限制 |
| `middleware.observability()` | Prometheus 指标 |
| `middleware.loadShedding()` | 自适应负载丢弃 |
| `middleware.rateLimitByIp()` | IP 速率限制 |
| `metric.Registry` | Prometheus 注册表 |
| `health.Registry` | 健康检查 |
| `limiter.IpLimiter` | Token bucket 限流 |
| `load.newAdaptiveShedder()` | 负载 shedder |
| `lifecycle.Manager` | 优雅关闭 |
| `log.Logger` | 结构化日志 |

chy3 不使用消息队列，也没有引入 `mq.Queue`。

## 已知问题

以下问题曾在此示例中真实存在，现已修复，保留说明以免读者按旧行为理解：

- `POST /api/v1/worlds/:world_id/events` 曾用分组 `g.post(...)` 注册而没有 `.user_data`，处理器解引用 `ctx.user_data.?` 会 panic。`RouteGroup` 现在支持 `withUserData(...)`，示例用 `server.group("/api/v1/worlds").withUserData(&app)` 注册分组路由。
- `GET /api/v1/worlds/stats` 曾被注入 `*metric.Registry`，而处理器按 `*AppContext` 解释 —— 类型错配。现改为注入 `&app`（注册表通过 `app.registry` 访问）。
- `ctx.bindJson` 曾返回指向已释放解析 arena 的字符串切片。它现在把解析结果放进请求 arena，字段在整个请求周期内有效。

## 扩展方向

- **数据持久化** — 使用 `sqlx` 将状态存入 PostgreSQL
- **Redis 缓存** — 使用 `redis` 缓存市场数据
- **WebSocket 推送** — 使用 `websocket` 实时推送 NPC 对话
- **消息总线** — 使用 `mq.Queue` 解耦领域事件（示例中尚未使用）
- **服务发现** — 使用 `discovery` + `etcd` 实现多实例部署
- **分布式锁** — 使用 `lock` 保护世界状态
- **Cron 任务** — 使用 `cron` 定时结算版权费
