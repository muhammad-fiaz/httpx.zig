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

When making client requests, HTTPX automatically adds the `Accept-Encoding: zstd, br, gzip, deflate` header unless explicitly overridden.

When the server returns `Content-Encoding: zstd`, `br`, `gzip`, or `deflate`, HTTPX decodes the body transparently before returning it to the caller:

```zig
var response = try client.get("https://httpbun.com/gzip", .{});
defer response.deinit();

// response.body is already decompressed plaintext bytes
std.debug.print("Body: {s}\n", .{response.body});
```

---

## Server Response Compression

The high-level server compresses responses automatically for HTTP/1.1, HTTP/2, and HTTP/3. It parses the request's `Accept-Encoding`, selects `zstd`, `br`, `gzip`, or `deflate`, and sends `Content-Encoding` plus `Vary: Accept-Encoding` only when the coded body is smaller. Handlers do not need to negotiate or encode anything:

```zig
fn largeDataHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    return ctx.renderJson(.{ .items = &.{ "alpha", "beta", "gamma" } });
}

try server.get("/large-data", largeDataHandler);
```

Compression applies to bodies up to `.maxCompressionInput` in the options passed to `httpx.Server.init` (128 KiB by default); larger bodies are sent unchanged to bound per-request memory. Tune codec levels with `.compression` and raise the input limit when large assets should be compressed at the cost of an extra copy. If the client forbids identity and offers no supported coding, the server returns `406 Not Acceptable`.

## Related

* [API: Compression](/api/compression)
* [Example: Compression Demo](/examples/compression-example)
