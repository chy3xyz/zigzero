# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-05-11

### Added
- `src/compat.zig` — Central compatibility shim bridging Zig 0.15.2 APIs to 0.16.0 `std.Io`
- `scripts/init-db.sh` — Database initialization script for PostgreSQL and MySQL testing
- `infra/sqlx`: Unix socket support for MySQL connections on macOS
- `infra/sqlx`: Environment variable overrides for DB connection credentials
- `infra/sqlx`: `skipUnlessDb()` test helper for DB-specific tests

### Fixed
- **Zig 0.16.0 migration**: Complete framework upgrade from Zig 0.15.2 to 0.16.0
  - Replaced legacy `std.os` file/net I/O with `std.Io` unified interface
  - Fixed `ArrayList` unmanaged API (`.empty`, per-call `allocator`)
  - Replaced `std.crypto.random` with `std.Random.DefaultPrng`
  - Replaced `std.process.getEnvVarOwned` with `std.process.Environ.getAlloc`
  - Replaced `std.net.Server.Connection` with direct `Stream` from `accept`
  - Fixed `std.Thread.sleep` → `std.Io.sleep` via `compat.sleep`
  - Fixed positional file I/O (`readPositionalAll`, `writePositionalAll`)
  - Fixed `Dir.writeFile`, `Dir.close`, `Dir.readFileAlloc` signatures for 0.16.0
  - Fixed `process.Args.Iterator` usage in CLI tools
  - Fixed `ArrayList.writer(allocator)` pattern with `ListWriter` helper
- `infra/sqlx`: MySQL connection crash with empty password (ptr=null issue)
- `infra/sqlx`: PostgreSQL `rows_affected` returning garbage due to missing `paramLengths`
- `infra/sqlx`: Memory leaks in 9 SQLite tests (double string duplication in `scanStruct`)
- `infra/sqlx`: MySQL `execFn` double-call to `mysql_store_result` causing undefined behavior
- `infra/sqlx`: `skipUnlessDb` returning error instead of skipping when DB env not set
- `infra/sqlx`: Connection pool `SIGABRT` on double mutex unlock

### Changed
- `infra/sqlx`: `Row.get()` now returns owned string copies (caller must free)
- `infra/sqlx`: `Row` struct requires `allocator` field
- `infra/sqlx`: PostgreSQL `beginTx` error handling improved

---

## [0.1.0] - 2024-04-11

### Added
- **Core Framework**: Comprehensive microservice framework aligned with go-zero patterns
- **HTTP Server** (`net/api`): Trie-based routing, middleware, JSON parsing, route groups
- **HTTP Client** (`net/http`): Timeout, retries, connection pooling
- **RPC Framework** (`net/rpc`): Binary protocol over TCP with circuit breaker
- **WebSocket** (`net/websocket`): RFC 6455 compliant server with room management
- **API Gateway** (`net/gateway`): Reverse proxy with load balancing
- **TLS/HTTPS** (`net/tls`): Secure server configuration
- **Middleware** (`server/middleware`): JWT (HMAC-SHA256), CORS, rate limiting, logging, recovery
- **Configuration** (`config`): JSON and YAML loading from files and environment
- **Logging** (`infra/log`): Structured logging with levels and file rotation
- **Redis Client** (`infra/redis`): RESP protocol implementation, cluster support
- **Connection Pool** (`infra/pool`): Generic connection pooling
- **Circuit Breaker** (`infra/breaker`): Hystrix-style with half-open state
- **Rate Limiter** (`infra/limiter`): Token bucket and sliding window algorithms
- **Load Balancer** (`infra/loadbalancer`): Round robin, random, weighted, least connection, IP hash, consistent hashing
- **Load Shedder** (`infra/load`): Adaptive load shedding with middleware integration
- **SQL Client** (`infra/sqlx`): Unified abstraction for SQLite, PostgreSQL, MySQL with query builder
- **ORM** (`data/orm`): Query builder and model traits
- **Service Context** (`svc`): Dependency injection context
- **Distributed Tracing** (`infra/trace`): OpenTelemetry-compatible with W3C TraceContext
- **Metrics** (`infra/metric`): Prometheus-compatible with `/metrics` endpoint
- **Health Checks** (`infra/health`): Probe registry with HTTP handler
- **Service Discovery** (`infra/discovery`): Static and etcd support
- **Distributed Locks** (`infra/lock`): Redis and local lock implementations
- **Message Queue** (`infra/mq`): In-memory pub/sub and persistent queue
- **Cron Scheduler** (`infra/cron`): Scheduled task execution
- **Lifecycle** (`infra/lifecycle`): Graceful shutdown hooks
- **Local Cache** (`infra/cache`): In-memory LRU cache
- **Retry** (`infra/retry`): Exponential backoff with jitter
- **Threading** (`core/threading`): RoutineGroup and TaskRunner
- **Stream/Parallel** (`core/fx`): Map, Parallel, Stream utilities
- **MapReduce** (`core/mapreduce`): Concurrent map/reduce pipelines
- **Validation** (`data/validate`): Input validation utilities
- **Code Generation** (`tools/zigzeroctl`): CLI for scaffolding, API codegen, and ORM models
- **CI/CD**: GitHub Actions workflow for macOS and Ubuntu with SQLite/PostgreSQL/MySQL testing
