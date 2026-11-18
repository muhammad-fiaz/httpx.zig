# Health Check Example

Liveness/readiness probe routes for Kubernetes-style checks. Register plain
routes (see `examples/healthCheck.zig`).

```zig
var server = try httpx.Server.init(allocator, io, .{ .port = 0 });
defer server.deinit();

try server.get("/healthz", healthHandler);
try server.get("/readyz", readyHandler);

fn healthHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    return ctx.json(.{ .status = "healthy" });
}

fn readyHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    return ctx.json(.{ .status = "ready" });
}
```

Both routes return JSON with the matching 200 status.

## Expected Output

```text
GET /healthz -> 200 {"status":"healthy"}
GET /readyz -> 200 {"status":"ready"}
```

Bodies follow the format printed by the `healthz`/`readyz` handlers (`{d} {s}` with status code and JSON body). Only the line format above is stable.

## Run

```bash
zig build run-health-check
```
