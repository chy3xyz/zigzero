# Middleware

中间件是在请求到达处理器之前或之后执行的拦截器。ZigZero 提供内置中间件并支持编写自定义中间件。

## 内置中间件速查

| 中间件 | 用途 | 签名 |
|--------|------|------|
| `requestId()` | 生成/传递请求 ID（响应头 `X-Request-ID`） | `api.Middleware` |
| `logging()` | 结构化请求/响应日志 | `api.Middleware` |
| `recovery()` | 把 handler 返回的错误转成 500 | `api.Middleware` |
| `cors()` | CORS preflight 和响应头 | `(allocator, CorsOptions) !api.Middleware` |
| `jwt()` | HMAC-SHA256 JWT 验证 | `(allocator, secret) !api.Middleware` |
| `rateLimit()` | Token bucket 限流 | `(*limiter.TokenBucket) api.Middleware` |
| `rateLimitByIp()` | 按 IP 的 token bucket 限流 | `(*limiter.IpLimiter) api.Middleware` |
| `loadShedding()` | 自适应负载丢弃 | `(*load.AdaptiveShedder) api.Middleware` |
| `maxBodySize()` | 请求体大小限制 | `(allocator, max_size: usize) !api.Middleware` |
| `requestTimeout()` | 请求超时 | `(timeout_ms: u32) api.Middleware` |
| `cacheResponses()` | HTTP 响应缓存 | `(*ResponseCache) api.Middleware` |
| `observability()` | 请求计数 + 延迟直方图 | `(*metric.Registry) api.Middleware` |
| `validateBody()` | 按 comptime 规则校验 JSON body | `(comptime T, comptime rules) api.Middleware` |

`requestId()` 只负责在响应头写入 `X-Request-ID`（客户端已带该头时原样回显），它**不会**在 `Context` 上提供读取方法——处理器请用 `ctx.header("X-Request-ID")` 取值。

`recovery()` 能兜住的是 handler *返回* 的错误；Zig 的 `panic`/`unreachable` 仍然终止进程，这一点无法被中间件捕获。

## 使用中间件

### 全局注册

```zig
try server.addMiddleware(middleware.requestId());
try server.addMiddleware(middleware.logging());
try server.addMiddleware(try middleware.cors(allocator, .{
    .max_age = 86400,
}));
```

### 路由级注册

```zig
try server.addRoute(.{
    .method = .POST,
    .path = "/admin",
    .handler = handleAdmin,
    .middleware = &.{
        try middleware.jwt(allocator, "admin-secret"),
    },
});
```

`.middleware` 是切片指针，必须比请求活得久：在 `main()` 里写 `&.{...}` 没问题，在其他函数里注册时请把切片 `dupe` 到更长的生命周期（见 api-server 指南中的说明）。

### 组合使用

```zig
// 全局中间件 (所有路由)
try server.addMiddleware(middleware.requestId());
try server.addMiddleware(middleware.logging());

// 组级中间件 (该组下所有路由)
var g = server.group("/api/v1");
var authed = g.withMiddleware(&.{try middleware.jwt(allocator, "api-secret")});
try authed.post("/data", handleData);

// 路由级中间件 (仅此路由)
try server.addRoute(.{
    .method = .POST,
    .path = "/api/v1/admin",
    .handler = handleAdmin,
    .middleware = &.{
        try middleware.jwt(allocator, "admin-secret"),
        try middleware.maxBodySize(allocator, 1024 * 1024 * 100),
    },
});
```

## 中间件执行顺序

全局中间件按注册顺序排在路由中间件之前，处理器位于链尾：

```
请求 → requestId → logging → cors → observability → [路由中间件] → Handler
       ←                                                      ←
```

进入阶段先注册的先执行；返回阶段逆序返回，所以 `logging` 能记录到最终 `status_code`。

## 编写自定义中间件

### 函数签名

```zig
pub const Middleware = struct {
    func: MiddlewareFn,
    user_data: ?*anyopaque = null,
};

pub const MiddlewareFn = *const fn (*Context, HandlerFn, ?*anyopaque) anyerror!void;
pub const HandlerFn = *const fn (*Context) anyerror!void;
```

### 基础示例：请求日志中间件

```zig
const compat = zigzero.compat;

fn requestLoggerMw() zigzero.api.Middleware {
    return .{
        .func = struct {
            fn exec(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                const start = compat.milliTimestamp();
                const req_id = ctx.header("X-Request-ID") orelse "-";

                std.debug.print(
                    "[{s}] {s} {s} started\n",
                    .{ req_id, @tagName(ctx.method), ctx.path },
                );

                try next(ctx);

                const elapsed = compat.milliTimestamp() - start;
                std.debug.print(
                    "[{s}] {s} {s} -> {d} in {d}ms\n",
                    .{ req_id, @tagName(ctx.method), ctx.path, ctx.status_code, elapsed },
                );
            }
        }.exec,
    };
}

// 注册
try server.addMiddleware(requestLoggerMw());
```

`std.time.timestamp()` 在 0.17 已不存在，请改用 `compat.milliTimestamp()` / `compat.timestamp()`；线程休眠用 `compat.sleep(ns)`。

### 带状态的中间件：IP 黑名单

`Context` 没有 `remote_addr` 字段；IP 来源与 `rateLimitByIp` 保持一致，读请求头：

```zig
const IpBlocklist = struct {
    blocked_ips: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) IpBlocklist {
        return .{ .blocked_ips = std.StringHashMap(void).init(allocator) };
    }

    pub fn block(self: *IpBlocklist, ip: []const u8) !void {
        try self.blocked_ips.put(ip, {});
    }

    pub fn middleware(self: *IpBlocklist) zigzero.api.Middleware {
        return .{
            .func = struct {
                fn exec(ctx: *api.Context, next: api.HandlerFn, data: ?*anyopaque) anyerror!void {
                    const blocklist = @as(*IpBlocklist, @ptrCast(@alignCast(data.?)));
                    const ip = ctx.header("X-Forwarded-For") orelse
                        ctx.header("X-Real-Ip") orelse "unknown";

                    if (blocklist.blocked_ips.contains(ip)) {
                        try ctx.sendError(403, "ip blocked");
                        return;
                    }

                    try next(ctx);
                }
            }.exec,
            .user_data = self,
        };
    }
};

// 使用
var blocklist = IpBlocklist.init(allocator);
try blocklist.block("192.168.1.100");
try server.addMiddleware(blocklist.middleware());
```

### 带配置的工厂函数

```zig
fn requestValidatorMw(comptime allowed_methods: []const api.Method) zigzero.api.Middleware {
    return .{
        .func = struct {
            fn exec(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                inline for (allowed_methods) |method| {
                    if (ctx.method == method) {
                        try next(ctx);
                        return;
                    }
                }
                try ctx.sendError(405, "method not allowed");
            }
        }.exec,
    };
}

// 注册
try server.addMiddleware(requestValidatorMw(&.{ .GET, .POST }));
```

### 修改响应的中间件：Gzip 压缩

```zig
fn gzipResponseMw() zigzero.api.Middleware {
    return .{
        .func = struct {
            fn exec(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                try next(ctx);

                const accept_encoding = ctx.headers.get("Accept-Encoding") orelse return;
                if (!std.mem.containsAtLeast(u8, accept_encoding, 4, "gzip")) return;

                // Compress 需要一块至少 max_window_len 的工作区
                var comp_buf: [std.compress.flate.max_window_len]u8 = undefined;
                var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
                defer aw.deinit();
                var cmp = try std.compress.flate.Compress.init(&aw.writer, &comp_buf, .gzip, .default);
                try cmp.writer.writeAll(ctx.response_body.items);
                try cmp.finish();

                ctx.response_body.clearRetainingCapacity();
                try ctx.response_body.appendSlice(ctx.allocator, aw.written());
                try ctx.setHeader("Content-Encoding", "gzip");
                try ctx.setHeader("Vary", "Accept-Encoding");
            }
        }.exec,
    };
}
```

只有在真的压缩过响应体之后才能设置 `Content-Encoding: gzip`——否则客户端会按 gzip 解析明文响应。

### 认证 + 按用户查询

`jwt()` 已经完成了 token 校验，验证通过后会把 `sub` 写进响应头 `X-User-ID`。后续中间件/处理器直接读它即可，不需要自己实现 `verifyJwt`：

```zig
const auth_mw = try middleware.jwt(allocator, "secret");

try server.addRoute(.{
    .method = .GET,
    .path = "/admin/profile",
    .handler = struct {
        fn handle(ctx: *api.Context) !void {
            const user_id = ctx.header("X-User-ID") orelse return error.Unauthorized;
            const profile = try loadProfile(ctx.allocator, user_id); // 你自己的查询逻辑
            defer profile.deinit();
            try ctx.jsonStruct(200, profile);
        }
    }.handle,
    .middleware = &.{auth_mw},
});
```

需要在本服务签发 token 时用 `middleware.generateToken(allocator, .{ .sub = "user123", .exp = compat.timestamp() + 3600 }, secret)`；它能签与 `jwt()` 校验对称的 HS256 token。

## 中间件与 User Data

中间件自己的 `user_data` 在工厂函数里绑定；路由的 `.user_data` 则是给处理器用的，两者互不影响：

```zig
try server.addRoute(.{
    .method = .GET,
    .path = "/data",
    .handler = handleData,          // 通过 ctx.user_data 读到 &my_service
    .middleware = &.{myMiddleware()},
    .user_data = &my_service,
});
```

## 错误处理与中间件

把处理器返回的错误映射成状态码：

```zig
try server.addMiddleware(.{
    .func = struct {
        fn exec(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
            next(ctx) catch |err| {
                switch (err) {
                    error.NotFound => try ctx.sendError(404, "resource not found"),
                    error.Unauthorized => try ctx.sendError(401, "unauthorized"),
                    error.PermissionDenied => try ctx.sendError(403, "permission denied"),
                    else => try ctx.sendError(500, "internal error"),
                }
            };
        }
    }.exec,
});
```

## 短路中间件

不调用 `next` 直接返回响应：

```zig
// 认证中间件
try server.addMiddleware(.{
    .func = struct {
        fn exec(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
            const auth_header = ctx.headers.get("Authorization") orelse {
                try ctx.sendError(401, "missing authorization header");
                return;
            };

            if (!std.mem.startsWith(u8, auth_header, "Bearer ")) {
                try ctx.sendError(401, "invalid authorization format");
                return;
            }

            try next(ctx);
        }
    }.exec,
});
```

## 路由分组与中间件继承

`RouteGroup` 只提供 `withMiddleware`、`withUserData` 和 `get/post/put/delete/patch/handle`，没有 `group()`，因此**分组不能嵌套，也不会把中间件继承给子分组**。需要多段前缀时，直接在完整前缀上分组：

```zig
// 直接以完整前缀建组，而不是嵌套组
var v1 = server.group("/api/v1");
var v1_authed = v1.withMiddleware(&.{auth_mw});
try v1_authed.get("/resource", h3);   // /api/v1/resource 带 auth_mw
try v1.get("/public", h1);            // /api/v1/public 不带中间件
```

`withUserData(data)` 则给分组注册的每条路由的 `.user_data` 统一绑定共享状态（处理器从 `ctx.user_data` 取回），用法与 `withMiddleware` 一致，同样返回新的 `RouteGroup`。

## 下一步

- [Authentication](authentication.md) — JWT 认证实战
- [Rate Limiting](rate-limiting.md) — 速率限制模式
- [Graceful Shutdown](graceful-shutdown.md) — 生命周期管理
