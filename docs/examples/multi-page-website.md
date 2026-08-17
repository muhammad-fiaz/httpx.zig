# Multi Page Website

Serve a small website with multiple routes and shared assets, including static file serving and redirects.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

const site_root = "examples/multi_page_site/site";

fn contentTypeForPath(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    return "application/octet-stream";
}

fn serveRelativePath(ctx: *httpx.Context, rel_path: []const u8) anyerror!httpx.Response {
    if (std.mem.indexOf(u8, rel_path, "..") != null or std.mem.indexOfScalar(u8, rel_path, '\\') != null) {
        return ctx.status(400).text("Invalid path");
    }

    var full_path_buf: [1024]u8 = undefined;
    const full_path = std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ site_root, rel_path }) catch {
        return ctx.status(414).text("Path too long");
    };

    var resp = try ctx.fileAs(full_path, contentTypeForPath(rel_path));
    try resp.headers.set("Cache-Control", "no-cache");
    return resp;
}

fn homeHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return serveRelativePath(ctx, "index.html");
}

fn aboutHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return serveRelativePath(ctx, "about.html");
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = 0,
        .keep_alive = false,
        .request_timeout_ms = 10_000,
    });
    defer server.deinit();

    try server.get("/", homeHandler);
    try server.get("/about", aboutHandler);

    const thread = try server.listenInBackground();
    defer thread.join();
    defer server.stop();
}
```

## Run

```bash
zig build run-all-multi_page_website
```

## What to Verify

- Each route serves the matching HTML page from the `site/` subdirectory.
- Static assets (CSS, JS, images) are served correctly via the `/static/*` wildcard route.
- Redirects (e.g., `/go-home` -> `/`) work correctly.
- Path traversal protection blocks `../` in URLs.
