# Compression Guide

HTTPX incorporates native compression codecs for Gzip, Deflate, Brotli, and Zstandard, providing seamless bandwidth savings for both client requests and server responses.

## Supported Codecs

| Algorithm | Content-Encoding | Quality / Speed Profile |
|---|---|---|
| **Zstandard** | `zstd` | Ultra-fast decompression, outstanding ratio |
| **Brotli** | `br` | Highest compression ratio for web text/assets |
| **Gzip** | `gzip` | Universally supported legacy standard |
| **Deflate** | `deflate` | RFC 1951 raw deflate stream |

---

## Client Automatic Decompression

When making client requests, HTTPX automatically adds the `Accept-Encoding: gzip, br, zstd` header to request options unless explicitly overridden.

When the server returns `Content-Encoding: gzip` (or `br`, `zstd`), HTTPX decodes the body transparently before returning it to the caller:

```zig
const response = try client.get("https://httpbin.org/gzip", .{});
defer response.deinit();

// response.body is already decompressed plaintext bytes
std.debug.print("Body: {s}\n", .{response.body});
```

---

## Server Response Compression

HTTPX server supports on-the-fly response compression based on the client's `Accept-Encoding` preference:

```zig
server.get("/large-data", struct {
    fn handle(ctx: *httpx.Context) !void {
        const accept = ctx.header("Accept-Encoding") orelse "";
        if (std.mem.indexOf(u8, accept, "gzip") != null) {
            ctx.header("Content-Encoding", "gzip");
            // Compress and write
        }
        try ctx.json(large_data_payload);
    }
}.handle);
```

When serving static files via `server.static()`, HTTPX automatically detects pre-compressed `.gz`, `.br`, and `.zst` files and serves them with zero runtime CPU overhead.

## Related

* [API: Compression](/api/compression)
* [Example: Compression Demo](/examples/compression-example)
