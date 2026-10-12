# Installation

## Requirements

| Requirement | Version | Notes |
|-------------|---------|-------|
| **Zig** | 0.17.0+ | Install via [ziglang.org](https://ziglang.org/download.html) or Homebrew |
| **OS** | macOS, Linux, Windows (WSL) | Primary targets |
| **C libs** | Optional | Only needed for `sqlx` module |

## Install Zig

### macOS (Homebrew)

```bash
brew install zig
```

### Linux (二进制压缩包)

```bash
curl -L https://ziglang.org/download/0.17.0/zig-linux-x86_64-0.17.0.tar.xz | tar xJ
export PATH=$PWD/zig-linux-x86_64-0.17.0:$PATH
```

### 其他包管理器

```bash
# Ubuntu/Debian
apt install zig

# Fedora
dnf install zig

# Arch Linux
pacman -S zig
```

验证安装：

```bash
zig version
# 0.17.0
```

## System Dependencies (sqlx 模块)

The `sqlx` module supports SQLite, PostgreSQL, and MySQL. Install the C libraries for the databases you need.

### macOS

```bash
brew install sqlite3 libpq mariadb-connector-c

# Verify
brew list --versions sqlite3 libpq mariadb-connector-c
```

### Ubuntu / Debian

```bash
sudo apt-get update
sudo apt-get install -y libsqlite3-dev libpq-dev libmysqlclient-dev
```

### Fedora / RHEL

```bash
sudo dnf install sqlite-devel postgresql-devel mysql-devel
```

### Custom Paths

If libraries are installed in non-standard locations:

```bash
PQ_INCLUDE=/custom/include PQ_LIB=/custom/lib \
MYSQL_INCLUDE=/custom/include MYSQL_LIB=/custom/lib \
zig build
```

## Clone and Build

```bash
git clone https://github.com/chy3xyz/zigzero.git
cd zigzero
zig build
```

### 自定义构建

```bash
# Release build with runtime safety checks
zig build -Doptimize=safe

# Debug build (faster compile, slower runtime)
zig build -Doptimize=debug

# Release with unsafe optimizations (fastest, no runtime checks)
zig build -Doptimize=fast

# Smallest binary
zig build -Doptimize=small
```

## Install the CLI Tool

```bash
zig build
./zig-out/bin/zgctl --help
```

## 数据库初始化 (for testing)

```bash
# Setup all databases
./scripts/init-db.sh

# PostgreSQL only
./scripts/init-db.sh --postgres

# MySQL only
./scripts/init-db.sh --mysql

# Clean up test databases
./scripts/init-db.sh --clean
```

## 验证安装

```bash
# Build the framework
zig build

# Run tests (SQLite)
zig build test

# Run tests with PostgreSQL
DB=postgres zig build test

# Run tests with MySQL
DB=mysql zig build test
```

## 使用为依赖

### 方式 1: Fetch 自动解析

```bash
cd your-project
zig fetch https://github.com/chy3xyz/zigzero/archive/refs/tags/v0.2.3.tar.gz
```

Then add to `build.zig.zon`:

```zig
.{
    .dependencies = .{
        .zigzero = .{
            .url = "https://github.com/chy3xyz/zigzero/archive/refs/tags/v0.2.3.tar.gz",
            .hash = "1220...",  # zig fetch will fill this in
        },
    },
}
```

### 方式 2: Git Submodule

```bash
cd your-project
git submodule add https://github.com/chy3xyz/zigzero.git vendor/zigzero
```

```zig
// build.zig.zon
.{
    .dependencies = .{
        .zigzero = .{
            .path = "vendor/zigzero",
        },
    },
}
```

## 下一步

- [Quick Start](quick-start.md) — 5分钟快速上手
- [Build Your First Service](first-service.md) — 构建你的第一个 REST API
- [HTTP API Server Guide](../guides/api-server.md) — 深入了解 HTTP 服务器
