# Multipart Form Data Example

Multipart bodies with `httpx.multipart.encoder`, parsed back with
`httpx.multipart.decoder`. See `examples/multipart.zig`.

```zig
const fields = [_]httpx.multipart.FieldValue{
    .{ .name = "username", .value = "alice" },
};
const files = [_]httpx.multipart.File{
    .{ .name = "avatar", .data = &.{ 0x89, 0x50, 0x4E, 0x47 }, .filename = "avatar.png", .contentType = "image/png" },
};
var encoder = try httpx.multipart.encoder.init(allocator, io, .{
    .subtype = .formData,
    .fields = &fields,
    .files = &files,
});
defer encoder.deinit();

const body = try encoder.encodeAlloc();
defer allocator.free(body);

var ctBuf: [128]u8 = undefined;
const contentType = encoder.contentType(&ctBuf);

// Parse the generated body back.
var decoder = try httpx.multipart.decoder.init(allocator, io, .{});
defer decoder.deinit();
const fields = try decoder.parse(body, contentType);
defer decoder.free(fields);
for (fields) |part| {
    std.debug.print("Part: {s}, Content-Type: {s}, Data Size: {d}\n", .{
        part.name, part.contentType, part.data.len,
    });
}
```

Client requests accept separate field and file slices:

```zig
const fileData = "hello, world!";
const formFields = [_]struct { name: []const u8, value: []const u8 }{
    .{ .name = "description", .value = "hello" },
};
const uploadFiles = [_]struct {
    name: []const u8,
    filename: []const u8,
    contentType: []const u8,
    data: []const u8,
}{
    .{ .name = "upload", .filename = "hello.txt", .contentType = "text/plain", .data = fileData },
};
var res = try client.post("https://example.com/upload", .{
    .multipart = .{
        .fields = &formFields,
        .files = &uploadFiles,
    },
});
defer res.deinit();
```

Boundary extraction: `httpx.multipart.Boundary.extract(contentType)`.

## Expected Output

```text
Part: username, Content-Type: text/plain, Data Size: 5
Part: avatar, Content-Type: image/png, Data Size: 4
```

Part names, content types, and data sizes reflect the fields added to the form; they vary with the encoded payload.

## Run

```bash
zig build run-multipart
```

## What to Verify

- POST returns 200 with a `multipart/form-data; boundary=...` content type.
- Parsed parts round-trip name, content type, and data.
