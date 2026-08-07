# HTTP Methods

Demonstrates all standard HTTP methods (GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS, TRACE, CONNECT), their properties, string parsing, and client usage.

## Demo Program

```zig
// Method properties
const m = httpx.Method.POST;
m.isIdempotent();   // false
m.isSafe();         // false
m.hasRequestBody(); // true
m.hasResponseBody(); // true

// Parse from string
const method = httpx.Method.fromString("DELETE"); // .DELETE

// Register server routes for each method
try server.get("/resource", handler);
try server.post("/resource", handler);
try server.put("/resource", handler);
try server.patch("/resource", handler);
try server.delete("/resource", handler);

// Client requests
var resp = try client.get(url, .{});
var resp = try client.post(url, .{ .body = "create" });
var resp = try client.put(url, .{ .body = "update" });
var resp = try client.patch(url, .{ .body = "patch" });
var resp = try client.delete(url, .{});
var resp = try client.head(url, .{});
var resp = try client.options(url, .{});
```

## Run

```
zig build example-http-methods
```

## Checklist

- [x] All 9 methods print their properties (idempotent, safe, hasBody, hasResponse)
- [x] Method parsing handles standard and unknown methods
- [x] Server accepts GET, POST, PUT, PATCH, DELETE routes
- [x] Client sends each method and prints status code
- [x] HEAD and OPTIONS requests complete successfully
- [x] Convenience function summary prints at the end
