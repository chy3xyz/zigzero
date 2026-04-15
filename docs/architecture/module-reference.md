# Module Reference

ZigZero 所有模块的完整 API 参考。

## net/ — Network Layer

### `api.zig` — HTTP Server

HTTP 服务器核心模块。

```zig
const api = zigzero.api;

// 服务器初始化
var server = api.Server.init(allocator, 8080, logger);
defer server.deinit();

// 路由注册
try server.addRoute(.{
    .method = .GET,
    .path = "/path/:id",
    .handler = myHandler,
    .middleware = &.{mw1, mw2},
    .user_data = &myData,
});

// 路由分组
var g = server.group("/api/v1");
try g.get("/users", listUsers);
try g.post("/users", createUser);

// 中间件
try server.addMiddleware(middleware.requestId());

// 启动
try server.start();
```

**类型：**

| 类型 | 说明 |
|------|------|
| `Server` | HTTP 服务器 |
| `RouteGroup` | 路由分组 |
| `Context` | 请求上下文 |
| `Method` | HTTP 方法枚举 |
| `Route` | 路由定义 |
| `Middleware` | 中间件包装器 |
| `HandlerFn` | `fn(*Context) !void` |

**Context 方法：**

```zig
// 参数和查询
ctx.param("id") -> ?[]const u8
ctx.queryParam("q") -> ?[]const u8

// 请求体
ctx.body -> ?[]const u8
ctx.bindJson(comptime T: type) !T

// 响应
ctx.jsonStruct(status: u16, value: anytype) !void
ctx.json(status: u16, body: []const u8) !void
ctx.sendError(status: u16, message: []const u8) !void
ctx.setHeader(name: []const u8, value: []const u8) !void

// JWT
ctx.getJwtClaims() -> ?middleware.TokenClaims

// 请求信息
ctx.method -> Method
ctx.path -> []const u8
ctx.remote_addr -> std.net.Address
ctx.headers -> std.http.Headers
ctx.getRequestId() -> []const u8

// 内存
ctx.allocator -> std.mem.Allocator
ctx.user_data -> ?*anyopaque
```

### `http.zig` — HTTP Client

```zig
const http = zigzero.http;

var client = http.Client.init(allocator, .{
    .timeout_ms = 5000,
    .max_retries = 3,
});

var resp = try client.get("https://api.example.com/data");
defer resp.deinit();

try ctx.setHeader("Content-Type", "application/json");
try ctx.json(200, resp.body);

// 带 CircuitBreaker
var cb = breaker.CircuitBreaker.new();
client.withBreaker(&cb);
```

### `rpc.zig` — RPC Framework

二进制 RPC over TCP。

### `websocket.zig` — WebSocket

RFC 6455 兼容的 WebSocket 服务器。

```zig
var hub = websocket.Hub.init(allocator);
defer hub.deinit();

try server.addRoute(.{
    .method = .GET,
    .path = "/ws/chat",
    .handler = struct {
        fn handle(ctx: *api.Context) !void {
            var conn = try websocket.upgrade(ctx, ctx.stream.?, allocator);
            defer conn.close();
            const room = try hub.room("default");
            try room.join(&conn);
            // 处理消息...
        }
    }.handle,
});
```

### `gateway.zig` — API Gateway

反向代理和负载均衡。

## server/ — Server Utilities

### `middleware.zig` — Middleware

```zig
const middleware = zigzero.middleware;

// 内置中间件
middleware.requestId()                         // 请求 ID
middleware.logging()                           // 日志
try middleware.cors(allocator, .{ ... })       // CORS
try middleware.jwt(allocator, secret)         // JWT 验证
middleware.rateLimitByIp(limiter)             // IP 限流
middleware.loadShedding(shedder)               // 负载丢弃
try middleware.maxBodySize(allocator, size)   // Body 限制
middleware.requestTimeout(ms)                 // 请求超时
middleware.observability(registry)             // 指标
middleware.cacheResponses(cache)              // 响应缓存
middleware.healthHandler                       // 健康检查处理器
middleware.prometheusHandler                   // Prometheus 指标处理器

// JWT Token 生成
middleware.generateToken(allocator, .{
    .sub = "user123",
    .username = "alice",
    .exp = std.time.timestamp() + 3600,
}, secret) ![]const u8

// JWT Claims
pub const TokenClaims = struct {
    sub: []const u8,
    username: ?[]const u8 = null,
    role: ?[]const u8 = null,
    exp: i64,
    iat: ?i64 = null,
};
```

### `static.zig` — Static Files

```zig
try server.addRoute(.{
    .method = .GET,
    .path = "/static/:filename",
    .handler = static.serveHandler,
    .user_data = "/var/www/public",
});
```

## infra/ — Infrastructure

### `log.zig` — Logging

```zig
const log = zigzero.log;

log.initFromConfig(.{ .service_name = "myapp" });
const logger = log.Logger.new(.info, "my-service");

logger.info("Request processed", .{
    .request_id = "123",
    .status = 200,
    .duration_ms = 45,
});

logger.warn("High latency", .{ .ms = 1000 });
logger.err("Database error", .{ .err = @errorName(err) });
```

### `metric.zig` — Prometheus Metrics

```zig
const metric = zigzero.metric;

var registry = metric.Registry.init(allocator);
defer registry.deinit();

const counter = try registry.counter("requests_total", "Total requests");
const gauge = try registry.gauge("active_connections", "Active connections");
const hist = try registry.histogram(
    "request_duration_ms", "Duration in ms",
    &.{ 5, 10, 25, 50, 100, 250, 500, 1000 },
);

try counter.inc();
try gauge.inc();
try gauge.dec();
try gauge.set(42);
try hist.observe(45.5);

registry.exportPrometheus(writer) !void
```

### `health.zig` — Health Checks

```zig
const health = zigzero.health;

var registry = health.Registry.init(allocator);
defer registry.deinit();

try registry.register("memory", health.checks.memory);
try registry.register("disk", health.checks.disk);

// 自定义检查
try registry.register("database", myCheckFn);
```

### `limiter.zig` — Rate Limiting

```zig
const limiter = zigzero.limiter;

// IP 级别限流
var ip_limiter = limiter.IpLimiter.init(allocator, 100.0, 10);
defer ip_limiter.deinit();
ip_limiter.check(address) !bool

// Token Bucket
var bucket = limiter.TokenBucket.init(allocator, .{
    .capacity = 100,
    .refill_rate = 10,
    .refill_interval = 100,
});
try bucket.allow() -> bool

// Sliding Window
var window = limiter.SlidingWindow.init(allocator, .{
    .max_requests = 100,
    .window_size_ms = 1000,
});
try window.check(allocator, address) -> bool
```

### `breaker.zig` — Circuit Breaker

```zig
const breaker = zigzero.breaker;

var cb = breaker.CircuitBreaker.new();
defer cb.deinit();

cb.execute(struct { fn run() !T { ... } }.run) !T

cb.getState() -> enum { closed, open, half_open }
cb.getStats() -> struct { failures, successes, rejects }
cb.forceOpen()
cb.forceClose()
```

### `load.zig` — Adaptive Load Shedding

```zig
const load = zigzero.load;

var shedder = try load.newAdaptiveShedder(allocator, .{
    .window_ms = 1000,
    .buckets = 10,
    .cpu_threshold = 80,
});
defer shedder.deinit();

shedder.shouldDrop() -> bool
```

### `sqlx.zig` — SQL Client

```zig
const sqlx = zigzero.sqlx;

// SQLite
var db = try sqlx.open(allocator, "data.db");

// PostgreSQL
var db = try sqlx.open(allocator, .{
    .url = "postgres://user:pass@localhost/db",
});

// MySQL
var db = try sqlx.open(allocator, .{
    .url = "mysql://user:pass@localhost/db",
});

defer db.close();

// 查询
var rows = try db.query("SELECT * FROM users WHERE id = ?", .{id});
defer rows.deinit();
while (try rows.next()) |row| {
    const name = try row.get([]const u8, "name");
    std.debug.print("{s}\n", .{name});
}

// 执行
try db.exec("INSERT INTO users (name) VALUES (?)", .{name});

// 事务
try db.withTransaction(struct {
    fn run(tx: *sqlx.Tx) !void {
        try tx.exec("INSERT ...", .{...});
    }
}.run);

// 参数化查询支持：?, $1, @name
```

See [SQLx Guide](../guides/sqlx.md) for full documentation including transactions, struct scanning, query builder, CachedConn, circuit breaker integration, and metrics.

### `redis.zig` — Redis Client

```zig
const redis = zigzero.redis;

var client = try redis.Client.init(allocator, .{
    .address = "127.0.0.1:6379",
    .db = 0,
});
defer client.deinit();

// 字符串
try client.set("key", "value");
const val = try client.get("key");

// Hash
try client.hset("user:1", &.{
    .{ .field = "name", .value = "Alice" },
    .{ .field = "email", .value = "alice@example.com" },
});
const name = try client.hget("user:1", "name");

// List / Set / Sorted Set
try client.lpush("queue", "item");
const item = try client.rpop("queue");

// Pub/Sub
const sub = try client.subscribe("events");
while (try sub.next()) |msg| {
    std.debug.print("Got: {s}\n", .{msg});
}
```

### `cache.zig` — LRU Cache

```zig
const cache = zigzero.cache;

var c = cache.LruCache([]const u8, []const u8).init(allocator, 1000);
defer c.deinit();

try c.set("key", "value", 3600); // 1小时 TTL
const val = c.get("key");         // ?[]const u8

// 通用包装
const StringCache = cache.Cache([]const u8, []const u8);
var sc = StringCache.init(allocator, 1024);
```

### `mq.zig` — Message Queue

```zig
const mq = zigzero.mq;

var queue = mq.Queue.init(allocator);
defer queue.deinit();

try queue.publish("topic", "message");
const msg = try queue.subscribe("topic");
try queue.unsubscribe("topic");
```

### `lifecycle.zig` — Graceful Shutdown

```zig
const lifecycle = zigzero.lifecycle;

var lc = lifecycle.Manager.init(allocator);
defer lc.deinit();

try lc.onShutdown("cleanup", callback, context);

try server.start();
lc.run();     // 启动信号监听
lc.shutdown(); // 阻塞直到完成

lc.configure(.{ .timeout_ms = 30_000 });
lc.getStatus() -> struct { running, shutdown_hooks_remaining }
```

### `cron.zig` — Scheduler

```zig
const cron = zigzero.cron;

var scheduler = cron.Scheduler.init(allocator);
defer scheduler.deinit();

try scheduler.schedule("0 * * * *", struct {
    fn run(ctx: *anyopaque) void {
        std.debug.print("Hourly task\n", .{});
    }
}.run, null);

try scheduler.start();
lc.onShutdown("stop-cron", struct {
    fn run(_: *anyopaque) void { scheduler.stop(); }
}.run, null);
```

### `pool.zig` — Connection Pool

```zig
var pool = try pool.Pool(*DbConn).init(allocator, .{
    .max_size = 10,
    .min_idle = 2,
});
defer pool.deinit();

const conn = try pool.acquire();
defer pool.release(conn);

try conn.query("...");
```

### `retry.zig` — Retry with Backoff

```zig
const retry = zigzero.retry;

const result = try retry.withBackoff(allocator, struct {
    fn attempt() !T { try callThatMayFail(); }
}.attempt, .{
    .max_attempts = 3,
    .base_delay_ms = 100,
    .max_delay_ms = 2000,
    .jitter = true,
});
```

### `lock.zig` — Distributed Locks

```zig
// Redis 分布式锁
var lock = try lock.RedisLock.init(allocator, client, "my-lock");
defer lock.deinit();

const acquired = try lock.acquire(30_000); // 30s 超时
if (acquired) {
    defer _ = lock.release();
    // 临界区操作...
}
```

## data/ — Data Layer

### `orm.zig` — ORM Query Builder

### `validate.zig` — Validation

```zig
const validate = zigzero.validate;

const UserReq = struct {
    name: []const u8,
    email: []const u8,
    age: u32,
};

const rules = .{
    .name = validate.FieldRules{ .required = true, .min_len = 2, .max_len = 50 },
    .email = validate.FieldRules{ .required = true, .email = true },
    .age = validate.FieldRules{ .min = 0, .max = 150 },
};

try validate.validateStruct(UserReq, req, rules);
```

## core/ — Core Utilities

### `fx.zig` — Stream / Parallel

```zig
const fx = zigzero.fx;

// 并行执行
const results = try fx.parallel(struct {
    fn task1() !i32 { return 1; }
    fn task2() !i32 { return 2; }
    fn task3() !i32 { return 3; }
}.tasks).run(allocator);

const sum = results[0] + results[1] + results[2];

// 流式处理
try fx.stream(data)
    .map(transformFn)
    .filter(filterFn)
    .collect(allocator);
```

### `mapreduce.zig` — Map/Reduce

## config.zig — Configuration

```zig
const config = zigzero.config;

const cfg = try config.loadFromYamlFile("config.yaml");
const cfg = try config.loadFromJsonFile("config.json");

// 环境变量替换
// ${VAR:-default} 在 YAML 中自动替换
```

## svc.zig — Service Context

依赖注入容器。

```zig
const svc = zigzero.svc;

var context = svc.Context.init(allocator);
defer context.deinit();

try context.register(db);
try context.register(cache);
try context.register(queue);

const db = context.get(*Database);
```
