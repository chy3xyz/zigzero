# How-To Guides

每个指南解决一类具体问题：写中间件、限制流量、给下游加断路器、接数据库、做鉴权与配置加载。每篇都给出可直接使用的签名与示例，示例以 `src/` 下的真实源码为准。

## HTTP 与请求处理

- [HTTP API Server](./api-server.md) — 路由、处理器、路由分组、静态文件、启动配置
- [Middleware](./middleware.md) — 内置中间件、自定义中间件、分组与状态注入
- [Graceful Shutdown](./graceful-shutdown.md) — 生命周期钩子与信号处理

## 可靠性

- [Rate Limiting](./rate-limiting.md) — 令牌桶、滑动窗口、按 IP 限流
- [Circuit Breaker](./circuit-breaker.md) — 三态断路器与外呼保护

## 数据与配置

- [SQLx](./sqlx.md) — SQLite / PostgreSQL / MySQL 统一客户端：连接池、prepared statement、事务、结构体扫描、查询构建器、缓存
- [Configuration](./configuration.md) — YAML / JSON / 环境变量加载与文件监听

## 可观测性与安全

- [Metrics & Observability](./metrics.md) — Prometheus 指标与健康检查
- [Authentication](./authentication.md) — JWT 中间件与 token 签发

想了解某个模块的完整 API，见 [Module Reference](../architecture/module-reference.md)。
