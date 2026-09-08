# Single Page Applications (SPA)

HTTPX provides native Single Page Application (SPA) routing, automatically resolving static assets and falling back to `index.html` for client-side routing.

## SPA Fallback Configuration

Modern client-side frameworks (React, Vue, Svelte, Solid, Angular) rely on the HTML5 History API (`pushState`). When a user refreshes deep URLs like `/dashboard/settings`, the server must serve `index.html` rather than 404 Not Found.

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{ .port = 8080 });
    defer server.deinit();

    // API routes take precedence
    server.get("/api/status", struct {
        fn handle(ctx: *httpx.Context) !void {
            try ctx.json(.{ .status = "ok" });
        }
    }.handle);

    // SPA fallback: serves existing files from ./dist, or falls back to index.html
    try server.spa("/", "./dist");

    server.run();
}
```

## Resolution Flow

1. Match API routes first.
2. Check if the request path maps to a physical file in `./dist` (e.g. `/assets/app.js`, `/favicon.ico`).
3. If not found and request accepts `text/html`, serve `./dist/index.html` with status 200.

## Related

* [Web: Static Files](/web/static-files)
* [Example: SPA Fallback](/examples/spa-fallback)
