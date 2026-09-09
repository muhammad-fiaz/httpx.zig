# HTTP Methods

All standard HTTP methods over the URL-first client (`GET`, `POST`, `PUT`,
`PATCH`, `DELETE`, `HEAD`, `OPTIONS`, `TRACE`, `CONNECT`).

## Method Properties

```zig
const m = httpx.Method.POST;
m.isIdempotent(); // false
m.isSafe();       // false
m.hasBody();      // true

// Parse from string
const method = httpx.Method.fromString("DELETE"); // .DELETE
```

## Server Routes and Client Requests

```zig
try server.get("/resource", handler);
try server.post("/resource", handler);
try server.put("/resource", handler);
try server.patch("/resource", handler);
try server.delete("/resource", handler);
try server.head("/resource", handler);
try server.options("/resource", handler);

var get = try client.get(url, .{});
defer get.deinit();
var post = try client.post(url, .{ .body = "create" });
defer post.deinit();
var head = try client.head(url, .{});
defer head.deinit();
var opts = try client.options(url, .{});
defer opts.deinit();
```

`Method.toString()` renders the wire token; `fromString` returns `null` for
unknown methods.
