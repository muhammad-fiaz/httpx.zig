# Multipart Form Data Example

Multipart bodies with `httpx.multipart.encoder.Multipart`, parsed back with
`httpx.multipart.parser`. See `examples/multipart.zig`.

```zig
var form = httpx.multipart.encoder.Multipart.init(allocator);
defer form.deinit();

try form.field("username", "alice");
try form.file("avatar", &.{ 0x89, 0x50, 0x4E, 0x47 }, .{
    .filename = "avatar.png",
    .contentType = "image/png",
});

const body = try form.encodeAlloc();
defer allocator.free(body);

var ctBuf: [128]u8 = undefined;
const contentType = form.contentType(&ctBuf);

// Parse the generated body back.
const fields = try httpx.multipart.parser.parseMultipart(
    allocator, body, form.boundary, .{},
);
defer httpx.multipart.parser.freeFieldsAlloc(allocator, fields);
for (fields) |part| {
    std.debug.print("Part: {s}, Content-Type: {s}, Data Size: {d}\n", .{
        part.name, part.contentType, part.data.len,
    });
}
```

Client requests take a single part inline:

```zig
var res = try client.post("https://example.com/upload", .{
    .multipart = .{
        .name = "upload",
        .filename = "hello.txt",
        .contentType = "text/plain",
        .data = fileData,
    },
});
defer res.deinit();
```

Boundary extraction: `httpx.multipart.parser.extractBoundary(contentType)`.

## Run

```bash
zig build run-multipart
```

## What to Verify

- POST returns 200 with a `multipart/form-data; boundary=...` content type.
- Parsed parts round-trip name, content type, and data.
