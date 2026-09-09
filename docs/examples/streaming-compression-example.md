# Streaming Compression

Streaming compression over the codec API (`httpx.compression`). See
`examples/compression_demo.zig` and `examples/streaming.zig`.

```zig
// One-shot round trip.
const blob = try httpx.compression.compress(allocator, .gzip, input);
defer allocator.free(blob);
const plain = try httpx.compression.decompress(allocator, .gzip, blob);
defer allocator.free(plain);

// Bounded decompression for untrusted input.
const safe = try httpx.compression.decompressLimited(allocator, .gzip, blob, 1 << 20);
defer allocator.free(safe);
```

Servers negotiate `Accept-Encoding` per request (`gzip`, `deflate`,
`brotli`, `zstd`); clients decode transparently.

## Run

```bash
zig build run-compression-demo
```

## Checklist

- [x] Streaming gzip compression
- [x] Streaming gzip decompression
- [x] Streaming deflate
- [x] Identity passthrough
- [x] Decompression limits enforced
