# ZigZero

**Zero-cost microservice framework for Zig, aligned with go-zero patterns.**

[![CI](https://github.com/chy3xyz/zigzero/actions/workflows/ci.yml/badge.svg)](https://github.com/chy3xyz/zigzero/actions)
[![Zig](https://img.shields.io/badge/Zig-0.17.0+-blue.svg)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## Overview

ZigZero is a high-performance microservice framework written in pure Zig, inspired by [go-zero](https://github.com/zeromicro/go-zero). It is **pre-1.0 / beta** software: the HTTP server, middleware, and service-governance modules are stable and covered by tests, but some parts are still placeholders — the ORM has no real database driver yet, and `net/tls` only loads certificates. Treat it as a foundation to build on, not a turnkey production stack.

**Key design principles:**
- **go-zero compatibility** — Familiar API patterns for developers coming from Go
- **Pure Zig** — No C/C++ dependencies except for optional database drivers
- **Memory safety** — Leverage Zig's comptime and ownership model
- **Testability** — Comprehensive test coverage with memory leak detection

## Features

| Category | Modules | Description |
|----------|---------|-------------|
| **Network** | `api`, `http`, `rpc`, `websocket`, `gateway`, `tls` | HTTP server/client, binary RPC, WebSocket, API gateway, TLS 🚧 experimental (certificate loading only) |
| **Service Governance** | `breaker`, `limiter`, `loadbalancer`, `load` | Circuit breaker, rate limiting, load balancing, adaptive shedding |
| **Data** | `sqlx`, `redis`, `orm`, `cache` | Unified SQL client, Redis, ORM 🚧 placeholder (no real DB driver yet), LRU cache |
| **Infrastructure** | `log`, `config`, `trace`, `metric`, `health` | Structured logging, config loading, tracing, metrics |
| **Async** | `pool`, `fx`, `mapreduce`, `threading` | Connection pooling, streams, map/reduce, goroutine-style threading |
| **Reliability** | `retry`, `lock`, `lifecycle`, `mq`, `cron` | Retry, distributed locks, graceful shutdown, message queue, scheduling |
| **Code Gen** | `zgctl` | Project scaffolding, API codegen, ORM model generation |

See [Module Reference](#module-reference) for complete list.

## Quick Start

### 1. Create a project

```bash
git clone https://github.com/chy3xyz/zigzero.git
cd zigzero
zig build
```

### 2. Run the example

```bash
./zig-out/bin/zgctl new my-service
cd my-service
zig build
./zig-out/bin/my-service
```

### 3. Or use it as a dependency

```zig
// build.zig.zon
.{
    .dependencies = .{
        .zigzero = .{
            .url = "https://github.com/chy3xyz/zigzero/archive/refs/tags/v0.2.4.tar.gz",
            .hash = "<zig will print the expected hash after first fetch>",
        },
    },
}
```

```zig
// src/main.zig
const std = @import("std");
const zigzero = @import("zigzero");
const api = zigzero.api;
const compat = zigzero.compat;
const log = zigzero.log;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // The server requires the global Io backend to be initialised first.
    compat.initIo(allocator);
    defer compat.deinitIo();

    const logger = log.Logger.new(.info, "my-service");
    var server = api.Server.init(allocator, 8080, logger);
    defer server.deinit();

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

## Installation

### Requirements

- **Zig**: 0.17.0 or later
- **OS**: macOS, Linux, or other Unix-like systems
- **Optional**: C libraries for `sqlx` module (see below)

### System Dependencies (for `sqlx`)

The `sqlx` module supports SQLite, PostgreSQL, and MySQL via system C libraries.

**macOS (Homebrew):**
```bash
brew install libpq mariadb-connector-c sqlite3
```

**Ubuntu / Debian:**
```bash
sudo apt-get install libsqlite3-dev libpq-dev libmysqlclient-dev
```

**Fedora / RHEL:**
```bash
sudo dnf install sqlite-devel postgresql-devel mysql-devel
```

**Custom paths** (if needed):
```bash
PQ_INCLUDE=/custom/include PQ_LIB=/custom/lib \
MYSQL_INCLUDE=/custom/include MYSQL_LIB=/custom/lib \
zig build
```

## Project Structure

```
src/
├── core/           # Core utilities
│   ├── errors.zig  # Unified error types
│   ├── fx.zig      # Stream / Parallel / Map
│   ├── threading.zig
│   ├── mapreduce.zig
│   ├── hash.zig
│   ├── codec.zig
│   └── load.zig
├── net/            # Network layer
│   ├── api.zig     # HTTP server
│   ├── http.zig    # HTTP client
│   ├── rpc.zig     # RPC framework
│   ├── websocket.zig
│   ├── tls.zig
│   └── gateway.zig
├── server/         # Server utilities
│   ├── static.zig
│   └── middleware.zig
├── infra/          # Infrastructure
│   ├── log.zig
│   ├── redis.zig
│   ├── pool.zig
│   ├── cache.zig
│   ├── mq.zig
│   ├── cron.zig
│   ├── lifecycle.zig
│   ├── health.zig
│   ├── discovery.zig
│   ├── lock.zig
│   ├── trace.zig
│   ├── metric.zig
│   ├── retry.zig
│   ├── loadbalancer.zig
│   ├── breaker.zig
│   ├── limiter.zig
│   ├── sqlx.zig
│   └── etcd.zig
├── data/           # Data layer
│   ├── orm.zig
│   └── validate.zig
├── config.zig
├── svc.zig
└── zigzero.zig    # Root module
```

## Build & Test

```bash
# Build
zig build

# Run all tests (SQLite)
zig build test

# Run PostgreSQL tests
DB=postgres zig build test

# Run MySQL tests
DB=mysql zig build test
```

For database setup, use the initialization script:
```bash
./scripts/init-db.sh          # Setup all databases
./scripts/init-db.sh --postgres   # Setup PostgreSQL only
./scripts/init-db.sh --mysql      # Setup MySQL only
./scripts/init-db.sh --clean     # Clean up test databases
```

## Code Generation (zgctl)

```bash
# Build the CLI
zig build

# Scaffold new service
./zig-out/bin/zgctl new my-service

# Generate API from .api DSL
./zig-out/bin/zgctl api api-spec.api -o gen/api

# Generate ORM models from SQL
./zig-out/bin/zgctl model schema.sql -o gen/models
```

### API DSL Format

```
name user-api

type LoginReq {
    username string
    password string
}

type LoginResp {
    token string
}

get /users/:id getUser
post /users/login LoginReq LoginResp login
```

## Architecture

```
┌─────────────────────────────────────┐
│          接入层 (API Gateway)        │
├─────────────────────────────────────┤
│          服务层 (Service Layer)       │
├─────────────────────────────────────┤
│        服务治理层 (Governance)       │
│  breaker | limiter | loadbalancer    │
├─────────────────────────────────────┤
│       基础设施层 (Infrastructure)     │
│  config | log | redis | pool | http │
│  trace | metric | cache | lock      │
└─────────────────────────────────────┘
```

## Module Reference

| Module | Path | Status |
|--------|------|--------|
| HTTP Server | `net/api` | ✅ |
| HTTP Client | `net/http` | ✅ |
| RPC | `net/rpc` | ✅ |
| WebSocket | `net/websocket` | ✅ |
| Gateway | `net/gateway` | ✅ |
| TLS | `net/tls` | 🚧 Experimental (certificate loading only) |
| Middleware | `server/middleware` | ✅ |
| Static Files | `server/static` | ✅ |
| Configuration | `config` | ✅ |
| Service Context | `svc` | ✅ |
| Logging | `infra/log` | ✅ |
| Redis | `infra/redis` | ✅ |
| Connection Pool | `infra/pool` | ✅ |
| Cache | `infra/cache` | ✅ |
| Message Queue | `infra/mq` | ✅ |
| Cron | `infra/cron` | ✅ |
| Lifecycle | `infra/lifecycle` | ✅ |
| Health | `infra/health` | ✅ |
| Discovery | `infra/discovery` | ✅ |
| etcd | `infra/etcd` | ✅ |
| Distributed Lock | `infra/lock` | ✅ |
| Tracing | `infra/trace` | ✅ |
| Metrics | `infra/metric` | ✅ |
| Retry | `infra/retry` | ✅ |
| Load Balancer | `infra/loadbalancer` | ✅ |
| Circuit Breaker | `infra/breaker` | ✅ |
| Rate Limiter | `infra/limiter` | ✅ |
| ORM | `data/orm` | 🚧 Placeholder (no real DB driver yet) |
| Validation | `data/validate` | ✅ |
| SQL Client | `infra/sqlx` | ✅ |
| zgctl | `tools/zgctl` | ✅ |

## Documentation

The documentation is published as a site at **<https://chy3xyz.github.io/zigzero/>**
and lives in the [docs/](docs/README.md) directory — every page you read there is a
Markdown file in this repository, so a docs fix is an ordinary commit. The site is
built by [zdoc](https://github.com/chy3xyz/zdoc) in CI (`.github/workflows/docs.yml`),
which also fails the build on an unresolved link.

The same pages, in reading order:

- [Getting Started](docs/getting-started/installation.md) — Installation and setup
- [Quick Start](docs/getting-started/quick-start.md) — 5-minute tour
- [First Service Tutorial](docs/getting-started/first-service.md) — Build your first REST API
- [HTTP API Server](docs/guides/api-server.md) — Routing, handlers, route groups
- [Middleware](docs/guides/middleware.md) — Writing custom middleware
- [Graceful Shutdown](docs/guides/graceful-shutdown.md) — Lifecycle hooks and signal handling
- [Metrics & Observability](docs/guides/metrics.md) — Prometheus metrics integration
- [Rate Limiting](docs/guides/rate-limiting.md) — Token bucket, sliding window, IP limits
- [Circuit Breaker](docs/guides/circuit-breaker.md) — Resilience patterns
- [Configuration](docs/guides/configuration.md) — YAML/JSON config loading
- [Authentication](docs/guides/authentication.md) — JWT middleware and token generation
- [chy3 Example](docs/examples/chy3.md) — Full-stack example across three business domains
- [Architecture Overview](docs/architecture/overview.md) — Framework design principles
- [Module Reference](docs/architecture/module-reference.md) — Complete API reference

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT License - see [LICENSE](LICENSE)
