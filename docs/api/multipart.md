---
title: Multipart API Reference
description: API documentation for RFC 2046 and RFC 7578 multipart/form-data encoding, streaming, decoding, and client upload options in httpx.zig.
---

# Multipart API Reference

`httpx.zig` provides RFC 2046 and RFC 7578 compliant multipart/form-data encoding, streaming, and
decoding under the `httpx.multipart` namespace and via zero-boilerplate client options.

## Namespace Overview

```zig
const httpx = @import("httpx");

// Core buffered encoder and decoder
const encoder = httpx.multipart.encoder;
const decoder = httpx.multipart.decoder;

// Boundary utilities
const Boundary = httpx.multipart.Boundary;

// Data types returned by the server-side parser
const Field = httpx.multipart.Field;
const File  = httpx.multipart.File;
```

---

## Client-Side Upload — `.multipart` Option

Pass `.multipart` to any `client.post / put / patch / request` call.
All options work with `.{}` default configs; only override what you need.
The `allocator` and `io` are taken from the `Client` you initialised — no need to pass them again.

### Fields + Files

```zig
var client = httpx.Client.init(allocator, io, .{});
defer client.deinit();

var resp = try client.post("http://localhost:8080/upload", .{
    .multipart = .{
        .fields = .{
            .{ .name = "description", .value = "large upload" },
            .{ .name = "environment", .value = "production" },
        },
        .files = .{
            .{ .name = "file", .filename = "data.bin", .data = bytes },
            // contentType auto-detected from filename extension when omitted
            .{ .name = "image", .filename = "photo.png", .data = png_bytes },
        },
    },
});
defer resp.deinit();
```

### Generic Parts (full control)

```zig
var resp = try client.post("http://localhost:8080/ingest", .{
    .multipart = .{
        .parts = .{
            .{ .name = "meta",   .data = json_meta, .contentType = "application/json" },
            .{ .name = "binary", .data = bin_data,  .filename = "out.bin" },
        },
    },
});
defer resp.deinit();
```

### Single-File Shorthand

```zig
// All fields directly on .multipart
var resp = try client.post("http://localhost:8080/avatar", .{
    .multipart = .{ .name = "avatar", .filename = "photo.png", .data = png_bytes },
});
defer resp.deinit();
```

### Cooperative Cancellation

```zig
var cancel = std.atomic.Value(bool).init(false);
// From another thread: cancel.store(true, .release);

var resp = client.post("http://localhost:8080/upload", .{
    .cancel    = &cancel,
    .multipart = .{ .name = "payload", .filename = "archive.tar.gz", .data = bytes },
}) catch |err| switch (err) {
    error.Cancelled => return,
    else => return err,
};
defer resp.deinit();
```

---

## Encoder

`httpx.multipart.encoder` builds a complete multipart body in memory.
Initialise once; `allocator` and `io` are stored internally.

```zig
var encoder = try httpx.multipart.encoder.init(allocator, io, .{
    .subtype  = .formData, // default
    .boundary = null,      // auto-generated
    .fields   = .{
        .{ .name = "description", .value = "hello" },
    },
    .files = .{
        .{ .name = "data", .filename = "out.bin", .data = bytes },
    },
});
defer encoder.deinit();

const body = try encoder.encodeAlloc(); // allocates; caller frees
defer allocator.free(body);

var ctBuf: [160]u8 = undefined;
const contentType = encoder.contentType(&ctBuf);
// e.g. "multipart/form-data; boundary=\"abc123\""
```

---

## Streaming Encoder

Memory-bounded chunked streaming — no need to buffer the full body:

```zig
var output: std.ArrayList(u8) = .empty;
defer output.deinit(allocator);

var stream = try httpx.multipart.encoder.stream(&output.writer, .{
    .subtype = .formData,
    .boundary = "my-boundary",
});

try stream.beginPart("upload", .{ .filename = "archive.zip", .contentType = "application/zip" });
try stream.write(chunk1);
try stream.write(chunk2);
try stream.endPart();

try stream.finish();
```

---

## Server-Side - `ctx.multipart`

Inside a route handler parse an incoming multipart body:

```zig
pub fn handleUpload(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    var form = try ctx.multipart(.{
        .maxMemoryBytes = 16 * 1024 * 1024, // optional — defaults to 32 MB
    });
    defer form.deinit();

    if (form.getField("username")) |user| {
        std.debug.print("User: {s}\n", .{user});
    }
    if (form.getFile("avatar")) |file| {
        std.debug.print("Uploaded {s} ({d} bytes)\n", .{ file.filename.?, file.data.len });
    }

    return ctx.text("Upload received");
}
```

---

## Decoder

Parse a raw multipart body manually (outside a route handler):

```zig
const ct  = req.header("content-type") orelse return error.MissingContentType;

var decoder = try httpx.multipart.decoder.init(allocator, io, .{});
defer decoder.deinit();

const fields = try decoder.parse(body_bytes, ct);
defer decoder.free(fields);
for (fields) |part| {
    if (part.filename != null) {
        std.debug.print("File: {s} ({d} bytes)\n", .{ part.name, part.data.len });
    } else {
        std.debug.print("Field: {s} = {s}\n", .{ part.name, part.data });
    }
}
```

---

## Boundary Utilities

All boundary helpers live under `httpx.multipart.Boundary`:

| Function | Description |
|---|---|
| `Boundary.extract(contentType)` | Extract boundary from `Content-Type` header value |
| `Boundary.subtype(contentType)` | Detect multipart subtype (`"form-data"`, `"mixed"`, …) |
| `Boundary.validate(boundary)` | Validate a boundary per RFC 2046 §5.1.1 |
| `Boundary.generate(&buf)` | Generate a unique 32-char hex boundary |

```zig
const ct  = req.header("content-type") orelse return error.MissingContentType;
const bnd = httpx.multipart.Boundary.extract(ct) orelse return error.InvalidBoundary;
const sub = httpx.multipart.Boundary.subtype(ct); // "form-data", "mixed", ...
```

---

## Resumable Chunked Upload

```zig
const chunkSize: usize = 64 * 1024;
var offset: usize = 0;

while (offset < total_bytes.len) {
    if (cancel.load(.acquire)) return error.Cancelled;
    const end = @min(offset + chunkSize, total_bytes.len);

    var rangeBuf: [64]u8 = undefined;
    const rangeHeader = try std.fmt.bufPrint(
        &rangeBuf, "bytes {d}-{d}/{d}", .{ offset, end - 1, total_bytes.len },
    );

    var resp = try client.post("http://localhost:8080/upload-resumable", .{
        .cancel = &cancel,
        .headers = .{ .@"Content-Range" = rangeHeader },
        .multipart = .{
            .fields = &.{.{ .name = "part", .value = "1" }},
            .files = &.{.{ .name = "chunk", .filename = "data.bin", .data = total_bytes[offset..end] }},
        },
    });
    defer resp.deinit();

    if (resp.status == 200 or resp.status == 308) offset = end
    else return error.UploadFailed;
}
```

---

## Limits (server-side)

All fields have safe production defaults — `.{}` works out of the box:

```zig
pub const Limits = struct {
    maxMemoryBytes: usize = 32 * 1024 * 1024, // 32 MB
    maxFields: usize = 1_000,
    maxFiles: usize = 100,
    maxHeaderBytes: usize = 64 * 1024,
    maxBoundaryBytes: usize = 128,
};
```
