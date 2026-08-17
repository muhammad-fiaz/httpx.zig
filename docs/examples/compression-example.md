# Compression

Demonstrates `Content-Encoding` parsing, the `httpx.decompress()` API, compression middleware, and how clients advertise supported algorithms via `Accept-Encoding`.

## Demo Program

```zig
// Iterate all supported Content-Encoding values
for (httpx.ContentEncoding.ALL) |enc| {
    std.debug.print("{s} -> .{s}\n", .{ enc.toString(), @tagName(enc) });
}

// Identity passthrough — input equals output
const decompressed = try httpx.decompress(allocator, .identity, original);

// Enable compression middleware on the server
try server.use(httpx.middleware.compression());

// Client advertises supported encodings
var req = try httpx.Request.init(allocator, .GET, "http://127.0.0.1/data");
try req.headers.set("Accept-Encoding", "gzip, deflate, zstd");
```

## Run

```
zig build run-all-compression_example
```

## Checklist

- [x] `ContentEncoding.ALL` lists gzip, deflate, zstd, brotli
- [x] `httpx.decompress(.identity, ...)` returns input unchanged
- [x] Server accepts and applies compression middleware
- [x] Client sends `Accept-Encoding` header with supported algorithms
- [x] Supported algorithms print: gzip, deflate, zstd, br
