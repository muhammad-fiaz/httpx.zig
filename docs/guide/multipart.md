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

Use `httpx.multipart.stream.encoder.init` to encode fields and files. The encoder
generates a boundary unless one is supplied:

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const io = std.Io.Threaded.global_single_threaded.io();
    const png_data = @embedFile("avatar.png");
    const fields = [_]httpx.multipart.stream.encoder.FieldValue{
        .{ .name = "username", .value = "alice" },
        .{ .name = "email", .value = "alice@example.com" },
    };
    const files = [_]httpx.multipart.stream.encoder.File{
        .{ .name = "avatar", .data = png_data, .filename = "photo.png", .contentType = "image/png" },
    };
    var encoder = try httpx.multipart.stream.encoder.init(allocator, io, .{
        .fields = &fields,
        .files = &files,
    });
    defer encoder.deinit();

    // Finalize — caller owns the result
    const body = try encoder.encodeAlloc();
    defer allocator.free(body);

    // Get the Content-Type header value with boundary
    var ctBuf: [128]u8 = undefined;
    const contentType = encoder.contentType(&ctBuf);
    // contentType = "multipart/form-data; boundary=..."

    std.debug.print("body size: {d} bytes\n", .{body.len});
}
```

### `Encoder` API

| Method | Description |
|--------|-------------|
| `init(allocator, io, .{})` | Create the encoder with fields, files, and optional boundary |
| `encodeAlloc()` | Return the complete encoded body (caller owns) |
| `contentType(&buf)` | Return the `Content-Type` header value with the chosen boundary |
| `deinit()` | Release encoder resources |

The boundary must not contain `--` and should not exceed 70 characters (RFC 2046).

## Parsing Multipart Bodies

### Extracting the Boundary

Use `httpx.multipart.stream.decoder.extractBoundary` to get the boundary string from
a `Content-Type` header:

```zig
const contentType = "multipart/form-data; boundary=----WebKitFormBoundary";
const boundary = httpx.multipart.stream.decoder.extractBoundary(contentType) orelse {
    return error.MissingBoundary;
};
// boundary = "----WebKitFormBoundary"
```

Returns `null` if no boundary parameter is present. Handles both quoted (`boundary="abc"`) and unquoted (`boundary=abc`) forms.

### Parsing Parts

```zig
var decoder = try httpx.multipart.stream.decoder.init(allocator, io, .{});
defer decoder.deinit();
const fields = try decoder.parse(body, contentType);
defer decoder.free(fields);

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

Use `decoder.init(allocator, io, .{ .limits = .strict })` to bound part counts,
header sizes, and body sizes. Parsed part data borrows the input body; keep it
alive until the fields are released.

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
const fields = [_]struct { name: []const u8, value: []const u8 }{
    .{ .name = "name", .value = "alice" },
};
var resp = try client.post("https://example.com/upload", .{ .multipart = .{
    .fields = &fields,
} });
defer resp.deinit();
```

### Direct Multipart Upload

Pass field and file slices through `.multipart`:

```zig
const fields = [_]struct { name: []const u8, value: []const u8 }{
    .{ .name = "caption", .value = "portrait" },
};
const files = [_]struct {
    name: []const u8,
    filename: []const u8,
    contentType: []const u8,
    data: []const u8,
}{
    .{ .name = "avatar", .filename = "photo.png", .contentType = "image/png", .data = png_bytes },
};
var resp = try client.post("https://example.com/upload", .{ .multipart = .{
    .fields = &fields,
    .files = &files,
} });
defer resp.deinit();
```

## Full Server-Side Example

```zig
const std = @import("std");
const httpx = @import("httpx");

fn uploadHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    const ct = ctx.header("Content-Type") orelse
        return ctx.textStatus(400, "Missing Content-Type");

    var decoder = try httpx.multipart.stream.decoder.init(ctx.allocator, ctx.io, .{});
    defer decoder.deinit();
    const fields = try decoder.parse(ctx.body, ct);
    defer decoder.free(fields);

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

The HTTP client currently buffers multipart request bodies before transport,
so large client uploads use memory proportional to the encoded body. The incremental
`StreamEncoder` can write caller-provided chunks to a `std.Io.Writer`:

```zig
const std = @import("std");

var output: std.Io.Writer.Allocating = .init(allocator);
defer output.deinit();
const first_chunk = "file bytes 1";
const second_chunk = "file bytes 2";

var encoder = try httpx.multipart.stream.encoder.StreamEncoder.init(
    &output.writer,
    .formData,
    "upload-boundary",
);
try encoder.beginPart("description", .{});
try encoder.write("large upload");
try encoder.endPart();
try encoder.beginPart("file", .{
    .filename = "big.bin",
    .contentType = "application/octet-stream",
});
try encoder.write(first_chunk);
try encoder.write(second_chunk);
try encoder.endPart();
try encoder.finish();
```

The writer and boundary slice must remain valid while the encoder is in use.
The encoder writes each supplied chunk immediately and rejects state misuse or
boundary collisions. The returned request path still needs transport support
for streaming bodies before this can avoid whole-body buffering over HTTP.

On the server, `Context.multipartForm(.{})` parses the already-buffered request
body. For incremental input, initialize `httpx.multipart.stream.decoder` and
call `decoder.stream(contentType)`. Each returned `partData` slice is owned by
the decoder allocator and must be freed after use. Copy `partBegin` metadata
before calling `next()` again. To persist a parsed file,
`httpx.multipart.server.saveFile` takes an explicit allocator and `std.Io` and
writes under a generated basename rather than trusting the client filename.

For client uploads, pass the file bytes directly in `.multipart`. The client
currently encodes the complete request body in memory:

```zig
const large_bytes: []const u8 = ...; // e.g. @embedFile("big.bin")

const fields = [_]struct { name: []const u8, value: []const u8 }{
    .{ .name = "description", .value = "large upload" },
};
const files = [_]struct {
    name: []const u8,
    filename: []const u8,
    contentType: []const u8,
    data: []const u8,
}{
    .{ .name = "file", .filename = "big.bin", .contentType = "application/octet-stream", .data = large_bytes },
};
var response = try client.post(upload_url, .{ .multipart = .{ .fields = &fields, .files = &files } });
defer response.deinit();
```

### Resumable / Chunked Upload Pattern

When implementing a server-side chunked upload protocol (e.g. `TUS`), split the
file yourself at the call site and send each slice as a separate POST request.
A 64 KB slice matches the socket layer's per-send cap:

```zig
const chunk_size = 64 * 1024; // 65_536 bytes per request

var offset: usize = 0;
var part: usize = 1;
while (offset < file_bytes.len) {
    const end = @min(offset + chunk_size, file_bytes.len);
    const slice = file_bytes[offset..end];

    {
    const part_str = try std.fmt.allocPrint(allocator, "{d}", .{part});
    defer allocator.free(part_str);

    const fields = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "part", .value = part_str },
    };
    const files = [_]struct { name: []const u8, filename: []const u8, data: []const u8 }{
        .{ .name = "data", .filename = "chunk.bin", .data = slice },
    };
    var resp = try client.post(upload_url, .{ .multipart = .{
        .fields = &fields,
        .files = &files,
    } });
    defer resp.deinit();
    }

    offset = end;
    part += 1;
}
```

This pattern sends each chunk as a separate HTTP request, which:
- Keeps each application-level chunk at 64 KB; individual socket sends are capped separately
- Allows for retry of individual failed parts
- Works on the platforms listed above
