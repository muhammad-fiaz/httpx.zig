# Health Check Example

Liveness/readiness probe routes for Kubernetes-style checks. Register plain
routes (see `examples/healthCheck.zig`).

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

## What to Verify

- `GET /healthz` returns 200 `{"status":"healthy"}`.
- `GET /readyz` returns 200 `{"status":"ready"}`.
