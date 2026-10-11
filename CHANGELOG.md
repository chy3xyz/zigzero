# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security
- **`server/middleware` response cache served authenticated responses to anonymous callers**: entries are keyed by path and query alone and are replayed *before* a route's auth middleware runs, so one authorized `GET /admin` made that body public until the TTL expired. Requests carrying `Authorization`, `Proxy-Authorization` or `Cookie` (case-insensitive) are no longer cached, and are never served from cache
- **`server/middleware` JWT `exp` was never checked**: a token stayed valid forever regardless of its expiry; expired tokens are now rejected with `error.TokenExpired` inside `verifyJwt`, so every caller inherits the check
- **`server/middleware` malformed JWT signature crashed the server**: comparing `sig_decoded[0..32]` panicked (out-of-bounds) for any signature shorter than 32 bytes; wrong-length signatures are now rejected as `error.InvalidToken`
- **`infra/sqlx` MySQL argument injection**: `.string` arguments were interpolated into the SQL with no escaping, so quotes, backslashes and control characters in a value escaped their literal. They now go through `appendEscapedString`, mirroring `mysql_real_escape_string`

### Fixed
- **`infra/lock` and `infra/redis` sent malformed RESP frames**: the release command declared `*4` with five elements and a `$45` length prefix for a 93-byte Lua script, and `Redis.lock` declared `*5` for a six-element `SET ... NX PX`. Verified against a live Redis: the old frames answer `-ERR Protocol error` / `-ERR syntax error`, the new ones `+OK` and `:1`. Frames are now built by `redis.respCommand`, which derives the count and every length prefix from the payload
- **`core/codec` `JsonCodec.decode` returned dangling slices**: the parse arena was freed before the value was returned, so any `T` with slice fields pointed at freed memory; it now uses the leaky parse so the caller's allocator owns the result
- **`infra/cache` leaked every value it dropped**: eviction, expiry, `delete`, `clear` and `deinit` freed the node but not the value, so a `ResponseCache` grew without bound. `Cache` now takes an optional `on_evict` hook and calls it on every drop path, and `ResponseCache` frees bodies through it
- **`net/websocket` `writeClose` overflowed its stack buffer**: the reason was copied into a 125-byte payload with no bounds check; it is now truncated to the RFC 6455 control-frame limit
- **`infra/retry` divided by zero at `jitter = 0`** (and could panic on conversion for extreme jitter values); the jitter term is skipped when its span is zero and the floor saturates
- **`server/middleware` request-ID middleware returned a slice into a dead block**, so `X-Request-ID` read freed stack memory; the buffer now outlives the call
- **`tools/zgctl` test step ran zero tests**: `zig build test` compiled a binary containing no tests because `main.zig` never referenced `dsl.zig` / `generate.zig` declarations; an aggregating `test` block now pulls in all 11
- **`config` left keys that were absent from the source `undefined`**: `parseJson` and `loadEnv` both started from `var cfg: T = undefined`, so any field without a JSON key or environment variable was undefined memory the moment a caller read it. Both now start from each field's declared default (`defaultConfig`), zeroed where a field declares none. The environment test that unconditionally skipped now runs
- **`server/middleware` `recovery()` never recovered anything**: it tested `@errorReturnTrace()` *before* calling the handler, so it never saw an error, while `try next(ctx)` let handler errors travel up the chain. It now catches, logs and answers 500 — the code documents that Zig has no panic recovery, so `panic`/`unreachable` still aborts
- **`server/middleware` `requestTimeout()` could not time anything out**: it replaced the response *after* the handler had already run and been sent, and `requestTimeout(0)` panicked on unwrapping a null `user_data`. It now publishes `ctx.deadline_ms` for handlers that want to stop early, only replaces a response that has not been sent yet, treats `0` as "no deadline", and logs the case where the overrun happened after responding. The server-level `request_timeout_ms` — which only logged a warning — now answers 408 when nothing has been written
- **`infra/log`**: added `Level.off`. A log line written during `zig build test` deadlocks the build (the console sink writes to stdout, which is the test runner's IPC channel in `--listen=-` mode); this is now documented at the sink, and tests use `.off`

### Added
- Tests for every fix above (escaping, expiry, wrong-length signature, cache credential isolation, cache eviction hook, close-frame truncation, jitter edge cases, RESP frame bytes, config defaults, recovery, request timeout)

## [0.2.3] - 2026-10-10

### Fixed
- **`net/api` request parser buffer lifetime bug**: `path`/`raw_path` pointed into a stack buffer that the header loop overwrote, so every request matched routes against garbage (all real requests 404'd); paths are now copied before headers are parsed
- **`net/api` header termination bug**: `readUntilDelimiterOrEof` returns lines including `'\n'`, so the CRLF terminator was never detected and parsing hung; lines are now stripped of `'\n'`/`'\r'` before the empty-line check
- **`compat` stream I/O on 0.17.0**: `streamWrite`/`fileWrite` now flush (buffered writers never emitted short responses); `streamRead` performs a single read instead of filling the whole buffer (incremental protocol parsing hung)
- **`infra/cache`**: rewritten for 0.17's un-parameterized `std.DoublyLinkedList` (intrusive nodes) — now a real LRU via intrusive list + hash map
- **`infra/lock`**: distributed lock `renew` sent an unterminated command
- **`infra/retry`**: `retryWithBreaker` actually routes through the circuit breaker
- **`net/rpc`**: server now dispatches incoming frames to registered handlers (was accepted-but-never-executed); adds `boundPort()` and reliable `stop()` via self-connect wakeup
- **`tools/zgctl`**: generated routes use the real `addRoute` API with `{id}` param syntax; fixed `new` template project (builds on 0.17.0); fixed malformed usage text; `delCache` is now public so generated model code compiles; OpenAPI output is valid JSON

### Added
- Route params support both `{id}` and `:id` syntax
- End-to-end RPC roundtrip test (replaces the previously skipped stub)
- `examples/hello` minimal server example, wired into `zig build`
- zgctl unit tests wired into `zig build test`
- CI: `codegen-smoke` job exercising all four `zgctl` subcommands (api/openapi/model/new + template build)

### Changed
- **Renamed the CLI from `zigzeroctl` to `zgctl`** — shorter to type; the binary, `tools/zgctl` directory, docs, and CI all use the new name
- README module reference now marks `net/tls` (certificate loading only) and `data/orm` (no real DB driver) as experimental/placeholder
- SECURITY.md supported-versions table updated to 0.2.x

## [0.2.2] - 2026-10-05

### Fixed
- **Zig 0.17.0 stable adaptation**: Aligned with the final 0.17.0 release (type info restructuring landed after the 0.17.0-dev snapshot used for 0.2.1)
  - Migrated `@typeInfo(T).@"struct".fields` (unified `StructField` array) to the parallel-array layout: `field_names` / `field_types` / `field_attrs`
  - Migrated `@typeInfo(T).@"struct".decls` to `decl_names`
  - Affected: `src/data/validate.zig`, `src/data/orm.zig`, `src/config.zig`, `src/net/api.zig`, `src/net/rpc.zig`, `src/infra/sqlx.zig`
  - Updated `docs/getting-started/installation.md` and `CONTRIBUTING.md` to require Zig 0.17.0+
  - Synced hardcoded version constants in `src/zigzero.zig` and `build.zig`, and dependency URLs in README/docs, with the v0.2.2 release

## [0.2.1] - 2026-05-28

### Fixed
- **Zig 0.17.0 migration**: Updated from Zig 0.16.0 to 0.17.0
  - Replaced `Allocator.dupeZ` with `Allocator.dupeSentinel` (removed in 0.17)
  - Replaced `std.fmt.bufPrintZ` with `std.fmt.bufPrintSentinel` (removed in 0.17)
  - Updated `minimum_zig_version` in `build.zig.zon` to 0.17.0
  - Updated README badge and requirements to 0.17.0+
  - Updated CI workflow to Zig 0.17.0

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
- **Code Generation** ( `tools/zgctl`): CLI for scaffolding, API codegen, and ORM models
- **CI/CD**: GitHub Actions workflow for macOS and Ubuntu with SQLite/PostgreSQL/MySQL testing
