# Session Management Guide

`httpx.zig` includes a thread-safe, in-memory session store with TTL-based expiry and no external dependencies.

## Overview

Sessions are identified by a randomly generated 32-byte ID (encoded as a 64-character hex string). Each session holds arbitrary string key/value pairs. Sessions expire after a configurable TTL based on the time of last access.

## Initializing the Store

```zig
const httpx = @import("httpx");

var store = httpx.SessionStore.init(allocator, .{
    .ttl_ms = 30 * 60 * 1000, // 30 minutes
    .cookie_name = "session_id",
    .max_sessions = 0,         // 0 = unlimited
});
defer store.deinit();
```

`SessionConfig` fields:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `ttl_ms` | `u64` | `1_800_000` (30 min) | Session lifetime in milliseconds since last access |
| `cookie_name` | `[]const u8` | `"session_id"` | Cookie name to use when integrating with HTTP |
| `max_sessions` | `usize` | `0` | Max sessions held (0 = unlimited) |

`SESSION_ID_LEN` is 32 (bytes); the hex-encoded ID is 64 characters.

## Creating Sessions

```zig
const sid = try store.create();
// sid is [64]u8 — a hex-encoded session ID
```

Pass this value as a cookie to the client.

## Setting and Getting Values

```zig
try store.set(&sid, "user_id", "42");
try store.set(&sid, "role", "admin");

if (store.get(&sid, "user_id")) |uid| {
    std.debug.print("user: {s}\n", .{uid});
}
```

`get` returns null if the session does not exist or has expired. Both `set` and `get` update the session's last-accessed timestamp, resetting the TTL window.

## Deleting Sessions

```zig
store.delete(&sid);
```

## Checking Existence

```zig
if (store.exists(&sid)) {
    // session is live
}
```

## Counting Active Sessions

```zig
const n = store.count(); // includes expired sessions not yet evicted
```

## Evicting Expired Sessions

Call `evictExpired()` periodically to free memory from expired sessions:

```zig
const removed = store.evictExpired();
std.debug.print("evicted {d} expired sessions\n", .{removed});
```

A common pattern is to run eviction on a background timer or before each login to keep memory bounded.

## TTL Expiry Behavior

TTL is measured from the last access time (`get` or `set`). A session is expired when:

```
now_ms - last_accessed_ms > ttl_ms
```

Expired sessions are not automatically removed — they stay in memory until `evictExpired()` is called or until the next `set`/`get` touches them (at which point `set` returns `error.SessionExpired`).

## Thread Safety

All `SessionStore` operations acquire an internal mutex before accessing the session map. Multiple goroutines (threads) can call `create`, `set`, `get`, `delete`, `exists`, and `evictExpired` concurrently.

## Cookie Integration Pattern

```zig
fn loginHandler(ctx: *httpx.Context, store: *httpx.SessionStore) anyerror!httpx.Response {
    // authenticate user...
    const sid = try store.create();
    try store.set(&sid, "user_id", "42");

    try ctx.setCookie(store.config.cookie_name, &sid, .{
        .path = "/",
        .http_only = true,
        .secure = true,
        .same_site = .lax,
    });
    return ctx.json(.{ .ok = true });
}

fn profileHandler(ctx: *httpx.Context, store: *httpx.SessionStore) anyerror!httpx.Response {
    const sid = ctx.cookie(store.config.cookie_name) orelse
        return ctx.status(401).text("Not authenticated");

    const user_id = store.get(sid, "user_id") orelse
        return ctx.status(401).text("Session expired");

    return ctx.json(.{ .user_id = user_id });
}
```

## Full Working Example

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var store = httpx.SessionStore.init(allocator, .{
        .ttl_ms = 5 * 60 * 1000, // 5 minutes
    });
    defer store.deinit();

    // Create a session and store some data
    const sid = try store.create();
    try store.set(&sid, "username", "alice");
    try store.set(&sid, "role", "admin");

    // Read it back
    if (store.get(&sid, "username")) |name| {
        std.debug.print("username: {s}\n", .{name});
    }

    // Count and evict
    std.debug.print("active sessions: {d}\n", .{store.count()});
    const evicted = store.evictExpired();
    std.debug.print("evicted: {d}\n", .{evicted});

    // Logout
    store.delete(&sid);
    std.debug.print("session exists: {}\n", .{store.exists(&sid)});
}
```
