# Multi Page Website

Serve a small website with multiple routes and shared assets. See
`examples/staticSite.zig` (filesystem) and `examples/website/` (embedded
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

## Expected Output

When run via the static-site target, the output follows that program's print format:

```text
==> HTTPX Static Site Server Demo

Static site server listening on http://127.0.0.1:54321
GET / -> Status: 200, Length: 1024
Mounted Site Title: 'Example Site'
Static site verification successful.
```

The port number, content length, and page title vary with the served directory contents.

## Run

```bash
zig build run-static-site
zig build run-website
```

## What to Verify

- `/` and `/about` return 200 with HTML bodies.
- Static assets resolve with correct content types.
