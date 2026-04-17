# Static Files

Serve files with automatic MIME type resolution.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

const custom_mime_mappings = [_]httpx.MimeMapping{
    .{ .ext = ".geojson", .mime = "application/geo+json" },
    .{ .ext = ".glb", .mime = "model/gltf-binary" },
};

fn home(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.fileWithOptions("examples/multi_page_site/index.html", .{
        .cache_control = "no-cache",
        .add_etag = true,
        .conditional_get = true,
    });
}

fn asset(ctx: *httpx.Context) anyerror!httpx.Response {
    const path = "examples/multi_page_site/site/assets/app.js";
    const fallback = httpx.mimeTypeFromPath(path);
    const content_type = httpx.mimeTypeFromPathWith(path, &custom_mime_mappings, fallback);
    return ctx.fileWithOptions(path, .{
        .content_type = content_type,
        .cache_control = "public, max-age=300",
        .add_etag = true,
        .conditional_get = true,
    });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = httpx.Server.init(allocator);
    defer server.deinit();

    try server.get("/", home);
    try server.get("/app.js", asset);
    try server.listen();
}
```

## Run

```bash
zig build run-static_files
```

## What to Verify

- HTML file is served from disk.
- `Content-Type` matches file extension for `ctx.file(...)`.
- `ctx.fileWithOptions(...)` allows explicit MIME override and cache policy tuning.
- `ETag` is emitted and `If-None-Match` can return `304 Not Modified`.
- `mimeTypeFromPathWith(...)` supports user-defined external MIME mappings.
