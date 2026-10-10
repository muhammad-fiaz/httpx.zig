# JSON API Example

Typed JSON over the URL-first client: fetch with `client.fetch`, decode with
`Response.json(T)` or `Response.jsonAlloc(T, allocator)`. See
`examples/postJson.zig`.

```zig
const Posted = struct { name: []const u8, role: []const u8 };

var post = try client.fetch("https://httpbun.com/post", .{
    .method = .POST,
    .json = .{ .name = "Alice", .role = "admin" },
});
defer post.deinit();

// httpbun echoes our JSON under the "json" envelope key.
const Echo = struct { json: ?Posted = null };
const echo = try post.json(Echo);
if (echo.json) |back| std.debug.print("name={s} role={s}\n", .{ back.name, back.role });
```

Server side, parse request bodies with `ctx.json(T)` and render with
`ctx.renderJson(value)`.

## Expected Output

```text
name=Alice role=admin
```

The printed values reflect whatever JSON the server echoes back; names, roles, and ordering vary with the request payload and server response.

## Run

```bash
zig build run-post-json
```

## What to Verify

- POST returns 200 with the echoed JSON body.
- Typed decoding ignores unknown fields.
