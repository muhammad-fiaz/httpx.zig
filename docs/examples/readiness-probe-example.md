# Readiness Probe Example

Liveness/readiness probe routes for Kubernetes checks. Register plain
routes (see `examples/healthCheck.zig`).

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

## Expected Output

When run via the health-check target, the output follows that program's print format:

```text
endpoints on 127.0.0.1:54321
GET /healthz -> 200 {"status":"healthy"}
GET /readyz -> 200 {"status":"ready"}
```

The port number varies per run; the JSON bodies match the registered probe handlers.

## Run

```bash
zig build run-health-check
```

## What to Verify

- `GET /healthz` returns 200 (liveness: the process is running).
- `GET /readyz` returns 200 (readiness: ready to accept traffic).
