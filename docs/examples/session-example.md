# Session Store Example

Demonstrates how to use the built-in in-memory session management system in `httpx.zig` to track user sessions.

## Features Covered

- **Session Creation**: Spawning secure sessions with randomized unique IDs.
- **Session Data Store**: Storing, getting, and updating key-value attributes inside active session payloads.
- **Time-to-Live (TTL)**: Configurable TTL and active eviction of expired sessions.
- **HTTP Server Integration**: Integrating session checking and cookie parsing into server routes.

## Code Example

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var store = httpx.SessionStore.init(allocator, .{
        .ttl_ms = 60_000,
        .cookie_name = "sid",
    });
    defer store.deinit();

    // Create a new session
    const sid = try store.create();
    try store.set(&sid, "user_id", "42");
    try store.set(&sid, "role", "admin");

    // Fetch and check session data
    if (store.get(&sid, "user_id")) |uid| {
        std.debug.print("User: {s}, Role: {s}\n", .{ uid, store.get(&sid, "role").? });
    }
}
```

## Running the Example

Run the pre-configured session example:

```bash
zig build run-all-session_example
```
