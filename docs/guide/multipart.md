# Multipart Form Data Guide

`httpx.zig` provides RFC 2046 and RFC 7578 multipart/form-data support for building, streaming,
and parsing form submissions with file attachments across all platforms.

## What Multipart Is

Multipart/form-data is used when HTML forms contain file inputs or when an HTTP client needs to
send both text fields and binary data in the same request. Each part has its own headers
(`Content-Disposition`, `Content-Type`) and is separated by a boundary string.

---

## Client Upload — Zero Boilerplate

Pass `.multipart` directly to any `client.post / put / patch` call.
The `allocator` and `io` are taken from the `Client` you initialised — no need to pass them again.
All configs use `.{}` default values; only override what you need.

### Fields + Files

```zig
var client = httpx.Client.init(allocator, io, .{});
defer client.deinit();

var resp = try client.post("http://localhost:8080/upload", .{
    .multipart = .{
        .fields = .{
            .{ .name = "description", .value = "large upload" },
            .{ .name = "category",    .value = "reports" },
        },
        .files = .{
            .{ .name = "file",  .filename = "data.bin",   .data = bin_bytes },
            .{ .name = "image", .filename = "photo.png",  .data = png_bytes },
            // contentType auto-detected from filename extension when omitted
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
var resp = try client.post("http://localhost:8080/avatar", .{
    .multipart = .{ .name = "avatar", .filename = "photo.png", .data = png_data },
});
defer resp.deinit();
```

### Cooperative Cancellation

Use `.cancel` in any request:

```zig
var cancel = std.atomic.Value(bool).init(false);
// From another thread: cancel.store(true, .release);

var resp = client.post("http://localhost:8080/upload", .{
    .cancel    = &cancel,
    .multipart = .{ .name = "upload", .filename = "data.bin", .data = bytes },
}) catch |err| switch (err) {
    error.Cancelled => return,
    else => return err,
};
defer resp.deinit();
```

---

## Encoder (In-Memory)

`httpx.multipart.encoder` builds a complete multipart body in memory.
The `allocator` and `io` are stored internally after `init`.

```zig
var encoder = try httpx.multipart.encoder.init(allocator, io, .{
    .subtype  = .formData,
    .boundary = null,       // auto-generated
    .fields   = .{
        .{ .name = "username", .value = "alice" },
    },
    .files = .{
        .{ .name = "avatar", .filename = "photo.png", .data = png_bytes },
    },
});
defer encoder.deinit();

const body = try encoder.encodeAlloc();
defer allocator.free(body);

var ctBuf: [128]u8 = undefined;
const contentType = encoder.contentType(&ctBuf);
// e.g. "multipart/form-data; boundary=\"abc123\""
```

---

## Streaming Encoder

For memory-efficient uploads without buffering the full payload:

```zig
var output: std.ArrayList(u8) = .empty;
defer output.deinit(allocator);

var stream = try httpx.multipart.encoder.stream(&output.writer, .{
    .subtype = .formData,
    .boundary = "my-boundary",
});

try stream.beginPart("dataset", .{ .filename = "records.csv", .contentType = "text/csv" });
try stream.write(csv_header);
try stream.write(csv_rows);
try stream.endPart();

try stream.finish();
```

---

## Server-Side Parsing - `ctx.multipart`

Inside a router handler, parse an incoming `multipart/form-data` body:

```zig
pub fn handleUpload(ctx: *httpx.Context) !httpx.Response {
    var form = try ctx.multipart(.{
        .maxMemoryBytes = 16 * 1024 * 1024, // optional — defaults to 32 MB
    });
    defer form.deinit();

    if (form.getField("username")) |user| {
        std.debug.print("User: {s}\n", .{user});
    }
    if (form.getFile("avatar")) |file| {
        std.debug.print("Uploaded: {s} ({d} bytes)\n", .{ file.filename.?, file.data.len });
    }

    return ctx.text("Upload received");
}
```

> [!TIP]
> `ctx.multipart(.{})` works with no config - all limits have safe production defaults.

---

## Boundary Utilities

```zig
const ct = req.header("content-type") orelse return error.MissingContentType;

// Extract boundary from Content-Type header
const bnd = httpx.multipart.Boundary.extract(ct)
    orelse return error.InvalidBoundary;

// Detect the subtype ("form-data", "mixed", ...)
const sub = httpx.multipart.Boundary.subtype(ct);

// Validate a custom boundary
if (!httpx.multipart.Boundary.validate("my-custom-boundary")) return error.BadBoundary;

// Generate a unique boundary
var buf: [32]u8 = undefined;
const generated = httpx.multipart.Boundary.generate(&buf);
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
        .cancel  = &cancel,
        .headers = &.{ .{ .name = "Content-Range", .value = rangeHeader } },
        .multipart = .{
            .fields = .{ .{ .name = "part", .value = "1" } },
            .files  = .{ .{ .name = "chunk", .filename = "data.bin", .data = total_bytes[offset..end] } },
        },
    });
    defer resp.deinit();

    if (resp.status == 200 or resp.status == 308) offset = end
    else return error.UploadFailed;
}
```

Guarantees:
- Bounded 64 KB per-send across Windows, Linux, macOS
- Retries individual chunks without re-uploading the whole file
- Memory-bounded at both client and server
