# Static Files Guide

HTTPX provides high-performance static file serving with automatic MIME detection, directory index resolution, HTTP range requests, ETag caching, and path traversal security.

## Mounting Static Directories

```zig
var server = try httpx.Server.init(allocator, io, .{ .port = 8080 });
defer server.deinit();

// Mount public assets directory to /static URL prefix
try server.static("/static", "./public");

// SPA fallback: serves index.html for unknown HTML paths
try server.spa("/", "./public");

server.run();
```

## Features

1. **Automatic MIME Types**: Resolves `.html`, `.css`, `.js`, `.png`, `.svg`, `.json`, `.wasm`, and 100+ other extensions.
2. **Range Requests (206 Partial Content)**: Supports `Range: bytes=0-1023` for media streaming and resumable downloads.
3. **ETag & 304 Validation**: Automatically calculates ETags based on file modification timestamp and size.
4. **Directory Traversal Protection**: Rejects paths containing `../` or encoded traversal sequences (`%2e%2e/`).

## Embedded vs Filesystem Mode

By default assets serve from disk, which pairs with the watcher for live
iteration. To ship one self-contained `.exe`, register the same files with
`@embedFile` + `httpx.assets.registerEmbedded`: `server.static`,
`server.spa`, and `ctx.render` then resolve from memory with identical
handler code. See [Single-File Deployment](/guide/single-file).

## Related

* [Single-File Deployment](/guide/single-file)
* [Web: Static Files](/web/static-files)
* [Web: SPA](/web/spa)
* [Example: Static Files](/examples/static-files)
