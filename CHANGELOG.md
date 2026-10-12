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
- **`core/load` adaptive shedder never had a working signal**: `defaultCpuOverloaded` returned false unconditionally and `overloadFactor` therefore always saw `cpu_usage = 0`, so the shedder could not shed unless the caller injected a detector. `sampleCpuUsage()` now measures real CPU utilization — Linux from a `/proc/stat` tick delta, macOS from `host_statistics(HOST_CPU_LOAD_INFO)` ticks, the same busy/total quantity, cached for 250 ms — and reports `unavailable` rather than a fabricated zero when it cannot measure. `cpuUsage()` is null when unmeasured, and the injectable detector still wins
- **`infra/health` built-in checks were hardcoded healthy**: `checks.memory` ignored its allocator and `checks.disk` never looked at the filesystem, so a probe that could not fail reported `.healthy` forever. They now measure process RSS (Linux `/proc/self/statm`, macOS `task_info`) against a configured limit and free space (`statvfs`) against a minimum, report `.unhealthy` with the measured value when over, and `.degraded`/`unmeasured: <error>` when the platform cannot be measured. Both accept an injectable probe
- **`infra/loadbalancer` weighted round-robin destroyed its weights**: the per-node countdown consumed the configured weight and the "reset" set every node back to 1, so weights applied for a single cycle. Replaced with smooth weighted round-robin (nginx-style running weights); `weight` is now a read-only configuration value
- **`infra/loadbalancer` consistent hashing was not consistent**: selection was `(hash % (n * 150)) % n` with no ring, so removing one node remapped essentially every key, and `select()` hashed an empty string. It now builds a real virtual-node ring (`core/hash.ConsistentHash`, 300 replicas, rebuilt when the healthy set changes), and `selectWithKey(key)` passes the caller's actual client key. Measured: removing one of four nodes remaps ~24% of keys instead of nearly all
- **`net/http` client timeouts and retries were decorative**: `timeout_ms` and `retries` were never used, so a stalled peer hung the caller forever, and the status line was parsed at a fixed offset. Connect, write and read now share one absolute per-attempt deadline enforced through `std.Io.operateTimeout` (poll, 1 ms granularity), retries run through `infra/retry`'s backoff, and the status line is parsed properly (`error.InvalidStatusLine` on malformed input). `https://` is rejected with `error.HttpsNotSupported` instead of being silently attempted
- **`net/api` `bindJson` returned dangling slices**: it parsed with `parseFromSlice` and freed the arena in a `defer` before returning, so any `T` with slice fields pointed at freed memory; it now parses into the request arena
- **Six documented APIs had never compiled** (they were unreachable from any built binary, so the compiler never checked them; each is now called from a test):
  - **`server/static`**: `Server.handler()` captured a runtime local in an inner function, which Zig rejects — every call site was a compile error. It now reaches its `Server` through the route's `user_data`. Its 0.17 file APIs were stale too (`realPathFile`, `readFileAlloc`, `statFile`), and the traversal guard accepted a sibling directory that merely shared the root's prefix (`<root>-evil`), which is now rejected
  - **`config`**: `loadYaml` / `loadJson` / `Watcher.hasChanged` passed no `io` to `openFile`/`statFile` and used the removed `readToEndAlloc`; both loaders now also give the caller uniform ownership of every string (`Loader.freeConfig`), so a field absent from the source is no longer a static default that crashes on free
  - **`net/gateway`**: `registerRoute` did not compile, because `StringHashMap.get` hands back a *copy* of the upstream and `pickEndpoint` needs the map's own value — which also means the round-robin state was being discarded. It uses `getPtr` now, and the per-route `RouteConfig` allocations it leaked are freed by `Gateway.deinit()`
  - **`infra/redis`**: `hSet` returned `0` from a function declared `!bool`
  - **`net/api`**: `RouteGroup` had no way to attach state, so grouped handlers could not use `user_data` at all; added `withUserData(?*anyopaque)`
  - **`examples/chy3`**: a grouped route was registered without `user_data` (its handler unwrapped the null pointer, so the route panicked) and `/api/v1/worlds/stats` handed an `AppContext` handler a bare registry pointer (type confusion). Both fixed and verified against a running server; the two dead helpers in the example are gone

### Added
- Tests for every fix above (escaping, expiry, wrong-length signature, cache credential isolation, cache eviction hook, close-frame truncation, jitter edge cases, RESP frame bytes, config defaults, recovery, request timeout, CPU sampling, health probes, weighted distribution, consistent-hash remapping, HTTP timeouts and retries)

- **The documentation now builds as a published site**: `docs/` is rendered by [zdoc](https://github.com/chy3xyz/zdoc) — a pinned static binary, no Node and no site config — and deployed to GitHub Pages by `.github/workflows/docs.yml`, which also fails on an unresolved link. Each section (`getting-started/`, `guides/`, `architecture/`, `examples/`) gained an index page: they are useful landing pages, and zdoc resolves a bare `name.md` sibling link only when the directory has an index page — without them 32 links in the guides were unreachable

### Changed
- **Documentation corrected against the real source**: the guides described a pre-0.17 API surface and, in several places, APIs that never existed (circuit breaker `execute*`, `TokenBucket.init(allocator, .{...})`, `ctx.getRequestId()`, `ctx.remote_addr`, `config.loadFromYamlFile`, redis `Client.init(allocator, .{...})`, JWT claims with `role`/`iss`/`aud`, `limiter.GlobalLimiter`, …). Every sample in `README.md`, `docs/getting-started`, `docs/guides` and `docs/architecture` was checked against the source and the fabricated APIs replaced with the real ones; removed-in-0.17 std symbols (`GeneralPurposeAllocator`, `std.time.timestamp`, `std.Thread.sleep`) and missing `compat.initIo` calls were fixed throughout
- **README framing**: the "production-ready" claim is replaced with an honest pre-1.0/beta statement naming the placeholder (`data/orm`), the stub (`net/tls`) and the experimental modules

### Added
- **Router wildcards**: a trailing `*name` (or bare `*`) captures the rest of the path, separators included, so `/*file` covers a whole tree in one route. Precedence is exact segment > `:param` > wildcard; a wildcard must be the last segment and cannot share a node with a `:param` (the registration is rejected with `error.InvalidRoute` because their match sets overlap). `MatchedRoute` gained a `deinit` for its captured parameters
- `examples/api-server` serves its `public/` directory through the wildcard route, which is also the end-to-end path for the feature

### Fixed (this batch)
- **`net/api` leaked parameters when a match failed midway**: once a `:param` had been bound, every bail-out path called `params.deinit()` without freeing the keys and values it held
- **`net/http`'s large-body write could outlive its deadline**: `std.Io`'s write helper polls for writability and then performs a *blocking* `send`, which sits in the kernel until the peer reads — unbounded once the socket buffer fills, so the deadline never fired (a test showed the call returning only when the stalled peer closed the connection). Writes now go through a non-blocking `send` with `EAGAIN` retried under our own `poll` deadline, and the socket's blocking mode is restored afterwards for the read path
- **`net/tls` claimed to be available**: `isAvailable()` returned true unconditionally while nothing implements a handshake, so a caller gating HTTPS on it would have served plaintext. It now reports false, and the module states that it only loads certificate files
- **`core/load` / `infra/health` Linux parsing is now tested**: the `/proc/stat` cpu line and `/proc/self/statm` parsing were split out of the file reads into pure functions and covered with real Linux file samples (field layout, guest/guest_nice exclusion, delta arithmetic, malformed input), so the Linux paths are no longer compile-only
- **Documentation**: the guides said the router has no `/*` catch-all and told readers to register one route per directory level; that is replaced by the real wildcard usage
- **PostgreSQL statements built at runtime were handed to libpq without NUL termination**: `PQexecParams`, `PQexec`, `PQprepare` and `PQexecPrepared` take C strings, but the driver passed the `.ptr` of slices assembled at runtime, so libpq read past the end of the allocation. Statements written as string literals are sentinel-terminated and worked, which is why the repository's own tests passed while the ORM (and every generated model) failed against a live server. All four call sites now use sentinel-terminated buffers. Found by running the ORM's round trip against a live PostgreSQL
- **`infra/sqlx` PostgreSQL and MySQL returned every column as `.string`**: `sqlx.valueToType` could therefore not scan into `i64`/`f64`/`bool`, so `queryRow`/`queryRows` — and the ORM on those drivers — failed unless every field was a string. Both drivers now read the column metadata (`PQftype` OIDs; `MYSQL_FIELD.type` plus the unsigned flag) and build the matching `Value`, falling back to `.string` when the text does not parse. The same treatment applies to the prepared-statement paths, and the PostgreSQL statement paths also had two defects of their own: `execParamsPrepared` passed `null` lengths for parameters that are not NUL-terminated, and the prepared-statement name was freed with a length mismatch (the sentinel byte was not accounted for). Verified against live PostgreSQL and MySQL; the PostgreSQL parameter leak (`execParams` never freed the rendered int/float arguments) was fixed in the same pass
- **`data/orm` ignored a declared primary key**: `getPrimaryKey` only accepted a field literally named `id` and skipped `pub const primary_key` — the very declaration `zgctl model` emits — so a table keyed on anything else failed with `error.NoPrimaryKey`. The declaration now wins, with the `id` convention as the fallback, and `orm.Config` exposes `postgres_conninfo` for the connection-string form
- **`tools/zgctl` mapped almost every DDL column to `[]const u8`**: the type mapping compared lowercase names against the raw SQL token, so the uppercase DDL everyone writes (`INT`, `VARCHAR(255)`) matched nothing and fell through to a string; `SERIAL`/`BIGSERIAL` were missing from the integer family entirely, so a PostgreSQL primary key became a string. Types are matched case-insensitively now, the family lists cover the common SQL names (`serial`, `int2/int4/int8`, `real`, `money`, `uuid`, `json`, `bytea`, …), and date/time columns are documented as read-back-as-text. A generated model was compiled and run against sqlite (insert → findOne → findAll) to confirm the typed fields round-trip

- **`infra/sqlx` MySQL's "prepared statement" path was not one**: `Client.prepare` returned a handle that rebuilt an interpolated string and ran `mysql_real_query`, so the only thing standing between a caller's data and the server was `formatQuery`'s escaping. Statements are now really prepared server-side (`mysql_stmt_prepare`) with parameters bound as typed `MYSQL_BIND` buffers and result columns bound and fetched through `mysql_stmt_fetch`, decoded by the same column metadata as the text path. A column larger than the fetch buffer is re-read at the length the server reports (`mysql_stmt_fetch_column`), and a statement the server refuses to prepare falls back to the text path. The `mysql_stmt_*` bindings and the `MYSQL_BIND` layout were verified field by field against the installed `mariadb_stmt.h`
- **`data/orm` `create` can now fill a generated key on PostgreSQL too**: the driver reports no last-insert-id, so an unset integer key is obtained with `RETURNING <pk>`. A caller-supplied key is still never overwritten
- **`net/api` route groups can nest**: `RouteGroup.group(prefix)` extends the parent prefix and inherits its middleware and `user_data`; the combined prefix is owned by the `Server`
- **Fixed-point columns stay exact**: `NUMERIC`/`DECIMAL` mapped to `.float`, so a money column silently lost digits; they now map to `.string` (what the reference driver does with `numeric`), preserving the digits and scale the server sent

### Changed
- **`data/orm` is no longer a placeholder**: `Pool` now owns a real `sqlx.Client`, `Connection.query`/`execute` return real rows and row counts, `Transaction` delegates to sqlx, and `Crud(T).findById/findAll/create/update/delete` build and execute real SQL from the `Model(T)` metadata (driver-appropriate placeholders; `create` fills in the generated key where the driver reports one). `Pool.freeScanned`/`deinitRows` are the matching release helpers. Driver limits are documented in the file: PostgreSQL/MySQL still hand every column back as `.string` from sqlx, so scanning into `i64`/`f64`/`bool` fails there, and PostgreSQL cannot report a generated key

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
