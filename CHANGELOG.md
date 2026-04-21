# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1] - 2026-04-21

### Fixed
- **Zig 0.16 Migration**: Complete migration from Zig 0.15 to Zig 0.16.0
- **build.zig**: Fixed `env_map` → `environ_map` API change
- **io_instance.zig**: Created unified Io instance management module
- **main() entry points**: Updated all examples to use `std.process.Init`
- **Time API**: Fixed health.zig and limiter.zig to use `std.c.clock_gettime`
- **Mutex API**: Migrated 9 files from `std.Thread.Mutex` → `std.Io.Mutex`
- **File API**: Fixed log.zig to use `std.Io.File`
- **Collection APIs**: Partial fixes for ArrayList/HashMap initialization and method signatures
- **core/threading.zig**: Fixed `test.task runner` - added `started` flag for proper synchronization
- **infra/mq.zig**: Fixed `test.persistent queue` - added `createDirPath()` to create test directory
- **src/net/api.zig**: Partial migration to `std.Io.net.*` API for network operations
- **examples/hello/main.zig**: Updated to use Zig 0.16 API

### Changed
- **build.zig.zon**: Updated `minimum_zig_version` to 0.16.0
- **README.md**: Updated Zig version requirement from 0.15.2+ to 0.16.0+

## [Unreleased]
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
