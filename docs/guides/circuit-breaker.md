# Circuit Breaker

断路器模式防止级联故障。当下游服务不可用时，快速失败而不是无限等待。

`breaker.CircuitBreaker` 是一个纯值类型：不持有分配器、没有 `deinit`，直接用 `new()` 或 `withConfig()` 创建即可。

## 工作原理

```
closed    → 请求通过；失败请求数达到 request_threshold 且失败率 >= failure_rate_threshold → open
    ↓
open      → 立即拒绝（allow() 返回 false）；经过 sleep_duration_sec → half_open
    ↓
half_open → 放行探测请求
    ↓
连续成功 >= half_open_success_threshold → closed
任一次失败 → 立即回到 open（重新计时）
```

## 状态与配置

```zig
pub const State = enum { closed, open, half_open };

pub const Config = struct {
    request_threshold: u32 = 10,            // 计算失败率所需的最小请求数
    failure_rate_threshold: u32 = 50,       // 失败率阈值（百分比 0-100）
    sleep_duration_sec: u64 = 30,           // open 停留多久后转 half_open
    half_open_success_threshold: u32 = 3,   // half_open 中连续成功多少次才关闭
};
```

| 字段 | 默认值 | 说明 |
|------|--------|------|
| `request_threshold` | 10 | 样本不足时不评估失败率 |
| `failure_rate_threshold` | 50 | 失败率百分比阈值，达到即打开 |
| `sleep_duration_sec` | 30 | open → half_open 的等待秒数 |
| `half_open_success_threshold` | 3 | half_open 关闭所需的连续成功次数 |

## 基础使用

```zig
const zigzero = @import("zigzero");
const breaker = zigzero.breaker;

// 默认配置
var cb_default = breaker.CircuitBreaker.new();

// 自定义配置
var cb = breaker.CircuitBreaker.withConfig(.{
    .request_threshold = 10,
    .failure_rate_threshold = 50,
    .sleep_duration_sec = 30,
    .half_open_success_threshold = 3,
});
```

`CircuitBreaker` 没有 `execute()` 之类的包装函数，调用方需要显式检查 `allow()`，再根据结果记录成功或失败：

```zig
var cb = breaker.CircuitBreaker.new();

fn callExternal(url: []const u8) ![]const u8 {
    if (!cb.allow()) {
        // 断路器打开，或尚未到重试时间
        return error.CircuitBreakerOpen;
    }

    const body = fetch(url) catch |err| {
        cb.recordFailure();
        return err;
    };

    cb.recordSuccess();
    return body;
}
```

`allow()` 返回普通 `bool`，不是 error union。

## API 一览

| 方法 | 签名 | 说明 |
|------|------|------|
| `new()` | `fn () CircuitBreaker` | 使用默认配置创建 |
| `withConfig(config)` | `fn (Config) CircuitBreaker` | 使用自定义配置创建 |
| `allow()` | `fn (*CircuitBreaker) bool` | 是否放行；open 且未到期返回 false |
| `recordSuccess()` | `fn (*CircuitBreaker) void` | 记录成功；half_open 下累计到阈值即关闭 |
| `recordFailure()` | `fn (*CircuitBreaker) void` | 记录失败；可能触发打开 |
| `close()` | `fn (*CircuitBreaker) void` | 关闭并清零所有计数器 |
| `getState()` | `fn (*const CircuitBreaker) State` | 读取当前状态 |

计数器与时间戳（`total_requests`、`successful_requests`、`failed_requests`、`last_failure_time`、`opened_at`）都是公开字段，可以直接读取用于统计。

## HTTP 客户端集成

`http.Client` 内置了断路器挂钩：`withBreaker()` 传入一个 `*CircuitBreaker` 后，`request()` 会自动检查 `allow()` 并记录结果。

```zig
const http = zigzero.http;

var client = http.Client.init(allocator, .{ .timeout_ms = 5000 });
var cb = breaker.CircuitBreaker.withConfig(.{
    .request_threshold = 10,
    .failure_rate_threshold = 50,
    .sleep_duration_sec = 30,
    .half_open_success_threshold = 3,
});
client.withBreaker(&cb);

try server.addRoute(.{
    .method = .GET,
    .path = "/proxy/:service",
    .handler = struct {
        fn handle(ctx: *api.Context) !void {
            const service = ctx.param("service") orelse return error.BadRequest;
            const url = try std.fmt.allocPrint(
                ctx.allocator,
                "https://{s}.api.example.com/data",
                .{service},
            );
            defer ctx.allocator.free(url);

            const http_client = @as(*http.Client, @ptrCast(@alignCast(ctx.user_data.?)));
            var resp = http_client.get(url) catch {
                // 断路器打开（error.CircuitBreakerOpen）或请求失败
                try ctx.sendError(503, "service temporarily unavailable");
                return;
            };
            defer resp.deinit();

            try ctx.setHeader("Content-Type", "application/json");
            try ctx.json(200, resp.body);
        }
    }.handle,
    .user_data = &client,
});
```

集成语义：断路器打开时 `request()` 返回 `errors.Error.CircuitBreakerOpen`；响应状态码 `>= 500` 或传输错误时调用 `recordFailure()`，其余响应调用 `recordSuccess()`。`withBreaker` 保存的是指针，所以请让 `cb` 在整个服务生命周期内保持有效（例如放在全局或 `main` 的栈上）。注意 `cb` 不能是临时局部变量的地址。

## 数据库调用保护

```zig
var db_cb = breaker.CircuitBreaker.withConfig(.{
    .request_threshold = 5,
    .failure_rate_threshold = 60,
    .sleep_duration_sec = 10,
    .half_open_success_threshold = 2,
});

fn queryWithProtection(query: []const u8) ![]const u8 {
    if (!db_cb.allow()) {
        return error.CircuitBreakerOpen;
    }
    const rows = db.query(query) catch |err| {
        db_cb.recordFailure();
        return err;
    };
    db_cb.recordSuccess();
    return rows;
}
```

## 与重试结合

断路器 + 指数退避重试 = 最佳实践。框架提供了组合两者的 `retry.retryWithBreaker`：它在每次尝试前检查 `allow()`，自动调用 `recordSuccess()` / `recordFailure()`，断路器打开时立即返回 `errors.Error.CircuitBreakerOpen`。

```zig
const retry = zigzero.retry;
const errors = zigzero.errors;

fn attempt() errors.ResultT(http.Response) {
    // 只做实际工作；放行检查与结果记录由 retryWithBreaker 负责
    const resp = try http_client.get("https://api.example.com/data");
    if (resp.status_code >= 500) return errors.Error.ServerError;
    return resp;
}

fn callWithRetry() errors.ResultT(http.Response) {
    return retry.retryWithBreaker(http.Response, .{
        .max_attempts = 3,
        .initial_delay_ms = 100,
        .max_delay_ms = 2000,
        .multiplier = 2.0,
        .jitter = 0.1,
    }, &cb, attempt);
}
```

执行顺序：`allow()` → `attempt` → 记录结果 → 失败则退避重试：

1. 请求失败 → `recordFailure()` 后按策略退避重试
2. 失败样本与失败率同时达到阈值 → 断路器打开
3. 打开期间 `allow()` 返回 false → 立即返回 `error.CircuitBreakerOpen`，不再发起真实请求
4. `sleep_duration_sec` 之后 → half_open，放行探测请求
5. 探测成功数达到 `half_open_success_threshold` → 断路器关闭

不需要断路器时用 `retry.retry(T, policy, operation)`——它完全不碰断路器，`operation` 需要自己处理 `allow()` / `record*()`。`retry.Policy` 的字段是 `max_attempts`、`initial_delay_ms`、`max_delay_ms`、`multiplier`、`jitter`（0.0-1.0 的浮点比例，不是布尔开关）。

## 状态监控

```zig
fn logCircuitState(cb: *breaker.CircuitBreaker) void {
    switch (cb.getState()) {
        .closed => std.debug.print("Circuit: CLOSED (normal)\n", .{}),
        .open => std.debug.print("Circuit: OPEN (failing fast)\n", .{}),
        .half_open => std.debug.print("Circuit: HALF-OPEN (testing)\n", .{}),
    }

    // 计数器是公开字段，可直接读取；没有 getStats() 方法
    std.debug.print(
        "Circuit stats: total={d}, successes={d}, failures={d}\n",
        .{ cb.total_requests, cb.successful_requests, cb.failed_requests },
    );
}
```

## Prometheus 指标

用 gauge 暴露状态（0=closed, 1=open, 2=half-open）：

```zig
const metric = zigzero.metric;

var registry: metric.Registry = undefined;
var cb_state: *metric.Gauge = undefined;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    registry = metric.Registry.init(gpa.allocator());
    defer registry.deinit();

    cb_state = try registry.gauge(
        "circuit_breaker_state",
        "Circuit breaker state (0=closed, 1=open, 2=half-open)",
    );
}

pub fn recordCircuitState(cb: *breaker.CircuitBreaker) void {
    const value: i64 = switch (cb.getState()) {
        .closed => 0,
        .open => 1,
        .half_open => 2,
    };
    cb_state.set(value);
}
```

`Gauge.set()` 接收 `i64` 并且返回 `void`（不返回错误），所以不要写 `try cb_state.set(...)`。

## 服务降级

框架没有内置的 fallback 包装器（没有 `executeWithFallback()`）。在 `allow()` 返回 false 时自行返回降级数据：

```zig
fn callWithFallback(url: []const u8) ![]const u8 {
    if (!cb.allow()) {
        // 断路器打开：直接返回缓存/兜底数据
        return getCachedData() orelse error.ServiceUnavailable;
    }

    const body = realService.call(url) catch |err| {
        cb.recordFailure();
        return getCachedData() orelse err;
    };
    cb.recordSuccess();
    return body;
}
```

## 手动控制

公开的手动控制方法只有 `close()`：把状态改回 `closed` 并清零所有计数器。

```zig
fn resetCircuit(cb: *breaker.CircuitBreaker) void {
    cb.close(); // 关闭断路器并重置计数器
}
```

框架没有 `forceOpen()` / `forceClose()` / `reset()` / `executeWithPassThrough()`。断路器只能在失败率达到阈值时自动打开；如果需要临时绕过它（例如管理操作），直接调用底层函数而不经过断路器即可。

## 最佳实践

### 1. 细粒度断路器

每个外部依赖独立的断路器：

```zig
var user_service_cb = breaker.CircuitBreaker.new();
var payment_service_cb = breaker.CircuitBreaker.new();
var notification_service_cb = breaker.CircuitBreaker.new();
```

### 2. 合理的超时

`sleep_duration_sec` 决定下游的恢复窗口，不要设置过长：

```zig
var cb = breaker.CircuitBreaker.withConfig(.{
    .request_threshold = 10,
    .failure_rate_threshold = 50,
    .sleep_duration_sec = 30,
    .half_open_success_threshold = 3,
});
```

### 3. 监控断路器状态

配合上面的 `circuit_breaker_state` gauge：

```bash
# 告警规则
ALERT CircuitBreakerOpen
  IF circuit_breaker_state == 1
  FOR 1m
  LABELS { severity = "critical" }
  ANNOTATIONS {
    summary = "Circuit breaker is open"
  }
```

## 下一步

- [Rate Limiting](rate-limiting.md) — 速率限制
- [Metrics & Observability](metrics.md) — 断路器监控
- [Graceful Shutdown](graceful-shutdown.md) — 断路器与关闭集成
