# Health Check Middleware Example

Demonstrates using built-in health check and readiness probe middleware components in `httpx.zig` to support Kubernetes-style liveness/readiness probes.

## Features Covered

- **Liveness Probes**: Minimal health check endpoints responding with configured status code and JSON.
- **Readiness Probes**: Configurable readiness checks to identify database/cache availability before serving traffic.
- **Middleware Integration**: Stacking probes alongside logger, CORS, or other route handlers.

## Code Example

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = httpx.Server.init(allocator);
    defer server.deinit();

    // Register health check middleware
    try server.use(httpx.middleware.healthCheck(.{
        .path = "/health",
        .body = "{\"status\":\"ok\"}",
        .status = 200,
    }));

    // Register readiness probe middleware
    try server.use(httpx.middleware.readinessProbe(.{
        .path = "/ready",
        .body = "{\"ready\":true,\"db\":true}",
    }));

    const thread = try server.listenInBackground();
    defer thread.join();
    defer server.stop();
}
```

## Running the Example

Run the pre-configured health check example:

```bash
zig build run-all-health_check_example
```
