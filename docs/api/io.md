# IO Utilities API

Centralized in `src/io/`.

## AnyIO

- `defaultIo()` — returns the appropriate `std.Io` for test or runtime context
- `sleepMs(ms: u64)` — sleep using the canonical IO
- `sleepMsI(ms: i64)` — sleep using the canonical IO (signed)
- `AnyReader` — type-erased reader with `read`, `readByte`, `readNoEof`
- `AnyWriter` — type-erased writer with `write`, `writeAll`, `print`

## Buffer

Dynamic, growable byte buffer.

- `init(allocator, capacity)` — create buffer
- `append(bytes)` — append bytes
- `toOwnedSlice()` — return owned slice
- `clear()` — reset without deallocating
- `deinit()` — release memory

## FixedBuffer

Stack-allocated fixed-size buffer with no heap allocation.

```zig
var buf = FixedBuffer(64){};
```

## BufferPool

Pre-allocated buffer pool with slot-based ownership tracking, acquire/release semantics, and detection of foreign/double-release buffers.

- `init(allocator, config)` — create a pool
- `acquire()` — get a buffer from the pool
- `release(buffer)` — return a buffer to the pool
- `stats()` — get pool statistics (total, available, acquired, leaks, errors)
- `deinit()` — release all resources

Root-level alias: `httpx.BufferPool`.

## Base64

RFC 4648 base64 with standard and URL-safe alphabets.

- `encode(allocator, data)` — encode to base64
- `decode(allocator, data)` — decode from base64
- `encodeUrl(allocator, data)` — URL-safe encoding

## Hex

- `encode(allocator, data)` — hex encode
- `decode(allocator, data)` — hex decode

## PercentEncoding

RFC 3986 URL encoding.

- `encode(allocator, input)` — percent-encode
- `decode(allocator, input)` — percent-decode
