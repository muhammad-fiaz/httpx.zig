//! Environment utilities for client-side and application configuration.
//!
//! Provides convenient lookup of string, integer, and boolean values from
//! process environment variables (terminal) and .env files, allowing applications
//! to selectively configure httpx.Client or httpx.Server with standard `.{}` options.

const std = @import("std");
const Allocator = std.mem.Allocator;
const envMod = @import("env");

/// Installed env.Env structure for in-memory .env parsing and storage.
pub const Env = envMod.Env;

/// Direct access to process runtime environment methods.
pub const runtime = envMod.runtime;

/// Fetches a raw string value from the process/terminal environment.
pub fn get(key: []const u8) ?[]const u8 {
    return envMod.runtime.get(key);
}

/// Checks if an environment variable is present in the process/terminal environment.
pub fn has(key: []const u8) bool {
    return envMod.runtime.has(key);
}

/// Fetches an environment variable from process/terminal and parses it as integer `T`.
/// Returns `null` if the variable is not set or cannot be parsed.
pub fn getInt(comptime T: type, key: []const u8) ?T {
    const val = get(key) orelse return null;
    const trimmed = std.mem.trim(u8, val, " \t\r\n");
    return std.fmt.parseInt(T, trimmed, 10) catch null;
}

/// Fetches an environment variable from process/terminal and parses it as boolean.
/// Supports true/1/yes/on and false/0/no/off (case-insensitive).
pub fn getBool(key: []const u8) ?bool {
    const val = get(key) orelse return null;
    return parseBool(val);
}

/// Parses a boolean string value (true/1/yes/on vs false/0/no/off).
pub fn parseBool(val: []const u8) ?bool {
    const trimmed = std.mem.trim(u8, val, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "true") or
        std.mem.eql(u8, trimmed, "1") or
        std.ascii.eqlIgnoreCase(trimmed, "yes") or
        std.ascii.eqlIgnoreCase(trimmed, "on"))
    {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "false") or
        std.mem.eql(u8, trimmed, "0") or
        std.ascii.eqlIgnoreCase(trimmed, "no") or
        std.ascii.eqlIgnoreCase(trimmed, "off"))
    {
        return false;
    }
    return null;
}

/// Explicitly loads and parses a `.env` file from the given path into a new `Env` store.
/// Caller must deinit the returned `Env`.
pub fn loadFile(allocator: Allocator, path: []const u8) !Env {
    var e = Env.init(allocator, .{});
    errdefer e.deinit();
    try e.load(path);
    return e;
}

/// Parses `.env` formatted content from a string buffer into a new `Env` store.
/// Caller must deinit the returned `Env`.
pub fn parse(allocator: Allocator, content: []const u8) !Env {
    var e = Env.init(allocator, .{});
    errdefer e.deinit();
    try e.parseString(content);
    return e;
}

// Tests

test "env parseBool helper" {
    const testing = std.testing;
    try testing.expectEqual(@as(?bool, true), parseBool("true"));
    try testing.expectEqual(@as(?bool, true), parseBool("TRUE"));
    try testing.expectEqual(@as(?bool, true), parseBool("1"));
    try testing.expectEqual(@as(?bool, true), parseBool("yes"));
    try testing.expectEqual(@as(?bool, true), parseBool("on"));

    try testing.expectEqual(@as(?bool, false), parseBool("false"));
    try testing.expectEqual(@as(?bool, false), parseBool("FALSE"));
    try testing.expectEqual(@as(?bool, false), parseBool("0"));
    try testing.expectEqual(@as(?bool, false), parseBool("no"));
    try testing.expectEqual(@as(?bool, false), parseBool("off"));

    try testing.expectEqual(@as(?bool, null), parseBool("unknown"));
}

test "env parse in-memory store and typed lookups" {
    const testing = std.testing;
    const a = testing.allocator;

    var e = try parse(a,
        \\PORT=3000
        \\HOST=127.0.0.1
        \\ENABLE_TLS=true
        \\TIMEOUT_MS=5000
        \\API_KEY=my_secret_token
    );
    defer e.deinit();

    try testing.expectEqualStrings("3000", e.get("PORT").?);
    try testing.expectEqualStrings("127.0.0.1", e.get("HOST").?);
    try testing.expectEqualStrings("my_secret_token", e.get("API_KEY").?);

    // Using parseBool and std.fmt.parseInt on store values
    const port = if (e.get("PORT")) |p| try std.fmt.parseInt(u16, p, 10) else 8080;
    try testing.expectEqual(@as(u16, 3000), port);

    const enableTls = if (e.get("ENABLE_TLS")) |t| parseBool(t) orelse false else false;
    try testing.expect(enableTls);
}

test "env values explicitly applied to client and server options without hardcoded config layer" {
    const testing = std.testing;
    const a = testing.allocator;

    var e = try parse(a,
        \\APP_PROXY=http://127.0.0.1:8888
        \\APP_TIMEOUT=12000
        \\APP_HOST=127.0.0.1
        \\APP_PORT=9090
        \\APP_WORKERS=4
    );
    defer e.deinit();

    // Client options explicitly populated from env:
    const clientProxy = e.get("APP_PROXY");
    const clientTimeout = if (e.get("APP_TIMEOUT")) |t| try std.fmt.parseInt(u64, t, 10) else null;
    try testing.expectEqualStrings("http://127.0.0.1:8888", clientProxy.?);
    try testing.expectEqual(@as(?u64, 12000), clientTimeout);

    // Server options explicitly populated from env:
    const serverHost = e.get("APP_HOST") orelse "0.0.0.0";
    const serverPort = if (e.get("APP_PORT")) |p| try std.fmt.parseInt(u16, p, 10) else 8080;
    const serverWorkers = if (e.get("APP_WORKERS")) |w| try std.fmt.parseInt(u16, w, 10) else 0;
    try testing.expectEqualStrings("127.0.0.1", serverHost);
    try testing.expectEqual(@as(u16, 9090), serverPort);
    try testing.expectEqual(@as(u16, 4), serverWorkers);
}
