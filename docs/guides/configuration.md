# Configuration

ZigZero 提供灵活的配置系统，支持 YAML、JSON、环境变量和代码字面量。

## 配置加载

加载函数都是泛型的，`T` 由调用方指定；第一个参数是类型，第二个是分配器：

```zig
pub fn loadYaml(comptime T: type, allocator: std.mem.Allocator, path: []const u8) !T
pub fn loadJson(comptime T: type, allocator: std.mem.Allocator, path: []const u8) !T
pub fn loadEnv(comptime T: type, allocator: std.mem.Allocator, prefix: []const u8) !T
```

也可以用 `config.Loader`：

```zig
pub const Loader = struct {
    pub fn init(allocator: std.mem.Allocator) Loader;
    pub fn loadJson(self: Loader, comptime T: type, path: []const u8) !T;
    pub fn loadYaml(self: Loader, comptime T: type, path: []const u8) !T;
    pub fn parseJson(self: Loader, comptime T: type, content: []const u8) !T;
    pub fn parseYaml(self: Loader, comptime T: type, content: []const u8) !T;
    pub fn loadEnv(self: Loader, comptime T: type, prefix: []const u8) !T;
};
```

> **所有权约定**：按路径加载（`loadYaml` / `loadJson` / `loadEnv`，含 `Loader` 上的同名方法与 `Watcher.reload`）返回的配置里，每个字符串都由 loader 的 allocator 持有，释放时调用 `Loader.freeConfig(T, &cfg)`（例如 `config.Loader.init(alloc).freeConfig(MyConfig, &cfg)`），**不要手工 `free` 单个字段**——它会递归处理嵌套结构体与字符串数组。`parseYaml` / `parseJson` 接收的 `content` 参数仍由调用方自己读取和释放。

### 从 YAML 文件

```yaml
# config.yaml
name: my-service
port: 8080

log:
  service_name: my-service
  level: info
  mode: console

redis:
  host: 127.0.0.1
  port: 6379
  db: 0

mysql:
  host: localhost
  port: 3306
  database: myapp
  username: root
  password: ""

etcd:
  endpoints:
    - localhost:2379
  timeout_sec: 5
```

```zig
const std = @import("std");
const zigzero = @import("zigzero");
const compat = zigzero.compat;
const config = zigzero.config;
const api = zigzero.api;
const log = zigzero.log;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    compat.initIo(allocator);
    defer compat.deinitIo();

    const logger = log.Logger.new(.info, "my-service");

    // loadYaml 直接读文件；返回配置里的字符串都由 allocator 持有
    const cfg = try config.loadYaml(config.Config, allocator, "config.yaml");
    defer config.Loader.init(allocator).freeConfig(config.Config, &cfg);

    var server = api.Server.init(allocator, cfg.port, logger);
    // ...
}
```

`config.Config` 是框架内置的结构（`name`、`port`、`log`、`redis`、`mysql`、`etcd`）。YAML 解析器是简化子集：支持 `key: value`、按缩进嵌套、`- ` 数组、字符串/数字/布尔/`null`，以及整行 `#` 注释或 ` #` 行尾注释。

### 从 JSON 文件

```json
{
  "host": "127.0.0.1",
  "port": 6379,
  "db": 0
}
```

```zig
const cfg = try config.loadJson(config.RedisConfig, allocator, "redis.json");
defer config.Loader.init(allocator).freeConfig(config.RedisConfig, &cfg);
```

配置里的字符串字段都由 loader 的 allocator 分配；用 `Loader.freeConfig(T, &cfg)` 统一释放，不要自行 `free` 单个字段。

### 从环境变量

环境变量用独立的 `loadEnv` 加载，变量名是 `PREFIX_字段名大写`：

```bash
export SERVER_PORT=8080
export SERVER_WORKERS=4
```

```zig
const ServerConfig = struct {
    port: u16 = 8080,
    workers: u32 = 4,
};

const cfg = try config.loadEnv(ServerConfig, allocator, "SERVER");
// 读取 SERVER_PORT / SERVER_WORKERS，未设置的字段保留默认值
```

支持的字段类型：整数、浮点、布尔和 `[]const u8`；嵌套结构体在 `loadEnv` 中会编译报错（`Nested structs not supported in env vars`）。

### 组合配置源

框架不做自动合并，优先级由调用方决定。推荐顺序：

```
命令行参数 > 代码字面量 > 环境变量 > YAML/JSON 配置 > 字段默认值
```

YAML 里**不支持** `${VAR}` 插值，请分别加载后再覆盖，例如先 `loadYaml` 再用 `loadEnv` 的结果覆盖需要的字段。

## 配置结构定义

解析按字段名匹配。支持的类型：

| 类型 | 说明 |
|------|------|
| 整数 / 浮点 / 布尔 | 直接转换 |
| `[]const u8` | 拷贝为分配器持有的字符串 |
| `?T` | JSON `null` 映射为 `null` |
| 嵌套 struct | 必须实现 `pub fn fromJson(allocator, json: std.json.Value) !Self` |

字段可以声明默认值；配置文件中缺失的键保留默认值（而不是 `undefined`）。数组字段不在通用解析范围内——需要数组时，在自定义类型的 `fromJson` 里手工处理（参考框架内置的 `EtcdConfig.fromJson`）。

```zig
const ServerConfig = struct {
    port: u16 = 8080,
    workers: u32 = 4,
    read_timeout_ms: u32 = 30_000,
    write_timeout_ms: u32 = 30_000,

    // 作为嵌套字段解析时，必须提供 fromJson
    pub fn fromJson(allocator: std.mem.Allocator, json: std.json.Value) !ServerConfig {
        _ = allocator;
        var cfg = ServerConfig{};
        if (json.object.get("port")) |v| cfg.port = @intCast(v.integer);
        if (json.object.get("workers")) |v| cfg.workers = @intCast(v.integer);
        if (json.object.get("read_timeout_ms")) |v| cfg.read_timeout_ms = @intCast(v.integer);
        if (json.object.get("write_timeout_ms")) |v| cfg.write_timeout_ms = @intCast(v.integer);
        return cfg;
    }
};

const AppConfig = struct {
    server: ServerConfig,
    log_level: []const u8 = "info",

    pub fn fromJson(allocator: std.mem.Allocator, json: std.json.Value) !AppConfig {
        var cfg = AppConfig{ .server = .{} };
        if (json.object.get("server")) |v| {
            cfg.server = try ServerConfig.fromJson(allocator, v);
        }
        if (json.object.get("log_level")) |v| {
            cfg.log_level = try allocator.dupe(u8, v.string);
        }
        return cfg;
    }
};
```

## 配置验证

加载后手工校验并返回自己的错误：

```zig
pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !AppConfig {
    const cfg = try config.loadYaml(AppConfig, allocator, path);

    if (cfg.server.port < 1024) {
        return error.InvalidPort;
    }
    if (cfg.server.workers == 0) {
        return error.InvalidWorkerCount;
    }

    return cfg;
}
```

没有内置的校验 / 合并 API（没有 `config.merge`），需要时自行编写。

## 环境特定配置

### 开发/生产/测试环境

```bash
# config.dev.yaml
redis:
  host: localhost

# config.prod.yaml
redis:
  host: prod-db.internal
  pool_size: 50
```

```bash
# 启动时指定环境
./my-service --config config.prod.yaml

# 或通过环境变量
export ZIGZERO_ENV=prod
```

### 多环境配置

按环境选择文件路径即可，框架不提供跨文件合并：

```zig
pub fn configPathForEnv(env: []const u8) []const u8 {
    return if (std.mem.eql(u8, env, "prod")) "config.prod.yaml" else "config.dev.yaml";
}

pub fn loadEnvConfig(allocator: std.mem.Allocator, env: []const u8) !config.Config {
    const path = configPathForEnv(env);
    return config.loadYaml(config.Config, allocator, path);
}
```

## 配置热重载

`config.Watcher(T)` 用文件 mtime 轮询检测变化，构造时传分配器、文件路径和轮询间隔（毫秒）：

```zig
pub fn init(allocator: std.mem.Allocator, file_path: []const u8, interval_ms: u64) !Self
pub fn deinit(self: *Self) void
pub fn hasChanged(self: *Self) bool
pub fn reload(self: *Self) !T
pub fn watch(self: *Self, callback: *const fn (T) void) !void
```

没有 `FileWatcher` / `onChange` 这类命名，`interval_ms` 是构造参数而不是通过 `.onChange()` 传入。`init` 会复制 `file_path`，生命周期由 `Watcher` 自己管理（记得 `deinit`）。

轮询式：自己检查变化并按需重载：

```zig
var watcher = try config.Watcher(AppConfig).init(allocator, "config.yaml", 5000);
defer watcher.deinit();

if (watcher.hasChanged()) {
    const cfg = try watcher.reload();
    defer config.Loader.init(allocator).freeConfig(AppConfig, &cfg);
    applyNewConfig(cfg);
}
```

`reload()` 和 `loadYaml` / `loadJson` 一样，返回配置里每个字符串都由加载器分配；用完必须用 `Loader.freeConfig(T, &cfg)` 释放，不要手工 `free` 单个字段。

`watch(callback)` 是阻塞循环：按 `interval_ms` 轮询，变化时重载并调用回调，通常放到独立线程里跑。回调是普通函数指针 `*const fn (T) void`（不能捕获外层局部变量），它收到的 `cfg` 同样由 watcher 的 allocator 持有：

```zig
const t = try std.Thread.spawn(.{}, runWatch, .{allocator, &watcher});
t.detach();

fn runWatch(alloc: std.mem.Allocator, w: *config.Watcher(AppConfig)) void {
    _ = alloc;
    w.watch(&onConfigChange) catch |err| std.debug.print("watch failed: {s}\n", .{@errorName(err)});
}

fn onConfigChange(cfg: AppConfig) void {
    applyNewConfig(cfg); // cfg 的字符串由 watcher 的 allocator 持有，用完自行 freeConfig
}
```

## 从代码配置

不使用文件，直接构造结构体字面量：

```zig
const cfg = ServerConfig{
    .port = 9090,
    .workers = 2,
};
```

## 密钥管理

**不要将密钥提交到代码库：**

```bash
# .gitignore
config.yaml
!config.yaml.example
```

```yaml
# config.yaml.example (不含密钥)
mysql:
  password: ""
redis:
  password: ""
```

```bash
# 生产环境变量（变量名 = PREFIX_字段名大写）
export MYSQL_PASSWORD=actual-secure-password
export REDIS_PASSWORD=redis-secret
export JWT_SECRET=your-256-bit-secret
```

密钥通过 `config.loadEnv` 读入后覆盖配置字段，或直接作为 `middleware.jwt` 的 secret 参数传入。

## 下一步

- [Authentication](authentication.md) — JWT 认证配置
- [Graceful Shutdown](graceful-shutdown.md) — 配置与生命周期集成
- [First Service Tutorial](../getting-started/first-service.md) — 完整配置示例
