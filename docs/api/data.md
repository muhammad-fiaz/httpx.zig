# Data Formats API

MIME types, multipart form data, encoding, and JSON.

## MIME Types

`httpx.mime` (`src/common/mime.zig`) is the single MIME implementation shared
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

`httpx.json` is the single JSON implementation used by the client, server,
typed REST endpoints, GraphQL, and parsing. It covers media-type
classification, dynamic objects, typed decoding, and typed encoding. Unknown
object keys are always ignored on input.

### Typed structs

JSON keys are arbitrary strings, and Zig quoted identifiers express them
directly. There is no mapping layer: the field name *is* the wire key.

```zig
const User = struct {
    @"user-name": []const u8,
    @"user.name": []const u8,
    @"user name": []const u8,
    @"user@email": []const u8,
    @"user/id": u32,
    @"123user": []const u8,
    @"@context": []const u8,
    @"$schema": []const u8,
    @"Content-Type": []const u8,
    @"X-API-Key": []const u8,
    @"HTTP/2": bool,
};

const user = try httpx.json.decode(User, arena, body);
const wire = try httpx.json.encode(allocator, user);
defer allocator.free(wire);
```

Decoding rules:

- Field names are matched exactly, including header-style and symbol keys.
- Optional fields accept `null` and absence.
- Fields with Zig default values are optional on input.
- Missing required fields return `error.MissingField`.
- Unknown JSON keys are ignored.
- Encoding writes the same exact field names.

### Client requests

The `.json` request option accepts any Zig value and serializes it with its
exact field names:

```zig
var res = try client.post("https://example.com/users", .{
    .json = User{
        .@"user-name" = "Example User",
        .@"@context" = "https://schema.org",
    },
});
defer res.deinit();
```

The fluent builder has the same behavior:

```zig
_ = try client.builder(.POST, url).json(user).send();
```

### Client responses

`Response.json(T)` decodes with the shared decoder; `jsonValue` returns a
dynamic object:

```zig
const user = try res.json(User);
const dynamic = try res.jsonValue();
const name = httpx.json.getString(&dynamic.object, "user-name");
```

Values allocate from a response-owned arena released by `Response.deinit`; they
remain valid until then. `Response.jsonAlloc(T, allocator)` returns
`std.json.Parsed(T)` when the value must outlive the response.

### Server requests and responses

```zig
const user = try ctx.json(User);       // body -> User
const dynamic = try ctx.jsonValue();    // body -> std.json.Value
return ctx.json(user);                  // any value -> JSON response
return ctx.jsonStatus(422, problem);    // explicit status
```

`ctx.json(T)` decodes the request body into `T`; `ctx.json(value)` and
`ctx.jsonStatus(code, value)` serialize a response. Values decoded with
`ctx.json` and `ctx.jsonValue` borrow the per-request arena and are valid until
the request completes.

### Dynamic keys

`httpx.json.Value`, `.Object`, and `.Array` are `std.json` aliases. Typed
accessors read arbitrary keys without parsing by hand:

| Helper | Result |
|--------|--------|
| `get(object, key)` | Exact-key lookup |
| `getIgnoreCase(object, key)` | Header-style case-insensitive lookup |
| `getString`, `getInt`, `getFloat`, `getBool` | Scalar lookup |
| `getObject`, `getArray` | Nested container lookup |

```zig
const parsed = try httpx.json.parse(arena, body);
const headers = parsed.object;
const apiKey = httpx.json.getString(&headers, "X-API-Key") orelse "";
```

### Media types

`httpx.json.isJsonMediaType(value)` accepts `application/json`,
`text/json`, `application/x-json`, `application/csp-report`, and any valid
`+json` structured-syntax subtype. Parameters are validated, type tokens are
case-insensitive, and `httpx.json.classifyMediaType` distinguishes JSON5,
NDJSON/JSONL, and JSON text sequences for callers that provide the matching
parser.

## Cookies

`httpx.client.cookie` / `httpx.client.jar` (`Cookie` and `Jar`, including
`Cookie.SameSite`) are the cookie primitives. The jar stores cookies only when
your code passes `Set-Cookie` values to it; the client does not attach a jar or
persist cookies across requests automatically. Server handlers read cookies
with `ctx.cookie(name)`. `Set-Cookie` parsing, domain/path matching, expiry,
`Secure`, `HttpOnly`, and `SameSite` are handled in one place; there is no second cookie stack.
