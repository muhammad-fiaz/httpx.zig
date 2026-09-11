# Multipart Form Data Guide

`httpx.zig` provides RFC 2046 multipart/form-data support for building and parsing form submissions with file attachments.

## What Multipart Is

Multipart/form-data is the encoding used when HTML forms contain file inputs, or when an HTTP client needs to send both text fields and binary file data in the same request. Each part has its own headers (`Content-Disposition`, `Content-Type`) and is separated by a boundary string.

A multipart body looks like:

```
--boundary123
Content-Disposition: form-data; name="username"

alice
--boundary123
Content-Disposition: form-data; name="avatar"; filename="photo.png"
Content-Type: image/png

<binary PNG data>
--boundary123--
```

## Building Multipart Bodies

Use `httpx.multipart.encoder.Multipart` to construct the body incrementally
(boundary auto-generated):

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var form = httpx.multipart.encoder.Multipart.init(allocator);
    defer form.deinit();

    // Add text fields
    try form.field("username", "alice");
    try form.field("email", "alice@example.com");

    // Add a file upload
    const png_data = @embedFile("avatar.png");
    try form.file("avatar", png_data, .{
        .filename = "photo.png",
        .contentType = "image/png",
    });

    // Finalize — caller owns the result
    const body = try form.encodeAlloc();
    defer allocator.free(body);

    // Get the Content-Type header value with boundary
    var ctBuf: [128]u8 = undefined;
    const contentType = form.contentType(&ctBuf);
    // contentType = "multipart/form-data; boundary=..."

    std.debug.print("body size: {d} bytes\n", .{body.len});
}
```

### `Multipart` API

| Method | Description |
|--------|-------------|
| `init(allocator)` / `initWithSubtype(allocator, subtype)` | Create builder (boundary auto-generated; override with `setBoundary`) |
| `field(name, value)` | Append a text form field |
| `file(name, data, .{ .filename, .contentType, ... })` | Append a file upload part |
| `encodeAlloc()` | Finalize and return the complete body (caller owns) |
| `encode(writer)` | Stream-encode into any writer |
| `contentType(&buf)` | Return the `Content-Type` header value (borrowed from `buf`) |
| `deinit()` | Release builder resources |

The boundary must not contain `--` and should not exceed 70 characters (RFC 2046).

## Parsing Multipart Bodies

### Extracting the Boundary

Use `httpx.multipart.parser.extractBoundary` to get the boundary string from
a `Content-Type` header:

```zig
const contentType = "multipart/form-data; boundary=----WebKitFormBoundary";
const boundary = httpx.multipart.parser.extractBoundary(contentType) orelse {
    return error.MissingBoundary;
};
// boundary = "----WebKitFormBoundary"
```

Returns `null` if no boundary parameter is present. Handles both quoted (`boundary="abc"`) and unquoted (`boundary=abc`) forms.

### Parsing Parts

```zig
const boundary = httpx.multipart.parser.extractBoundary(contentType).?;
const fields = try httpx.multipart.parser.parseMultipart(allocator, body, boundary, .{});
defer httpx.multipart.parser.freeFieldsAlloc(allocator, fields);

for (fields) |part| {
    if (part.filename) |filename| {
        std.debug.print("file: {s} ({d} bytes, type={s})\n", .{
            filename, part.data.len, part.contentType,
        });
    } else {
        std.debug.print("field: {s} = {s}\n", .{ part.name, part.data });
    }
}
```

Use `Limits` presets (`.strict` / `.relaxed`, or `Parser.initWithLimits`) to
bound part counts, header sizes, and body sizes.

### `Field` fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | `[]const u8` | Form field name from `Content-Disposition` |
| `filename` | `?[]const u8` | Original filename for file uploads, or null |
| `contentType` | `[]const u8` | Part content type (defaults to `""`) |
| `data` | `[]const u8` | Raw bytes of the part body |
| `headers` | `[]const Header` | All raw header pairs (`{ .name, .value }`) |

## Integration with HTTP Requests

When sending a multipart request with the httpx client:

```zig
var form = httpx.multipart.encoder.Multipart.init(allocator);
defer form.deinit();
try form.field("name", "alice");

const body = try form.encodeAlloc();
defer allocator.free(body);
var ctBuf: [128]u8 = undefined;
const ct = form.contentType(&ctBuf);

var resp = try client.post("https://example.com/upload", .{ .body = body,
    .headers = &.{.{ .name = "Content-Type", .value = ct }},
});
defer resp.deinit();
```

### Direct Multipart Upload

Instead of manually building the body, post a single part inline with the
`.multipart` request option:

```zig
var resp = try client.post("https://example.com/upload", .{ .multipart = .{
    .name = "avatar",
    .filename = "photo.png",
    .contentType = "image/png",
    .data = png_bytes,
} });
defer resp.deinit();
```

## Full Server-Side Example

```zig
const std = @import("std");
const httpx = @import("httpx");

fn uploadHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const ct = ctx.header("Content-Type") orelse
        return ctx.textStatus(400, "Missing Content-Type");

    const parser = httpx.multipart.parser;
    const boundary = parser.extractBoundary(ct) orelse
        return ctx.textStatus(400, "Missing boundary");

    const fields = try parser.parseMultipart(ctx.allocator, ctx.body, boundary, .{});
    defer parser.freeFieldsAlloc(ctx.allocator, fields);

    for (fields) |part| {
        if (part.filename) |name| {
            std.debug.print("uploaded: {s} ({d} bytes)\n", .{ name, part.data.len });
        } else {
            std.debug.print("field {s}: {s}\n", .{ part.name, part.data });
        }
    }

    return ctx.renderJson(.{ .ok = true, .parts = fields.len });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{});
    defer server.deinit();

    try server.post("/upload", uploadHandler);
    server.run();
}
```
## Large File Uploads & Windows Compatibility

> **Windows users:** a known limitation of Winsock (issue [#26](https://github.com/muhammad-fiaz/httpx.zig/issues/26)) can
> cause multipart uploads to hang after a few parts when the combined request body
> exceeds ~64 KB. The root cause is that a single `winsock.send()` call with a
> buffer larger than the kernel send buffer (~8–64 KB) triggers `WSAEWOULDBLOCK`,
> which previously caused the upload loop to stall.

**httpx.zig 0.1.8+** fixes the socket layer to cap each individual `send()` call
at 64 KB automatically, and increases the writability timeout from 5 s to 30 s.
No application-level changes are required for most users.

For large file data, stream-encode directly into a buffer or writer instead
of holding two copies: `encode(writer)` writes parts incrementally, and the
socket layer caps each `send()` at 64 KB — safe on all platforms:

```zig
const large_bytes: []const u8 = ...; // e.g. @embedFile("big.bin")

var form = httpx.multipart.encoder.Multipart.init(allocator);
defer form.deinit();

try form.field("description", "large upload");
try form.file("file", large_bytes, .{
    .filename = "big.bin",
    .contentType = "application/octet-stream",
});

const body = try form.encodeAlloc();
defer allocator.free(body);
```

### Resumable / Chunked Upload Pattern

When implementing a server-side chunked upload protocol (e.g. `TUS`), split the
file yourself at the call site and send each slice as a separate POST request.
Use `httpx.MultipartMaxChunk` (64 KB) as the slice size:

```zig
const chunk_size = 64 * 1024; // 65_536 bytes per request

var offset: usize = 0;
var part: usize = 1;
while (offset < file_bytes.len) {
    const end = @min(offset + chunk_size, file_bytes.len);
    const slice = file_bytes[offset..end];

    const part_str = try std.fmt.allocPrint(allocator, "{d}", .{part});
    defer allocator.free(part_str);

    var form = httpx.multipart.encoder.Multipart.init(allocator);
    defer form.deinit();
    try form.field("part", part_str);
    try form.file("data", slice, .{ .filename = "chunk.bin" });
    const req_body = try form.encodeAlloc();
    defer allocator.free(req_body);
    var ctBuf: [128]u8 = undefined;

    var resp = try client.post(upload_url, .{
        .body = req_body,
        .headers = &.{.{ .name = "Content-Type", .value = form.contentType(&ctBuf) }},
    });
    defer resp.deinit();

    offset = end;
    part += 1;
}
```

This pattern sends each chunk as a separate HTTP request, which:
- Keeps each request body well under the 64 KB socket limit
- Allows for retry of individual failed parts
- Works reliably on Windows, Linux, and macOS
