# Static Files

Serve a directory with automatic MIME type resolution (`httpx.mime.fromPath`),
ETag / `If-None-Match` conditional requests, range requests, and index
resolution. See `examples/static_files.zig`.

## Demo Program

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{
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

    var response = try httpx.get("http://127.0.0.1:PORT/static/index.html", .{});
    defer response.deinit();
}
```

Mount options (all fields use camelCase): `root`, `mount`, `indexFile`,
`maxFileSize`, `cacheControl`, `liveReload`, `reloadSsePath`,
`spaFallback`, `filesystem` (set `false` for embedded-only deployments).

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
