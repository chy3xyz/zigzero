# Quick Start

5分钟快速了解 ZigZero。构建一个带路由、中间件和健康检查的 HTTP 服务器。

## 目标

构建一个微服务，处理以下请求：

```
GET  /health         → 健康检查
GET  /api/users/:id  → 获取用户
POST /api/users      → 创建用户
GET  /metrics        → Prometheus 指标
```

## 步骤 1: 创建项目

```bash
git clone https://github.com/chy3xyz/zigzero.git
cd zigzero
zig build
```

## 步骤 2: 使用 zgctl 脚手架

```bash
./zig-out/bin/zgctl new hello-service
cd hello-service
zig build
./zig-out/bin/hello-service
```

或者，直接创建一个简单的 `main.zig`：

```zig
// src/main.zig
const std = @import("std");
const zigzero = @import("zigzero");
const api = zigzero.api;
const log = zigzero.log;
const middleware = zigzero.middleware;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const logger = log.Logger.new(.info, "hello-service");
    var server = api.Server.init(gpa.allocator(), 8080, logger);
    defer server.deinit();

    // 全局中间件
    try server.addMiddleware(middleware.requestId());
    try server.addMiddleware(middleware.logging());

    // 健康检查
    try server.addRoute(.{
        .method = .GET,
        .path = "/health",
        .handler = struct {
            fn handle(ctx: *api.Context) !void {
                try ctx.jsonStruct(200, .{ .status = "ok" });
            }
        }.handle,
    });

    // 获取用户
    try server.addRoute(.{
        .method = .GET,
        .path = "/api/users/:id",
        .handler = struct {
            fn handle(ctx: *api.Context) !void {
                const id = ctx.param("id") orelse "unknown";
                try ctx.jsonStruct(200, .{
                    .id = id,
                    .name = "Alice",
                    .email = "alice@example.com",
                });
            }
        }.handle,
    });

    try server.start();
}
```

## 步骤 3: 运行

```bash
zig build
./zig-out/bin/hello-service
```

输出：

```
[2024-04-15 10:00:00] [hello-service] [INFO] Server listening on port 8080
```

## 步骤 4: 测试端点

```bash
# 健康检查
curl http://localhost:8080/health
# {"status":"ok"}

# 获取用户
curl http://localhost:8080/api/users/42
# {"id":"42","name":"Alice","email":"alice@example.com"}
```

## 添加 CORS 中间件

允许跨域请求：

```zig
try server.addMiddleware(try middleware.cors(gpa.allocator(), .{
    .max_age = 86400,
    .allow_origins = &.{ "https://example.com" },
}));
```

## 添加 JWT 认证

保护需要登录的路由：

```zig
try server.addRoute(.{
    .method = .POST,
    .path = "/api/users",
    .handler = struct {
        fn handle(ctx: *api.Context) !void {
            try ctx.jsonStruct(201, .{ .id = "123", .status = "created" });
        }
    }.handle,
    .middleware = &.{
        try middleware.jwt(gpa.allocator(), "your-secret-key"),
    },
});
```

## 路由分组

为一组路由共享前缀和中间件：

```zig
{
    var g = server.group("/api/users");
    try g.get("/:id", handleGetUser);
    try g.post("/", handleCreateUser);
    try g.put("/:id", handleUpdateUser);
    try g.delete("/:id", handleDeleteUser);
}
```

## Prometheus 指标

添加指标收集和导出：

```zig
var registry = metric.Registry.init(gpa.allocator());
defer registry.deinit();

const counter = try registry.counter("http_requests_total", "Total HTTP requests");

try server.addMiddleware(middleware.observability(&registry));

try server.addRoute(.{
    .method = .GET,
    .path = "/metrics",
    .handler = middleware.prometheusHandler,
    .user_data = &registry,
});
```

访问 `http://localhost:8080/metrics` 查看 Prometheus 格式的指标。

## 下一步

- [Build Your First Service](first-service.md) — 更完整的教程
- [API Server Guide](../guides/api-server.md) — 路由和中间件的完整参考
- [Metrics & Observability](../guides/metrics.md) — Prometheus 集成
- [Authentication](../guides/authentication.md) — JWT 认证
