# Compression

Content encoding negotiation and codecs (`httpx.compression`): gzip,
deflate, brotli, and zstd. See `examples/compression_demo.zig`.

```zig
// Advertise encodings; the client decodes transparently.
var response = try client.get("http://httpbun.com/get", .{
    .headers = .{ .acceptEncoding = "gzip, deflate, br" },
});
defer response.deinit();

// Codec-level API.
const blob = try httpx.compression.compress(allocator, .gzip, data);
defer allocator.free(blob);
const plain = try httpx.compression.decompress(allocator, .gzip, blob);
defer allocator.free(plain);
const limited = try httpx.compression.decompressLimited(allocator, .gzip, blob, 1 << 20);
defer allocator.free(limited);
```

Negotiate with `httpx.compression.negotiate(headerValue)` and parse offers
with `httpx.compression.parseAcceptEncoding(allocator, headerValue)`.
Decompression is always size-bounded (`MAX_DECOMPRESSED_SIZE`).

## Run

```bash
zig build run-compression-demo
```

## Checklist

- [x] Client sends `Accept-Encoding` and reads decoded bodies
- [x] Round-trip compress/decompress matches input
- [x] `decompressLimited` enforces the cap
