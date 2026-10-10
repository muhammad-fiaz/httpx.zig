# Simple Get Deserialize

Parse JSON responses into typed Zig structs with `Response.json(T)`.
See `examples/postJson.zig`.

```zig
const User = struct { id: u64, name: []const u8, email: []const u8 };

var res = try client.get("https://httpbun.com/get", .{});
defer res.deinit();

// Decode into a struct (unknown fields are ignored).
const user = try res.json(User);

// Or keep the parsed DOM with an explicit allocator.
const parsed = try res.jsonAlloc(User, allocator);
defer parsed.deinit();
```

## Expected Output

The snippet itself prints nothing; `examples/postJson.zig` (which posts the
typed struct and echoes it back) prints lines in this format
(representative values shown):

```text
Status: 200
Body: {"name":"Alice","role":"developer"}
```

Status codes and bodies vary with the target URL and payload.

## Run

```bash
zig build run-post-json
```

## What to Verify

- GET returns 200 with a JSON body.
- Typed decoding succeeds and ignores unknown fields.
