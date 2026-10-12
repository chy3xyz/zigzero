# Architecture Overview

ZigZero 的设计原则和架构层次。

## 设计原则

### 1. go-zero 兼容性

ZigZero 借鉴 [go-zero](https://github.com/zeromicro/go-zero) 的 API 设计哲学，让 Go 开发者能平滑迁移到 Zig：

```go
// go-zero (Go)
func (svc *ServiceContext) GetUser(ctx *svc.ServiceContext, in *types.GetUserRequest) (*types.User, error) {
    user, err := svc.UserModel.FindOne(ctx, in.Id)
    if err != nil {
        return nil, err
    }
    return &types.User{ Id: user.Id, Name: user.Name }, nil
}
```

```zig
// zigzero (Zig)
fn handleGetUser(ctx: *api.Context) !void {
    const req = try ctx.bindJson(GetUserReq);
    const user = try loadUser(ctx.allocator, req.id); // 你自己实现的数据访问
    try ctx.jsonStruct(200, user);
}
```

### 2. 零成本抽象

尽可能利用 Zig 的 comptime 特性：

- `std.json.parseFromSlice` 为 `T` 生成类型化的解析代码，处理器里 `bindJson(T)` 无需运行时反射
- `validate.validateStruct` 在编译期展开校验规则
- 泛型容器避免运行时反射开销

`RouteGroup` 的前缀拼接与路由匹配都在运行时完成：路由表是一棵按路径段切分的 trie，分组只是把前缀与路径用 `std.fmt.allocPrint` 拼起来后交给它。

### 3. 纯 Zig 依赖

除了可选的数据库 C 驱动，没有任何外部依赖：

```
zigzero
├── 纯 Zig 代码（框架核心）
├── libsqlite3（可选）
├── libpq（可选）
└── libmysqlclient（可选）
```

## 四层架构

```
┌────────────────────────────────────────────────────┐
│                   接入层 (API Gateway)               │
│  HTTP Server | RouteGroup | Middleware Chain        │
├────────────────────────────────────────────────────┤
│                    服务层 (Service)                  │
│  Business Logic (Handlers / Domain)                 │
├────────────────────────────────────────────────────┤
│                 服务治理层 (Governance)              │
│  Breaker | Limiter | LoadShedder | LoadBalancer     │
├────────────────────────────────────────────────────┤
│                基础设施层 (Infrastructure)           │
│  Log | Metric | Health | Config | Lifecycle        │
│  SQLx | Redis | Cache | MQ | Cron                   │
├────────────────────────────────────────────────────┤
│                   核心层 (Core)                      │
│  Threading | FX (Stream/Parallel) | MapReduce       │
└────────────────────────────────────────────────────┘
```

## 模块关系图

```
                    ┌──────────────────────┐
                    │     API Server       │
                    │   (net/api.zig)      │
                    └──────────┬───────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
              ▼                ▼                ▼
    ┌─────────────────┐ ┌───────────┐ ┌──────────────┐
    │ RouteGroup      │ │Middleware │ │   Context    │
    │ (路由分组)      │ │ (拦截器)  │ │ (请求上下文)  │
    └────────┬────────┘ └─────┬─────┘ └──────────────┘
             │                 │
             │    ┌────────────┼────────────┐
             │    │            │             │
             ▼    ▼            ▼             ▼
    ┌─────────────────────────────────────────────────┐
    │              Infrastructure                     │
    │  ┌─────────┐ ┌──────────┐ ┌────────┐          │
    │  │  Log    │ │  Metric  │ │ Health │  ...      │
    │  └─────────┘ └──────────┘ └────────┘          │
    │  ┌─────────┐ ┌──────────┐ ┌────────┐          │
    │  │  SQLx   │ │  Redis   │ │ Cache  │  ...      │
    │  └─────────┘ └──────────┘ └────────┘          │
    └─────────────────────────────────────────────────┘
```

## 请求处理流程

```
HTTP Request
    │
    ▼
┌─────────────────────────┐
│ Parse Request            │ 提取 method, path, query, headers, body
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ Route Match             │ Trie 树匹配；未命中直接回 404
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ Middleware Chain        │ 全局中间件 → 路由中间件 → Handler
│                         │ (如中间件短路，直接返回响应)
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ Handler (业务逻辑)       │ 调用 db, redis, mq 等服务
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ Response Writer         │ 写入状态行、头部与响应体
└─────────────────────────┘
```

## 中间件链执行

```zig
// 全局中间件 (server.addMiddleware)
// 应用于所有路由

try server.addMiddleware(mw1);  // #1
try server.addMiddleware(mw2);  // #2
try server.addMiddleware(mw3);  // #3

// 路由级中间件 (addRoute.middleware)
// 仅应用于该路由

try server.addRoute(.{
    .method = .GET,
    .path = "/admin",
    .handler = handleAdmin,
    .middleware = &.{ r1, r2 },
});

// 执行顺序：
// mw1 → mw2 → mw3 → r1 → r2 → Handler
//       ←                        ←
//       (逆序返回，mw3 最后设置响应头)
```

## 数据流

```
用户请求
    │
    ▼
api.Context (请求上下文)
    ├── param("id")       → 路径参数
    ├── queryParam("q")   → 查询参数
    ├── bindJson(T)       → JSON 解析
    ├── body              → 原始请求体
    ├── headers           → HTTP 头部
    ├── user_data         → 依赖注入
    │
    ▼
业务处理器 (Handler)
    │
    ├── AppContext        → 共享状态
    ├── metric.Registry    → 指标记录
    ├── 数据库/缓存/队列   → 数据操作
    │
    ▼
ctx.jsonStruct() / ctx.sendError()
    │
    ▼
HTTP 响应
```

## 内存管理模型

ZigZero 遵循 Zig 的所有权模型：

| 模式 | 使用场景 |
|------|----------|
| **所有者持有** | `Server.deinit()` 在函数退出时清理 |
| **Arena 分配** | 每个连接一个 `std.heap.ArenaAllocator`，解析请求、构造 `Context` 都在其中 |
| **请求级** | 处理器用 `ctx.allocator` 分配；响应写出后整个 arena 一次性释放，因此不要在处理器之外保留这些指针 |
| **全局共享** | 通过指针传递，`defer` 确保清理 |

```zig
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 0.17 的 I/O 接口需要先初始化，服务器/客户端才能建连
    zigzero.compat.initIo(allocator);
    defer zigzero.compat.deinitIo();

    const logger = zigzero.log.Logger.new(.info, "my-service");
    var server = api.Server.init(allocator, 8080, logger);
    defer server.deinit();  // main 退出时清理

    try server.start();
}

fn handleRequest(ctx: *api.Context) !void {
    // 请求级分配，由 ctx.allocator 管理
    const id = try std.fmt.allocPrint(ctx.allocator, "id_{d}", .{compat.milliTimestamp()});
    defer ctx.allocator.free(id);

    try ctx.jsonStruct(200, .{ .id = id });
}
```

注意：`std.heap.GeneralPurposeAllocator` 在 Zig 0.17 已被移除，请使用 `std.heap.DebugAllocator(.{})`（发布构建可换成 `std.heap.smp_allocator` 或 `std.heap.page_allocator`）；`std.Thread.sleep` 也已被移除，线程休眠用 `zigzero.compat.sleep(ns)`。

## 下一步

- [Module Reference](module-reference.md) — 所有模块的详细 API 文档
- [API Server Guide](../guides/api-server.md) — HTTP 服务器使用
- [First Service Tutorial](../getting-started/first-service.md) — 实践教程
