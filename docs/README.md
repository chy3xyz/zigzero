# ZigZero Documentation

Welcome to the ZigZero documentation! This is your complete guide to building production-ready microservices with Zig.

## 📚 Documentation Overview

### Getting Started
- [Installation](getting-started/installation.md) — System requirements and dependency setup
- [Quick Start](getting-started/quick-start.md) — 5-minute tour of ZigZero
- [Build Your First Service](getting-started/first-service.md) — Step-by-step REST API tutorial

### How-To Guides
- [HTTP API Server](guides/api-server.md) — Routing, handlers, route groups
- [Middleware](guides/middleware.md) — Writing and composing middleware
- [Graceful Shutdown](guides/graceful-shutdown.md) — Lifecycle hooks and signal handling
- [Metrics & Observability](guides/metrics.md) — Prometheus metrics integration
- [Rate Limiting](guides/rate-limiting.md) — Token bucket, sliding window, IP-based limits
- [Circuit Breaker](guides/circuit-breaker.md) — Resilience patterns for external calls
- [SQLx](guides/sqlx.md) — Unified SQL client for SQLite/PostgreSQL/MySQL with connection pooling, caching, and query builder
- [Configuration](guides/configuration.md) — YAML/JSON config loading and env overrides
- [Authentication](guides/authentication.md) — JWT middleware and token generation

### Examples
- [chy3 — Creator Metaverse](examples/chy3.md) — Full-stack example across three business domains

### Architecture
- [Architecture Overview](architecture/overview.md) — Framework design principles and layer diagram
- [Module Reference](architecture/module-reference.md) — Complete API reference for all modules

## 🏗️ Architecture at a Glance

```
zigzero/
├── net/            # Network layer
│   ├── api.zig     # HTTP server (routing + middleware)
│   ├── http.zig    # HTTP client
│   ├── rpc.zig     # Binary RPC
│   └── websocket.zig
├── server/         # Server utilities
│   └── middleware.zig
├── infra/          # Infrastructure
│   ├── log.zig     # Structured logging
│   ├── metric.zig  # Prometheus metrics
│   ├── health.zig  # Health probes
│   ├── limiter.zig # Rate limiting
│   ├── breaker.zig # Circuit breaker
│   ├── load.zig    # Adaptive load shedding
│   ├── sqlx.zig    # SQL client (SQLite/PG/MySQL)
│   ├── redis.zig   # Redis client
│   ├── mq.zig      # Message queue
│   ├── lifecycle.zig # Graceful shutdown
│   ├── cache.zig   # LRU cache
│   └── cron.zig    # Job scheduler
├── data/           # Data layer
│   ├── orm.zig     # Query builder
│   └── validate.zig
├── core/           # Core utilities
│   ├── fx.zig      # Stream / Parallel
│   └── mapreduce.zig
├── config.zig      # Config loading
└── zigzero.zig      # Root module
```

## 🔑 Key Design Principles

| Principle | Description |
|-----------|-------------|
| **go-zero compatibility** | Familiar API patterns for Go developers transitioning to Zig |
| **Zero-cost abstractions** | Leverage comptime for zero runtime overhead where possible |
| **Memory safety** | Zig's ownership model enforced at compile time |
| **Testability** | Comprehensive test coverage with memory leak detection |
| **Pure Zig** | No C/C++ dependencies except optional database drivers |

## 🚀 Quick Example

```zig
const zigzero = @import("zigzero");
const api = zigzero.api;
const log = zigzero.log;
const middleware = zigzero.middleware;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const logger = log.Logger.new(.info, "my-service");
    var server = api.Server.init(gpa.allocator(), 8080, logger);
    defer server.deinit();

    try server.addMiddleware(middleware.requestId());
    try server.addMiddleware(middleware.logging());

    try server.addRoute(.{
        .method = .GET,
        .path = "/health",
        .handler = struct {
            fn handle(ctx: *api.Context) !void {
                try ctx.jsonStruct(200, .{ .status = "ok" });
            }
        }.handle,
    });

    try server.start();
}
```

## 📦 As a Dependency

```bash
# Add to build.zig.zon
zig fetch https://github.com/knot3bot/zigzero/archive/refs/tags/v0.1.0.tar.gz
```

```zig
// build.zig.zon
.{
    .dependencies = .{
        .zigzero = .{
            .url = "https://github.com/knot3bot/zigzero/archive/refs/tags/v0.1.0.tar.gz",
            .hash = "<hash>",
        },
    },
}
```

## 📄 License

MIT — see [LICENSE](../LICENSE)
