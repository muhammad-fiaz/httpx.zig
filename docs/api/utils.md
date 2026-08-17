# Utilities API

Common utilities for buffer management, encoding, multipart, metrics, and sessions.

## Shared Helpers

`httpx.common` provides reusable helpers used across client/server/core modules.

- `queryValue(query, key)`: Get a query parameter value from a raw query string.
- `parseSetCookiePair(set_cookie)`: Parse the first `name=value` pair from a `Set-Cookie` header value.
- `parseSetCookie(set_cookie)`: Parse a `Set-Cookie` header extracting name, value, Domain, Path, Secure, and HttpOnly attributes.
- `cookieValue(cookie_header, name)`: Read a cookie value from a request `Cookie` header.
- `buildSetCookieHeader(allocator, name, value, options)`: Build a `Set-Cookie` header value with RFC 6265 style attributes.
- `mimeTypeFromPath(path)`: Resolve a best-effort MIME type from file extension.
- `mimeTypeFromPathOr(path, fallback)`: Resolve MIME from extension with an explicit fallback.
- `mimeTypeFromPathWith(path, mappings, fallback)`: Resolve MIME using caller-provided external mappings.
- `MimeMapping`: Extension-to-MIME pair type for external mapping lists.
- `defaultMimeMappings`: Built-in mapping table exported for extension/composition.
- `CookieOptions`: Cookie attributes (`Path`, `Domain`, `Max-Age`, `SameSite`, `Secure`, `HttpOnly`).
- `SameSite`: Enum values `lax`, `strict`, `none`.

Root-level aliases:

- `httpx.queryValue(...)`
- `httpx.parseSetCookiePair(...)`
- `httpx.mimeTypeFromPath(...)`
- `httpx.mimeTypeFromPathOr(...)`
- `httpx.mimeTypeFromPathWith(...)`
- `httpx.MimeMapping`
- `httpx.defaultMimeMappings`
- `httpx.CookieOptions`
- `httpx.SameSite`
- `httpx.encodeVarInt(...)`
- `httpx.decodeVarInt(...)`

## WebSocket Protocol

See [Protocol API](/api/protocol) for the full WebSocket section. Root-level aliases:

- `httpx.isWebSocketUpgrade(req)` — checks upgrade headers
- `httpx.wsExtractKey(req)` — returns `Sec-WebSocket-Key` value
- `httpx.wsAcceptKey(key, allocator)` — computes `Sec-WebSocket-Accept`
- `httpx.wsEncodeFrame(allocator, opcode, payload, fin, masked, mask_key)` — low-level frame encoder
- `httpx.wsDecodeFrame(allocator, data)` — decode one frame, returns `WsDecodeResult`
- `httpx.wsTextFrame(allocator, text)` — encode server text frame
- `httpx.wsBinaryFrame(allocator, data)` — encode server binary frame
- `httpx.wsPingFrame(allocator, data)` — encode ping frame
- `httpx.wsPongFrame(allocator, data)` — encode pong frame
- `httpx.wsCloseFrame(allocator, code, reason)` — encode close frame
- `httpx.WsOpcode` — frame opcode enum
- `httpx.WsFrame` — decoded frame struct
- `httpx.WsCloseCode` — close status codes
- `httpx.WsDecodeResult` — `{ frame, consumed }`
- `httpx.WS_GUID` — RFC 6455 magic GUID

## Multipart Form Data

RFC 2046 multipart/form-data builder and parser.

### `MultipartBuilder`

| Method | Description |
|--------|-------------|
| `init(allocator, boundary)` | Create a builder with a boundary string |
| `addField(name, value)` | Append a text form field part |
| `addFile(name, filename, content_type, data)` | Append a file upload part |
| `build()` | Finalize and return the complete body (caller owns) |
| `contentType()` | Return the `Content-Type` header value (caller owns) |
| `deinit()` | Release builder resources |

### `extractMultipartBoundary(content_type)`

Extracts the boundary value from a `Content-Type` header. Returns `null` if no boundary is present. Handles both quoted and unquoted boundary parameters.

Root-level alias: `httpx.extractMultipartBoundary(...)`.

### `parseMultipart(allocator, body, boundary)`

Parses a complete multipart body. Returns `ParsedParts`; call `.deinit()` when done.

Root-level alias: `httpx.parseMultipart(...)`.

### `Part`

| Field | Type | Description |
|-------|------|-------------|
| `name` | `[]const u8` | Form field name |
| `filename` | `?[]const u8` | File name for uploads, null for text fields |
| `content_type` | `[]const u8` | Part content type (defaults to `"text/plain"`) |
| `data` | `[]const u8` | Raw body bytes (slice into `ParsedParts` buffer) |
| `headers` | `[]const [2][]const u8` | All raw header pairs |

### `ParsedParts`

| Member | Description |
|--------|-------------|
| `parts` | `[]Part` — parsed parts slice |
| `deinit()` | Free all allocated memory |

## Metrics and Observability

Thread-safe, allocation-free request/response metrics using atomic operations.

### `Metrics`

| Method | Description |
|--------|-------------|
| `init()` | Create a zeroed Metrics instance |
| `initWithCallback(fn)` | Create with a custom event callback |
| `recordRequest()` | Increment total requests |
| `recordResponse(status, bytes, latency_ns)` | Record response, update status buckets and latency |
| `recordBytesSent(bytes)` | Increment bytes sent |
| `recordError()` | Increment error counter |
| `connectionOpened()` | Increment active connections |
| `connectionClosed()` | Decrement active connections |
| `reset()` | Reset all counters to zero |
| `snapshot()` | Return a `MetricsSnapshot` |

### `MetricsSnapshot`

| Field | Type | Description |
|-------|------|-------------|
| `total_requests` | `u64` | Total requests recorded |
| `total_responses` | `u64` | Total responses recorded |
| `active_connections` | `i64` | Current open connections |
| `errors` | `u64` | Total errors |
| `bytes_sent` | `u64` | Total bytes sent |
| `bytes_received` | `u64` | Total bytes received |
| `responses_2xx` | `u64` | 2xx response count |
| `responses_3xx` | `u64` | 3xx response count |
| `responses_4xx` | `u64` | 4xx response count |
| `responses_5xx` | `u64` | 5xx response count |
| `avg_latency_ns` | `u64` | Average latency in nanoseconds |
| `min_latency_ns` | `u64` | Minimum latency in nanoseconds |
| `max_latency_ns` | `u64` | Maximum latency in nanoseconds |

| Method | Returns | Description |
|--------|---------|-------------|
| `errorRate()` | `f64` | `errors / total_requests` |
| `successRate()` | `f64` | `responses_2xx / total_responses` |
| `print()` | `void` | Print a human-readable summary to stderr |

### `MetricsEvent`

Tagged union passed to the optional callback:

- `.request` — a request was recorded
- `.response` — `{ status: u16, bytes: u64, latency_ns: u64 }`
- `.bytes_sent` — `u64`
- `.err` — an error was recorded
- `.connection_open` / `.connection_close`

### `MetricsCallbackFn`

`*const fn (event: MetricsEvent) void`

Root-level aliases: `httpx.Metrics`, `httpx.MetricsSnapshot`, `httpx.MetricsEvent`, `httpx.MetricsCallbackFn`.

## Session Store

In-memory server-side sessions with TTL expiry.

### `SessionStore`

| Method | Returns | Description |
|--------|---------|-------------|
| `init(allocator, config)` | `SessionStore` | Create a store with the given config |
| `deinit()` | `void` | Release all resources |
| `create()` | `![SESSION_ID_LEN * 2]u8` | Create a new session, return hex ID |
| `set(hex_id, key, value)` | `!void` | Set a key in the session (duplicates value) |
| `get(hex_id, key)` | `?[]const u8` | Get a value; null if not found or expired |
| `delete(hex_id)` | `void` | Remove a session |
| `exists(hex_id)` | `bool` | True if session exists and is not expired |
| `evictExpired()` | `usize` | Remove expired sessions, returns count removed |
| `count()` | `usize` | Number of sessions in the store |

### `SessionConfig`

| Field | Default | Description |
|-------|---------|-------------|
| `ttl_ms` | `1_800_000` | Session TTL in milliseconds since last access |
| `cookie_name` | `"session_id"` | Cookie name for session ID |
| `max_sessions` | `0` | Max sessions (0 = unlimited) |

### Constants

- `SESSION_ID_LEN = 32` — raw session ID byte length
- `DEFAULT_TTL_MS = 1_800_000` — 30 minutes

Root-level aliases: `httpx.SessionStore`, `httpx.SessionConfig`, `httpx.SESSION_ID_LEN`.

## IO Utilities

Centralized in `src/util/any_io.zig`.

- `defaultIo()` — returns the appropriate `std.Io` for test or runtime context
- `sleepMs(ms: u64)` — sleep using the canonical IO
- `sleepMsI(ms: i64)` — sleep using the canonical IO (signed)
- `AnyReader` — type-erased reader with `read`, `readByte`, `readNoEof`
- `AnyWriter` — type-erased writer with `write`, `writeAll`, `print`

## Buffers

### `Buffer`

Dynamic, growable byte buffer.

- `init(allocator, capacity)` — create buffer
- `append(bytes)` — append bytes
- `toOwnedSlice()` — return owned slice
- `clear()` — reset without deallocating
- `deinit()` — release memory

### `FixedBuffer`

Stack-allocated fixed-size buffer with no heap allocation.

```zig
var buf = FixedBuffer(64){};
```

## Encoding

### `Base64`

RFC 4648 base64 with standard and URL-safe alphabets.

- `encode(allocator, data)` — encode to base64
- `decode(allocator, data)` — decode from base64
- `encodeUrl(allocator, data)` — URL-safe encoding

### `Hex`

- `encode(allocator, data)` — hex encode
- `decode(allocator, data)` — hex decode

### `PercentEncoding`

RFC 3986 URL encoding.

- `encode(allocator, input)` — percent-encode
- `decode(allocator, input)` — percent-decode

## JSON

### `json.JsonBuilder`

Fluent builder for constructing JSON strings.

```zig
var jb = httpx.json.JsonBuilder.init(allocator);
defer jb.deinit();

try jb.beginObject();
try jb.key("name");
try jb.string("alice");
try jb.key("age");
try jb.number(30);
try jb.endObject();

const s = try jb.toSlice();
defer allocator.free(s);
```

- `beginObject()` / `endObject()`
- `beginArray()` / `endArray()`
- `key(name)` / `string(val)` / `number(val)` / `boolean(val)` / `nullValue()`

## Compression

Content-Encoding negotiation, compression, and decompression for gzip, deflate, Brotli, and Zstd.

### `ContentEncoding`

Enum representing supported Content-Encoding values.

| Variant | Description |
|---------|-------------|
| `.gzip` | gzip (RFC 1952) |
| `.deflate` | DEFLATE (RFC 1951) |
| `.br` | Brotli (RFC 7932) |
| `.zstd` | Zstandard |
| `.identity` | No encoding (pass-through) |

### `ContentEncoding` Constants and Methods

| Member | Description |
|--------|-------------|
| `ContentEncoding.ALL` | Array of all supported encodings: `[_]ContentEncoding{ .gzip, .deflate, .br, .zstd, .identity }` |
| `toString()` | Convert to wire-format string (e.g., `.gzip` → `"gzip"`) |
| `fromString(str)` | Parse from a string; returns `?ContentEncoding` (case-insensitive) |
| `buildAcceptEncoding(encodings)` | Build an `Accept-Encoding` header value from a slice of encodings |

### `httpx.decompress()`

```zig
pub fn decompress(allocator: Allocator, encoding: ContentEncoding, data: []const u8) ![]u8
```

Decompresses body content based on the provided `Content-Encoding`. The caller owns the returned slice.

### `httpx.compress()`

```zig
pub fn compress(allocator: Allocator, encoding: ContentEncoding, data: []const u8) ![]u8
```

Compresses data using the specified encoding. The caller owns the returned slice.

Root-level aliases: `httpx.ContentEncoding`, `httpx.decompress`, `httpx.compress`.

## SSE (Server-Sent Events)

### `sse.Event`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `data` | `[]const u8` | (required) | Event payload body |
| `event` | `?[]const u8` | `null` | Optional SSE event name |
| `id` | `?[]const u8` | `null` | Optional event id |
| `retry_ms` | `?u32` | `null` | Optional client reconnect hint |

#### `Event.format(allocator)`

Serializes an SSE event to wire format. Caller owns the returned slice.

### `SseWriter(WriterType)`

Streaming SSE writer that emits events to any writer interface. Useful for server-side SSE endpoints that push events over a connection.

| Method | Description |
|--------|-------------|
| `init(underlying)` | Create a writer wrapping the given underlying writer |
| `sendEvent(event)` | Send a complete SSE event (id, event, retry, data) |
| `sendComment(comment)` | Send a comment line (used as keep-alive) |
| `sendNamed(name, data)` | Send a named event with data |
| `sendData(data)` | Send a plain data event (no event name) |
| `sendWithId(data, id)` | Send an event with an ID for Last-Event-ID tracking |

Fields:
- `last_event_id: ?[]const u8` — tracks the last event ID sent

### `parseSseStream(allocator, data, on_event)`

Parses a raw SSE stream, invoking the callback for each complete event. Returns the number of events parsed.

```zig
fn onEvent(event: sse.Event) void {
    std.debug.print("event: {s}\n", .{event.data});
}
const count = httpx.parseSseStream(allocator, raw_data, onEvent);
```

Root-level alias: `httpx.parseSseStream(...)`.
