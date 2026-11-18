# Readiness Probe Example

Liveness/readiness probe routes for Kubernetes checks. Register plain
routes (see `examples/healthCheck.zig`).

```zig
fn healthHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    return ctx.json(.{ .status = "healthy" });
}

fn readyHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    return ctx.json(.{ .status = "ready" });
}

try server.get("/health", .{ .handler = healthHandler });
try server.get("/ready", .{ .handler = readyHandler });
```

Both routes return JSON with the matching 200 status.

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
