# Simplified API Aliases

Concise top-level helpers mirror the client methods, URL-first with no
allocator needed. See `examples/simple_get.zig`.

```zig
var res = try httpx.get("https://httpbun.com/get", .{});
defer res.deinit();

var post = try httpx.post("https://httpbun.com/post", .{
    .json = .{ .name = "Alice" },
});
defer post.deinit();

var del = try httpx.delete("https://httpbun.com/delete", .{});
defer del.deinit();
```

Available verbs: `fetch`, `get`, `post`, `put`, `patch`, `delete`, `head`,
`options`, `trace`, `connect`, `request`, plus `getAll` / `requestAll` for
batches and `isOnline` / `checkConnectivity` probes. Downloads, GraphQL,
and DNS live on the client namespace (`client.download`,
`client.graphql`, `client.resolve`, `client.resolveUrl`).

## Run

```bash
zig build run-simple-get
```

## What to Verify

- Each verb returns the expected status and body.
