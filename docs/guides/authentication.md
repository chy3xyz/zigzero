# Authentication

JWT 认证、自定义 Token 生成和 Bearer Token 验证。

## JWT 中间件

`middleware.jwt(allocator, secret)` 创建中间件，它从 `Authorization: Bearer <token>` 头读取并校验 Token（HMAC-SHA256，`exp` 过期即拒绝）：

```zig
const middleware = zigzero.middleware;

try server.addMiddleware(try middleware.jwt(allocator, "your-secret-key"));
```

签名：

```zig
pub fn jwt(allocator: std.mem.Allocator, secret: []const u8) !api.Middleware
```

校验失败一律返回 401：缺少头 / 格式不是 `Bearer ` / 空 Token / 签名错误 / `exp` 已过期。

## Token Claims 结构

框架的 claims 只有以下五个字段，全部可选：

```zig
pub const Claims = struct {
    sub: ?[]const u8 = null,       // 用户 ID (subject)
    user_id: ?[]const u8 = null,
    username: ?[]const u8 = null,
    exp: ?i64 = null,              // 过期时间 (Unix 秒)
    iat: ?i64 = null,              // 签发时间 (Unix 秒)
};
```

没有 `role`、`iss`、`aud` 字段——给 claims 传 `.role = ...` 无法编译。角色信息需要在应用层自己维护（见下文「角色/权限检查」）。

## 生成 JWT Token

```zig
const compat = zigzero.compat;
const middleware = zigzero.middleware;

pub fn handleLogin(ctx: *api.Context) !void {
    const req = try ctx.bindJson(LoginReq);

    // 验证用户凭证
    const user = try db.findUser(req.username, req.password) orelse {
        try ctx.sendError(401, "invalid credentials");
        return;
    };

    // 生成 Token
    const token = try middleware.generateToken(ctx.allocator, .{
        .sub = user.id,
        .username = user.name,
        .exp = compat.timestamp() + 3600 * 24,  // 24 小时过期
        .iat = compat.timestamp(),
    }, "your-secret-key");
    defer ctx.allocator.free(token);

    try ctx.jsonStruct(200, .{ .token = token });
}
```

签名：`generateToken(allocator, claims: Claims, secret) ![]u8`。返回值由调用方持有并释放。

## 受保护路由

```zig
// 方式 1: 全局 JWT 中间件（所有路由需要认证）
try server.addMiddleware(try middleware.jwt(allocator, "secret"));
try server.addRoute(.{
    .method = .GET,
    .path = "/api/users",
    .handler = handleListUsers,
});

// 方式 2: 路由级 JWT（仅特定路由需要认证）
try server.addRoute(.{
    .method = .POST,
    .path = "/api/users",
    .handler = handleCreateUser,
    .middleware = &.{try middleware.jwt(allocator, "secret")},
});
```

## 从请求中获取用户信息

没有 `ctx.getJwtClaims()`。校验通过后，中间件只把 `sub` 写入一个 `X-User-ID` 头：

```zig
// 中间件内部（middleware.zig）
if (parsed.value.object.get("sub")) |sub| {
    if (sub == .string) {
        try ctx.setHeader("X-User-ID", sub.string);
    }
}
```

`ctx.setHeader` 写入的是**响应头**（`ctx.response_headers`），`ctx.header()` 读的是**请求头**（`ctx.headers`），所以下游处理器要这样读：

```zig
fn handleGetProfile(ctx: *api.Context) !void {
    const user_id = ctx.response_headers.get("X-User-ID") orelse {
        try ctx.sendError(401, "no token");
        return;
    };

    const user = try db.findUserById(ctx.allocator, user_id);
    try ctx.jsonStruct(200, user);
}
```

`X-User-ID` 同时会随响应返回给客户端；如需隐藏，可在最终响应前删除该头。

## 角色/权限检查

claims 里没有 `role`，权限必须在应用层维护。下面的中间件用一个由 `X-User-ID` 索引的角色表：

```zig
const RoleTable = std.StringHashMap([]const u8);

// 中间件函数体不能捕获运行时局部变量，角色表放在文件作用域，
// 在 main 里用真实 allocator 初始化。
var role_table: RoleTable = undefined;

fn requireRole(comptime role: []const u8) zigzero.api.Middleware {
    return .{
        .func = struct {
            fn exec(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) !void {
                const user_id = ctx.response_headers.get("X-User-ID") orelse {
                    try ctx.sendError(401, "unauthorized");
                    return;
                };

                const actual = role_table.get(user_id) orelse "";
                if (!std.mem.eql(u8, actual, role)) {
                    try ctx.sendError(403, "forbidden");
                    return;
                }

                try next(ctx);
            }
        }.exec,
    };
}

// 使用
pub fn main() !void {
    role_table = RoleTable.init(allocator);
    defer role_table.deinit();
    try role_table.put("user123", "admin");

    try server.addRoute(.{
        .method = .DELETE,
        .path = "/api/admin/users/:id",
        .handler = handleDeleteUser,
        .middleware = &.{
            try middleware.jwt(allocator, "secret"),
            requireRole("admin"),
        },
    });
}
```

## 刷新 Token

`verifyJwt` 是私有函数，中间件也不会把 `exp` 透传到下游——下游唯一能拿到的身份信息是 `X-User-ID`。因此：

- 过期 Token 会被 JWT 中间件直接拒绝（401），无法用它换新 Token；
- 刷新必须在 Token 仍有效时由客户端发起，服务端不再校验旧 `exp`。

```zig
// 客户端在 Token 到期前调用此路由；jwt 中间件保证调用者持有有效 Token
try server.addRoute(.{
    .method = .POST,
    .path = "/auth/refresh",
    .handler = handleRefreshToken,
    .middleware = &.{try middleware.jwt(allocator, "your-secret-key")},
});

fn handleRefreshToken(ctx: *api.Context) !void {
    const user_id = ctx.response_headers.get("X-User-ID") orelse {
        try ctx.sendError(401, "invalid token");
        return;
    };

    const new_token = try middleware.generateToken(ctx.allocator, .{
        .sub = user_id,
        .exp = compat.timestamp() + 3600 * 24 * 7,  // 新 Token 7 天过期
        .iat = compat.timestamp(),
    }, "your-secret-key");
    defer ctx.allocator.free(new_token);

    try ctx.jsonStruct(200, .{ .token = new_token });
}
```

## 多种认证方式

### API Key 认证

```zig
try server.addMiddleware(.{
    .func = struct {
        fn exec(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) !void {
            const api_key = ctx.headers.get("X-API-Key") orelse {
                try ctx.sendError(401, "missing API key");
                return;
            };

            const valid = try db.validateApiKey(api_key);
            if (!valid) {
                try ctx.sendError(403, "invalid API key");
                return;
            }

            try next(ctx);
        }
    }.exec,
});
```

### Basic Auth

Base64 解码用框架自带的 `codec.Base64`：

```zig
const codec = zigzero.codec;

try server.addMiddleware(.{
    .func = struct {
        fn exec(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) !void {
            const auth = ctx.headers.get("Authorization") orelse {
                try ctx.sendError(401, "missing auth header");
                return;
            };

            if (!std.mem.startsWith(u8, auth, "Basic ")) {
                try ctx.sendError(401, "invalid auth scheme");
                return;
            }

            const encoded = auth[6..];
            const decoded = try codec.Base64.decode(ctx.allocator, encoded);
            defer ctx.allocator.free(decoded);

            const colon = std.mem.indexOfScalar(u8, decoded, ':') orelse {
                try ctx.sendError(401, "invalid credentials format");
                return;
            };
            const username = decoded[0..colon];
            const password = decoded[colon + 1..];

            const valid = try db.verifyCredentials(username, password);
            if (!valid) {
                try ctx.sendError(401, "invalid credentials");
                return;
            }

            try next(ctx);
        }
    }.exec,
});
```

## OAuth2 集成

```zig
// 1. 登录跳转
fn handleLoginRedirect(ctx: *api.Context) !void {
    const state = try generateRandomState(ctx.allocator);
    defer ctx.allocator.free(state);

    const redirect_url = try std.fmt.allocPrint(
        ctx.allocator,
        "https://oauth.provider.com/authorize?client_id=xxx&redirect_uri=...&state={s}",
        .{state},
    );
    defer ctx.allocator.free(redirect_url);

    try ctx.setHeader("Location", redirect_url);
    ctx.status_code = 302;
    ctx.responded = true;
}

// 2. OAuth 回调处理
fn handleOAuthCallback(ctx: *api.Context) !void {
    const code = ctx.queryParam("code") orelse {
        try ctx.sendError(400, "missing code");
        return;
    };
    // 校验 state 防止 CSRF（此处省略实现）

    // 用 code 换 Access Token
    const token_resp = try oauthExchangeCode(code);
    const user_info = try oauthGetUserInfo(token_resp.access_token);

    // 签发应用自己的 JWT（claims 只有 sub/user_id/username/exp/iat）
    const app_token = try middleware.generateToken(ctx.allocator, .{
        .sub = user_info.id,
        .username = user_info.name,
        .exp = compat.timestamp() + 3600 * 24,
    }, "app-secret");

    try ctx.jsonStruct(200, .{ .token = app_token });
}
```

## Token 黑名单

撤销被盗用的 Token（登出时加入黑名单）：

```zig
// 进程级黑名单；启动时用真实 allocator 初始化
var token_blacklist: std.StringHashMap(i64) = undefined;

pub fn main() !void {
    token_blacklist = std.StringHashMap(i64).init(allocator);
    defer token_blacklist.deinit();
}

try server.addMiddleware(.{
    .func = struct {
        fn exec(ctx: *api.Context, next: api.HandlerFn, data: ?*anyopaque) !void {
            const bl = @as(*std.StringHashMap(i64), @ptrCast(@alignCast(data.?)));

            const auth = ctx.headers.get("Authorization") orelse {
                try ctx.sendError(401, "missing authorization header");
                return;
            };
            if (!std.mem.startsWith(u8, auth, "Bearer ")) {
                try ctx.sendError(401, "invalid authorization format");
                return;
            }
            const token = auth[7..];

            if (bl.contains(token)) {
                try ctx.sendError(401, "token revoked");
                return;
            }

            try next(ctx);
        }
    }.exec,
    .user_data = &token_blacklist,
});

// 登出时加入黑名单（key 必须是可长期存活的字符串副本）
fn handleLogout(ctx: *api.Context) !void {
    const auth = ctx.headers.get("Authorization") orelse return;
    const token = auth[7..];
    const key = try ctx.allocator.dupe(u8, token);
    try token_blacklist.put(key, getTokenExpiry(token));
    try ctx.jsonStruct(200, .{ .ok = true });
}
```

## 最佳实践

| 实践 | 说明 |
|------|------|
| 使用 HTTPS | 始终通过 TLS 传输 Token |
| 短期 Token | `exp` 建议 15min - 1h |
| Refresh Token | 长期凭证存 Redis，仅换发 Access Token |
| 密钥轮换 | 定期更换 JWT 签名密钥（更换后旧 Token 立即失效） |
| 记录审计 | 记录所有认证事件 |

## 下一步

- [Rate Limiting](rate-limiting.md) — 防止暴力破解
- [Middleware](middleware.md) — 组合认证中间件
- [First Service Tutorial](../getting-started/first-service.md) — 完整认证示例
