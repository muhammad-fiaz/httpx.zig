# Data Formats API

MIME types, multipart form data, encoding, and JSON.

## MIME Types

`httpx.mime` (`src/utils/mime.zig`) is the single MIME implementation shared
by static files, embedded assets, templates, and downloads:

- `httpx.mime.fromPath(path)` — Resolve a best-effort MIME type from the file extension (always returns a valid content type, defaulting to `application/octet-stream`)
- `httpx.mime.octetStream` — `"application/octet-stream"` fallback constant

## Multipart Form Data

RFC 2046 multipart/form-data builder and parser
(`httpx.multipart.encoder` / `httpx.multipart.parser`).

### Building

```zig
var form = httpx.multipart.encoder.Multipart.init(allocator);
defer form.deinit();

try form.field("username", "alice");
try form.file("avatar", png_bytes, .{
    .filename = "photo.png",
    .contentType = "image/png",
});

const body = try form.encodeAlloc();
defer allocator.free(body);

var ctBuf: [128]u8 = undefined;
const contentType = form.contentType(&ctBuf);
// contentType = "multipart/form-data; boundary=..."
```

| Method | Description |
|--------|-------------|
| `init(allocator)` / `initWithSubtype(allocator, subtype)` | Create a builder (boundary auto-generated; override with `setBoundary`) |
| `field(name, value)` | Append a text form field part |
| `file(name, data, .{ .filename, .contentType, ... })` | Append a file upload part |
| `encodeAlloc()` | Finalize and return the complete body (caller owns) |
| `encode(writer)` | Stream-encode into any writer |
| `contentType(&buf)` | Return the `Content-Type` header value with boundary |
| `deinit()` | Release builder resources |

The boundary must not contain `--` and should not exceed 70 characters (RFC 2046).
For a single inline part on a client request, use the `.multipart` request
option instead:

```zig
var res = try client.post("https://example.com/upload", .{
    .multipart = .{
        .name = "upload",
        .filename = "hello.txt",
        .contentType = "text/plain",
        .data = fileData,
    },
});
defer res.deinit();
```

### extractBoundary(contentType)

Extracts the boundary value from a `Content-Type` header via
`httpx.multipart.parser.extractBoundary(...)`. Returns `null` if no boundary
is present. Handles both quoted (`boundary="abc"`) and unquoted
(`boundary=abc`) forms.

### parseMultipart(allocator, body, boundary, limits)

Parses a complete multipart body:

```zig
const parser = httpx.multipart.parser;
const boundary = parser.extractBoundary(contentType) orelse return error.MissingBoundary;
const fields = try parser.parseMultipart(allocator, body, boundary, .{});
defer parser.freeFieldsAlloc(allocator, fields);
for (fields) |part| {
    std.debug.print("{s} ({d} bytes, type={s})\n", .{ part.name, part.data.len, part.contentType });
}
```

Use `httpx.multipart.parser.Limits` (presets `.strict` / `.relaxed`, or
`Parser.initWithLimits`) to bound parts, header sizes, and body sizes.

### Field

| Field | Type | Description |
|-------|------|-------------|
| `name` | `[]const u8` | Form field name |
| `filename` | `?[]const u8` | File name for uploads, null for text fields |
| `contentType` | `[]const u8` | Part content type (defaults to `""`) |
| `data` | `[]const u8` | Raw body bytes |
| `headers` | `[]const Header` | All raw header pairs (`{ .name, .value }`) |

## Encoding

For base64 use `std.base64`; for hex use `std.fmt.bytesToHex`; for URL
percent-encoding use `httpx.uri.percentEncode(buf, input)` (RFC 3986
unreserved set kept as-is). HTTPX does not duplicate these standard
library primitives.

## JSON

Use Zig std JSON facilities (`std.json`) plus httpx conveniences:

- Client: `client.fetch(url, .{ .json = value })` serializes any struct/value automatically; `Response.json(r)` / `Response.jsonAlloc(r, allocator)` decode with unknown fields ignored.
- Server: `ctx.json(r)` deserializes the request body into `r`; `ctx.renderJson(value)` / `ctx.renderJsonStatus(code, value)` render any struct/value as `application/json`.

## Cookies

`httpx.cookies` (`Jar` / `Cookie`, incl. `Cookie.SameSite`) is the single
cookie implementation: the client jar persists cookies across requests and
redirects, while server handlers read them with `ctx.cookie(name)`.
`Set-Cookie` parsing, domain/path matching, expiry, `Secure`, `HttpOnly`,
and `SameSite` are handled in one place — there is no second cookie stack.
