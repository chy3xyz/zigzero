# Module Reference

ZigZero 所有模块的完整 API 参考。所有签名与 `src/` 下的源码一一对应（Zig 0.17）。

## net/ — Network Layer

### `api.zig` — HTTP Server

HTTP 服务器核心模块。

```zig
const api = zigzero.api;
const middleware = zigzero.middleware;

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
| `ServerConfig` | 端口 / body 上限 / 超时 / worker pool 配置 |
| `RouteGroup` | 路由分组（`group()` 可嵌套，继承中间件与 `user_data`） |
| `Context` | 请求上下文 |
| `Method` | HTTP 方法枚举 |
| `Route` | 路由定义 |
| `Middleware` | 中间件包装器 |
| `HandlerFn` | `*const fn (*Context) anyerror!void` |
| `MiddlewareFn` | `*const fn (*Context, HandlerFn, ?*anyopaque) anyerror!void` |

**Server 方法：**

```zig
Server.init(allocator, port: u16, logger: log.Logger) Server
Server.initWithConfig(allocator, logger, config: ServerConfig) Server
server.addRoute(route: Route) !void
server.group(prefix: []const u8) RouteGroup
server.addMiddleware(mw: Middleware) !void
server.start() !void
server.stop() void
server.deinit() void
```

`ServerConfig` 字段：`port`、`max_body_size`、`request_timeout_ms: u32`、`worker_threads`（0 = CPU 核数）、`max_queue_size`。

`RouteGroup` 方法：`withMiddleware(mws: []const Middleware) RouteGroup`、`withUserData(data: ?*anyopaque) RouteGroup`、`get/post/put/delete/patch(path, handler) !void`、`handle(method, path, handler) !void`。`withUserData` 把状态写进该分组之后注册的每条路由的 `.user_data`，供组内处理器共享。

**Context 字段与方法：**

```zig
// 参数和查询
ctx.param("id")             // ?[]const u8  路径参数
ctx.queryParam("q")         // ?[]const u8  query 参数
ctx.header("X-Request-ID")  // ?[]const u8  请求头
ctx.formValue("field")      // ?[]const u8  表单字段

// 请求体
ctx.body                    // ?[]const u8
ctx.bindJson(comptime T: type) !T
ctx.bindJsonAndValidate(comptime T: type, comptime rules: anytype) !T
ctx.parseReq(comptime T: type, sources: anytype) !T

// 响应
ctx.json(status: u16, data: []const u8) !void
ctx.text(status: u16, data: []const u8) !void
ctx.jsonStruct(status: u16, value: anytype) !void
ctx.sendError(status: u16, message: []const u8) !void
ctx.sendErrorResponse(status: u16, resp: errors.ErrorResponse) !void
ctx.setHeader(name: []const u8, value: []const u8) !void

// 请求信息（字段）
ctx.method            // Method
ctx.path              // []const u8                         去掉 query 的路径
ctx.raw_path          // []const u8                         原始请求目标（含 query）
ctx.query             // std.StringHashMap([]const u8)
ctx.params            // std.StringHashMap([]const u8)
ctx.headers           // std.StringHashMap([]const u8)
ctx.form              // std.StringHashMap([]const u8)
ctx.status_code       // u16
ctx.response_body     // std.ArrayList(u8)
ctx.response_headers  // std.StringHashMap([]const u8)
ctx.responded         // bool
ctx.deadline_ms       // ?i64  requestTimeout() 写入的截止时间
ctx.upgraded          // bool  WebSocket 升级后置 true

// 内存与依赖注入
ctx.allocator         // std.mem.Allocator
ctx.logger            // log.Logger
ctx.user_data         // ?*anyopaque
```

`Context` **没有** `getRequestId()`、`remote_addr`、`getJwtClaims()`：请求 ID 由 `middleware.requestId()` 写入响应头 `X-Request-ID`；IP 从 `X-Forwarded-For` / `X-Real-Ip` 请求头读取；JWT 校验由 `middleware.jwt()` 完成，通过后 `sub` claim 会以响应头 `X-User-ID` 暴露。

### `http.zig` — HTTP Client

```zig
const http = zigzero.http;
const breaker = zigzero.breaker;

var client = http.Client.init(allocator, .{
    .timeout_ms = 5000,
    .retries = 3,
});

var resp = try client.get("https://api.example.com/data");
defer resp.deinit();

// resp.status_code: u16
// resp.headers: std.StringHashMap([]const u8)
// resp.body: []const u8

// 带 CircuitBreaker
var cb = breaker.CircuitBreaker.new();
client.withBreaker(&cb);

// 透传 trace 上下文
client.withTraceContext(ctx.trace_context);
```

`Client.init(allocator, config: Config) Client`；`Config` 字段为 `timeout_ms: u32`、`retries: u32`、`base_url: ?[]const u8`。`post(url, body, headers: ?std.StringHashMap([]const u8)) !Response`。

### `rpc.zig` — RPC Framework

二进制 RPC over TCP。

```zig
const rpc = zigzero.rpc;

const AddReq = struct { a: u32 };
const AddResp = struct { sum: u32 };

// 服务端：ServiceType 中所有以 rpc_ 开头的函数会被注册为 RPC 方法，
// 签名必须是 fn (*ServiceType, Req) !Resp，body 按 JSON 解码、结果按 JSON 编码
const CalcService = struct {
    pub fn rpc_add(self: *CalcService, req: AddReq) !AddResp {
        _ = self;
        return .{ .sum = req.a + 1 };
    }
};
var calc = CalcService{};

var srv = rpc.Server.init(allocator, .{ .port = 9000 });
try srv.registerService(CalcService, &calc);
try srv.start();          // 阻塞，需另起线程
defer srv.deinit();
_ = srv.boundPort();

// 客户端：方法全名是 "<@typeName(ServiceType)>.<去掉 rpc_ 前缀的名字>"
var cli = rpc.Client.init(allocator, .{});
cli.addEndpoint("127.0.0.1:9000");
const body = try cli.call("main.CalcService.add", .{ .a = 1 });
```

`rpc.Service(comptime T: type) type` 可以提供 `getName()` / `getMethods()` 这类元信息。

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
            const stream = ctx.stream orelse return error.ServerError;
            // 连接比 handler 活得久，用 page_allocator 而不是 ctx.allocator（连接级 arena）
            var conn = try websocket.upgrade(ctx, stream, std.heap.page_allocator);
            ctx.upgraded = true;
            defer conn.close();

            // hub 通过 user_data 传入，不能在嵌套函数里捕获外层局部变量
            const h = @as(*websocket.Hub, @ptrCast(@alignCast(ctx.user_data.?)));
            const room = try h.room("chat");
            try room.join(&conn);
            // 处理消息...
        }
    }.handle,
    .user_data = &hub,
});
```

`websocket.Hub.init(allocator) Hub`、`hub.room(name) !*Room`、`room.join(&conn) !void`、`room.broadcast(data) void`、`websocket.upgrade(ctx, conn, allocator) !Conn`、`conn.readFrame() !Frame`、`conn.writeText(text) !void`。

### `gateway.zig` — API Gateway

反向代理和负载均衡。

```zig
var gw = gateway.Gateway.init(allocator, .{ .timeout_ms = 5000 });
defer gw.deinit(); // 释放上游与每条路由的配置

try gw.addUpstream("user-service", &.{ "127.0.0.1:8081", "127.0.0.1:8082" });

// GatewayRoute 的字段：method / path / upstream / upstream_path / strip_prefix / middleware
const route: gateway.GatewayRoute = .{
    .method = .GET,
    .path = "/api/users/:id",
    .upstream = "user-service",
    .strip_prefix = "/api",
};
try gw.registerRoute(&server, route);
```

`registerRoute` 会把 `GatewayRoute` 复制成内部的 `RouteConfig`（含 `upstream`、`upstream_path`、`strip_prefix` 的副本），这份副本由 `Gateway.deinit()` 释放；调用方只需保证 `gw` 活过服务器。

## server/ — Server Utilities

### `middleware.zig` — Middleware

```zig
const middleware = zigzero.middleware;

// 内置中间件
middleware.requestId()                          // 请求 ID（响应头 X-Request-ID）
middleware.logging()                            // 日志
middleware.recovery()                           // 错误 -> 500
try middleware.cors(allocator, .{ ... })        // CORS
try middleware.jwt(allocator, secret)           // JWT 验证
middleware.rateLimit(&bucket)                   // TokenBucket 限流
middleware.rateLimitByIp(&ip_limiter)           // IP 限流
middleware.loadShedding(&shedder)               // 负载丢弃
try middleware.maxBodySize(allocator, size)     // Body 限制
middleware.requestTimeout(timeout_ms)           // u32
middleware.observability(&registry)            // 指标
middleware.cacheResponses(&response_cache)      // 响应缓存
middleware.validateBody(T, rules)               // body 校验
middleware.healthHandler                        // 健康检查处理器
middleware.prometheusHandler                    // Prometheus 指标处理器

// JWT Token 生成
try middleware.generateToken(allocator, .{
    .sub = "user123",
    .username = "alice",
    .exp = compat.timestamp() + 3600,
}, secret); // ![]u8，调用方负责释放

// JWT Claims（全部字段可选）
pub const Claims = struct {
    sub: ?[]const u8 = null,
    user_id: ?[]const u8 = null,
    username: ?[]const u8 = null,
    exp: ?i64 = null,
    iat: ?i64 = null,
};

// CORS 配置
pub const CorsOptions = struct {
    allow_origins: []const u8 = "*",
    allow_methods: []const u8 = "GET,POST,PUT,DELETE,PATCH,OPTIONS",
    allow_headers: []const u8 = "Content-Type,Authorization,X-Request-ID",
    allow_credentials: bool = false,
    max_age: ?u32 = null,
};
```

`jwt()` 校验失败返回 401；`exp` 过期返回 401（内部先按 `exp` 失败）。`requestTimeout(0)` 表示不设截止时间。`cacheResponses()` 只缓存无凭证的 GET 请求。

### `static.zig` — Static Files

```zig
const static = zigzero.static;

var files = static.Server.init(allocator, "public");
try server.addRoute(.{
    .method = .GET,
    .path = "/*file",
    .handler = files.handler(),
    .user_data = &files,   // 处理器没有自身状态，服务器实例经 user_data 传入
});
```

`static.Server.init(allocator, root_dir) Server`、`Server.handler() api.HandlerFn`、`static.guessMimeType(path) []const u8`。

`handler()` 返回一个不捕获任何状态的固定处理函数，因此服务器实例必须通过路由的 `.user_data` 传入，处理器内部用 `@ptrCast(@alignCast(ctx.user_data))` 取回；`files` 要活过服务器。处理器把 `ctx.raw_path` 原样拼在 `root_dir` 之后，所以每条路由的路径要能对应到磁盘上的相对路径。

路由树按路径段匹配：精确段、单段 `:param` / `{param}`，以及**尾段通配** `*name`（或裸 `*`，捕获名为 `"*"`）。通配捕获该段及其之后的全部剩余路径（含分隔符），因此 `/*file` 一次覆盖多级目录；它必须是模式的最后一段，且不能与同层的 `:param` 共存——两者范围重叠，注册时返回 `error.InvalidRoute`。匹配优先级：精确段 > `:param` > 通配。不存在的路径返回 404。

## infra/ — Infrastructure

### `log.zig` — Logging

```zig
const log = zigzero.log;

log.initFromConfig(.{ .service_name = "myapp", .level = "info" });
const logger = log.Logger.new(.info, "my-service");

// 注意：Logger 的 info/warn/err/debug 只接收一条已格式化好的字符串
const msg = try std.fmt.allocPrint(allocator, "Request processed: {d} in {d}ms", .{ 200, 45 });
defer allocator.free(msg);
logger.info(msg);

logger.warn("High latency");
logger.err(@errorName(err));

// JSON 编码 / 文件轮转
const json_logger = logger.withJson();
var file_logger = try logger.withFile(allocator, "app.log", 100 * 1024 * 1024, 30);
```

`Logger.new(level: Level, service_name: []const u8) Logger`；`FileLogger.init(allocator, path, max_size, max_backups) !FileLogger`。

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

counter.inc();
counter.add(2);
gauge.inc();
gauge.dec();
gauge.set(42);
hist.observe(45.5);

try registry.exportPrometheus(writer);
```

`Registry.counter/gauge/histogram` 返回指向注册表持有对象的 `!*Counter` / `!*Gauge` / `!*Histogram`；`inc`/`dec`/`set`/`observe` 返回 `void`（不要加 `try`）。`exportPrometheus(writer)` 需要带 `writeAll` 的 writer。

### `health.zig` — Health Checks

```zig
const health = zigzero.health;

var registry = health.Registry.init(allocator);
defer registry.deinit();

try registry.register("memory", health.checks.memory);
try registry.register("disk", health.checks.disk);

// 自定义检查：*const fn (std.mem.Allocator) anyerror!health.Result
try registry.register("database", myCheckFn);

// 内置检查的阈值/探针在启动时配置（全局，只配一次）
health.checks.configureMemory(.{ .limit_bytes = 512 * 1024 * 1024 });          // 返回 void
try health.checks.configureDisk(.{ .path = "/", .min_free_bytes = 1024 * 1024 }); // 返回 !void

var results = try registry.checkAll();     // !std.StringHashMap(Result)，需 var 才能 deinit
defer results.deinit();
const overall = try registry.overall();    // !Status{ healthy, degraded, unhealthy }
```

### `limiter.zig` — Rate Limiting

```zig
const limiter = zigzero.limiter;

// IP 级别限流
var ip_limiter = limiter.IpLimiter.init(allocator, 100.0, 10);
defer ip_limiter.deinit();
const ok: bool = ip_limiter.allow("192.168.1.1");

// Token Bucket（无 allocator，纯值类型）
var bucket = limiter.TokenBucket.new(100.0, 10);
const allowed: bool = bucket.allow();
const more: bool = bucket.allowN(5);

// Sliding Window
var window = try limiter.SlidingWindow.init(allocator, 100.0, 1); // rate/秒, 窗口秒数
defer window.deinit();
const ok2: bool = window.allow();

// 按名字共享的全局 limiter
limiter.initGlobalLimiters(allocator);
const shared = limiter.getLimiter("getUser", .{ .rate = 100.0, .burst = 10 });
```

### `breaker.zig` — Circuit Breaker

```zig
const breaker = zigzero.breaker;

var cb = breaker.CircuitBreaker.new();
// 或 custom config
var cb2 = breaker.CircuitBreaker.withConfig(.{
    .request_threshold = 10,
    .failure_rate_threshold = 50,   // 百分比
    .sleep_duration_sec = 30,
    .half_open_success_threshold = 3,
});

if (cb.allow()) {
    const result = doCall() catch {
        cb.recordFailure();
        return;
    };
    cb.recordSuccess();
    _ = result;
}

const state = cb.getState(); // .closed / .open / .half_open
cb.close();                  // 复位为关闭
```

`CircuitBreaker` 没有 `execute()`、`getStats()`、`forceOpen()`/`forceClose()`：调用方自己决定在 `allow()` 通过后记录成功或失败。

### `load.zig` — Adaptive Load Shedding

```zig
const load = zigzero.load;

var shedder = try load.newAdaptiveShedder(allocator, .{
    .window_ms = 1000,
    .buckets = 10,
    .cpu_threshold = 80,
});
defer shedder.deinit();

// allow() 返回 Promise；被丢弃时返回 error.ServiceOverloaded
if (shedder.allow()) |promise| {
    doWork() catch {
        promise.fail();
        return;
    };
    promise.pass();
} else |_| {
    // 过载，拒绝请求
}
```

`load.AdaptiveShedder.init(allocator, opts: ShedderOptions) !Self`、`NopShedder` 永不丢弃。

### `sqlx.zig` — SQL Client

```zig
const sqlx = zigzero.sqlx;

var client = sqlx.Client.init(allocator, .{
    .driver = .sqlite,
    .sqlite_path = "data.db",
});
defer client.deinit();

const id: i64 = 1;
const name = "Alice";

// 连接与查询：参数是 []const Value
const rows = try client.query("SELECT * FROM users WHERE id = ?", &.{.{ .int = id }});
defer rows.deinit();
for (rows.rows) |row| {
    if (row.get("name")) |value| {
        if (value == .string) std.debug.print("{s}\n", .{value.string});
    }
}

const res = try client.exec("INSERT INTO users (name) VALUES (?)", &.{.{ .string = name }});
const new_id = res.last_insert_id;

// 事务：回调接收 *sqlx.Transaction
const inserted = try client.transact(usize, struct {
    fn run(tx: *sqlx.Transaction) !usize {
        try tx.exec("INSERT ...", &.{});
        return 1;
    }
}.run);
```

`Config` 字段：`driver: Driver{ sqlite, postgres, mysql }`、`host`、`port`、`database`、`username`、`password`、`sqlite_path`、`postgres_conninfo`、`max_open_conns`、`max_idle_conns`、`max_wait_ms`。

`Client` 其它成员：`connect() !void`、`prepare(sql) !Stmt`、`queryRow(T, sql, args) !T`（`T` 必须是结构体，内部走 `scanStruct`）、`ping() !void`、`beginTx() !Transaction`；按连接也提供了 `sqlx.SQLiteConn.open(allocator, path)`、`sqlx.PostgresConn.connect(allocator, conninfo)`、`sqlx.MySqlConn.connect(allocator, host, user, password, db, port)`，它们可通过 `toConn()` 转成统一的 `Conn`。

`Row.get(column: []const u8) ?Value`；`Row.scan(allocator, T) !T` 做结构体扫描。参数占位符按驱动支持 `?` / `$1` 等。

See [SQLx Guide](../guides/sqlx.md) for full documentation including transactions, struct scanning, query builder, CachedConn, circuit breaker integration, and metrics.

### `redis.zig` — Redis Client

```zig
const redis = zigzero.redis;
const config = zigzero.config;

var client = try redis.Redis.new(allocator, .{
    .host = "127.0.0.1",
    .port = 6379,
    .db = 0,
});
defer client.deinit();
try client.connect();

// 字符串
try client.set("key", "value", 60); // ex_seconds: ?u32
const val = try client.get("key");  // ?[]const u8

// Hash / List
try client.hSet("user:1", "name", "alice");  // errors.ResultT(bool)：该字段是否新建
const name = try client.hGet("user:1", "name");

try client.lPush("queue", "item");
const item = try client.rPop("queue");

// 分布式锁（unlock 只接收 key）
const locked = try client.lock("my-lock", "token", 30);
try client.unlock("my-lock");

// 连接池
var pool = try redis.RedisPool.init(allocator, .{}, 10);
defer pool.deinit();
try pool.connect();
const conn = try pool.acquire();
defer pool.release(conn);
```

Redis 方法返回 `errors.ResultT(T)` / `errors.Result`（即 `Error!T` / `Error!void`），调用方需处理该错误集。方法名是 camelCase：`setNX`、`lPush`、`rPop`、`hSet`、`hGet`、`publish`。

### `cache.zig` — LRU Cache

```zig
const cache = zigzero.cache;

// K 必须能被 std.hash.autoHash 哈希：切片不行（[]const u8 会触发编译错误），
// 用整数或定长结构体；middleware.ResponseCache 内部就用 u64
var c = cache.Cache(u64, []const u8).init(allocator, 1000);
defer c.deinit();

try c.set(1, "value", 3600_000); // ttl_ms: ?i64，null = 不过期
const val = c.get(1);            // ?[]const u8
c.delete(1);
_ = c.size();
```

`Cache(K, V)` 也支持 `clear()` 和可选的 `on_evict` 回调（`EvictFn`），用于释放持有资源的 value。

### `mq.zig` — Message Queue

```zig
const mq = zigzero.mq;

var queue = mq.Queue.init(allocator);
defer queue.deinit();

// 订阅需要一个 handler + 任意 context（*anyopaque，不可省），返回订阅 id
var sub_state: u32 = 0;
const id = try queue.subscribe("topic", struct {
    fn onMessage(context: *anyopaque, msg: mq.Message) void {
        _ = context;
        std.debug.print("Got: {s}\n", .{msg.payload});
    }
}.onMessage, &sub_state);

try queue.publish("topic", "message");
queue.unsubscribe(id);

// 需要后台派发线程时
try queue.start();
queue.stop();
```

`mq.PersistentQueue.init(allocator, data_dir, queue_name)` 提供带 `enqueue` / `dequeue(consumer_group, max_messages)` / `ack` 的持久队列。

### `lifecycle.zig` — Graceful Shutdown

```zig
const lifecycle = zigzero.lifecycle;

var lc = lifecycle.Manager.init(allocator);
defer lc.deinit();

// context 是 *anyopaque（不可省，传 null 无法编译）
var cleanup_ctx: u8 = 0;
try lc.onShutdown("cleanup", struct {
    fn run(_: *anyopaque) void { /* 释放资源 */ }
}.run, &cleanup_ctx);

try server.start();
lc.run();      // 阻塞直到 shutdown()，然后按 LIFO 执行钩子
lc.shutdown(); // 置停止标志，让 run() 返回

_ = lc.isRunning();
lc.wait(1000); // 最多等待 1000ms，期间持续检查运行状态
```

`Manager` 没有 `configure()` / `getStatus()`；钩子回调签名为 `*const fn (*anyopaque) void`。

### `cron.zig` — Scheduler

```zig
const cron = zigzero.cron;

var scheduler = cron.Scheduler.init(allocator);
defer scheduler.deinit();

// 计划用 Expression 表达（minute/hour/day/month/dow，0 表示不限制）
// context 是 *anyopaque（不可省）
var job_ctx: u8 = 0;
try scheduler.addJob("hourly", .{ .minute = 0 }, struct {
    fn run(_: *anyopaque) void {
        std.debug.print("Hourly task\n", .{});
    }
}.run, &job_ctx);

try scheduler.start();
scheduler.stop();

// 或者只按秒间隔执行
cron.every(30, struct {
    fn run(_: *anyopaque) void { /* ... */ }
}.run, &job_ctx);
```

`scheduler.addJob(name, schedule: Expression, task, context) !void`——没有接受 cron 字符串的 `schedule()`；`Expression` 也不解析 `"0 * * * *"` 这类文本，需要逐字段填写。

### `pool.zig` — Connection Pool

```zig
const pool = zigzero.pool;

var p = try pool.Pool(DbConn).init(
    allocator,
    createFn,   // *const fn () errors.ResultT(*DbConn)
    destroyFn,  // *const fn (*DbConn) void
    validateFn, // *const fn (*DbConn) bool
    .{ .min_idle = 2, .max_active = 10, .max_wait_ms = 5000 },
);
defer p.deinit();

const conn = try p.acquire();
defer p.release(conn);
```

`Config` 字段：`min_idle`、`max_active`、`max_wait_ms`、`max_idle_time_ms`。池满且等待超时返回 `error.Timeout`。

`Pool(T)` 里的 `T` 是**连接类型本身**（不是指针）：`Node.conn` 为 `*T`，工厂函数返回 `errors.ResultT(*T)`。所以用 `Pool(DbConn)` 配 `fn () errors.ResultT(*DbConn)`，不要写 `Pool(*DbConn)`。

### `retry.zig` — Retry with Backoff

```zig
const retry = zigzero.retry;

const MyType = u32;
fn doCall() zigzero.errors.ResultT(MyType) { return 1; }

// Policy 字段：max_attempts / initial_delay_ms / max_delay_ms / multiplier / jitter(f64)
const policy = retry.Policy{
    .max_attempts = 3,
    .initial_delay_ms = 100,
    .max_delay_ms = 2000,
    .multiplier = 2.0,
    .jitter = 0.1,
};

const result = try retry.retry(MyType, policy, struct {
    fn attempt() zigzero.errors.ResultT(MyType) { return doCall(); }
}.attempt);

// void 版本
try retry.retryVoid(policy, struct {
    fn attempt() zigzero.errors.Result { return; }
}.attempt);

// 与熔断器组合
var cb = zigzero.breaker.CircuitBreaker.new();
const v = try retry.retryWithBreaker(MyType, policy, &cb, struct {
    fn attempt() zigzero.errors.ResultT(MyType) { return doCall(); }
}.attempt);
```

### `lock.zig` — Distributed Locks

```zig
const lock = zigzero.lock;

var redis_lock = lock.RedisLock.init(client); // client: *redis.Redis
const acquired = try redis_lock.acquire("my-lock", "token", 30); // ttl_seconds
if (acquired) {
    defer _ = redis_lock.release("my-lock", "token") catch {};
    // 临界区...
}
try redis_lock.renew("my-lock", "token", 30);

// 进程内锁
var local = lock.LocalLock.init();
_ = try local.acquire("my-lock", "token", 30);
```

## data/ — Data Layer

### `orm.zig` — ORM Query Builder

```zig
const orm = zigzero.orm;

var pool = orm.Pool.init(allocator, .{ .database = "app", .username = "root", .password = "", .port = 3306 });
defer pool.deinit();
const conn = try pool.acquire();
defer pool.release(conn);

const users = try conn.query(User, "SELECT * FROM users", .{});
const changed = try conn.execute("UPDATE users SET name = ? WHERE id = ?", .{ "Alice", 1 });

// 查询构建器（where 返回 !*Query，需要 try）
var q = orm.Query.init(allocator, "users");
defer q.deinit();
_ = try q.select("*").where("age > ?");   // 链式：.order("name").limit(10).offset(0)
const sql = try q.build();
```

`orm.Connection.query` / `execute` 目前是占位实现（返回空结果 / 0），生产存储请优先用 `sqlx`。

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

const req = UserReq{ .name = "alice", .email = "alice@example.com", .age = 20 };

// 返回分配好的错误信息（调用方释放），通过时为 null
if (try validate.validateStruct(allocator, req, rules)) |msg| {
    defer allocator.free(msg);
    return error.ValidationError;
}
```

`validateStruct(allocator, value, rules) !?[]const u8`。`FieldRules` 字段：`required`、`min_len`、`max_len`、`min: ?i64`、`max: ?i64`、`email`、`uuid`、`phone`、`url`、`one_of: ?[]const u8`（逗号分隔）。单字段校验函数：`notEmpty`、`minLength`、`maxLength`、`email`、`phone`、`range`、`oneOf`、`uuid`、`url`。

## core/ — Core Utilities

### `fx.zig` — Stream / Parallel

```zig
const fx = zigzero.fx;

const items = [_]u32{ 1, 2, 3, 4 };

// 并行遍历
try fx.Parallel(u32, allocator, &items, 4, struct {
    fn work(item: u32) void { std.debug.print("{d}\n", .{item}); }
}.work);

// 并行 map
const out = try fx.Map(u32, u32, allocator, &items, 4, struct {
    fn square(x: u32) u32 { return x * x; }
}.square);
defer allocator.free(out);

// 链式流
var s = try fx.Stream(u32).fromSlice(allocator, &items);
defer s.deinit();
s.filter(struct {
    fn keep(x: u32) bool { return x > 1; }
}.keep);
const mapped = try s.map(allocator, u32, struct {
    fn dbl(x: u32) u32 { return x * 2; }
}.dbl);
defer allocator.free(mapped);
const sum = s.reduce(0, struct {
    fn add(a: u32, b: u32) u32 { return a + b; }
}.add);
_ = sum;
```

`Stream` 提供 `fromSlice`、`add`、`map`、`filter`、`reduce`、`toSlice`；`max_workers = 0` 表示并发度为元素个数。

### `mapreduce.zig` — Map/Reduce

```zig
const items = [_]u32{ 1, 2, 3, 4 };
const mr = zigzero.mapreduce.MapReduce(u32, u32).init(allocator, 2);

const squared = try mr.map(&items, struct {
    fn square(x: u32) u32 { return x * x; }
}.square);
defer allocator.free(squared);

const sum = try mr.reduce(squared, 0, struct {
    fn add(a: u32, b: u32) u32 { return a + b; }
}.add);

const total = try mr.mapReduce(&items, struct {
    fn square(x: u32) u32 { return x * x; }
}.square, 0, struct {
    fn add(a: u32, b: u32) u32 { return a + b; }
}.add);

try mr.forAll(&items, struct {
    fn work(x: u32) void { _ = x; }
}.work);

_ = sum;
_ = total;
```

## config.zig — Configuration

```zig
const config = zigzero.config;

// 从文件按路径加载（loadYaml / loadJson 内部自行读文件）
const cfg1 = try config.loadYaml(MyConfig, allocator, "config.yaml");
defer config.Loader.init(allocator).freeConfig(MyConfig, &cfg1);

const cfg2 = try config.loadJson(MyConfig, allocator, "config.json");
defer config.Loader.init(allocator).freeConfig(MyConfig, &cfg2);

// 泛型加载：T 是目标配置结构体
const cfg3 = try config.loadEnv(MyConfig, allocator, "APP");
defer config.Loader.init(allocator).freeConfig(MyConfig, &cfg3);

// 对象式 API
var loader = config.Loader.init(allocator);
const cfg5 = try loader.parseJson(MyConfig, "{\"port\":8080}");
defer loader.freeConfig(MyConfig, &cfg5);
const cfg6 = try loader.parseYaml(MyConfig, "port: 8080");
defer loader.freeConfig(MyConfig, &cfg6);
```

**所有权**：`loadYaml` / `loadJson` / `loadEnv`（以及 `Loader` 上的同名方法与 `Watcher.reload`）返回的配置里，每个字符串都由 loader 的 allocator 持有；释放时调用 `Loader.freeConfig(T, &cfg)`，它递归处理嵌套结构体与字符串数组——**不要手工 `free` 单个字段**。`Watcher.hasChanged` / `reload` / `watch` 均可正常使用。

没有 `loadFromYamlFile` / `loadFromJsonFile`。YAML 解析器是简化子集，**不做 `${VAR:-default}` 环境变量替换**；需要环境变量时用 `loadEnv(T, allocator, prefix)`（前缀 + 大写字段名，如 `APP_PORT`）。内置结构：`Config`、`LogConfig`、`RedisConfig`、`MysqlConfig`、`EtcdConfig`。

## svc.zig — Service Context

服务上下文：持有配置、日志和按需创建的 Redis 客户端。

```zig
const svc = zigzero.svc;

var context = try svc.Context.init(allocator, &cfg, logger);
defer context.deinit();

const rds = try context.getRedis();       // 首次调用时创建并连接
try context.setMetadata("trace_id", id);
_ = context.getMetadata("trace_id");

// Builder 形式
var built = try svc.Builder.init(allocator)
    .withConfig(&cfg)
    .withLogger(logger)
    .build();
defer built.deinit();
```

`svc.Context` 没有泛型 `register` / `get(*T)` 依赖容器；应用级共享状态请按 `examples/chy3` 的做法放进自己的 `AppContext`，通过路由的 `.user_data` 传给处理器。
