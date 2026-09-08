# Static File Serving

HTTPX provides an efficient, memory-safe static file server with built-in MIME resolution, directory index fallback, range requests, and conditional ETag validation.

## Usage

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

    // Serve files from ./public at /static URL prefix
    try server.static("/static", "./public");

    server.run();
}
```

## Out-of-the-Box Watcher & Live Reload
 
HTTPX servers feature built-in directory watching, event debouncing, and Server-Sent Events (SSE) live-reload script injection:
 
```zig
var server = try httpx.Server.init(allocator, io, .{
    .port = 8080,
    .watch = true,
    .watch_dir = "./public",
    .live_reload = true,
});
defer server.deinit();

try server.static("/", "./public");
server.run();
```

When files within `watch_dir` are created, modified, or deleted:
1. Filesystem notifications normalize across Windows (`ReadDirectoryChangesW`) and Linux (`inotify`).
2. Rapid editor saves are debounced and coalesced.
3. CSS changes trigger instant in-place style refreshes (`hot_reload`).
4. HTML/template modifications trigger page reloads (`warm_reload`).

## Key Capabilities

1. **Zero Memory Copying**: Streams files directly using system I/O buffers.
2. **Range Support (206)**: Handles `Range: bytes=start-end` for audio/video seeking and resumable downloads.
3. **Automatic ETag Caching**: Sends `ETag` and responds with `304 Not Modified` when client sends matching `If-None-Match`.
4. **Path Traversal Protection**: Rejects encoded traversal sequences (`../`, `%2e%2e/`) protecting confidential system files.

## Related

* [Guide: Static Files](/guide/static-files)
* [Security: Path Security](/security/path-security)
* [Example: Static Files](/examples/static-files)
