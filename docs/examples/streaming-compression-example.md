# Streaming Compression

Streaming compression over the codec API (`httpx.compression`). See
`examples/compressionDemo.zig` and `examples/streaming.zig`.

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

## Expected Output

The codec round trip itself prints nothing; `examples/compressionDemo.zig`
(which requests with `acceptEncoding = "gzip, deflate, br"`) prints lines in
this format (representative values shown):

```text
Status: 200
Body length: 512
```

On failure it prints `Compression request failed: <ErrorName>`. Statuses, lengths, and error names vary with the target URL and network conditions.

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
