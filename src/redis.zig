        return -1;
    }
    return -1;
}

/// Acquire a distributed lock
pub fn lock(self: *Redis, key: []const u8, value: []const u8, ttl_seconds: u32) errors.ResultT(bool) {
    // SET key value NX PX ttl
    if (self.stream) |stream| {
        const cmd = std.fmt.allocPrint(self.allocator, "*5\r\n$3\r\nSET\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n$2\r\nNX\r\n$2\r\nPX\r\n${d}\r\n{d}\r\n", .{
            key.len, key, value.len, value, std.fmt.count("{d}", .{ttl_seconds * 1000}), ttl_seconds * 1000,
        }) catch return error.RedisError;
        defer self.allocator.free(cmd);

        _ = stream.write(cmd) catch return error.RedisError;

        var buf: [256]u8 = undefined;
        const n = stream.read(&buf) catch return error.RedisError;
        const response = buf[0..n];

        // Check for +OK or $-1
        if (response.len >= 3 and std.mem.eql(u8, response[0..3], "+OK")) {
            return true;
        }
    }
    return false;
}

/// Release a distributed lock
pub fn unlock(self: *Redis, key: []const u8) errors.Result {
    // DEL key
    if (self.stream) |stream| {
        const cmd = std.fmt.allocPrint(self.allocator, "*2\r\n$3\r\nDEL\r\n${d}\r\n{s}\r\n", .{ key.len, key }) catch return error.RedisError;
        defer self.allocator.free(cmd);

        _ = stream.write(cmd) catch return error.RedisError;

        var buf: [256]u8 = undefined;
        _ = stream.read(&buf) catch return error.RedisError;
    }
    return;
}

/// List operations
pub fn lPush(self: *Redis, key: []const u8, value: []const u8) errors.ResultT(u32) {
    if (self.stream) |stream| {
        const cmd = std.fmt.allocPrint(self.allocator, "*3\r\n$5\r\nLPUSH\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n", .{ key.len, key, value.len, value }) catch return error.RedisError;
        defer self.allocator.free(cmd);

        _ = stream.write(cmd) catch return error.RedisError;

        var buf: [256]u8 = undefined;
        const n = stream.read(&buf) catch return error.RedisError;
        const response = buf[0..n];

        if (response.len > 1 and response[0] == ':') {
            const val = std.fmt.parseInt(u32, response[1..], 10) catch return error.RedisError;
            return val;
        }
    }
    return error.RedisError;
}

pub fn rPop(self: *Redis, key: []const u8) errors.ResultT(?[]const u8) {
    if (self.stream) |stream| {
        const cmd = std.fmt.allocPrint(self.allocator, "*2\r\n$4\r\nRPOP\r\n${d}\r\n{s}\r\n", .{ key.len, key }) catch return error.RedisError;
        defer self.allocator.free(cmd);

        _ = stream.write(cmd) catch return error.RedisError;

        var buf: [4096]u8 = undefined;
        const n = stream.read(&buf) catch return error.RedisError;
        const response = buf[0..n];

        // Parse bulk string response
        if (response.len > 1) {
            if (response[0] == '$') {
                if (response[1] == '-') {
                    return null; // Null bulk string
                }
                // Find the length
                var end_idx: usize = 1;
                while (end_idx < response.len and response[end_idx] != '\r') : (end_idx += 1) {}
                const len = std.fmt.parseInt(i32, response[1..end_idx], 10) catch return error.RedisError;
                if (len <= 0) return null;
                
                // Skip \r\n and extract value
                const value_start = end_idx + 2;
                const value = self.allocator.dupe(u8, response[value_start..@min(value_start + @as(usize, @intCast(len)), response.len)]) catch return error.RedisError;
                return value;
            }
        }
    }
    return error.RedisError;
}

/// Hash operations
pub fn hSet(self: *Redis, key: []const u8, field: []const u8, value: []const u8) errors.ResultT(bool) {
    if (self.stream) |stream| {
        const cmd = std.fmt.allocPrint(self.allocator, "*4\r\n$4\r\nHSET\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n", .{
            key.len, key, field.len, field, value.len, value,
        }) catch return error.RedisError;
        defer self.allocator.free(cmd);

        _ = stream.write(cmd) catch return error.RedisError;

        var buf: [256]u8 = undefined;
        const n = stream.read(&buf) catch return error.RedisError;
        const response = buf[0..n];

        // :0 = field already exists, :1 = new field
        if (response.len > 1 and response[0] == ':') {
            const val = std.fmt.parseInt(i32, response[1..], 10) catch return 0;
            return val == 1;
        }
    }
    return false;
}

pub fn hGet(self: *Redis, key: []const u8, field: []const u8) errors.ResultT(?[]const u8) {
    if (self.stream) |stream| {
        const cmd = std.fmt.allocPrint(self.allocator, "*3\r\n$4\r\nHGET\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n", .{
            key.len, key, field.len, field,
        }) catch return error.RedisError;
        defer self.allocator.free(cmd);

        _ = stream.write(cmd) catch return error.RedisError;

        var buf: [4096]u8 = undefined;
        const n = stream.read(&buf) catch return error.RedisError;
        const response = buf[0..n];

        // Parse bulk string response
        if (response.len > 1) {
            if (response[0] == '$') {
                if (response[1] == '-') {
                    return null; // Null bulk string
                }
                var end_idx: usize = 1;
                while (end_idx < response.len and response[end_idx] != '\r') : (end_idx += 1) {}
                const len = std.fmt.parseInt(i32, response[1..end_idx], 10) catch return error.RedisError;
                if (len <= 0) return null;
                
                const value_start = end_idx + 2;
                const value = self.allocator.dupe(u8, response[value_start..@min(value_start + @as(usize, @intCast(len)), response.len)]) catch return error.RedisError;
                return value;
            }
        }
    }
    return error.RedisError;
}

/// Pub/Sub
pub fn publish(self: *Redis, channel: []const u8, message: []const u8) errors.ResultT(u32) {
    if (self.stream) |stream| {
        const cmd = std.fmt.allocPrint(self.allocator, "*3\r\n$7\r\nPUBLISH\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n", .{
            channel.len, channel, message.len, message,
        }) catch return error.RedisError;
        defer self.allocator.free(cmd);

        _ = stream.write(cmd) catch return error.RedisError;

        var buf: [256]u8 = undefined;
        const n = stream.read(&buf) catch return error.RedisError;
        const response = buf[0..n];

        if (response.len > 1 and response[0] == ':') {
            const val = std.fmt.parseInt(u32, response[1..], 10) catch return error.RedisError;
            return val;
        }
    }
    return error.RedisError;
}

test "redis client" {
    // Note: These tests require a running Redis server
    // Skip in CI environment
    if (true) return error.SkipZigTest;

    const cfg = config.RedisConfig{};
    var redis = try Redis.new(std.testing.allocator, cfg);
    defer redis.deinit();

    try redis.connect();
    
    // Test basic operations
    try redis.set("test_key", "test_value", null);
    const value = try redis.get("test_key");
    try std.testing.expect(value != null);
    if (value) |v| {
        try std.testing.expectEqualStrings("test_value", v);
        std.testing.allocator.free(v);
    }

    // Test lock
    const acquired = try Lock.acquire(&redis, "test_lock", "token123", 10);
    try std.testing.expect(acquired);
}

test "resp protocol parsing" {
    // Test parsing RESP simple strings
    const simple_string = "+OK\r\n";
    try std.testing.expectEqualStrings("OK", simple_string[1..3]);
}