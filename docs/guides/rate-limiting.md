# Rate Limiting

速率限制保护服务免受流量突刺和滥用。ZigZero 提供多种速率限制策略。

## 可用策略

| 类型 | 结构 | 算法 | 适用场景 |
|------|------|------|----------|
| Token Bucket | `limiter.TokenBucket` | 固定速率 + burst | 通用限流 |
| Sliding Window | `limiter.SlidingWindow` | 滑动窗口计数 | 精确限流 |
| IP Limiter | `limiter.IpLimiter` | 按 key 维护 Token Bucket | 防止单个来源滥用 |
| 命名限流器 | `limiter.getLimiter()` | 进程级共享 Token Bucket | 全局/按名称限流 |
| Adaptive Shedder | `load.AdaptiveShedder` | 基于响应时间的概率丢弃 | 高负载保护 |

## IP 级别限流

最常见的限流方式，基于客户端 IP 地址。`IpLimiter` 用 `StringHashMap` 为每个 key 维护一个 `TokenBucket`：

```zig
const std = @import("std");
const zigzero = @import("zigzero");
const compat = zigzero.compat;
const api = zigzero.api;
const log = zigzero.log;
const limiter = zigzero.limiter;
const middleware = zigzero.middleware;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    compat.initIo(allocator);
    defer compat.deinitIo();

    const logger = log.Logger.new(.info, "my-service");

    // 100 requests/second, burst of 10
    var ip_limiter = limiter.IpLimiter.init(allocator, 100.0, 10);
    defer ip_limiter.deinit();

    var server = api.Server.init(allocator, 8080, logger);
    defer server.deinit();
    try server.addMiddleware(middleware.rateLimitByIp(&ip_limiter));

    // ...
}
```

`IpLimiter.init(allocator, rate: f64, burst: u32)` 返回结构体本身（不是 error union），只有 `deinit()` 涉及分配。

参数：
- `rate: f64` — 每秒补充的令牌数
- `burst: u32` — 令牌桶容量（允许的突发请求数）

中间件从 `X-Forwarded-For`、`X-Real-Ip` 头取 IP，取不到时回退为 `"unknown"`：

```zig
pub fn rateLimitByIp(ip_limiter: *limiter.IpLimiter) api.Middleware
```

### 自定义错误响应

如果需要自定义 429 响应，编写自己的中间件。`IpLimiter` 的查询方法是 `allow(key: []const u8) bool`（不是 `check()`）：

```zig
try server.addMiddleware(.{
    .func = struct {
        fn exec(ctx: *api.Context, next: api.HandlerFn, data: ?*anyopaque) !void {
            const limit = @as(*limiter.IpLimiter, @ptrCast(@alignCast(data.?)));
            const ip = ctx.headers.get("X-Forwarded-For") orelse ctx.headers.get("X-Real-Ip") orelse "unknown";

            if (!limit.allow(ip)) {
                try ctx.setHeader("Retry-After", "1");
                try ctx.jsonStruct(429, .{
                    .error = "rate_limit_exceeded",
                    .message = "Too many requests. Please slow down.",
                });
                return;
            }

            try next(ctx);
        }
    }.exec,
    .user_data = &ip_limiter,
});
```

> 注意：`api.Context` 没有 `remote_addr` 字段，获取客户端地址只能通过请求头。

### 不同端点不同限制

```zig
// 公开端点：宽松限制
var public_limiter = limiter.IpLimiter.init(allocator, 50.0, 5);
try server.addRoute(.{
    .method = .GET,
    .path = "/api/public",
    .handler = handlePublic,
    .middleware = &.{ middleware.rateLimitByIp(&public_limiter) },
});

// 写操作：严格限制
var write_limiter = limiter.IpLimiter.init(allocator, 10.0, 2);
try server.addRoute(.{
    .method = .POST,
    .path = "/api/data",
    .handler = handleWrite,
    .middleware = &.{ middleware.rateLimitByIp(&write_limiter) },
});
```

## Token Bucket 算法

`TokenBucket` 不持有分配器，`new()` 即可，没有 `deinit`：

```zig
var bucket = limiter.TokenBucket.new(10.0, 100); // 10 tokens/s, burst 100

pub fn checkLimit() !void {
    if (!bucket.allow()) {
        return error.RateLimitExceeded;
    }
    // 处理请求...
}
```

`allow()` 返回普通 `bool`，所以不要写 `try bucket.allow()`；`allowN(n: u32) bool` 可以一次取多个令牌。

## 滑动窗口限流

`SlidingWindow` 是带分配器的结构体，用 `init(allocator, rate, window_sec)` 创建：

```zig
// 应用启动时创建，退出时释放
fn setupWindow(allocator: std.mem.Allocator) !limiter.SlidingWindow {
    return limiter.SlidingWindow.init(allocator, 100.0, 1); // 每 1 秒最多 100 次
}

pub fn checkWindow(ctx: *api.Context, window: *limiter.SlidingWindow) !void {
    if (!window.allow()) {
        try ctx.sendError(429, "rate limited");
        return;
    }
    try next(ctx);
}
```

`allow()` 无参数、返回 `bool`，窗口内过期的记录会被就地清理。

## 自适应负载丢弃

当系统响应时间变长时按概率丢弃请求：

```zig
const load = zigzero.load;

pub fn setupShedding(allocator: std.mem.Allocator) !load.AdaptiveShedder {
    return load.newAdaptiveShedder(allocator, .{});
}

fn installShedding(server: *api.Server, shedder: *load.AdaptiveShedder) !void {
    try server.addMiddleware(middleware.loadShedding(shedder));
}
```

丢弃规则：

```zig
pub const ShedderOptions = struct {
    window_ms: i64 = 5000,     // 滚动窗口长度（毫秒）
    buckets: usize = 50,       // 窗口分桶数
    cpu_threshold: i64 = 900,  // 阈值，千分比（900 = 90%）
    cpu_overloaded_fn: *const fn (threshold: i64) bool = defaultCpuOverloaded,
    cpu_usage_fn: *const fn () CpuUsage = sampleCpuUsage,
};
```

注意 `cpu_threshold` 用的是千分比（900 表示 90%），不是 0-100 的百分比。默认的 `defaultCpuOverloaded` 采样平台 CPU 使用率并与 `cpu_threshold` 比较（平台无法测量时按未过载处理）；`cpu_usage_fn` / `cpu_overloaded_fn` 都可以注入，便于测试或接入自己的监控信号。

## 命名限流器（进程级共享）

框架没有 `GlobalLimiter` / `UserLimiter` 类型。需要在整个进程内共享、按名称获取同一个桶时，用 `initGlobalLimiters()` + `getLimiter()`：

```zig
const limiter = zigzero.limiter;

// 启动时注册一个专用的分配器（例如 GPA）
limiter.initGlobalLimiters(allocator);

// 之后任意位置按名称获取；同名返回同一个指针，线程安全
const upload_bucket = limiter.getLimiter("upload", .{ .rate = 20.0, .burst = 5 });
if (!upload_bucket.allow()) {
    return error.RateLimitExceeded;
}
```

`getLimiter(name, config: limiter.Config)` 返回 `*TokenBucket`。`Config` 的字段是：

```zig
pub const Config = struct {
    rate: f64,
    burst: u32,
    type: Type = .token_bucket,
};
```

`Type` 目前声明了 `token_bucket` / `sliding_window` / `leaky_bucket`，但 `getLimiter` 实际只构造 Token Bucket。

## 组合限流

多层防护：

```zig
// 1. 全局限流（自适应丢弃）
try server.addMiddleware(middleware.loadShedding(&shedder));

// 2. IP 级别限流
try server.addMiddleware(middleware.rateLimitByIp(&ip_limiter));

// 3. 路由级别限流 + 请求体大小限制
try server.addRoute(.{
    .method = .POST,
    .path = "/api/upload",
    .handler = handleUpload,
    .middleware = &.{
        try middleware.maxBodySize(allocator, 1024 * 1024 * 10),
        middleware.rateLimitByIp(&upload_limiter),
    },
});
```

## 用户级别限流

没有 `UserLimiter`。`IpLimiter` 的 key 只是普通字符串，因此可以传入用户 ID 复用它，实现按用户限流：

```zig
// 用 userId 作为 key；deinit/清理逻辑与 IP 版本完全一致
var user_limiter = limiter.IpLimiter.init(allocator, 60.0, 10);
defer user_limiter.deinit();

try server.addMiddleware(.{
    .func = struct {
        fn exec(ctx: *api.Context, next: api.HandlerFn, data: ?*anyopaque) !void {
            const limit = @as(*limiter.IpLimiter, @ptrCast(@alignCast(data.?)));
            const user_id = ctx.response_headers.get("X-User-ID") orelse "anonymous";

            if (!limit.allow(user_id)) {
                try ctx.setHeader("X-RateLimit-Remaining", "0");
                try ctx.sendError(429, "rate limit exceeded");
                return;
            }

            try next(ctx);
        }
    }.exec,
    .user_data = &user_limiter,
});
```

（JWT 中间件会把 `sub` 写入 `X-User-ID` 响应头，见 [Authentication](authentication.md)。）

## 监控限流指标

`Registry.counter(name, help)` 返回 `!*Counter`；`Counter.inc()` 返回 `void`，标签用单次调用的 `setLabel(key, value)`：

```zig
const rate_limited = try registry.counter(
    "rate_limited_requests_total",
    "Total requests rejected by rate limiter",
);

pub fn handleRateLimited() !void {
    rate_limited.setLabel("reason", "ip") catch {};
    rate_limited.inc();
    try ctx.sendError(429, "rate limited");
}
```

## Redis 分布式限流

跨多实例协调限流，用 `redis.Redis` 的 `incr` / `expire`：

```zig
const redis = zigzero.redis;

var redis_client = try redis.Redis.new(allocator, .{ .host = "127.0.0.1", .port = 6379 });
defer redis_client.deinit();
try redis_client.connect();

pub fn checkDistributedLimit(ctx: *api.Context) !void {
    const key = try std.fmt.allocPrint(
        ctx.allocator,
        "ratelimit:ip:{s}",
        .{ctx.headers.get("X-Real-Ip") orelse "unknown"},
    );
    defer ctx.allocator.free(key);

    const count = try redis_client.incr(key);
    if (count == 1) {
        try redis_client.expire(key, 1);
    }

    if (count > 100) {
        try ctx.sendError(429, "rate limited");
        return;
    }

    try next(ctx);
}
```

## 配置示例

配置解析器支持任意结构体（字段名与 YAML key 对应），限流参数可以放在配置文件里：

```yaml
# config.yaml
rate_limiting:
  ip:
    rate: 100  # req/s
    burst: 10
  write:
    rate: 10
    burst: 2
  upload:
    rate: 1
    burst: 1

load_shedding:
  enabled: true
  cpu_threshold: 900  # 千分比：900 = 90%
  window_ms: 1000
  buckets: 10
```

注意 YAML 解析器是简化子集，不支持 `${VAR:-default}` 这类插值；环境变量请用 `config.loadEnv` 单独加载。嵌套 struct 需要自行实现 `fromJson`（见 [Configuration](configuration.md)）。配置文件可用 `config.loadYaml(T, allocator, path)` 直接读入，返回的配置里所有字符串都属于 loader 的 allocator，用完调用 `config.Loader.init(allocator).freeConfig(T, &cfg)` 释放，不要手工 `free` 单个字段。

## 下一步

- [Circuit Breaker](circuit-breaker.md) — 熔断器保护外部调用
- [Metrics & Observability](metrics.md) — 限流指标监控
- [Middleware](middleware.md) — 自定义限流中间件
