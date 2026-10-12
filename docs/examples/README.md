# Examples

完整可运行的示例，配合仓库根目录的 `examples/` 源码阅读。

- [chy3 — Creator Metaverse Platform](./chy3.md) — 跨三个业务域（问题域 / 解决域 / 世界域）的实战案例：路由分组、按路由中间件、JWT 鉴权、指标采集、健康检查

仓库里还有更小的例子：

| 示例 | 说明 |
|------|------|
| `examples/hello` | 最小服务器：一条路由、一次响应 |
| `examples/api-server` | 单个文件覆盖十余个中间件、WebSocket 房间广播、断路器保护的 HTTP 客户端、静态文件、服务发现 |
| `examples/chy3` | 多文件分层结构（domain / infra / types），本文档的主角 |
