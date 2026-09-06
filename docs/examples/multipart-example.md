# Multipart Form Data Example

Demonstrates how to use the built-in multipart/form-data encoding and parsing support (`RFC 2046`) in `httpx.zig`.

## Features Covered

- **Multipart Body Builder**: Appending normal text fields and uploading files with custom file names and mime-types.
- **Boundary Extraction**: Reading boundaries cleanly from incoming `Content-Type` headers (handles quoted boundaries and boundary extraction edge cases).
- **Multipart Payload Parser**: Decoding raw multipart payloads back into distinct structured parts.
- **Request Integration**: Building and attaching multipart payloads to client HTTP requests.

## Code Example

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const boundary = "----httpxBoundary7MA4YWxkTrZu0gW";
    var builder = httpx.MultipartBuilder.init(allocator, boundary);
    defer builder.deinit();

    // Add fields and files
    try builder.addField("username", "alice");
    try builder.addFile("avatar", "avatar.png", "image/png", &.{ 0x89, 0x50, 0x4E, 0x47 });

    const body = try builder.build();
    defer allocator.free(body);

    const ct = try builder.contentType();
    defer allocator.free(ct);

    // Parse the generated body back
    var parsed = try httpx.multipart.parse(allocator, body, boundary);
    defer parsed.deinit();

    for (parsed.parts) |part| {
        std.debug.print("Part: {s}, Content-Type: {s}, Data Size: {d}\n", .{
            part.name, part.content_type, part.data.len,
        });
    }

    // Client-side RequestOptions Integration
    var client = httpx.Client.init(allocator);
    defer client.deinit();

    const fields = [_]httpx.MultipartField{
        .{ .name = "user", .value = "bob" },
    };
    const files = [_]httpx.MultipartFile{
        .{ .name = "attachment", .filename = "resume.html", .data = "resumedata" },
    };

    const reqOpts = httpx.RequestOptions.defaults()
        .withMultipartFields(&fields)
        .withMultipartFiles(&files)
        .withMultipartBoundary("clientBoundary999");
}
```

## Running the Example

Run the pre-configured multipart example:

```bash
zig build run-all-multipart_example
```
