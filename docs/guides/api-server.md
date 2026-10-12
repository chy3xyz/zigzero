# HTTP API Server

完整的 HTTP 服务器 API 参考：路由、中间件、请求处理、响应构建。

## 服务器初始化

```zig
const std = @import("std");
const zigzero = @import("zigzero");
const api = zigzero.api;
const compat = zigzero.compat;
const log = zigzero.log;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 0.17 的 I/O 接口需要先初始化
    compat.initIo(allocator);
    defer compat.deinitIo();

    const logger = log.Logger.new(.info, "my-service");
    var server = api.Server.init(allocator, 8080, logger);
    defer server.deinit();

    // 添加路由和中间件...

    try server.start();
}
```

构造函数签名：

```zig
pub fn init(allocator: std.mem.Allocator, port: u16, logger: log.Logger) Server
pub fn initWithConfig(allocator: std.mem.Allocator, logger: log.Logger, config: ServerConfig) Server
```

`server.deinit()` 内部会先调用 `stop()`，然后回收 worker pool 与路由表。

## 路由注册

### 基础路由

```zig
try server.addRoute(.{
    .method = .GET,
    .path = "/users",
    .handler = handleGetUsers,
});
```

### 路径参数

路径段写成 `:name` 或 `{name}` 都可以，两种写法由同一个参数解析器处理：

```zig
try server.addRoute(.{
    .method = .GET,
    .path = "/users/:id/posts/:post_id",
    .handler = handleGetUserPost,
});
```

在处理器中获取参数：

```zig
fn handleGetUserPost(ctx: *api.Context) !void {
    const user_id = ctx.param("id") orelse return error.MissingId;
    const post_id = ctx.param("post_id") orelse return error.MissingPostId;

    try ctx.jsonStruct(200, .{
        .user_id = user_id,
        .post_id = post_id,
    });
}
```

### 路由分组

为一组路由共享前缀：

```zig
{
    var g = server.group("/api/v1/users");
    try g.get("/:id", handleGetUser);
    try g.post("/", handleCreateUser);
    try g.put("/:id", handleUpdateUser);
    try g.delete("/:id", handleDeleteUser);
}
```

分组本身不带中间件；需要组级中间件时用 `withMiddleware`，它返回一个新的 `RouteGroup`：

```zig
{
    var users = server.group("/api/v1/users");
    var authed = users.withMiddleware(&.{try middleware.jwt(allocator, "secret")});
    try authed.get("/me", handleGetMe);
}
```

`RouteGroup` 没有 `group()` 方法：**路由分组只能从 `server.group()` 创建**，不支持嵌套。`withMiddleware` 也不会把中间件传给其他分组——需要哪一组生效就显式设置在哪一组上。

分组注册的每条路由都携带 `user_data`，用 `withUserData(data: ?*anyopaque)` 一次性给整组处理器注入共享状态（它返回新的 `RouteGroup`，同样不修改原分组）：

```zig
{
    var repo = UserRepository{};
    var g = server.group("/api/v1/users").withUserData(&repo);
    try g.get("/:id", handleGetUser);   // 处理器里用 ctx.user_data 取回 &repo
}
```

### HTTP 方法

`api.Method` 覆盖标准方法，`server.addRoute()` 接受其中任意一个：

```zig
.GET  .POST  .PUT  .DELETE  .PATCH  .HEAD  .OPTIONS
```

`RouteGroup` 提供其中五个的快捷方法：

```zig
try g.get("/path", handler);
try g.post("/path", handler);
try g.put("/path", handler);
try g.delete("/path", handler);
try g.patch("/path", handler);
```

`HEAD` 与 `OPTIONS` 需要用完整形式注册：`server.addRoute(.{ .method = .OPTIONS, .path = p, .handler = h })`，或走 `g.handle(.HEAD, path, handler)`。

## 中间件

### 全局中间件

按注册顺序执行（先注册先执行，中间件链在 handler 之前逐层进入）：

```zig
try server.addMiddleware(middleware.requestId());
try server.addMiddleware(middleware.logging());
try server.addMiddleware(try middleware.cors(allocator, .{}));
```

### 路由级中间件

通过 `.middleware` 字段为特定路由添加中间件：

```zig
try server.addRoute(.{
    .method = .POST,
    .path = "/api/admin/dangerous",
    .handler = handleDangerous,
    .middleware = &.{
        try middleware.jwt(allocator, "secret"),
        middleware.rateLimitByIp(&ip_limiter),
    },
});
```

`.middleware` 是切片指针，必须比请求活得久。字面量 `&.{...}` 在 `main()` 里有效（帧随进程存活）；如果路由在函数内注册，请把中间件切片分配在更长的生命周期上——`examples/chy3` 就为此在启动时 `allocator.dupe` 出一份：

```zig
const mws = [_]api.Middleware{
    try middleware.jwt(allocator, "chy3-secret-key"),
    try middleware.maxBodySize(allocator, 1024 * 1024 * 10),
};
const route_mws = try allocator.dupe(api.Middleware, &mws);
try server.addRoute(.{ .method = .POST, .path = "/api/v1/assets/mint", .handler = h, .middleware = route_mws });
```

### 可用中间件

| 中间件 | 功能 | 签名 |
|--------|------|------|
| `requestId()` | 复用/生成请求 ID，写入响应头 `X-Request-ID` | `api.Middleware` |
| `logging()` | 结构化请求日志 | `api.Middleware` |
| `cors()` | CORS 头部处理 | `(allocator, CorsOptions) !api.Middleware` |
| `jwt()` | HMAC-SHA256 JWT 验证 | `(allocator, secret) !api.Middleware` |
| `rateLimit()` | Token bucket 限流 | `(*limiter.TokenBucket) api.Middleware` |
| `rateLimitByIp()` | IP 级别速率限制 | `(*limiter.IpLimiter) api.Middleware` |
| `loadShedding()` | 自适应负载丢弃 | `(*load.AdaptiveShedder) api.Middleware` |
| `recovery()` | 把 handler 返回的错误转成 500 | `api.Middleware` |
| `maxBodySize()` | 请求体大小限制 | `(allocator, max_size: usize) !api.Middleware` |
| `requestTimeout()` | 请求超时 | `(timeout_ms: u32) api.Middleware` |
| `cacheResponses()` | 响应缓存 | `(*ResponseCache) api.Middleware` |
| `observability()` | 请求计数和延迟直方图 | `(*metric.Registry) api.Middleware` |
| `validateBody()` | 按 comptime 规则校验 JSON body | `(comptime T, comptime rules) api.Middleware` |
| `healthHandler` | 健康检查 handler（非中间件） | `fn (*api.Context) !void` |
| `prometheusHandler` | Prometheus 指标 handler（非中间件） | `fn (*api.Context) !void` |

`jwt()` 校验通过后会把 `sub` claim 写入响应头 `X-User-ID`。

`CorsOptions` 的字段为 `allow_origins`、`allow_methods`、`allow_headers`、`allow_credentials`、`max_age`。

## 请求处理

### 获取请求体

```zig
fn handleCreateUser(ctx: *api.Context) !void {
    // 绑定 JSON 到结构体
    const req = try ctx.bindJson(CreateUserReq);

    // 直接获取原始 body
    if (ctx.body) |body| {
        std.debug.print("Raw body: {s}\n", .{body});
    }
}
```

### 自动参数绑定

`parseReq` 按 `.path` / `.query` / `.form` / `.header` 从四个来源填充结构体字段；缺失的可选字段留 `null`，缺失的必填字段返回 `error.MissingParameter`：

```zig
const ListReq = struct {
    id: u32,
    page: ?u32,
};

const req = try ctx.parseReq(ListReq, .{ .id = .path, .page = .query });
```

`bindJson` 之外还可以用 `bindJsonAndValidate` 做 comptime 规则校验，失败时字段描述会放在 `ctx.validation_error_message`：

```zig
const rules = .{
    .name = zigzero.validate.FieldRules{ .required = true, .min_len = 2 },
};
const req = try ctx.bindJsonAndValidate(CreateUserReq, rules);
```

### 设置响应

```zig
// JSON 结构体 (推荐)
try ctx.jsonStruct(200, .{ .key = "value" });

// 已序列化的 JSON
try ctx.json(200, "{\"ok\":true}");

// 纯文本
try ctx.text(200, "hello");

// 错误响应（JSON: {"code":404,"message":"not found"}）
try ctx.sendError(404, "not found");

// 设置自定义头部
try ctx.setHeader("X-Request-Id", "12345");
try ctx.setHeader("Cache-Control", "max-age=3600");

// 直接写响应体
try ctx.response_body.appendSlice(ctx.allocator, "Hello, World!");
ctx.responded = true;
```

### 响应构建

```zig
// 简单 JSON
try ctx.jsonStruct(200, .{ .status = "ok" });

// 带嵌套的 JSON
try ctx.jsonStruct(200, .{
    .user = .{
        .id = "123",
        .name = "Alice",
        .profile = .{
            .bio = "Developer",
            .avatar_url = "https://example.com/avatar.png",
        },
    },
    .meta = .{
        // requestId() 中间件把 ID 放在响应头里；客户端自带的 ID 会原样回显，
        // 处理器可以从请求头读到同一个值
        .request_id = ctx.header("X-Request-ID") orelse "-",
    },
});
```

## 请求上下文

`api.Context` 是处理器拿到的全部状态。字段与方法的真实形态：

```zig
pub const Context = struct {
    // 字段
    allocator:          std.mem.Allocator,
    method:             Method,
    path:               []const u8,                      // 去掉 query 的路径
    raw_path:           []const u8,                      // 原始请求目标（含 query）
    query:              std.StringHashMap([]const u8),
    params:             std.StringHashMap([]const u8),
    headers:            std.StringHashMap([]const u8),
    form:               std.StringHashMap([]const u8),
    body:               ?[]const u8,
    response_body:      std.ArrayList(u8),
    status_code:        u16,
    response_headers:   std.StringHashMap([]const u8),
    responded:          bool,
    logger:             log.Logger,
    user_data:          ?*anyopaque,
    trace_context:      ?trace.TraceContext,
    deadline_ms:        ?i64,                            // requestTimeout() 设置
    stream:             ?compat.net.Stream,
    upgraded:           bool,

    // 方法
    pub fn queryParam(key: []const u8) ?[]const u8;
    pub fn param(key: []const u8) ?[]const u8;
    pub fn header(key: []const u8) ?[]const u8;
    pub fn formValue(key: []const u8) ?[]const u8;
    pub fn setHeader(key: []const u8, value: []const u8) !void;
    pub fn json(status: u16, data: []const u8) !void;
    pub fn text(status: u16, data: []const u8) !void;
    pub fn sendError(status: u16, message: []const u8) !void;
    pub fn bindJson(comptime T: type) !T;
    pub fn bindJsonAndValidate(comptime T: type, comptime rules: anytype) !T;
    pub fn jsonStruct(status: u16, value: anytype) !void;
    pub fn parseReq(comptime T: type, sources: anytype) !T;
};
```

`Context` **没有** `getRequestId()`，也没有 `remote_addr` 字段：请求 ID 由 `requestId()` 中间件写进响应头；客户端地址请从 `X-Forwarded-For` / `X-Real-Ip` 请求头读取（`rateLimitByIp` 就是这么做的），或在反代提供连接信息后由你自己注入。

## User Data (依赖注入)

通过 `user_data` 向处理器传递依赖：

```zig
// 在路由注册时设置
try server.addRoute(.{
    .method = .GET,
    .path = "/users",
    .handler = handleListUsers,
    .user_data = &user_repo,
});

// 在处理器中读取
fn handleListUsers(ctx: *api.Context) !void {
    const repo = @as(*UserRepository, @ptrCast(@alignCast(ctx.user_data.?)));
    const users = try repo.list(ctx.allocator);
    try ctx.jsonStruct(200, .{ .users = users });
}
```

`addMiddleware` 接收的是 `Middleware` 值，它的 `user_data` 通常由工厂函数自带（例如 `jwt()` 存放密钥的内部状态）；而路由的 `.user_data` 是传给处理器的，两者互不影响。

## 错误处理

内置错误响应：

```zig
try ctx.sendError(400, "invalid request");
try ctx.sendError(401, "unauthorized");
try ctx.sendError(403, "forbidden");
try ctx.sendError(404, "not found");
try ctx.sendError(500, "internal server error");
```

返回自定义 JSON 错误：

```zig
try ctx.jsonStruct(400, .{
    .error = "validation_error",
    .message = "email field is required",
    .field = "email",
});
```

处理器返回错误且尚未写响应时，服务器会补一个 500：

```zig
fn handle(ctx: *api.Context) !void {
    try doWork(); // 出错 -> HTTP 500 {"code":500,"message":"..."}
}
```

## 静态文件服务

静态文件由 `static.Server` 提供，处理器通过 `.handler()` 生成：

```zig
const static = zigzero.static;

var files = static.Server.init(allocator, "public");
try server.addRoute(.{
    .method = .GET,
    .path = "/static/:filename",
    .handler = files.handler(),
    .user_data = &files,   // 处理器没有自身状态，服务器实例经路由的 user_data 传入
});
```

`static.Server.init(allocator, root_dir)` 的第二个参数是根目录。`handler()` 返回的是一个不捕获任何状态的固定处理函数，路由器注册时不带状态，所以必须用 `.user_data` 把 `files` 交给处理器：处理器内部 `@ptrCast(@alignCast(ctx.user_data.?))` 取回，因此 `files` 要活过服务器。

处理器把 `ctx.raw_path` 原样拼在 `root_dir` 之后，所以上面这条路由收到 `/static/a.css` 时读取的是 `public/static/a.css`——`root_dir` 要按这个规则选。路由按路径段匹配，`:param` 只匹配单个路径段，多级目录要为每级注册路由（如 `/static/:dir/:filename`），或自行包装处理器。

## 启动选项

`ServerConfig` 控制端口、body 上限、超时与 worker pool：

```zig
var server = api.Server.initWithConfig(allocator, logger, .{
    .port = 8080,
    .max_body_size = 8 * 1024 * 1024,   // 默认 8MB
    .request_timeout_ms = 30000,        // 默认 30s（u32）
    .worker_threads = 4,                // 0 = CPU 核数
    .max_queue_size = 1024,             // 连接队列上限，满了回 503
});
```

`Server.start()` 只监听 TCP，不做 Unix socket 监听，也没有 `startWithOptions()`：端口与线程数都只能通过上面的 `ServerConfig` 配置。`ServerConfig.port = 0` 时由内核分配端口，服务器不会把实际端口暴露出来。

## 下一步

- [Middleware Guide](middleware.md) — 编写自定义中间件
- [Metrics & Observability](metrics.md) — Prometheus 集成
- [Rate Limiting](rate-limiting.md) — 速率限制模式
