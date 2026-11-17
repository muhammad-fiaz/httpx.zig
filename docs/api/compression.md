# Compression API

Content-Encoding negotiation, compression, and decompression for gzip, deflate, Brotli, and Zstd.

Located in `src/compression/` (`httpx.compression`).

## Encoding

Enum representing supported Content-Encoding values.

| Variant | Description |
|---------|-------------|
| `.gzip` | gzip (RFC 1952) |
| `.deflate` | DEFLATE (RFC 1951) |
| `.br` | Brotli (RFC 7932) |
| `.zstd` | Zstandard |
| `.identity` | No encoding (pass-through) |

## Encoding Constants and Methods

| Member | Description |
|--------|-------------|
| `token()` | Convert to wire-format string (e.g., `.gzip` → `"gzip"`) |
| `fromToken(str)` | Parse from a string; returns `?Encoding` (case-insensitive) |
| `parseAcceptEncoding(allocator, headerValue)` | Parse an `Accept-Encoding` header into quality-sorted entries (caller owns) |
| `negotiate(headerValue)` | Pick the best supported encoding for an `Accept-Encoding` header value |

## httpx.compression.decompress()

```zig
pub fn decompress(allocator: Allocator, encoding: Encoding, data: []const u8) ![]u8
```

Decompresses body content based on the provided `Content-Encoding`. The caller owns the returned slice. Use `decompressLimited(allocator, encoding, data, maxSize)` to cap output (default cap `MAX_DECOMPRESSED_SIZE` = 64 MiB).

## httpx.compression.compress()

```zig
pub fn compress(allocator: Allocator, encoding: Encoding, data: []const u8) ![]u8
```

Compresses data using the specified encoding. The caller owns the returned slice.

## Incremental Codec APIs

Httpx's public compression API is buffer-oriented: `compress` and `decompress`
return complete buffers, and the HTTP client and server buffer bodies at their
public APIs. Brotli and Zstandard are implemented by the internal `brotli` and
`zstd` dependencies; those package namespaces are not re-exported. If an
application needs incremental codec objects, add the package directly to its
own `build.zig.zon` and import it there.

Automatic negotiation encodes responses with `Content-Encoding` and adds
`Vary: Accept-Encoding`. `decompressLimited` enforces the output cap before any
decoded body is returned.
