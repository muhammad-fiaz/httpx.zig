# Utilities API

Common utilities for buffer management and encoding.

## Shared Helpers

`httpx.common` provides reusable helpers used across client/server/core modules.

- `queryValue(query, key)`: Get a query parameter value from a raw query string.
- `parseSetCookiePair(set_cookie)`: Parse the first `name=value` pair from a `Set-Cookie` header value.

Root-level aliases are also available:

- `httpx.queryValue(...)`
- `httpx.parseSetCookiePair(...)`

Compatibility note:

- `httpx.utils` remains available as an alias to `httpx.common`.

## Buffers

### `Buffer`

A dynamic, growable byte buffer.

```zig
const buf = try Buffer.init(allocator, 1024);
defer buf.deinit();

try buf.append("Hello");
```

- `append(bytes: []const u8) !void`
- `toOwnedSlice() ![]u8`
- `clear()`

### `RingBuffer`

Circular buffer optimized for streaming data.

```zig
var ring = try RingBuffer.init(allocator, 4096);
```

- `writeBytes(bytes: []const u8) !usize`
- `readBytes(buffer: []u8) usize`
- `getAvailable() usize`
- `getFreeSpace() usize`

### `FixedBuffer`

Stack-allocated fixed-size buffer.

```zig
var buf = FixedBuffer(64){};
```

## Encoding

### `Base64`

Base64 encoding (RFC 4648) with support for standard and URL-safe alphabets.

- `encode(allocator: Allocator, data: []const u8) ![]u8`
- `decode(allocator: Allocator, data: []const u8) ![]u8`
- `encodeUrl(allocator: Allocator, data: []const u8) ![]u8`

### `Hex`

Hexadecimal encoding/decoding.

- `encode(allocator: Allocator, data: []const u8) ![]u8`
- `decode(allocator: Allocator, data: []const u8) ![]u8`

### `PercentEncoding`

URL encoding/decoding (RFC 3986).

- `encode(allocator: Allocator, input: []const u8) ![]u8`
- `decode(allocator: Allocator, input: []const u8) ![]u8`

## JSON

### `JsonBuilder`

Fluent builder for constructing JSON strings efficiently.

```zig
var jb = JsonBuilder.init(allocator);
defer jb.deinit();

try jb.beginObject();
try jb.key("name");
try jb.string("John");
try jb.endObject();
```

- `beginObject() !void`
- `endObject() !void`
- `beginArray() !void`
- `endArray() !void`
- `key(name: []const u8) !void`
- `string(val: []const u8) !void`
- `number(val: anytype) !void`
- `boolean(val: bool) !void`
- `nullValue() !void`

