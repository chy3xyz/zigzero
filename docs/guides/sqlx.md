# SQLx — Unified SQL Client

SQLx provides a unified SQL client for SQLite, PostgreSQL, and MySQL, with connection pooling, prepared statements, transactions, struct scanning, query builder, Redis caching, and built-in circuit breaker support.

**Alignment:** Inspired by [go-zero sqlx](https://github.com/zeromicro/go-zero/blob/master/core/stores/sqlx/sqlx.go) patterns — `SqlOption`, `transact()` helper, `CachedConn`, `SqlContext`.

---

## Supported Databases

| Driver | URL Format | Placeholder |
|--------|-----------|-------------|
| SQLite | `data.db` (file path) | `?` |
| PostgreSQL | `postgres://user:pass@host:5432/db` | `$1`, `$2`, ... |
| MySQL | `mysql://user:pass@host:3306/db` | `?` |

---

## 1. Quick Start

```zig
const sqlx = zigzero.sqlx;

var db = try sqlx.open(allocator, "data.db");
defer db.close();

// Query rows
var rows = try db.query("SELECT id, name FROM users", .{});
defer rows.deinit();

while (try rows.next()) |row| {
    const id = try row.get(i64, "id");
    const name = try row.get([]const u8, "name");
    std.debug.print("{}: {s}\n", .{ id, name });
}

// Query single row
const user = try db.queryRow("SELECT name FROM users WHERE id = ?", .{}, struct {
    name: []const u8,
});
std.debug.print("User: {s}\n", .{user.name});

// Exec (INSERT/UPDATE/DELETE)
try db.exec("INSERT INTO users (name, email) VALUES (?, ?)", .{ "Alice", "alice@example.com" });
```

---

## 2. Opening Connections

### SQLite

```zig
// File path
var db = try sqlx.open(allocator, "data.db");

// In-memory
var db = try sqlx.open(allocator, ":memory:");
```

### PostgreSQL

```zig
var db = try sqlx.open(allocator, .{
    .url = "postgres://user:pass@localhost:5432/mydb",
});
defer db.close();
```

### MySQL

```zig
var db = try sqlx.open(allocator, .{
    .url = "mysql://user:pass@localhost:3306/mydb",
});
defer db.close();
```

### URL with Query Parameters

```zig
var db = try sqlx.open(allocator, .{
    .url = "postgres://user:pass@localhost:5432/mydb?sslmode=disable",
});
```

### With Connection Pool Options

```zig
var db = try sqlx.open(allocator, .{
    .url = "postgres://user:pass@localhost:5432/mydb",
    .max_open_conns = 20,
    .max_idle_conns = 5,
    .conn_max_lifetime_ms = 300_000,
});
```

**Pool Options:**

| Option | Default | Description |
|--------|---------|-------------|
| `max_open_conns` | `1` | Max connections. `1` = no pool (single connection). `>1` = pool enabled |
| `max_idle_conns` | `1` | Max idle connections in pool |
| `conn_max_lifetime_ms` | `300_000` (5 min) | Max lifetime per connection before reconnect |

---

## 3. Query Variants

SQLx provides 5 query patterns, each with `Partial` and `*Ctx` variants:

| Method | Returns | Use Case |
|--------|---------|----------|
| `query()` | `Rows` | Multiple rows |
| `queryRow()` | single `T` | Single row scanned to struct |
| `queryRows()` | `[]T` | All rows scanned to slice |
| `findOne()` | `?T` | Single row, returns null if not found |
| `findAll()` | `[]T` | All rows, returns empty slice if none |

**Partial variants** (`queryPartial`, `queryRowPartial`, etc.) allow partial struct field matching — scanned struct can have a subset of the selected columns.

**Ctx variants** (`queryCtx`, `queryRowCtx`, etc.) accept a `SqlContext` for deadline/timeout control.

### 3.1 `query` — Multiple Rows

```zig
var rows = try db.query("SELECT id, name, email FROM users WHERE age > ?", .{ 18 });
defer rows.deinit();

while (try rows.next()) |row| {
    const id = try row.get(i64, "id");
    const name = try row.get([]const u8, "name");
    const email = try row.get(?[]const u8, "email"); // nullable
    _ = email;
}
```

### 3.2 `queryRow` — Single Row to Struct

```zig
const user = try db.queryRow(
    "SELECT id, name, email FROM users WHERE id = ?",
    .{ id },
    struct {
        id: i64,
        name: []const u8,
        email: ?[]const u8,
    },
);
std.debug.print("Name: {s}\n", .{user.name});
```

### 3.3 `queryRows` — All Rows to Slice

```zig
const users = try db.queryRows(
    "SELECT id, name FROM users ORDER BY id",
    .{},
    struct {
        id: i64,
        name: []const u8,
    },
);
defer allocator.free(users);

for (users) |user| {
    std.debug.print("{}: {s}\n", .{ user.id, user.name });
}
```

### 3.4 `findOne` — Single or Null

```zig
// Returns null if no rows found
const user = try db.findOne(
    "SELECT name FROM users WHERE id = ?",
    .{ id },
    struct { name: []const u8 },
);
if (user) |u| {
    std.debug.print("Found: {s}\n", .{u.name});
}
```

### 3.5 `findAll` — All Rows or Empty

```zig
const all_users = try db.findAll(
    "SELECT id, name FROM users WHERE active = ?",
    .{ true },
    struct { id: i64, name: []const u8 },
);
defer allocator.free(all_users);
```

### 3.6 Context Variants — Deadline / Timeout

```zig
const sqlx = zigzero.sqlx;

// Create context with deadline
var ctx = sqlx.SqlContext.init(allocator, 5000); // 5 second timeout
defer ctx.deinit();

// Use in query
var rows = try db.queryCtx(&ctx, "SELECT ...", .{});
defer rows.deinit();

// Check if deadline exceeded mid-operation
while (try rows.next()) |row| {
    if (ctx.isDone()) break; // deadline exceeded
    // process row...
}
```

---

## 4. Row — Getting Column Values

The `Row` type provides `get()` for accessing individual columns:

```zig
while (try rows.next()) |row| {
    const id: i64 = try row.get(i64, "id");
    const name: []const u8 = try row.get([]const u8, "name");
    const active: bool = try row.get(bool, "active");
    const balance: f64 = try row.get(f64, "balance");
    const bio: ?[]const u8 = try row.get(?[]const u8, "bio"); // nullable
}
```

**Supported types:** `i64`, `f64`, `[]const u8`, `bool`, `?T` (nullable)

---

## 5. Struct Scanning

### `Row.scan(T)` — Full Match

All struct fields must match a selected column:

```zig
var rows = try db.query("SELECT id, name, email FROM users", .{});
defer rows.deinit();

while (try rows.next()) |row| {
    const user = try row.scan(struct {
        id: i64,
        name: []const u8,
        email: ?[]const u8,
    });
    defer user.email_deinit(); // free nullable []const u8 fields
    std.debug.print("{s}\n", .{user.name});
}
```

### `Row.scanPartial(T)` — Partial Match

Only scanned fields need a matching column. Extra columns are ignored:

```zig
// Select 5 columns, scan only 2
var rows = try db.query("SELECT id, name, email, created_at, updated_at FROM users", .{});
defer rows.deinit();

while (try rows.next()) |row| {
    const partial = try row.scanPartial(struct {
        id: i64,
        name: []const u8,
    });
    defer partial.deinit(); // free allocated strings
    std.debug.print("{}: {s}\n", .{ partial.id, partial.name });
}
```

**Important:** When using `scanPartial`, always call `.deinit()` on the result to free any heap-allocated string data.

### Memory Management

Scanning allocates memory for `[]const u8` fields. Use `deinit()` or `freeScanned()`:

```zig
const user = try row.scan(User);
defer {
    // Manually free string fields
    allocator.free(user.name);
    if (user.email) |e| allocator.free(e);
}

// Or for partial scans, use the generated deinit:
const partial = try row.scanPartial(PartialUser);
defer partial.deinit();
```

---

## 6. Parameterized Queries

All drivers support parameterized queries. Placeholder style varies:

```zig
// SQLite — uses ?
try db.exec("INSERT INTO users (name, email) VALUES (?, ?)", .{ name, email });

// PostgreSQL — uses $1, $2...
try db.exec("INSERT INTO users (name, email) VALUES ($1, $2)", .{ name, email });

// MySQL — uses ?
try db.exec("INSERT INTO users (name, email) VALUES (?, ?)", .{ name, email });

// Mixed types
try db.query(
    "SELECT * FROM users WHERE age > ? AND status = ?",
    .{ @as(i64, 18), "active" },
);
```

SQLx automatically reformats the placeholder syntax per-driver, so your code stays the same across databases.

---

## 7. Transactions

### 7.1 `withTransaction` — Automatic Commit/Rollback

The simplest way — commits on success, rolls back on error:

```zig
try db.withTransaction(struct {
    fn run(tx: *sqlx.Tx) !void {
        // Insert user
        try tx.exec(
            "INSERT INTO users (name, email) VALUES (?, ?)",
            .{ "Alice", "alice@example.com" },
        );

        // Update related record
        try tx.exec(
            "UPDATE counters SET count = count + 1 WHERE name = ?",
            .{"user_count"},
        );
    }
}.run);
```

### 7.2 Manual Transactions

Full control over begin/commit/rollback:

```zig
var tx = try db.beginTx();
defer tx.rollback(); // safe: rollback is no-op if already committed

try tx.exec("INSERT INTO orders (user_id, total) VALUES (?, ?)", .{ user_id, total });
try tx.commit();
```

### 7.3 `transact` — Helper for Nested Transactions

Go-zero style helper that handles the boilerplate:

```zig
try sqlx.transact(allocator, &db, struct {
    fn run(tx: *sqlx.Tx, a: std.mem.Allocator) !void {
        try tx.exec("INSERT INTO users (name) VALUES (?)", .{"Bob"});
        try tx.exec("INSERT INTO logs (msg) VALUES (?)", .{"user created"});
    }
}.run, allocator);
```

---

## 8. Connection Pool

SQLx manages connections automatically. Pool is created when `max_open_conns > 1`:

```zig
var db = try sqlx.open(allocator, .{
    .url = "postgres://user:pass@localhost:5432/mydb",
    .max_open_conns = 20,
    .max_idle_conns = 5,
    .conn_max_lifetime_ms = 300_000,
});
defer db.close();
```

**Pool behavior:**
- Thread-safe: multiple goroutine-style concurrent queries
- Health check: pings idle connections, reconnects if unhealthy
- Reconnect: drops broken connections, creates fresh ones

---

## 9. CachedConn — Redis + LRU Cache Layer

`CachedConn` wraps a DB client with a two-tier cache (Redis + local LRU) and automatic invalidation.

```zig
var db = try sqlx.open(allocator, "data.db");
defer db.close();

// Create cache client
var redis_client = try redis.Client.init(allocator, .{
    .address = "127.0.0.1:6379",
});
defer redis_client.deinit();

var cache = cache.LruCache([]const u8, []const u8).init(allocator, 1000);
defer cache.deinit();

// Wrap with CachedConn
var cached_db = try sqlx.CachedConn.init(allocator, db, redis_client, &cache, 300);
defer cached_db.deinit();

// Cached queries — auto-cached by key
const user = try cached_db.queryRow(
    "SELECT id, name FROM users WHERE id = ?",
    .{ id },
    struct { id: i64, name: []const u8 },
);

// Auto-invalidated on mutations
try cached_db.exec("UPDATE users SET name = ? WHERE id = ?", .{ new_name, id });
try cached_db.exec("DELETE FROM users WHERE id = ?", .{id});
```

**Cache key format:** `cachedconn:sql:{hash(query)}:{args_hash}`

**Auto-invalidation:** `exec()`, `queryRow`, `queryRows`, `findOne`, `findAll` with cache keys trigger local LRU invalidation (but not Redis — for multi-instance, handle Redis invalidation externally).

---

## 10. Query Builder

The `Builder` provides a fluent, type-safe query builder:

### Select

```zig
const query = try sqlx.Builder.select(allocator, "id, name, email")
    .from("users")
    .where("age > ?", .{18})
    .orderBy("created_at DESC")
    .limit(10)
    .offset(0)
    .build();
defer query.deinit();

var rows = try db.query(query.sql, query.params);
defer rows.deinit();
```

### Insert

```zig
const query = try sqlx.Builder.insert(allocator, "users")
    .cols(&.{ "name", "email", "age" })
    .values(&.{ .{"Alice", "alice@example.com", 25}, .{"Bob", "bob@example.com", 30} })
    .build();
defer query.deinit();

try db.exec(query.sql, query.params);
```

### Batch Insert

```zig
const query = try sqlx.Builder.batchInsert(allocator, "users", &.{ "name", "email" })
    .addRow(&.{ "Alice", "alice@example.com" })
    .addRow(&.{ "Bob", "bob@example.com" })
    .addRow(&.{ "Carol", "carol@example.com" })
    .build();
defer query.deinit();

try db.exec(query.sql, query.params);
// Executes: INSERT INTO users (name, email) VALUES (?, ?), (?, ?), (?, ?)
```

### Update

```zig
const query = try sqlx.Builder.update(allocator, "users")
    .set("name", .{"Alice Updated"})
    .set("updated_at", .{"NOW()"})
    .where("id = ?", .{id})
    .build();
defer query.deinit();

try db.exec(query.sql, query.params);
```

### Delete

```zig
const query = try sqlx.Builder.delete(allocator, "users")
    .where("id = ? AND status = ?", .{ id, "inactive" })
    .build();
defer query.deinit();

try db.exec(query.sql, query.params);
```

### Count

```zig
const query = try sqlx.Builder.count(allocator, "users")
    .where("age > ?", .{18})
    .build();
defer query.deinit();

const result = try db.queryRow(query.sql, query.params, struct { count: i64 });
```

### Chaining with Where / Join / OrderBy

```zig
const query = try sqlx.Builder.select(allocator, "u.id, u.name, o.total")
    .from("users u")
    .join("orders o", "u.id = o.user_id")
    .where("u.age > ?", .{18})
    .where("o.status = ?", .{"completed"})
    .orderBy("o.total DESC")
    .limit(100)
    .build();
defer query.deinit();
```

---

## 11. Circuit Breaker Integration

SQLx integrates with `infra/breaker` to prevent cascade failures:

```zig
var cb = breaker.CircuitBreaker.new();
defer cb.deinit();

var db = try sqlx.open(allocator, "data.db");
try db.withBreaker(&cb);
defer db.close();

// Now queries are wrapped with circuit breaker
// If failures exceed threshold, circuit opens and fast-fails
const result = db.queryRow("SELECT ...", .{}, struct { ... });
```

**Configuration** — see [`circuit-breaker.md`](circuit-breaker.md) for threshold and timeout settings.

**Error filtering:** By default, `NotFound` errors do **not** count toward circuit breaker failures, since "not found" is expected behavior:

```zig
// Custom acceptable errors (don't count as failures)
var cb = breaker.CircuitBreaker.new();
try cb.setAcceptableErrors(&.{ sqlx.Error.NotFound, sqlx.Error.ConstraintError });
```

---

## 12. Metrics

SQLx supports zero-cost metrics via callback:

```zig
try db.setMetricsCallback(struct {
    fn callback(duration_ns: i64, query: []const u8, ok: bool, err_msg: ?[]const u8) void {
        std.debug.print("Query took {}ns, ok={}, err={s}\n", .{
            duration_ns, ok, err_msg orelse "none",
        });
    }
}.callback);
```

Metrics callback is invoked after every query/exec. Set to `null` to disable.

---

## 13. Tracing

SQLx supports OpenTelemetry-compatible tracing:

```zig
var tracer = try trace.Tracer.init(allocator, "my-service");
defer tracer.deinit();

var db = try sqlx.open(allocator, "data.db");
try db.setTracer(&tracer);
defer db.close();

// Each query creates a span automatically
var rows = try db.query("SELECT * FROM users", .{});
```

---

## 14. Prepared Statements

Prepared statements are managed automatically per-driver:

```zig
// SQLx handles prepare/execute internally
var stmt = try db.prepare("SELECT name FROM users WHERE id = ?");
defer stmt.close();

var rows = try stmt.query(.{ id });
defer rows.deinit();
```

Direct `Stmt` usage is available for performance-critical hot paths where you want to reuse the statement across many executions.

---

## 15. Full Example — CRUD API

```zig
const User = struct {
    id: i64,
    name: []const u8,
    email: []const u8,
};

const CreateUserReq = struct {
    name: []const u8,
    email: []const u8,
};

pub fn createUser(allocator: std.mem.Allocator, db: *sqlx.Client, req: CreateUserReq) !i64 {
    try db.exec(
        "INSERT INTO users (name, email) VALUES (?, ?)",
        .{ req.name, req.email },
    );

    const row = try db.queryRow("SELECT last_insert_rowid() as id", .{}, struct { id: i64 });
    return row.id;
}

pub fn getUser(allocator: std.mem.Allocator, db: *sqlx.Client, id: i64) !?User {
    return db.findOne(
        "SELECT id, name, email FROM users WHERE id = ?",
        .{id},
        User,
    );
}

pub fn listUsers(allocator: std.mem.Allocator, db: *sqlx.Client, limit: i64) ![]User {
    const users = try db.queryRows(
        "SELECT id, name, email FROM users ORDER BY id LIMIT ?",
        .{limit},
        User,
    );
    errdefer allocator.free(users);
    return users;
}

pub fn updateUser(allocator: std.mem.Allocator, db: *sqlx.Client, id: i64, name: []const u8) !void {
    try db.exec("UPDATE users SET name = ? WHERE id = ?", .{ name, id });
}

pub fn deleteUser(allocator: std.mem.Allocator, db: *sqlx.Client, id: i64) !void {
    try db.exec("DELETE FROM users WHERE id = ?", .{id});
}
```

---

## 16. Error Handling

```zig
const User = struct { id: i64, name: []const u8 };

switch (db.findOne("SELECT ...", .{}, User)) {
    .ok => |user| {
        if (user) |u| {
            // Found
            _ = u;
        } else {
            // No rows
        }
    },
    .err => |err| switch (err) {
        error.NotFound => {}, // expected — no rows matched
        else => return err,   // unexpected
    },
}
```

**Common errors:**

| Error | Cause |
|-------|-------|
| `NotFound` | `findOne`/`queryRow` returned no rows |
| `ConstraintError` | UNIQUE, NOT NULL, FK constraint violated |
| `SqliteError` | SQLite-specific errors (code + message) |
| `PostgresError` | PostgreSQL-specific errors (code + message) |
| `MysqlError` | MySQL-specific errors (code + message) |

---

## Related

- [Configuration](configuration.md) — YAML config for database connections
- [Circuit Breaker](circuit-breaker.md) — Resilience patterns
- [Metrics](metrics.md) — Prometheus metrics integration
- [Module Reference](../architecture/module-reference.md) — Complete API reference
