# ZigZero

**Zero-cost microservice framework for Zig, aligned with go-zero patterns.**

## Overview

ZigZero is a high-performance microservice framework written in Zig, inspired by go-zero. It provides comprehensive capabilities for building production-ready microservices. Most modules rely only on the Zig standard library; the `sqlx` module requires system C libraries for database connectivity (SQLite, PostgreSQL, MySQL).

## Features

- **HTTP Server** (`api`) - Full HTTP server with trie-based routing, middleware, JSON parsing, route groups, and struct-tag auto parameter binding
- **API Gateway** (`gateway`) - Reverse proxy to upstream services with load balancing
- **RPC Framework** (`rpc`) - Binary protocol RPC over TCP with circuit breaker
- **HTTP Client** (`http`) - HTTP client with timeout and retries
- **WebSocket** (`websocket`) - RFC 6455 WebSocket server
- **TLS/HTTPS** (`tls`) - TLS configuration for secure servers
- **Static File Server** (`static`) - Static file serving with MIME types
- **Middleware** (`middleware`) - JWT (HMAC-SHA256 verified), CORS, rate limit, logging, recovery
- **Configuration** (`config`) - JSON and YAML configuration loading
- **Logging** (`log`) - Structured logging with levels and file rotation
- **Circuit Breaker** (`breaker`) - Hystrix-style circuit breaker
- **Rate Limiter** (`limiter`) - Token bucket and sliding window
- **Load Shedder** (`load`) - Adaptive load shedding with middleware integration
- **Load Balancer** (`loadbalancer`) - Round robin, random, weighted, least connection, IP hash, consistent hashing
- **Redis Client** (`redis`) - RESP protocol implementation with cluster support
- **Connection Pool** (`pool`) - Generic connection pooling
- **Health Checks** (`health`) - Health probe registry with HTTP handler
- **Service Discovery** (`discovery`) - Static service discovery
- **Distributed Tracing** (`trace`) - OpenTelemetry-compatible tracing with W3C TraceContext propagation
- **Metrics** (`metric`) - Prometheus-compatible metrics with `/metrics` handler
- **Retry** (`retry`) - Exponential backoff with jitter
- **Message Queue** (`mq`) - In-memory pub/sub messaging
- **Cron Scheduler** (`cron`) - Scheduled task execution
- **Lifecycle Management** (`lifecycle`) - Graceful shutdown hooks
- **Validation** (`validate`) - Input validation utilities
- **Local Cache** (`cache`) - In-memory LRU cache
- **Distributed Lock** (`lock`) - Redis and local locks
- **ORM** (`orm`) - Query builder and model traits
- **Service Context** (`svc`) - Dependency injection context
- **Stream/Parallel** (`fx`) - Map, Parallel, Stream utilities aligned with go-zero's fx
- **MapReduce** (`mapreduce`) - Concurrent map/reduce pipelines aligned with go-zero's mr
- **Threading** (`threading`) - RoutineGroup, TaskRunner, safe goroutine spawning
- **SQL Client** (`sqlx`) - Unified SQL client abstraction with query builder
- **Code Generation** (`zigzeroctl`) - CLI tool for scaffolding, API codegen, and model generation from SQL

## Quick Start

```zig
const std = @import("std");
const zigzero = @import("zigzero");
const api = zigzero.api;
const log = zigzero.log;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const logger = log.Logger.new(.info, "my-service");
    var server = api.Server.init(allocator, 8080, logger);
    defer server.deinit();

    try server.addRoute(.{
        .method = .GET,
        .path = "/health",
        .handler = struct {
            fn handle(ctx: *api.Context) !void {
                try ctx.json(200, "{\"status\":\"ok\"}");
            }
        }.handle,
    });

    try server.start();
}
```

## Installation

Add to your `build.zig.zon`:

```zig
.{
    .dependencies = .{
        .zigzero = .{
            .url = "https://github.com/knot3bot/zigzero/archive/refs/tags/v0.1.0.tar.gz",
            .hash = "<zig will print the expected hash after first fetch>",
        },
    },
}
```

Then in your `build.zig`:

```zig
const zigzero = b.dependency("zigzero", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zigzero", zigzero.module("zigzero"));
```

### System Dependencies for `sqlx`

If you use the `sqlx` module, the following C libraries must be installed on your system:

- **SQLite 3** (`libsqlite3`)
- **PostgreSQL client** (`libpq`)
- **MySQL / MariaDB client** (`libmysqlclient`)

On **macOS** (Homebrew):
```bash
brew install libpq mariadb-connector-c sqlite3
```

On **Ubuntu / Debian**:
```bash
sudo apt-get install libsqlite3-dev libpq-dev libmysqlclient-dev
```

On **Fedora / RHEL**:
```bash
sudo dnf install sqlite-devel postgresql-devel mysql-devel
```

You can override auto-detected paths via environment variables:
```bash
PQ_INCLUDE=/custom/pq/include PQ_LIB=/custom/pq/lib \
MYSQL_INCLUDE=/custom/mysql/include MYSQL_LIB=/custom/mysql/lib \
zig build
```

## Project Structure

Modules are organized following Zig best practices:

```
src/
├── core/
│   ├── errors.zig          # Unified error types
│   ├── fx.zig              # Stream / Parallel / Map utilities
│   ├── threading.zig       # RoutineGroup / TaskRunner
│   ├── mapreduce.zig       # Map / Reduce / MapReduce pipelines
│   ├── hash.zig            # Consistent hash / murmur3 / fnv1a
│   ├── codec.zig           # JSON / Binary / Base64 / Hex codecs
│   └── load.zig            # Adaptive load shedding
├── net/
│   ├── api.zig             # HTTP server
│   ├── http.zig            # HTTP client
│   ├── rpc.zig             # RPC framework
│   ├── websocket.zig       # WebSocket support
│   ├── tls.zig             # TLS/HTTPS
│   └── gateway.zig         # API Gateway reverse proxy
├── server/
│   ├── static.zig          # Static file serving
│   └── middleware.zig      # JWT, CORS, rate limit, recovery
├── infra/
│   ├── log.zig             # Structured logging
│   ├── redis.zig           # Redis client
│   ├── pool.zig            # Connection pooling
│   ├── cache.zig           # In-memory cache
│   ├── mq.zig              # In-memory message queue
│   ├── cron.zig            # Scheduled tasks
│   ├── lifecycle.zig       # Graceful shutdown
│   ├── health.zig          # Health checks
│   ├── discovery.zig       # Service discovery
│   ├── lock.zig            # Distributed locks
│   ├── trace.zig           # Distributed tracing
│   ├── metric.zig          # Prometheus metrics
│   ├── retry.zig           # Exponential backoff retry
│   ├── loadbalancer.zig    # Load balancing
│   ├── breaker.zig         # Circuit breaker
│   ├── limiter.zig         # Rate limiting
│   └── sqlx.zig            # Unified SQL client abstraction
├── data/
│   ├── orm.zig             # Query builder
│   └── validate.zig        # Input validation
├── config.zig              # Configuration management
├── svc.zig                 # Service context (DI)
└── zigzero.zig             # Root module exports
```

## Examples

See `examples/` directory for complete working examples:

- `examples/api-server/` - Full HTTP API server with middleware, health checks, and validation

## Build & Test

```bash
# Build
zig build

# Run tests
zig build test
```

## Code Generation (zigzeroctl)

`zigzeroctl` is the goctl-equivalent code generation tool for zigzero.

```bash
# Build the CLI
zig build

# Scaffold a new service project
./zig-out/bin/zigzeroctl new my-service

# Generate API routes and handlers from a .api DSL spec
./zig-out/bin/zigzeroctl api api-spec.api -o gen/api

# Generate API routes and handlers from a JSON spec (legacy)
./zig-out/bin/zigzeroctl api api-spec.json -o gen/api

# Generate ORM models from SQL DDL
./zig-out/bin/zigzeroctl model schema.sql -o gen/models
```

### API DSL Format (.api)

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

Supported field types: `string`, `int`, `bool`, `float`.
Route formats:
- `method path handler` — simple route
- `method path reqType respType handler` — route with request/response types

### JSON API Spec Format (legacy)

```json
{
  "name": "user-api",
  "routes": [
    { "method": "GET", "path": "/users", "handler": "listUsers" },
    { "method": "POST", "path": "/users", "handler": "createUser" }
  ]
}
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

| Module | Path | Description | Status |
|--------|------|-------------|--------|
| `api` | `net/api` | HTTP server, routing, middleware | ✅ Complete |
| `gateway` | `net/gateway` | API Gateway reverse proxy | ✅ Complete |
| `rpc` | `net/rpc` | RPC framework over TCP | ✅ Complete |
| `http` | `net/http` | HTTP client | ✅ Complete |
| `websocket` | `net/websocket` | WebSocket server (RFC 6455) | ✅ Complete |
| `tls` | `net/tls` | TLS/HTTPS configuration | ✅ Complete |
| `static` | `server/static` | Static file serving | ✅ Complete |
| `middleware` | `server/middleware` | JWT, CORS, rate limit, recovery | ✅ Complete |
| `config` | `config` | Configuration management | ✅ Complete |
| `svc` | `svc` | Service context / DI | ✅ Complete |
| `log` | `infra/log` | Structured logging | ✅ Complete |
| `redis` | `infra/redis` | Redis client (RESP) | ✅ Complete |
| `pool` | `infra/pool` | Connection pooling | ✅ Complete |
| `cache` | `infra/cache` | In-memory LRU cache | ✅ Complete |
| `mq` | `infra/mq` | In-memory + persistent message queue | ✅ Complete |
| `cron` | `infra/cron` | Scheduled task execution | ✅ Complete |
| `lifecycle` | `infra/lifecycle` | Graceful shutdown hooks | ✅ Complete |
| `health` | `infra/health` | Health probe registry | ✅ Complete |
| `discovery` | `infra/discovery` | Static + etcd service discovery | ✅ Complete |
| `etcd` | `infra/etcd` | etcd v3 HTTP client | ✅ Complete |
| `lock` | `infra/lock` | Redis and local locks | ✅ Complete |
| `trace` | `infra/trace` | Distributed tracing | ✅ Complete |
| `metric` | `infra/metric` | Prometheus metrics | ✅ Complete |
| `retry` | `infra/retry` | Exponential backoff retry | ✅ Complete |
| `loadbalancer` | `infra/loadbalancer` | Load balancing algorithms | ✅ Complete |
| `breaker` | `infra/breaker` | Circuit breaker | ✅ Complete |
| `limiter` | `infra/limiter` | Token bucket / sliding window | ✅ Complete |
| `orm` | `data/orm` | Query builder | ✅ Complete |
| `validate` | `data/validate` | Input validation | ✅ Complete |
| `errors` | `core/errors` | Unified error types | ✅ Complete |
| `fx` | `core/fx` | Stream / Parallel / Map utilities | ✅ Complete |
| `threading` | `core/threading` | RoutineGroup / TaskRunner | ✅ Complete |
| `mapreduce` | `core/mapreduce` | Map / Reduce / MapReduce pipelines | ✅ Complete |
| `load` | `core/load` | Adaptive load shedding | ✅ Complete |
| `sqlx` | `infra/sqlx` | Unified SQL client abstraction | ✅ Complete |
| `zigzeroctl` | `tools/zigzeroctl` | Code generation CLI (goctl equivalent) | ✅ Complete |

## Requirements

- Zig 0.15.2+
- For `sqlx` database support:
  - SQLite 3 development libraries
  - PostgreSQL client development libraries (`libpq`)
  - MySQL / MariaDB client development libraries (`libmysqlclient`)

## License

MIT
