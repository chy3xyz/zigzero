# Metrics & Observability

使用 Prometheus 指标和健康检查实现可观测性。

## 指标注册表

`metric.Registry` 是三种指标（Counter / Gauge / Histogram）的容器，按名称去重：

```zig
const std = @import("std");
const zigzero = @import("zigzero");
const compat = zigzero.compat;
const metric = zigzero.metric;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    compat.initIo(allocator);
    defer compat.deinitIo();

    var registry = metric.Registry.init(allocator);
    defer registry.deinit();

    // 创建指标...
}
```

创建方法都会返回指向注册表内部实例的指针，同名重复调用返回同一个实例：

```zig
pub fn counter(self: *Registry, name: []const u8, help: []const u8) !*Counter
pub fn gauge(self: *Registry, name: []const u8, help: []const u8) !*Gauge
pub fn histogram(self: *Registry, name: []const u8, help: []const u8, buckets: []const f64) !*Histogram
```

## 指标类型

### Counter（计数器）

单调递增，用于请求总数、错误计数等。`inc()` 返回 `void`，不要加 `try`：

```zig
const requests_total = try registry.counter(
    "http_requests_total",
    "Total number of HTTP requests",
);

pub fn handleRequest() void {
    requests_total.inc();      // 加 1
    // requests_total.add(5);  // 加 5
}
```

| 方法 | 签名 | 说明 |
|------|------|------|
| `inc()` | `fn (*Counter) void` | 加 1 |
| `add(value)` | `fn (*Counter, u64) void` | 加指定值 |
| `get()` | `fn (*const Counter) u64` | 读取当前值 |
| `setLabel(k, v)` | `fn (*Counter, []const u8, []const u8) !void` | 设置一个标签 |

标签是该实例上的一个 `StringHashMap`，不是每次调用的参数——没有 `incBy`、`incWithLabels`、`.labels` 选项。需要不同标签组合时，请创建不同名称的指标：

```zig
const get_requests = try registry.counter("http_requests_get_total", "GET requests");
const post_requests = try registry.counter("http_requests_post_total", "POST requests");
```

### Gauge（仪表）

可增可减，用于当前连接数、队列深度等。所有修改方法都返回 `void`：

```zig
const active_connections = try registry.gauge(
    "active_connections",
    "Number of active connections",
);

active_connections.inc();     // +1
active_connections.dec();     // -1
active_connections.add(5);    // +5
active_connections.set(42);   // 设为 42
```

`set()` 的参数类型是 `i64`。

### Histogram（直方图）

用于延迟、请求大小等分布统计。buckets 必须按升序传入：

```zig
const request_duration_ms = try registry.histogram(
    "http_request_duration_ms",
    "HTTP request duration in milliseconds",
    &.{ 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000 },
);

pub fn handleRequest() !void {
    const start = compat.milliTimestamp();
    defer {
        const elapsed = compat.milliTimestamp() - start;
        request_duration_ms.observe(@floatFromInt(elapsed));
    }
    // 处理请求...
}
```

`observe()` 返回 `void`。每个样本只在第一个满足 `value <= bucket` 的桶里 +1；超过所有 buckets 的样本只计入 `_sum` / `_count`。

## Observability 中间件

自动记录请求计数和延迟：

```zig
try server.addMiddleware(middleware.observability(&registry));
```

它固定生成两个指标（**都不带标签**，名称与 buckets 都是写死的）：

- `http_requests_total` — 请求总数计数器，help 为 `Total HTTP requests`
- `http_request_duration_ms` — 延迟直方图，单位毫秒，buckets `{10, 50, 100, 250, 500, 1000, 2500, 5000, 10000}`

它还会为每个请求创建一个 trace span，并把 `X-Trace-ID` 写入响应头。

## Prometheus 导出端点

```zig
try server.addRoute(.{
    .method = .GET,
    .path = "/metrics",
    .handler = middleware.prometheusHandler,
    .user_data = &registry,
});
```

访问 `http://localhost:8080/metrics` 查看（导出格式由 `exportPrometheus` 决定）：

```
# HELP http_requests_total Total HTTP requests
# TYPE http_requests_total counter
http_requests_total 1523

# HELP http_request_duration_ms HTTP request duration in milliseconds
# TYPE http_request_duration_ms histogram
http_request_duration_ms_bucket{le="10.000"} 120
http_request_duration_ms_bucket{le="50.000"} 1200
...
http_request_duration_ms_bucket{le="+Inf"} 1523
http_request_duration_ms_sum 81234.000
http_request_duration_ms_count 1523
```

多个指标实例各自输出一组 `# HELP` / `# TYPE`，用不同名称区分。

## 健康检查

### 注册健康检查

```zig
const health = zigzero.health;

var health_registry = health.Registry.init(allocator);
defer health_registry.deinit();

try health_registry.register("memory", health.checks.memory);
try health_registry.register("disk", health.checks.disk);
```

`register(name, checker)` 的 checker 类型是 `*const fn (std.mem.Allocator) anyerror!Result`。

### 内置健康检查

| 检查 | 功能 |
|------|------|
| `health.checks.memory` | 测量进程 RSS；超过配置的 `limit_bytes` 时报告 `unhealthy` |
| `health.checks.disk` | 用 `statvfs` 测量指定路径的可用空间；低于 `min_free_bytes` 时报告 `unhealthy` |

框架只内置这两个。没有 `health.checks.tcp` / `health.checks.http`；需要探测 TCP/HTTP 时自行注册。

两者在启动时通过 `checks.configure*` 配置（0 表示不设限：仍会测量并报告，但不会因超限失败）：

```zig
// 可选：进程 RSS 上限 512MB
health.checks.configureMemory(.{ .limit_bytes = 512 * 1024 * 1024 });

// 可选：根文件系统至少保留 1GB 空闲
try health.checks.configureDisk(.{ .path = "/", .min_free_bytes = 1024 * 1024 * 1024 });
```

探针无法测量时（例如平台不支持或读取失败），检查返回 `degraded` 并附带 `unmeasured: <错误名>` 消息，而不是谎报健康。

### 自定义健康检查

返回类型是 `health.Result`（字段 `name`、`status`、`message`、`timestamp`），没有 `CheckResult` 类型：

```zig
try health_registry.register("database", struct {
    fn check(allocator: std.mem.Allocator) anyerror!health.Result {
        _ = allocator;
        db.ping() catch |err| {
            return health.Result.init("database", .unhealthy).withMessage(@errorName(err));
        };
        return health.Result.init("database", .healthy).withMessage("connected");
    }
}.check);
```

`Result.init(name, status)` 创建结果，`withMessage(msg)` 追加说明。`Status` 是 `healthy` / `unhealthy` / `degraded`。checker 返回 error 时，`checkAll()` 会把它转换成 `unhealthy` 结果并把错误名当作 message，整体不会失败。

### 健康检查端点

```zig
try server.addRoute(.{
    .method = .GET,
    .path = "/health",
    .handler = middleware.healthHandler,
    .user_data = &health_registry,
});
```

响应：

```json
// GET /health
{
  "status": "healthy",
  "checks": {
    "memory": { "status": "healthy" },
    "disk": { "status": "healthy" },
    "database": { "status": "healthy", "message": "connected" }
  }
}
```

任一项 `unhealthy` 时 HTTP 状态码为 503，否则 200。`degraded` 不会改变整体状态（`overall()` 只在存在 `unhealthy` 时返回 `unhealthy`）。

### 就绪探针 vs 存活探针

框架只提供 `Registry.overall()` 这一种整体判定，没有内置 `/health/live` 或 `/health/ready`。需要区分时自己注册两条路由，各自传入不同的 registry：

```zig
// 存活探针 (liveness) — 进程是否存活，永远返回 200
try server.addRoute(.{ .method = .GET, .path = "/health/live", .handler = liveHandler });

// 就绪探针 (readiness) — 依赖是否就绪，复用 healthHandler
try server.addRoute(.{
    .method = .GET,
    .path = "/health/ready",
    .handler = middleware.healthHandler,
    .user_data = &health_registry,
});
```

## 自定义业务指标

### 业务计数器

```zig
const user_registrations = try registry.counter(
    "user_registrations_total",
    "Total user registrations",
);

pub fn handleRegister(ctx: *api.Context) !void {
    _ = try ctx.bindJson(CreateUserReq);
    user_registrations.inc();
    try ctx.jsonStruct(201, .{ .status = "created" });
}
```

### 带标签的指标

标签通过 `setLabel` 设置在该指标实例上（整个进程共享一份），不要用它承载请求级别的维度：

```zig
const orders_by_status = try registry.counter(
    "orders_total",
    "Total orders by status",
);
orders_by_status.setLabel("unit", "usd") catch {};

pub fn handleOrder(ctx: *api.Context) !void {
    _ = try ctx.bindJson(OrderReq);
    orders_by_status.inc();
}
```

### 仪表类指标

```zig
const queue_depth = try registry.gauge(
    "job_queue_depth",
    "Current job queue depth",
);

const active_worlds = try registry.gauge(
    "chy3_active_worlds",
    "Active metaverse worlds",
);
```

## Prometheus 抓取配置

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'my-service'
    static_configs:
      - targets: ['localhost:8080']
    metrics_path: /metrics
    scrape_interval: 15s
```

## Grafana 仪表板建议

| 面板 | 指标 |
|------|------|
| 请求 QPS | `rate(http_requests_total[5m])` |
| P99 延迟 | `histogram_quantile(0.99, rate(http_request_duration_ms_bucket[5m]))` |
| 活跃连接 | `active_connections` |
| 队列深度 | `job_queue_depth` |

`http_requests_total` 没有 `status` 标签，无法用它计算错误率；错误率需要另外注册专门的计数器。

## 日志

除了指标，日志也是可观测性的重要组成。`Logger.info` 只接受一条完整的消息字符串（没有结构化字段重载）：

```zig
const log = zigzero.log;

const logger = log.Logger.new(.info, "my-service");

pub fn handleRequest(ctx: *api.Context, status_code: u16, elapsed: i64) void {
    const msg = std.fmt.allocPrint(
        ctx.allocator,
        "request processed method={s} path={s} status={d} duration_ms={d}",
        .{ ctx.method.toString(), ctx.path, status_code, elapsed },
    ) catch return;
    defer ctx.allocator.free(msg);
    logger.info(msg);
}
```

需要 JSON 行格式时用 `log.Logger.new(.info, "my-service").withJson()`，消息会被放进 `"message"` 字段。

## 下一步

- [Rate Limiting](rate-limiting.md) — 速率限制配置
- [Circuit Breaker](circuit-breaker.md) — 熔断器模式
- [Graceful Shutdown](graceful-shutdown.md) — 健康检查与关闭集成
