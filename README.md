# ZigZero

**Zero-cost microservice framework for Zig, aligned with go-zero patterns.**

## Overview

ZigZero is a high-performance microservice framework written in Zig, inspired by go-zero. It provides:

- **API Server** - HTTP server with routing, middleware, and handlers
- **RPC Framework** - RPC client and server with circuit breaker
- **Configuration** - Unified config loading from YAML/JSON/env
- **Logging** - Structured logging with rotation
- **Circuit Breaker** - Protect services from cascading failures
- **Rate Limiter** - Token bucket, sliding window algorithms
- **Load Balancer** - Round robin, random, weighted, least connection
- **Redis Client** - Distributed cache and locks
- **Middleware** - JWT auth, CORS, logging, rate limiting

## Quick Start

```zig
const zigzero = @import("zigzero");
const api = zigzero.api;

pub fn main() !void {
    var server = api.Server.new(8080);
    
    server.addRoute(.{
        .method = .GET,
        .path = "/health",
        .handler = struct {
            fn handle(ctx: *api.Context) !void {
                ctx.json(200, `{"status":"ok"}`);
            }
        }.handle,
    });
    
    try server.start();
}
```

## Modules

| Module | Description |
|--------|-------------|
| `api` | HTTP server, routing, handlers |
| `rpc` | RPC client/server with circuit breaker |
| `config` | Config loading from YAML/JSON/env |
| `log` | Structured logging with rotation |
| `breaker` | Circuit breaker pattern |
| `limiter` | Rate limiting (token bucket, sliding window) |
| `loadbalancer` | Load balancing strategies |
| `redis` | Redis client, distributed locks |
| `middleware` | JWT, CORS, logging, rate limiting |
| `errors` | Unified error types |

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
│  config | log | redis | errors      │
└─────────────────────────────────────┘
```

## Requirements

- Zig 0.15.0+

## License

MIT
