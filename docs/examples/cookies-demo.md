# Cookies Demo

Work with the built-in client cookie jar for session-style flows.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = httpx.Client.init(allocator);
    defer client.deinit();

    try client.setCookie("session", "abc123");
    std.debug.print("has session: {}\n", .{client.hasCookie("session")});

    const value = client.getCookie("session") orelse "";
    std.debug.print("session={s}\n", .{value});

    client.removeCookie("session");
    std.debug.print("cookie count={d}\n", .{client.cookieCount()});
}
```

## Run

```bash
zig build run-all-cookies_demo
```

## What to Verify

- Cookie values are set/read/removed as expected.
- Cookie count reflects jar state changes.
