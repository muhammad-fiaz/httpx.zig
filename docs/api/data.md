# Data Formats API

MIME types, multipart form data, encoding, and JSON.

Located in `src/data/`.

## MIME Types

- `mimeTypeFromPath(path)` — Resolve a best-effort MIME type from file extension
- `mimeTypeFromPathOr(path, fallback)` — Resolve MIME from extension with an explicit fallback
- `mimeTypeFromPathWith(path, mappings, fallback)` — Resolve MIME using caller-provided external mappings
- `MimeMapping` — Extension-to-MIME pair type for external mapping lists
- `defaultMimeMappings` — Built-in mapping table exported for extension/composition

Root-level aliases: `httpx.mimeTypeFromPath(...)`, `httpx.mimeTypeFromPathOr(...)`, `httpx.mimeTypeFromPathWith(...)`, `httpx.MimeMapping`, `httpx.defaultMimeMappings`.

## Multipart Form Data

RFC 2046 multipart/form-data builder and parser.

### MultipartBuilder

| Method | Description |
|--------|-------------|
| `init(allocator, boundary)` | Create a builder with a boundary string |
| `addField(name, value)` | Append a text form field part |
| `addFile(name, filename, content_type, data)` | Append a file upload part |
| `addFileChunked(name, filename, content_type, reader, chunk_size)` | Append a file upload from a reader |
| `build()` | Finalize and return the complete body (caller owns) |
| `contentType()` | Return the `Content-Type` header value (caller owns) |
| `deinit()` | Release builder resources |

### extractMultipartBoundary(content_type)

Extracts the boundary value from a `Content-Type` header. Returns `null` if no boundary is present. Handles both quoted and unquoted boundary parameters.

Root-level alias: `httpx.extractMultipartBoundary(...)`.

### parseMultipart(allocator, body, boundary)

Parses a complete multipart body. Returns `ParsedParts`; call `.deinit()` when done.

Root-level alias: `httpx.parseMultipart(...)`.

### Part

| Field | Type | Description |
|-------|------|-------------|
| `name` | `[]const u8` | Form field name |
| `filename` | `?[]const u8` | File name for uploads, null for text fields |
| `content_type` | `[]const u8` | Part content type (defaults to `"text/plain"`) |
| `data` | `[]const u8` | Raw body bytes (slice into `ParsedParts` buffer) |
| `headers` | `[]const [2][]const u8` | All raw header pairs |

### ParsedParts

| Member | Description |
|--------|-------------|
| `parts` | `[]Part` — parsed parts slice |
| `deinit()` | Free all allocated memory |

## Encoding

### Base64

RFC 4648 base64 with standard and URL-safe alphabets.

- `encode(allocator, data)` — encode to base64
- `decode(allocator, data)` — decode from base64
- `encodeUrl(allocator, data)` — URL-safe encoding

### Hex

- `encode(allocator, data)` — hex encode
- `decode(allocator, data)` — hex decode

### PercentEncoding

RFC 3986 URL encoding.

- `encode(allocator, input)` — percent-encode
- `decode(allocator, input)` — percent-decode

## JSON

### json.JsonBuilder

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

## Shared Helpers

`httpx.common` provides reusable helpers used across client/server/core modules.

- `queryValue(query, key)` — Get a query parameter value from a raw query string
- `parseSetCookiePair(set_cookie)` — Parse the first `name=value` pair from a `Set-Cookie` header value
- `parseSetCookie(set_cookie)` — Parse a `Set-Cookie` header extracting name, value, Domain, Path, Secure, and HttpOnly attributes
- `cookieValue(cookie_header, name)` — Read a cookie value from a request `Cookie` header
- `buildSetCookieHeader(allocator, name, value, options)` — Build a `Set-Cookie` header value with RFC 6265 style attributes
- `CookieOptions` — Cookie attributes (`Path`, `Domain`, `Max-Age`, `SameSite`, `Secure`, `HttpOnly`)
- `SameSite` — Enum values `lax`, `strict`, `none`

Root-level aliases:

- `httpx.queryValue(...)`
- `httpx.parseSetCookiePair(...)`
- `httpx.CookieOptions`
- `httpx.SameSite`
- `httpx.encodeVarInt(...)`
- `httpx.decodeVarInt(...)`
