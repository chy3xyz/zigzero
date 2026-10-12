# Graceful Shutdown

优雅关闭确保在服务停止时完成正在处理的请求，清理资源，并正确处理系统信号。

## 核心概念

```
调用 shutdown()（置 running=false） → 停止接收新请求 → run() 退出等待循环 → 逆序执行关闭钩子 → 进程退出
```

`lifecycle.Manager` 只提供两部分能力：

1. 一个 `running` 标志和 `run()` 阻塞循环；
2. 一个钩子列表，在 `run()` 结束时按 LIFO（后注册先执行）顺序调用。

**它不注册任何信号处理器**（源码中只有注释说明这一点）。`SIGTERM` / `SIGINT` 的处理需要应用自己安装，再在处理器里调用 `lc.shutdown()`。

## Manager API

```zig
pub const Manager = struct {
    pub fn init(allocator: std.mem.Allocator) Manager;
    pub fn deinit(self: *Manager) void;

    /// 注册关闭钩子。context 是 *anyopaque，不能传 null。
    pub fn onShutdown(
        self: *Manager,
        name: []const u8,
        callback: *const fn (*anyopaque) void,
        context: *anyopaque,
    ) !void;

    /// 阻塞：轮询 running 标志（每 100ms 一次），退出后执行所有钩子
    pub fn run(self: *Manager) void;

    /// 请求关闭：仅把 running 置为 false，不执行钩子、不阻塞
    pub fn shutdown(self: *Manager) void;

    pub fn isRunning(self: *Manager) bool;

    /// 在 interval_ms 内以 10ms 为步长等待，期间检测 running
    pub fn wait(self: *Manager, interval_ms: u64) void;
};
```

没有 `configure(...)`、`getStatus()`、超时配置或信号开关。

## 基础实现

`api.Server.init` 返回结构体本身（不是 error union），`server.start()` 是阻塞的 accept 循环，因此需要放到独立线程：

```zig
const std = @import("std");
const zigzero = @import("zigzero");
const compat = zigzero.compat;
const api = zigzero.api;
const log = zigzero.log;
const lifecycle = zigzero.lifecycle;

const StopContext = struct {
    server: *api.Server,
};

fn stopServer(ctx: *anyopaque) void {
    const c: *StopContext = @ptrCast(@alignCast(ctx));
    c.server.stop();
}

fn serve(server: *api.Server) void {
    server.start() catch |err| {
        std.debug.print("server error: {s}\n", .{@errorName(err)});
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    compat.initIo(allocator);
    defer compat.deinitIo();

    const logger = log.Logger.new(.info, "my-service");

    var lc = lifecycle.Manager.init(allocator);
    defer lc.deinit();

    var server = api.Server.init(allocator, 8080, logger);
    defer server.deinit();

    var stop_ctx = StopContext{ .server = &server };
    try lc.onShutdown("stop-http", stopServer, &stop_ctx);

    // server.start() 阻塞，放入独立线程
    const server_thread = try std.Thread.spawn(.{}, serve, .{&server});
    defer server_thread.join();

    // 在这里由你自己的信号处理器（std.posix.sigaction 等）调用 lc.shutdown()
    // run() 阻塞到 running=false，然后按 LIFO 执行钩子并返回
    lc.run();
}
```

如果只是在一段更大的关闭流程里执行钩子，可以不并发，顺序调用即可：

```zig
lc.shutdown(); // 先置 running=false
lc.run();      // 立即退出等待循环并执行钩子
```

## 注册关闭钩子

```zig
try lc.onShutdown("resource-name", callback, context);
```

参数：
- `name: []const u8` — 钩子名称（仅用于可读性，框架不打印它）
- `callback: *const fn (*anyopaque) void` — 清理函数，不能返回错误
- `context: *anyopaque` — 传给回调的指针；**必须是有效指针，不能是 `null`**

回调忽略 context 时传 `undefined`：

```zig
try lc.onShutdown("close-db", struct {
    fn run(_: *anyopaque) void {
        std.debug.print("Closing database connections...\n", .{});
        db.close();
    }
}.run, undefined);
```

### 带上下文的钩子

```zig
const DbPool = struct {
    connections: []Connection,
    allocator: std.mem.Allocator,

    pub fn close(self: *DbPool) void {
        for (self.connections) |conn| {
            conn.disconnect();
        }
        self.allocator.free(self.connections);
    }
};

var db_pool = DbPool{ .connections = &.{}, .allocator = allocator };

try lc.onShutdown("close-db-pool", struct {
    fn run(data: *anyopaque) void {
        const pool = @as(*DbPool, @ptrCast(@alignCast(data)));
        pool.close();
    }
}.run, &db_pool);
```

### 多个钩子执行顺序

按注册顺序逆序执行（后注册先执行）。若按 `cleanup-tmp`、`close-db-pool`、`close-server` 的顺序注册，实际执行顺序为：

```
1. close-server
2. close-db-pool
3. cleanup-tmp
```

## 与 HTTP 服务器集成

### 等待处理中请求

`compat.sleep` 接收纳秒数（Zig 0.17 移除了 `std.Thread.sleep`）：

```zig
var active_requests = std.atomic.Value(u32).init(0);

try lc.onShutdown("drain-requests", struct {
    fn run(_: *anyopaque) void {
        // 等待活跃请求计数归零
        while (active_requests.load(.monotonic) > 0) {
            compat.sleep(100 * std.time.ns_per_ms);
        }
    }
}.run, undefined);
```

### 典型关闭钩子清单

钩子按注册顺序**逆序**执行（LIFO）。因此要让清理按「先停流量 → 再等待 → 最后释放资源」进行，就要按相反顺序注册：

```zig
// 最后执行 → 最先注册
try lc.onShutdown("close-redis", struct {
    fn run(_: *anyopaque) void { redis_client.disconnect(); }
}.run, undefined);
try lc.onShutdown("close-db", struct {
    fn run(data: *anyopaque) void {
        const pool = @as(*DbPool, @ptrCast(@alignCast(data)));
        pool.close();
    }
}.run, &db_pool);
try lc.onShutdown("drain-requests", struct {
    fn run(_: *anyopaque) void {
        while (active_requests.load(.monotonic) > 0) {
            compat.sleep(100 * std.time.ns_per_ms);
        }
    }
}.run, undefined);
// 最先执行 → 最后注册
try lc.onShutdown("stop-accepting", struct {
    fn run(data: *anyopaque) void {
        const s = @as(*api.Server, @ptrCast(@alignCast(data)));
        s.stop();
    }
}.run, &server);
```

`Logger` 没有 `flush()` 方法；写出到文件时 `FileLogger.write()` 内部已经 `sync`。

### lifecycle.Server 包装器

框架还提供一个薄包装：

```zig
pub fn Server(comptime T: type) type {
    pub fn init(server: *T, manager: *Manager) Self;
    /// 注册一个调用 server.stop() 的钩子
    pub fn register(self: *Self) !void;
    /// 先 server.start()，再 manager.run()
    pub fn start(self: *Self) !void;
}
```

```zig
var wrapper = lifecycle.Server(api.Server).init(&server, &lc);
try wrapper.register();
try wrapper.start();
```

注意 `start()` 会先调用 `server.start()`（阻塞的 accept 循环），`manager.run()` 只有在服务器停止之后才会被执行；因此这个包装器适合与外部触发（信号/另一个线程）配合使用，本身并不提供信号处理。

## 关于关闭超时

`Manager` 没有超时配置。`run()` 会一直执行钩子直到全部返回；如果某个钩子阻塞，关闭就会挂起。需要超时保护时，自己在独立线程里跑 `lc.run()` 并计时，超时后强制退出：

```zig
var shutdown_done = std.atomic.Value(bool).init(false);

fn runShutdown(manager: *lifecycle.Manager, done: *std.atomic.Value(bool)) void {
    manager.run();
    done.store(true, .release);
}

const shutdown_thread = try std.Thread.spawn(.{}, runShutdown, .{ &lc, &shutdown_done });

// 等待最多 30 秒
const deadline = compat.milliTimestamp() + 30_000;
while (!shutdown_done.load(.acquire) and compat.milliTimestamp() < deadline) {
    compat.sleep(50 * std.time.ns_per_ms);
}
if (!shutdown_done.load(.acquire)) {
    std.debug.print("shutdown timed out, forcing exit\n", .{});
    std.process.exit(1);
}
```

（`std.Thread` 没有 `isRunning()`；用上面的共享原子标志，或直接 `join`。）

## 与 Kubernetes 集成

Kubernetes 发送 `SIGTERM` 并等待 `terminationGracePeriodSeconds`（默认 30s）。由于框架不安装信号处理器，你必须自己安装并调用 `lc.shutdown()`（可用 `std.posix.sigaction`），同时保证钩子在宽限期内完成。

健康检查应在收到信号后立即变为不健康：把健康状态放进一个原子/共享结构，并在同一个信号处理器里更新它。

## 验证关闭行为

```bash
# 启动服务
./zig-out/bin/my-service &
PID=$!

# 发送 SIGTERM
kill -TERM $PID
```

未安装信号处理器时，`SIGTERM` 会直接终止进程，**关闭钩子不会执行**——这正是需要自己做信号接线的原因。安装后应看到钩子按 LIFO 顺序打印的日志。

## 调试关闭问题

```bash
# 跟踪未完成的关闭钩子
kill -USR1 $PID  # 仅当你自己实现了 USR1 处理器

# 强制退出（最后手段）
kill -9 $PID
```

## 下一步

- [Metrics & Observability](metrics.md) — 健康检查和 Prometheus 指标
- [Configuration](configuration.md) — 使用 YAML 配置管理服务参数
