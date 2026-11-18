# Static Files

Serve a directory with automatic MIME type resolution (`httpx.mime.fromPath`),
ETag / `If-None-Match` conditional requests, range requests, and index
resolution. See `examples/staticFiles.zig`.

## Example

```zig
//! Static file server with mount path and index fallback.
//!
//! Run with: `zig build run-static-files`
//!
//! Mounts a directory at `/static`. Files are served with proper Content-Type
//! detection, ETag/If-None-Match support, and a configurable cache header.
//! Directories resolve to `index.html`. Path traversal is rejected.

const std = @import("std");
const httpx = @import("httpx");

fn healthHandler(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return .{ .status = 200, .body = "ok" };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .limits = .{ .maxConns = 1 },
    });
    defer server.deinit();

    try server.router.add(.GET, "/healthz", &healthHandler, .{});
    try httpx.static.files.register(&server.router, .{
        .root = "examples/static",
        .mount = "/static",
        .indexFile = "index.html",
    });

    // Start server on a background thread
    const port = server.localPort();
    std.debug.print("serving examples/static on http://127.0.0.1:{d}/static\n", .{port});
    std.debug.print("health endpoint on http://127.0.0.1:{d}/healthz\n", .{port});

    const thread = try server.start();

    // Give server worker thread a moment to enter accept loop
    var spin: usize = 0;
    while (spin < 1000) : (spin += 1) std.Thread.yield() catch {};

    var urlBuf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/static/index.html", .{port});

    var response = try client.get(url, .{});
    defer response.deinit();

    std.debug.print("GET /static/index.html -> {d} ({d} bytes)\n", .{ response.status, response.body.len });

    thread.join();
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
