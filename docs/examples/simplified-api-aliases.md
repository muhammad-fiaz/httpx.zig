# Explicit Client Request Methods

Use one explicitly initialized client to share its connection pool across
requests. See `examples/simpleGet.zig`.

```zig
var res = try client.get("https://httpbun.com/get", .{});
defer res.deinit();

var post = try client.post("https://httpbun.com/post", .{
    .json = .{ .name = "Alice" },
});
defer post.deinit();

var del = try client.delete("https://httpbun.com/delete", .{});
defer del.deinit();
```

Available methods include `fetch`, `get`, `post`, `put`, `patch`, `delete`,
`head`, `options`, `trace`, `connect`, `request`, `getAll` and `requestAll`.
Downloads, GraphQL, connectivity and DNS are also methods on the client.

## Expected Output

The helpers print nothing themselves; `examples/simpleGet.zig` prints
lines in this format (representative values shown):

```text
Status: 200
Body: {"args":{},"headers":{"Host":"httpbun.com"},"url":"https://httpbun.com/get"}
```

Status codes and bodies vary with the target URL and verb.

## Run

```bash
zig build run-simple-get
```

## What to Verify

- Each verb returns the expected status and body.
