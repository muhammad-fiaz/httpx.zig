# Streaming Compression

Demonstrates streaming compression and decompression with gzip, deflate, and identity passthrough.

## Demo Program

```zig
// Streaming compress
var comp = httpx.StreamingCompressor.init(.gzip);
const compressed = try comp.compress(allocator, input);

// Streaming decompress
var decomp = httpx.StreamingDecompressor.init(.gzip);
const decompressed = try decomp.decompress(allocator, compressed);
```

## Run

```
zig build run-all-streaming_compression_example
```

## Checklist

- [x] Streaming gzip compression
- [x] Streaming gzip decompression
- [x] Streaming deflate
- [x] Identity passthrough
- [x] Incremental processing
