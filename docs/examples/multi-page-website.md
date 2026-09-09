# Multi Page Website

Serve a small website with multiple routes and shared assets. See
`examples/static_site.zig` (filesystem) and `examples/website/` (embedded
single-file).

```zig
var server = try httpx.Server.init(allocator, io, .{
    .host = "127.0.0.1",
    .port = 0,
});
defer server.deinit();

try server.get("/", homeHandler);
try server.get("/about", aboutHandler);

// Static assets with ETag + conditional GET.
try server.static("/static", "./public");
```

MIME types resolve through the shared table (`httpx.mime.fromPath`), and
path traversal is rejected by the static layer. For file-based routing with
clean URLs, use `httpx.Site` (see [Single File](/guide/single-file)).

## Run

```bash
zig build run-static-site
zig build run-website
```

## What to Verify

- `/` and `/about` return 200 with HTML bodies.
- Static assets resolve with correct content types.
