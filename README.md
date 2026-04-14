# ZigZero

**Zero-cost microservice framework for Zig, aligned with go-zero patterns.**

## Overview

ZigZero is a high-performance microservice framework written in Zig, inspired by go-zero. It provides comprehensive capabilities for building production-ready microservices with zero external dependencies.

## Features

- **HTTP Server** (`api`) - Full HTTP server with routing, middleware, JSON parsing, route groups, and struct-tag auto parameter binding
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
- **Load Balancer** (`loadbalancer`) - Round robin, random, weighted, least connection, IP hash, consistent hashing
- **Redis Client** (`redis`) - RESP protocol implementation
- **Connection Pool** (`pool`) - Generic connection pooling
- **Health Checks** (`health`) - Health probe registry
- **Service Discovery** (`discovery`) - Static service discovery
- **Distributed Tracing** (`trace`) - OpenTelemetry-compatible tracing
- **Metrics** (`metric`) - Prometheus-compatible metrics
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

Add to your `build.zig`:

```zig
const zigzero = b.dependency("zigzero", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zigzero", zigzero.module("zigzero"));
```

## Project Structure

Modules are organized following Zig best practices:

```
src/
├── core/
│   └── errors.zig          # Unified error types
├── net/
│   ├── api.zig             # HTTP server
│   ├── http.zig            # HTTP client
│   ├── rpc.zig             # RPC framework
│   ├── websocket.zig       # WebSocket support
│   └── tls.zig             # TLS/HTTPS
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
│   └── limiter.zig         # Rate limiting
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
| `mq` | `infra/mq` | In-memory message queue | ✅ Complete |
| `cron` | `infra/cron` | Scheduled task execution | ✅ Complete |
| `lifecycle` | `infra/lifecycle` | Graceful shutdown hooks | ✅ Complete |
| `health` | `infra/health` | Health probe registry | ✅ Complete |
| `discovery` | `infra/discovery` | Static service discovery | ✅ Complete |
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
| `sqlx` | `infra/sqlx` | Unified SQL client abstraction | ✅ Complete |

## Requirements

- Zig 0.15.2+
- No external dependencies (uses std library only)

## License

MIT
