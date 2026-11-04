# Multipart Form Data Guide

`httpx.zig` provides RFC 2046 and RFC 7578 multipart/form-data support for building, streaming, and parsing form submissions with file attachments across all platforms (Windows, Linux, macOS, x86_64, aarch64, and 32-bit targets).

## What Multipart Is

Multipart/form-data is the encoding used when HTML forms contain file inputs, or when an HTTP client needs to send both text fields and binary file data in the same request. Each part has its own headers (`Content-Disposition`, `Content-Type`) and is separated by a boundary string.

A multipart body looks like:

```http
--boundary123
Content-Disposition: form-data; name="username"

alice
--boundary123
Content-Disposition: form-data; name="avatar"; filename="photo.png"
Content-Type: image/png

<binary PNG data>
--boundary123--
```

## Client Upload Configurations

`httpx.Client` provides zero-boilerplate, type-safe multipart upload options using anonymous struct literals.

### 1. Multi-Field and Multi-File Uploads

Pass arrays or slices of anonymous structs directly to `.multipart`:

```zig
const std = @import("std");
const httpx = @import("httpx");

var client = httpx.Client.init(allocator, io, .{});
defer client.deinit();

const fields = [_]struct { name: []const u8, value: []const u8 }{
    .{ .name = "description", .value = "large upload" },
    .{ .name = "category", .value = "reports" },
};

const files = [_]struct {
    name: []const u8,
    filename: []const u8,
    contentType: ?[]const u8,
    data: []const u8,
}{
    .{
        .name = "file",
        .filename = "big.bin",
        .contentType = "application/octet-stream", // Optional: automatically detected if omitted
        .data = large_bytes,
    },
};

var response = try client.post("http://127.0.0.1:8080/upload", .{
    .multipart = .{
        .fields = &fields,
        .files = &files,
    },
});
defer response.deinit();
```

### 2. Single-File Upload Convenience

When uploading only one file, pass the struct directly to `.multipart` without wrapping it in an array:

```zig
var resp = try client.post("http://127.0.0.1:8080/upload-avatar", .{
    .multipart = .{
        .name = "avatar",
        .filename = "photo.png", // Content-Type detected as image/png automatically
        .data = png_data,
    },
});
defer resp.deinit();
```

Or nested under `.file`:

```zig
var resp = try client.post("http://127.0.0.1:8080/upload-report", .{
    .multipart = .{
        .file = .{
            .name = "report",
            .filename = "audit.json",
            .data = json_data,
        },
    },
});
defer resp.deinit();
```

### 3. Cooperative Cancellation with `cancelFlag`

All client operations (connection, body uploading, response header reading, and response body streaming) can be cooperatively aborted using an atomic cancellation flag:

```zig
var cancel = std.atomic.Value(bool).init(false);

// Signal cancellation from another thread or timeout watcher:
// cancel.store(true, .release);

var resp = client.post("http://127.0.0.1:8080/upload", .{
    .cancelFlag = &cancel,
    .multipart = .{
        .name = "upload",
        .filename = "data.bin",
        .data = file_bytes,
    },
}) catch |err| switch (err) {
    error.Cancelled => {
        std.debug.print("Upload was cancelled cooperatively\n", .{});
        return;
    },
    else => return err,
};
defer resp.deinit();
```

Using the fluent `RequestBuilder`:

```zig
var builder = client.builder(.POST, "http://127.0.0.1:8080/upload");
defer builder.deinit();

_ = builder.cancelFlag(&cancel);
var resp = try builder.send();
defer resp.deinit();
```

---

## Low-Level Building & Encoding

Use `httpx.multipart.Encoder` to encode parts manually:

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const parts = [_]httpx.multipart.Part{
        .{ .name = "username", .data = "alice" },
        .{
            .name = "avatar",
            .filename = "photo.png",
            .contentType = "image/png",
            .data = @embedFile("avatar.png"),
        },
    };

    var encoder = try httpx.multipart.Encoder.init(allocator, io, .{
        .subtype = .formData,
    });
    defer encoder.deinit();

    const body = try encoder.encodePartsAlloc(&parts);
    defer allocator.free(body);

    var ctBuf: [128]u8 = undefined;
    const contentType = encoder.contentType(&ctBuf);

    std.debug.print("Encoded {d} bytes with Content-Type: {s}\n", .{ body.len, contentType });
}
```

---

## Parsing Multipart Bodies on Server

### Server Context Integration

Inside a router handler, use `ctx.multipartForm`:

```zig
pub fn handleUpload(ctx: *httpx.Context) !httpx.Response {
    var form = try ctx.multipartForm(.{
        .maxMemoryBytes = 16 * 1024 * 1024,
    });
    defer form.deinit();

    if (form.getField("username")) |user| {
        std.debug.print("User: {s}\n", .{user});
    }

    if (form.getFile("avatar")) |file| {
        std.debug.print("Uploaded {s} ({d} bytes)\n", .{ file.filename, file.data.len });
    }

    return ctx.text("Upload received successfully");
}
```

### Manual Parsing with `Decoder`

```zig
const contentType = req.header("content-type") orelse return error.MissingContentType;
const boundary = httpx.multipart.extractBoundary(contentType) orelse return error.InvalidBoundary;

var decoder = try httpx.multipart.Decoder.init(allocator, body_bytes, boundary, .{});
defer decoder.deinit();

while (try decoder.next()) |part| {
    if (part.isFile()) {
        std.debug.print("File: {s} filename={?s}\n", .{ part.name, part.filename });
    } else {
        std.debug.print("Field: {s} = {s}\n", .{ part.name, part.data });
    }
}
```

---

## Streaming Multipart Encoder

For memory-efficient streaming without buffering the full payload in memory:

```zig
var output: std.ArrayList(u8) = .empty;
defer output.deinit(allocator);

var stream = try httpx.multipart.Stream.init(
    &output.writer,
    .formData,
    "custom-upload-boundary",
);

try stream.writeField("description", "streaming payload");

try stream.beginFile("dataset", "records.csv", "text/csv", null);
try stream.writeChunk(csv_header);
try stream.writeChunk(csv_rows);
try stream.endFile();

try stream.finish();
```

---

## Resumable & Chunked Upload Patterns

When uploading multi-gigabyte files over unstable networks, split uploads into discrete chunks and track progress:

```zig
const chunkSize = 64 * 1024; // 64 KB per chunk
var offset: usize = 0;
var partIndex: usize = 1;

while (offset < totalBytes.len) {
    if (cancel.load(.acquire)) return error.Cancelled;

    const end = @min(offset + chunkSize, totalBytes.len);
    const slice = totalBytes[offset..end];

    var partBuf: [32]u8 = undefined;
    const partStr = try std.fmt.bufPrint(&partBuf, "{d}", .{partIndex});

    var resp = try client.post("http://127.0.0.1:8080/upload-resumable", .{
        .cancelFlag = &cancel,
        .multipart = .{
            .fields = &[_]struct { name: []const u8, value: []const u8 }{
                .{ .name = "part", .value = partStr },
            },
            .files = &[_]struct { name: []const u8, filename: []const u8, data: []const u8 }{
                .{ .name = "chunk", .filename = "data.bin", .data = slice },
            },
        },
    });
    defer resp.deinit();

    offset = end;
    partIndex += 1;
}
```

This pattern ensures:
- Safe 64 KB per-send limits across Windows, Linux, and macOS.
- Retries on interrupted individual chunks without re-uploading the entire file.
- Total memory boundedness at the client and server.
