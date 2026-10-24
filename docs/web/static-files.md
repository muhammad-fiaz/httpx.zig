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

    var server = try httpx.server.Server.init(allocator, io, .{ .port = 8080 });
    defer server.deinit();

    // Serve files from ./public at /static URL prefix
    try server.static("/static", "./public");

    server.run();
}
```

## Out-of-the-Box Watcher & Live Reload
 
HTTPX servers feature built-in directory watching, event debouncing, and Server-Sent Events (SSE) live-reload script injection:
 
```zig
var server = try httpx.server.Server.init(allocator, io, .{
    .port = 8080,
    .watch = true,
    .watchDir = "./public",
    .liveReload = true,
});
defer server.deinit();

try server.static("/", "./public");
server.run();
```

When files within `watchDir` are created, modified, deleted, or renamed:
1. Native filesystem notifications normalize across Windows (`ReadDirectoryChangesW`), Linux (`inotify`), and macOS (kqueue), with recursive watching and rename pairing.
2. Rapid editor saves (including atomic save+rename) are debounced and coalesced into one logical change.
3. CSS changes trigger instant in-place style refreshes (`hot_reload`).
4. HTML/template modifications run Tree-sitter incremental analysis, invalidate exactly the affected cache entries via the dependency graph, and trigger page reloads (`warm_reload`).

## Key Capabilities

1. **Zero Memory Copying & Streaming**: Delivers files efficiently using system I/O buffers.
2. **RFC 9110 HEAD Compliance**: Returns accurate `Content-Length`, `ETag`, and `Last-Modified` metadata without buffering unnecessary body payloads.
3. **Range Support (206)**: Handles `Range: bytes=start-end` for audio/video seeking and resumable downloads; returns `416 Range Not Satisfiable` for invalid bounds.
4. **Conditional Requests (304)**: Supports `If-None-Match` (strong/weak ETags) and `If-Modified-Since` (IMF-fixdate parsing) for client cache revalidation.
5. **Path Traversal Protection**: Rejects encoded traversal sequences (`../`, `%2e%2e/`, Windows drive letters, null bytes) ensuring requests cannot escape the configured document root.
6. **Controlled SPA Integration**: Seamlessly delegates unmatched application routes to SPA entry points while guarding API routes and asset 404s.

## Related

* [Guide: Static Files](/guide/static-files)
* [Security: Path Security](/security/path-security)
* [Example: Static Files](/examples/static-files)
