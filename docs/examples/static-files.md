# Static Files

Serve a directory with automatic MIME type resolution (`httpx.mime.fromPath`),
ETag / `If-None-Match` conditional requests, range requests, and index
resolution. See `examples/staticFiles.zig`.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.server.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
        .maxConnections = 1,
    });
    defer server.deinit();

    // Mount a filesystem directory at /static (relative to the process CWD).
    try httpx.static.files.register(&server.router, .{
        .root = "examples/static",
        .mount = "/static",
        .indexFile = "index.html",
    });
    defer httpx.static.files.unregister();

    // ...or the shorthand, equivalent for the common case:
    // try server.static("/static", "examples/static");

    const thread = try server.start();
    defer thread.join();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();
    var response = try client.get("http://127.0.0.1:PORT/static/index.html", .{});
    defer response.deinit();
}
```

Mount options (all fields use camelCase): `root`, `mount`, `indexFile`,
`maxFileSize`, `cacheControl`, `liveReload`, `reloadSsePath`,
`spaFallback`, `filesystem` (set `false` for embedded-only deployments).

## Expected Output

```text
serving examples/static on http://127.0.0.1:41237/static
health endpoint on http://127.0.0.1:41237/healthz
GET /static/index.html -> 200 (4821 bytes)
```

The port is the ephemeral port selected at runtime; the status code and byte count vary with the requested file.

## Run

```bash
zig build run-static-files
```

## What to Verify

- HTML file is served from disk with the `Content-Type` matching its extension.
- `ETag` is emitted and `If-None-Match` can return `304 Not Modified`.
- Directories resolve to `index.html`; `..` traversal is rejected with `403`.
- Single-file deployments register the same paths with
  `httpx.assets.registerEmbedded` and serve them from memory (see
  `zig build run-static-embedded`).
