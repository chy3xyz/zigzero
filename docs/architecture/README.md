# Architecture

分层结构、模块职责，以及每个公开 API 的签名参考。这里的签名与 `src/` 一一对应（Zig 0.17），改动源码时请同步。

- [Architecture Overview](./overview.md) — 设计原则、分层图、请求处理流程、内存与并发模型
- [Module Reference](./module-reference.md) — 所有模块的完整 API：net、server、infra、data、core、config、svc

先读 Overview 建立整体印象，需要查具体函数签名时再翻 Module Reference。
