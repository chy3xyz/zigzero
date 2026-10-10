# Build Your First Service

逐步构建一个完整的 RESTful 用户服务，带有 CRUD 操作、中间件、指标和优雅关闭。

## 项目结构

```
my-service/
├── build.zig.zon
├── build.zig
└── src/
    ├── main.zig      # 入口点，服务器接线
    ├── types.zig     # 请求/响应 DTO
    ├── handlers.zig  # 路由处理器
    └── middleware.zig # 中间件工厂
```

## 步骤 1: 初始化项目

```bash
./zig-out/bin/zgctl new my-service
cd my-service
zig build
```

## 步骤 2: 定义类型 (src/types.zig)

```zig
//! 用户服务类型定义

pub const User = struct {
    id: []const u8,
    name: []const u8,
    email: []const u8,
    created_at: i64,
};

pub const CreateUserReq = struct {
    name: []const u8,
    email: []const u8,
};

pub const UpdateUserReq = struct {
    name: ?[]const u8 = null,
    email: ?[]const u8 = null,
};

pub const UserListResp = struct {
    users: []const User,
    total: u32,
};
```

## 步骤 3: 处理器 (src/handlers.zig)

```zig
//! 用户 CRUD 处理器

const std = @import("std");
const api = zigzero.api;
const types = @import("types.zig");

// 模拟数据库
var users_db = std.StringHashMap(types.User).init(std.heap.page_allocator);

pub fn handleListUsers(ctx: *api.Context) !void {
    var list = std.ArrayList(types.User).init(ctx.allocator);
    defer list.deinit();

    var it = users_db.valueIterator();
    while (it.next()) |user| {
        try list.append(user.*);
    }

    try ctx.jsonStruct(200, .{
        .users = try list.toOwnedSlice(),
        .total = @as(u32, @intCast(list.items.len)),
    });
}

pub fn handleGetUser(ctx: *api.Context) !void {
    const id = ctx.param("id") orelse return error.MissingId;

    if (users_db.get(id)) |user| {
        try ctx.jsonStruct(200, user);
    } else {
        try ctx.sendError(404, "user not found");
    }
}

pub fn handleCreateUser(ctx: *api.Context) !void {
    const req = try ctx.bindJson(types.CreateUserReq);

    const user = types.User{
        .id = std.fmt.allocPrint(ctx.allocator, "{d}", .{std.time.timestamp()}) catch "0",
        .name = req.name,
        .email = req.email,
        .created_at = std.time.timestamp(),
    };
    errdefer ctx.allocator.free(user.id);

    try users_db.put(ctx.allocator.dupe(u8, user.id), user);

    try ctx.jsonStruct(201, user);
}

pub fn handleUpdateUser(ctx: *api.Context) !void {
    const id = ctx.param("id") orelse return error.MissingId;
    const req = try ctx.bindJson(types.UpdateUserReq);

    const existing = users_db.get(id) orelse return error.NotFound;

    const updated = types.User{
        .id = existing.id,
        .name = req.name orelse existing.name,
        .email = req.email orelse existing.email,
        .created_at = existing.created_at,
    };

    try users_db.put(id, updated);
    try ctx.jsonStruct(200, updated);
}

pub fn handleDeleteUser(ctx: *api.Context) !void {
    const id = ctx.param("id") orelse return error.MissingId;

    if (users_db.remove(id)) {
        try ctx.jsonStruct(200, .{ .ok = true });
    } else {
        try ctx.sendError(404, "user not found");
    }
}
```

## 步骤 4: 中间件工厂 (src/middleware.zig)

```zig
//! 中间件工厂函数

const std = @import("std");
const zigzero = @import("zigzero");
const api = zigzero.api;

pub fn globalMiddleware(allocator: std.mem.Allocator) ![]api.Middleware {
    const mws = [_]zigzero.middleware.Middleware{
        zigzero.middleware.requestId(),
        zigzero.middleware.logging(),
        try zigzero.middleware.cors(allocator, .{ .max_age = 86400 }),
    };
    return &mws;
}
```

## 步骤 5: 主入口 (src/main.zig)

```zig
//! 用户服务 — 完整示例

const std = @import("std");
const zigzero = @import("zigzero");
const api = zigzero.api;
const log = zigzero.log;
const middleware = zigzero.middleware;
const metric = zigzero.metric;
const lifecycle = zigzero.lifecycle;

const types = @import("types.zig");
const handlers = @import("handlers.zig");
const mw_factory = @import("middleware.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 指标注册表
    var registry = metric.Registry.init(allocator);
    defer registry.deinit();
    _ = try registry.counter("http_requests_total", "Total HTTP requests");

    // 生命周期管理
    var lc = lifecycle.Manager.init(allocator);
    defer lc.deinit();

    try lc.onShutdown("cleanup", struct {
        fn run(_: *anyopaque) void {
            std.debug.print("Shutting down gracefully...\n", .{});
        }
    }.run, null);

    // HTTP 服务器
    const logger = log.Logger.new(.info, "user-service");
    var server = api.Server.init(allocator, 8080, logger);
    defer server.deinit();

    // 全局中间件
    const global_mws = try mw_factory.globalMiddleware(allocator);
    for (global_mws) |mw| {
        try server.addMiddleware(mw);
    }

    // 健康检查
    try server.addRoute(.{
        .method = .GET,
        .path = "/health",
        .handler = struct {
            fn handle(ctx: *api.Context) !void {
                try ctx.jsonStruct(200, .{
                    .status = "healthy",
                    .version = "1.0.0",
                });
            }
        }.handle,
    });

    // 用户 CRUD 路由
    {
        var g = server.group("/api/users");
        try g.get("/:id", handlers.handleGetUser);
        try g.post("/", handlers.handleCreateUser);
        try g.put("/:id", handlers.handleUpdateUser);
        try g.delete("/:id", handlers.handleDeleteUser);
        try g.get("/", handlers.handleListUsers);
    }

    std.debug.print(
        \\
        \\user-service — RESTful User Management
        \\============================================================
        \\  GET    /health             → Health check
        \\  GET    /api/users          → List users
        \\  GET    /api/users/:id      → Get user
        \\  POST   /api/users          → Create user
        \\  PUT    /api/users/:id      → Update user
        \\  DELETE /api/users/:id      → Delete user
        \\============================================================
        \\
    , .{});

    try server.start();
    lc.run();
    lc.shutdown();
}
```

## 步骤 6: 运行和测试

```bash
zig build
./zig-out/bin/my-service

# 测试端点
curl http://localhost:8080/health
# {"status":"healthy","version":"1.0.0"}

curl -X POST http://localhost:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"name":"Alice","email":"alice@example.com"}'
# {"id":"1713200000","name":"Alice","email":"alice@example.com","created_at":1713200000}

curl http://localhost:8080/api/users
# {"users":[...],"total":1}
```

## 添加速率限制

使用 IP 限制器保护服务：

```zig
const limiter = zigzero.limiter;
var ip_limiter = limiter.IpLimiter.init(allocator, 100.0, 10); // 100 req/s, burst 10
defer ip_limiter.deinit();

try server.addMiddleware(middleware.rateLimitByIp(&ip_limiter));
```

## 添加断路器

保护对外部服务的调用：

```zig
const breaker = zigzero.breaker;

var cb = breaker.CircuitBreaker.new();
defer cb.deinit();

pub fn callExternalService() !void {
    const result = try cb.execute(struct {
        fn run() ![]const u8 {
            // 外部 API 调用
            return try httpGet("https://api.external.com/data");
        }
    }.run);
    defer std.heap.page_allocator.free(result);
    // 处理结果...
}
```

## 下一步

- [API Server Guide](../guides/api-server.md) — 路由、中间件、请求绑定的完整参考
- [Graceful Shutdown](../guides/graceful-shutdown.md) — 生命周期钩子和信号处理
- [Metrics & Observability](../guides/metrics.md) — Prometheus 指标集成
