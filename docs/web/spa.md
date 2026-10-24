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

    var server = try httpx.server.Server.init(allocator, io, .{ .port = 8080 });
    defer server.deinit();

    // API routes take precedence (register code routes before the SPA mount)
    try server.get("/api/status", statusHandler);

    // SPA fallback: serves existing files from ./dist, or falls back to index.html
    try server.spa("/", "./dist");

    server.run();
}

fn statusHandler(ctx: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    _ = ctx;
    return .{ .status = 200, .body = "{\"status\":\"ok\"}", .contentType = "application/json" };
}
```

## Resolution Flow & Fallback Policy

HTTPX uses an explicit, controlled SPA fallback policy rather than returning `index.html` indiscriminately:

1. **API & Explicit Code Routes**: Checked first. Known routes and handlers registered before `server.spa()` execute with their normal responses.
2. **Physical Asset Resolution**: If the request path maps to a real file in the document root (or embedded asset registry), it is served with appropriate MIME types, `ETag`, and conditional request caching.
3. **Controlled Fallback Determination (`shouldSpaFallback`)**:
   - **HTTP Method**: Fallback is restricted to `GET` and `HEAD` requests. Other methods (POST, PUT, DELETE) return `404 Not Found`.
   - **Excluded Prefixes**: Paths starting with configured `excludePrefixes` (e.g. `/api`, `/auth`) never fall back and return `404 Not Found`.
   - **Asset Requests**: Missing files with asset extensions (e.g. `.js`, `.mjs`, `.css`, `.png`, `.jpg`, `.svg`, `.ico`, `.woff2`, `.map`, `.json`, `.wasm`) return `404 Not Found` rather than `index.html`, preventing browser syntax errors (`Unexpected token '<'`).
   - **Content Negotiation**: If the client provides an `Accept` header that explicitly does not permit `text/html` (e.g. `Accept: application/json` or `Accept: image/*`), fallback is declined.
4. **Application Navigation**: Deep links and client routes (e.g. `/dashboard`, `/users/42/profile`, `/settings`) that pass these checks receive the SPA fallback (`index.html`) with status 200.

## Configuration Options

```zig
try httpx.web.spa.register(&server.router, .{
    .root = "./dist",
    .fallback = "index.html",
    .mount = "/",
    .excludePrefixes = &.{ "/api", "/auth" },
    .cacheControl = "public, max-age=3600",
    .liveReload = true,
});
```

## Related

* [Web: Static Files](/web/static-files)
* [Example: SPA Fallback](/examples/spa-fallback)
