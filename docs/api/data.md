# Data Formats API

MIME types, multipart form data, encoding, and JSON.

## MIME Types

`httpx.mime` (`src/utils/mime.zig`) is the single MIME implementation shared
by static files, embedded assets, templates, and downloads:

- `httpx.mime.fromPath(path)` — Resolve a best-effort MIME type from the file extension (always returns a valid content type, defaulting to `application/octet-stream`)
- `httpx.mime.octetStream` — `"application/octet-stream"` fallback constant

## Multipart Form Data

RFC 2046 multipart builder and parser are available at
`httpx.multipart.encoder` and `httpx.multipart.decoder`.

### Building

```zig
var encoder = try httpx.multipart.encoder.init(allocator, io, .{
    .fields = .{
        .{ .name = "username", .value = "alice" },
    },
    .files = .{
        .{ .name = "avatar", .data = png_bytes, .filename = "photo.png", .contentType = "image/png" },
    },
});
defer encoder.deinit();

const body = try encoder.encodeAlloc();
defer allocator.free(body);

var ctBuf: [128]u8 = undefined;
const contentType = encoder.contentType(&ctBuf);
// contentType = "multipart/form-data; boundary=..."
```

| Method | Description |
|--------|-------------|
| `init(allocator, io, .{})` | Create an encoder with generated or caller-supplied boundary |
| `encodeAlloc()` | Return the complete encoded body (caller owns) |
| `contentType(&buf)` | Return the `Content-Type` header value with the encoder boundary |
| `deinit()` | Release encoder resources |

Each form field and file is supplied in the initialization options. The boundary
must follow RFC 2046 syntax and be no longer than 70 characters.
For client requests, pass fields and files through `.multipart`:

```zig
const fileData = "file contents";
var res = try client.post("https://example.com/upload", .{
    .multipart = .{
        .fields = .{
            .{ .name = "description", .value = "sample" },
        },
        .files = .{
            .{ .name = "upload", .filename = "hello.txt", .contentType = "text/plain", .data = fileData },
        },
    },
});
defer res.deinit();
```

### extractBoundary(contentType)

Extracts the boundary value from a `Content-Type` header via
`httpx.multipart.Boundary.extract(...)`. Returns `null` if no boundary
is present. Handles both quoted (`boundary="abc"`) and unquoted
(`boundary=abc`) forms.

### Decoder.parse(body, contentType)

Parses a complete multipart body:

```zig
const parser = httpx.multipart.decoder;
var decoder = try parser.init(allocator, io, .{});
defer decoder.deinit();
const fields = try decoder.parse(body, contentType);
defer decoder.free(fields);
for (fields) |part| {
    std.debug.print("{s} ({d} bytes, type={s})\n", .{ part.name, part.data.len, part.contentType });
}
```

Pass limits through `.limits` in `decoder.init(allocator, io, .{ .limits = .strict })`.
The decoded metadata is owned by the decoder allocator; part data borrows the
input body, which must remain alive while the fields are used.

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

- Client: `client.request(url, .{ .method = .POST, .json = value })` serializes a struct/value automatically; `Response.json(r)` / `Response.jsonAlloc(r, allocator)` decode with unknown fields ignored.
- Server: `ctx.json(r)` deserializes the request body into `r`; `ctx.json(value)` / `ctx.jsonStatus(code, value)` render any struct/value as `application/json`.

## Cookies

`httpx.client.cookie` / `httpx.client.jar` (`Cookie` and `Jar`, including
`Cookie.SameSite`) are the cookie primitives. The jar stores cookies only when
your code passes `Set-Cookie` values to it; the client does not attach a jar or
persist cookies across requests automatically. Server handlers read cookies
with `ctx.cookie(name)`. `Set-Cookie` parsing, domain/path matching, expiry,
`Secure`, `HttpOnly`, and `SameSite` are handled in one place; there is no second cookie stack.
