# Cloud HTTPS Server Example

Demonstrates setting up a production-ready HTTP server for cloud deployment with TLS configuration, middleware stacking, health checks, and self-verification. Designed to run behind a TLS-terminating reverse proxy (e.g., Nginx, AWS ALB).

## Features Covered

- **Server Configuration**: HTTP/1.1 + HTTP/2, multi-threaded accept loop, connection limits.
- **Middleware Stack**: CORS, health-check (`/health`), readiness probe (`/ready`), and request logging.
- **Route Registration**: Path parameters, JSON responses, and 404 fallback handlers.
- **Self-Test**: Automatically verifies all endpoints after startup.
- **Cloud Deployment Tips**: Security groups, TLS certs, process management, and observability guidance.

## Code Example

```zig
const std = @import("std");
const httpx = @import("httpx");

fn indexHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.json(.{
        .status = "ok",
        .service = "cloud-https-api",
        .version = "1.0.0",
    });
}

fn healthHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.json(.{ .status = "healthy" });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = 8080,
        .port_conflict = .increment,
        .max_connections = 10000,
        .threads = 4,
        .http2_enabled = true,
        .http3_enabled = false,
        .tls_alpn_protocols = &.{ "h3", "h2", "http/1.1" },
        .keep_alive = true,
        .request_timeout_ms = 30_000,
        .keep_alive_timeout_ms = 60_000,
    });
    defer server.deinit();

    try server.use(httpx.middleware.cors(.{
        .allowed_origins = &.{"*"},
        .allowed_methods = &.{ "GET", "POST", "OPTIONS" },
        .allowed_headers = &.{ "Content-Type", "Authorization" },
        .max_age_seconds = 3600,
    }));

    try server.use(httpx.middleware.healthCheck(.{
        .path = "/health",
        .body = "{\"status\":\"ok\"}",
        .status = 200,
    }));

    try server.use(httpx.middleware.readinessProbe(.{
        .path = "/ready",
        .body = "{\"ready\":true}",
    }));

    try server.use(httpx.middleware.logger());

    try server.get("/", indexHandler);

    const thread = try server.listenInBackground();
    defer thread.join();
    defer server.stop();
}
```

## Running the Example

```bash
zig build run-all-cloud_https_server
```

## Cloud Deployment Notes

- **TLS Termination**: In production, TLS is typically terminated at the load balancer or reverse proxy (Nginx, HAProxy, AWS ALB). This server runs plain HTTP behind the proxy.
- **Security Groups**: Allow inbound TCP 443 from 0.0.0.0/0 (public) and internal traffic on the backend port (e.g., 8080).
- **TLS Certs**: Use Certbot / Let's Encrypt or a cloud LB with ACM for TLS termination.
- **Health Checks**: Configure the LB to hit `/health` (liveness) and `/ready` (readiness).
- **Process Management**: Run under systemd (`Restart=always`) or a container orchestrator (Kubernetes, Nomad, ECS).
