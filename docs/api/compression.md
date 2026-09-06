# Compression API

Content-Encoding negotiation, compression, and decompression for gzip, deflate, Brotli, and Zstd.

Located in `src/compress/`.

## ContentEncoding

Enum representing supported Content-Encoding values.

| Variant | Description |
|---------|-------------|
| `.gzip` | gzip (RFC 1952) |
| `.deflate` | DEFLATE (RFC 1951) |
| `.br` | Brotli (RFC 7932) |
| `.zstd` | Zstandard |
| `.identity` | No encoding (pass-through) |

## ContentEncoding Constants and Methods

| Member | Description |
|--------|-------------|
| `ContentEncoding.ALL` | Array of all supported encodings: `[_]ContentEncoding{ .gzip, .deflate, .br, .zstd, .identity }` |
| `toString()` | Convert to wire-format string (e.g., `.gzip` → `"gzip"`) |
| `fromString(str)` | Parse from a string; returns `?ContentEncoding` (case-insensitive) |
| `buildAcceptEncoding(encodings)` | Build an `Accept-Encoding` header value from a slice of encodings |

## httpx.decompress()

```zig
pub fn decompress(allocator: Allocator, encoding: ContentEncoding, data: []const u8) ![]u8
```

Decompresses body content based on the provided `Content-Encoding`. The caller owns the returned slice.

## httpx.compress()

```zig
pub fn compress(allocator: Allocator, encoding: ContentEncoding, data: []const u8) ![]u8
```

Compresses data using the specified encoding. The caller owns the returned slice.

## StreamingCompressor

Streaming compression for chunked data without buffering entire payloads.

- `init(allocator, encoding)` — create a streaming compressor
- `feed(data)` — feed input data
- `finish()` — finalize compression
- `deinit()` — release resources

## StreamingDecompressor

Streaming decompression for chunked data without buffering entire payloads.

- `init(allocator, encoding)` — create a streaming decompressor
- `feed(data)` — feed compressed data
- `finish()` — finalize decompression
- `deinit()` — release resources

Root-level aliases: `httpx.ContentEncoding`, `httpx.decompress`, `httpx.compress`, `httpx.StreamingCompressor`, `httpx.StreamingDecompressor`.
