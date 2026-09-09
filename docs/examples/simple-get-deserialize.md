# Simple Get Deserialize

Parse JSON responses into typed Zig structs with `Response.json(T)`.
See `examples/post_json.zig`.

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

## Run

```bash
zig build run-post-json
```

## What to Verify

- GET returns 200 with a JSON body.
- Typed decoding succeeds and ignores unknown fields.
