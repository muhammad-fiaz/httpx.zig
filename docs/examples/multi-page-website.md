# Multi Page Website

Serve a small website with multiple routes and shared assets.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

fn index(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.file("examples/multi_page_site/index.html");
}

fn about(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.file("examples/multi_page_site/about.html");
}

fn contact(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.file("examples/multi_page_site/contact.html");
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = httpx.Server.init(allocator);
    defer server.deinit();

    try server.get("/", index);
    try server.get("/about", about);
    try server.get("/contact", contact);
    try server.listen();
}
```

## Run

```bash
zig build run-multi_page_website
```

## What to Verify

- Each route serves the matching HTML page.
- Browser navigation across pages works correctly.
