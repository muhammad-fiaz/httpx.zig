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

Use `MultipartBuilder` to construct the body incrementally:

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var builder = httpx.MultipartBuilder.init(allocator, "boundary-abc123");
    defer builder.deinit();

    // Add text fields
    try builder.addField("username", "alice");
    try builder.addField("email", "alice@example.com");

    // Add a file upload
    const png_data = @embedFile("avatar.png");
    try builder.addFile("avatar", "photo.png", "image/png", png_data);

    // Finalize — caller owns the result
    const body = try builder.build();
    defer allocator.free(body);

    // Get the Content-Type header value with boundary
    const content_type = try builder.contentType();
    defer allocator.free(content_type);
    // content_type = "multipart/form-data; boundary=boundary-abc123"

    std.debug.print("body size: {d} bytes\n", .{body.len});
}
```

### `MultipartBuilder` API

| Method | Description |
|--------|-------------|
| `init(allocator, boundary)` | Create builder with a boundary string |
| `addField(name, value)` | Append a text form field |
| `addFile(name, filename, content_type, data)` | Append a file upload part |
| `build()` | Finalize and return the complete body (caller owns) |
| `contentType()` | Return the `Content-Type` header value (caller owns) |
| `deinit()` | Release builder resources |

The boundary must not contain `--` and should not exceed 70 characters (RFC 2046).

## Parsing Multipart Bodies

### Extracting the Boundary

Use `extractMultipartBoundary` (also exported as `httpx.extractMultipartBoundary`) to get the boundary string from a `Content-Type` header:

```zig
const content_type = "multipart/form-data; boundary=----WebKitFormBoundary";
const boundary = httpx.extractMultipartBoundary(content_type) orelse {
    return error.MissingBoundary;
};
// boundary = "----WebKitFormBoundary"
```

Returns `null` if no boundary parameter is present. Handles both quoted (`boundary="abc"`) and unquoted (`boundary=abc`) forms.

### Parsing Parts

```zig
const boundary = httpx.extractMultipartBoundary(content_type).?;
var result = try httpx.parseMultipart(allocator, body, boundary);
defer result.deinit();

for (result.parts) |part| {
    if (part.filename) |filename| {
        std.debug.print("file: {s} ({d} bytes, type={s})\n", .{
            filename, part.data.len, part.content_type,
        });
    } else {
        std.debug.print("field: {s} = {s}\n", .{ part.name, part.data });
    }
}
```

### `Part` fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | `[]const u8` | Form field name from `Content-Disposition` |
| `filename` | `?[]const u8` | Original filename for file uploads, or null |
| `content_type` | `[]const u8` | Part content type (defaults to `"text/plain"`) |
| `data` | `[]const u8` | Raw bytes of the part body |
| `headers` | `[]const [2][]const u8` | All raw header pairs for this part |

`ParsedParts` has a `deinit()` method that frees all allocated memory. The `data` slice points into the internal raw buffer, so it is valid until `deinit()` is called.

## Integration with HTTP Requests

When sending a multipart request with the httpx client:

```zig
var builder = httpx.MultipartBuilder.init(allocator, "myBoundary");
defer builder.deinit();
try builder.addField("name", "alice");

const body = try builder.build();
defer allocator.free(body);
const ct = try builder.contentType();
defer allocator.free(ct);

var opts = httpx.RequestOptions.defaults();
opts.body = body;
try opts.withHeaders(&.{.{ "Content-Type", ct }});

var resp = try client.post("https://example.com/upload", opts);
defer resp.deinit();
```

### Fluent Client-Side API

Instead of manually building and cleaning up the body, you can pass fields and files directly using `RequestOptions` for automatic formatting and optional MIME type resolution:

```zig
const fields = [_]httpx.MultipartField{
    .{ .name = "name", .value = "alice" },
};
const files = [_]httpx.MultipartFile{
    .{ .name = "avatar", .filename = "photo.png", .data = png_bytes },
};

const opts = httpx.RequestOptions.defaults()
    .withMultipartFields(&fields)
    .withMultipartFiles(&files);

var resp = try client.post("https://example.com/upload", opts);
defer resp.deinit();
```

If the file's `content_type` is omitted, it will automatically resolve the extension using built-in mapping defaults out-of-the-box.

## Full Server-Side Example

```zig
const std = @import("std");
const httpx = @import("httpx");

fn uploadHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const ct = ctx.request.headers.get("Content-Type") orelse
        return ctx.status(400).text("Missing Content-Type");

    const boundary = httpx.extractMultipartBoundary(ct) orelse
        return ctx.status(400).text("Missing boundary");

    const body = ctx.request.body orelse "";
    var result = try httpx.parseMultipart(ctx.allocator, body, boundary);
    defer result.deinit();

    for (result.parts) |part| {
        if (part.filename) |name| {
            std.debug.print("uploaded: {s} ({d} bytes)\n", .{ name, part.data.len });
        } else {
            std.debug.print("field {s}: {s}\n", .{ part.name, part.data });
        }
    }

    return ctx.json(.{ .ok = true, .parts = result.parts.len });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = httpx.Server.init(allocator);
    defer server.deinit();

    try server.post("/upload", uploadHandler);
    try server.listen();
}
```
## Large File Uploads & Windows Compatibility

> **Windows users:** a known limitation of Winsock (issue [#26](https://github.com/muhammad-fiaz/httpx.zig/issues/26)) can
> cause multipart uploads to hang after a few parts when the combined request body
> exceeds ~64 KB. The root cause is that a single `winsock.send()` call with a
> buffer larger than the kernel send buffer (~8–64 KB) triggers `WSAEWOULDBLOCK`,
> which previously caused the upload loop to stall.

**httpx.zig 0.1.6+** fixes the socket layer to cap each individual `send()` call
at 64 KB automatically, and increases the writability timeout from 5 s to 30 s.
No application-level changes are required for most users.

For large file data passed as a single slice, you can also use
`MultipartBuilder.addFileChunked`, which writes `data` internally in
`MAX_RECOMMENDED_CHUNK` (64 KB) blocks:

```zig
const large_bytes: []const u8 = ...; // e.g. @embedFile("big.bin")

var builder = httpx.MultipartBuilder.init(allocator, "myBound");
defer builder.deinit();

try builder.addField("description", "large upload");
// Writes internally in ≤64 KB slices — safe on all platforms.
try builder.addFileChunked("file", "big.bin", "application/octet-stream", large_bytes);

const body = try builder.build();
defer allocator.free(body);
```

### Resumable / Chunked Upload Pattern

When implementing a server-side chunked upload protocol (e.g. `TUS`), split the
file yourself at the call site and send each slice as a separate POST request.
Use `httpx.MultipartMaxChunk` (64 KB) as the slice size:

```zig
const chunk_size = httpx.MultipartMaxChunk; // 65 536 bytes

var offset: usize = 0;
var part: usize = 1;
while (offset < file_bytes.len) {
    const end = @min(offset + chunk_size, file_bytes.len);
    const slice = file_bytes[offset..end];

    const part_str = try std.fmt.allocPrint(allocator, "{d}", .{part});
    defer allocator.free(part_str);

    const fields = [_]httpx.MultipartField{
        .{ .name = "part", .value = part_str },
    };
    const files = [_]httpx.MultipartFile{
        .{ .name = "data", .filename = "chunk.bin", .data = slice },
    };

    const opts = httpx.RequestOptions.defaults()
        .withMultipartFields(&fields)
        .withMultipartFiles(&files);

    var resp = try client.post(upload_url, opts);
    defer resp.deinit();

    offset = end;
    part += 1;
}
```

This pattern sends each chunk as a separate HTTP request, which:
- Keeps each request body well under the 64 KB socket limit
- Allows for retry of individual failed parts
- Works reliably on Windows, Linux, and macOS
