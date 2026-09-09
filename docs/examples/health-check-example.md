# Health Check Example

Liveness/readiness probe routes for Kubernetes-style checks. Register plain
routes (see `examples/health_check.zig`).

```zig
var server = try httpx.Server.init(allocator, io, .{ .port = 0 });
defer server.deinit();

try server.get("/healthz", healthHandler);
try server.get("/readyz", readyHandler);

fn healthHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.renderJson(.{ .status = "healthy" });
}

fn readyHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.renderJson(.{ .status = "ready" });
}
```

`httpx.health.Status` (`.healthy`, `.ready`, ...) renders standard JSON
bodies via `jsonBody()` with matching HTTP status codes.

## Run

```bash
zig build run-health-check
```

## What to Verify

- `GET /healthz` returns 200 `{"status":"healthy"}`.
- `GET /readyz` returns 200 `{"status":"ready"}`.
