---
title: Multipart API Reference
description: API documentation for RFC 2046 and RFC 7578 multipart/form-data encoding, streaming, decoding, and client upload options in httpx.zig.
---

# Multipart API Reference

`httpx.zig` provides a comprehensive, RFC 2046 and RFC 7578 compliant multipart/form-data encoding, streaming, and decoding subsystem under the `httpx.multipart` namespace and via built-in client options.

## Namespace Overview

Access all multipart primitives through `httpx.multipart`:

```zig
const httpx = @import("httpx");

// Core Encoders & Decoders
const Encoder = httpx.multipart.Encoder;
const Decoder = httpx.multipart.Decoder;
const Stream = httpx.multipart.Stream;
const extractBoundary = httpx.multipart.extractBoundary;

// Data Models
const Part = httpx.multipart.Part;
const Field = httpx.multipart.Field;
const File = httpx.multipart.File;
const FieldValue = httpx.multipart.FieldValue;
const Subtype = httpx.multipart.Subtype;
const Limits = httpx.multipart.Limits;
```

---

## Client-Side Upload Options

`httpx.Client` provides native, zero-boilerplate multipart uploads via the `.multipart` configuration option in `post`, `put`, `patch`, and `request`.

### 1. Anonymous Struct File & Field Slices

```zig
const fields = [_]struct { name: []const u8, value: []const u8 }{
    .{ .name = "description", .value = "large upload" },
    .{ .name = "environment", .value = "production" },
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
        .contentType = "application/octet-stream", // Optional; auto-detected if omitted or null
        .data = large_bytes,
    },
};

var resp = try client.post("http://127.0.0.1:8080/upload", .{
    .multipart = .{
        .fields = &fields,
        .files = &files,
    },
});
defer resp.deinit();
```

### 2. Single-File Upload Convenience

When uploading a single file, pass the struct directly without wrapping in a slice:

```zig
var resp = try client.post("http://127.0.0.1:8080/upload-avatar", .{
    .multipart = .{
        .name = "avatar",
        .filename = "profile.png", // Content-Type automatically detected as "image/png"
        .data = png_bytes,
    },
});
defer resp.deinit();
```

Or nested under `.file`:

```zig
var resp = try client.post("http://127.0.0.1:8080/upload-doc", .{
    .multipart = .{
        .file = .{
            .name = "document",
            .filename = "contract.pdf", // Auto-detected as "application/pdf"
            .data = pdf_bytes,
        },
    },
});
defer resp.deinit();
```

### 3. Cooperative Request Cancellation

All HTTP client requests, including large multipart transfers, support cooperative cancellation via `cancelFlag: ?*const std.atomic.Value(bool)`.

```zig
var cancel = std.atomic.Value(bool).init(false);

// Signal cancellation from another thread, signal handler, or timeout loop:
// cancel.store(true, .release);

var resp = client.post("http://127.0.0.1:8080/upload", .{
    .cancelFlag = &cancel,
    .multipart = .{
        .name = "payload",
        .filename = "archive.tar.gz",
        .data = archive_bytes,
    },
}) catch |err| switch (err) {
    error.Cancelled => {
        // Request connection, transmission, or reading was cancelled cleanly
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

## Core Types

### `httpx.multipart.Part`

Represents an individual multipart element for encoding:

```zig
pub const Part = struct {
    name: []const u8,
    data: []const u8,
    filename: ?[]const u8 = null,
    contentType: ?[]const u8 = null,
    headers: ?[]const Header = null,
};
```

### `httpx.multipart.Field` & `httpx.multipart.File`

Used for parsed forms:

```zig
pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

pub const File = struct {
    name: []const u8,
    filename: []const u8,
    contentType: []const u8,
    data: []const u8,
    tempPath: ?[]const u8 = null,
};
```

### `httpx.multipart.Subtype`

```zig
pub const Subtype = enum {
    formData,
    mixed,
    related,
    alternative,
    parallel,
    digest,
};
```

### `httpx.multipart.Limits`

Controls buffer boundaries and denial-of-service limits:

```zig
pub const Limits = struct {
    maxMemoryBytes: usize = 32 * 1024 * 1024,
    maxFields: usize = 1_000,
    maxFiles: usize = 100,
    maxHeaderBytes: usize = 64 * 1024,
    maxBoundaryBytes: usize = 128,
};
```

---

## Streaming Encoder API

The `httpx.multipart.Stream` encoder allows writing chunked or direct streams into any writer with bounded memory.

```zig
const Stream = httpx.multipart.Stream;

var output: std.ArrayList(u8) = .empty;
defer output.deinit(allocator);

var stream = try Stream.init(
    &output.writer,
    .formData,
    "unique-boundary-marker",
);

// Stream a text field
try stream.writeField("username", "alice");

// Stream a file part
try stream.beginFile("upload", "archive.zip", "application/zip", null);
try stream.writeChunk(chunk1);
try stream.writeChunk(chunk2);
try stream.endFile();

// Finalize multipart envelope
try stream.finish();
```

---

## Decoder API

### In-Memory Decoding

Parse an encoded multipart body:

```zig
const Decoder = httpx.multipart.Decoder;

var decoder = try Decoder.init(allocator, body_bytes, boundary, .{});
defer decoder.deinit();

while (try decoder.next()) |part| {
    if (part.isFile()) {
        std.debug.print("File: {s} (filename={?s}, type={s}, len={d})\n", .{
            part.name,
            part.filename,
            part.contentType,
            part.data.len,
        });
    } else {
        std.debug.print("Field: {s} = {s}\n", .{ part.name, part.data });
    }
}
```

### Extracting Boundaries

Extract the boundary parameter from a `Content-Type` header:

```zig
if (httpx.multipart.extractBoundary(req.header("content-type").?)) |boundary| {
    // boundary is now available
}
```

---

## Resumable & Chunked Upload Patterns

For very large uploads where network interruptions can occur, combine streaming uploads with HTTP Range headers:

```zig
// In a chunked resumable upload loop:
var offset: u64 = resumeOffset;
while (offset < totalSize) {
    if (cancelFlag.load(.acquire)) return error.Cancelled;

    const chunkLen = @min(chunkSize, totalSize - offset);
    const chunkData = fileData[offset .. offset + chunkLen];

    var rangeBuf: [64]u8 = undefined;
    const rangeHeader = try std.fmt.bufPrint(&rangeBuf, "bytes {d}-{d}/{d}", .{
        offset,
        offset + chunkLen - 1,
        totalSize,
    });

    var resp = try client.post("http://127.0.0.1:8080/upload-resumable", .{
        .cancelFlag = &cancelFlag,
        .headers = &.{
            .{ .name = "Content-Range", .value = rangeHeader },
        },
        .multipart = .{
            .name = "chunk",
            .filename = "large_dataset.bin",
            .data = chunkData,
        },
    });
    defer resp.deinit();

    if (resp.status == 200 or resp.status == 201 or resp.status == 308) {
        offset += chunkLen;
    } else {
        return error.UploadFailed;
    }
}
```

