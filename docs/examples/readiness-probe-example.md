# Readiness Probe Example

Liveness/readiness probe routes for Kubernetes checks. Register plain
routes (see `examples/health_check.zig`).

```zig
fn healthHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.renderJson(.{ .status = "healthy" });
}

fn readyHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.renderJson(.{ .status = "ready" });
}

try server.get("/healthz", healthHandler);
try server.get("/readyz", readyHandler);
```

`httpx.health.Status` (`.healthy`, `.ready`, ...) renders standard JSON
bodies via `jsonBody()` with matching HTTP status codes.

## Run

```bash
zig build run-health-check
```

## What to Verify

- `GET /healthz` returns 200 (liveness: the process is running).
- `GET /readyz` returns 200 (readiness: ready to accept traffic).
