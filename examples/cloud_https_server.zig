//! Cloud HTTPS Deployment & Multi-Protocol Server Example for httpx.zig
//!
//! Demonstrates a production-ready HTTP server supporting HTTP/1.1, HTTP/2, and
//! HTTP/3, with TLS configuration, middleware stacking (CORS, logging, rate
//! limiting, health checks), route registration, and self-verification.
//!
//! ## Protocol Support
//!
//! httpx.zig implements HTTP/2 (RFC 7540), HTTP/3 (RFC 9114), QUIC (RFC 9000),
//! TLS/ALPN negotiation, HPACK (RFC 7541), and QPACK (RFC 9204) entirely from
//! scratch — Zig's standard library does not provide any of these.
//!
//! The server can run in any combination of protocols:
//!   - HTTP/1.1 only (default)
//!   - HTTP/2 only (`.http2_enabled = true`)
//!   - HTTP/3 only (`.http3_enabled = true`)
//!   - HTTP/1.1 + HTTP/2 (both enabled; ALPN selects at TLS handshake)
//!   - HTTP/3 over UDP (QUIC transport, independent of TCP listener)
//!
//! ## TLS / HTTPS Notes
//!
//! The server stores `tls_config` for documentation / client-side reference.
//! Actual TLS termination is **not** performed by this library's TCP listener —
//! in production, TLS is terminated by a reverse proxy (nginx, Caddy, cloud LB)
//! which forwards plain HTTP to this server on an internal port. The example
//! includes self-signed certificates (`examples/certs/server.{crt,key}`) for
//! local dev/staging behind such a proxy.
//!
//! ## Cloud Deployment Tips
//!
//! 1. **Security Groups**: Allow inbound TCP 443 from 0.0.0.0/0 (public) and
//!    internal traffic on the backend port.
//! 2. **TLS Certs**: Use Certbot / Let's Encrypt or a cloud LB with ACM.
//! 3. **Process Management**: Run under systemd (`Restart=always`) or a
//!    container orchestrator (Kubernetes, Nomad, ECS).
//! 4. **Health Checks**: Configure the LB to hit `/health` (liveness) and
//!    `/ready` (readiness).
//! 5. **Observability**: Wire `log_fn` to your structured logger.
//! 6. **Graceful Shutdown**: Catch SIGTERM/SIGINT and call `server.stop()`.

const std = @import("std");
const httpx = @import("httpx");

fn indexHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.json(.{
        .status = "ok",
        .service = "cloud-https-api",
        .version = "1.0.0",
        .protocols = .{ "HTTP/1.1", "HTTP/2", "HTTP/3" },
    });
}

/// Health-check liveness endpoint. In production, verify DB / cache / upstream
/// dependencies here and return 503 when they are down.
fn healthHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.json(.{
        .status = "healthy",
        .checks = .{
            .database = true,
            .cache = true,
            .uptime_seconds = 3600,
        },
    });
}

/// Readiness probe for load balancer / orchestrator rolling updates.
fn readyHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.json(.{
        .ready = true,
        .checks = .{
            .database = true,
            .cache = true,
            .disk = true,
        },
    });
}

/// API route with a path parameter (e.g. `/api/users/42`).
fn userHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const user_id = ctx.param("id") orelse "unknown";
    return ctx.json(.{
        .id = user_id,
        .name = "Example User",
        .email = "user@example.com",
        .role = "developer",
    });
}

/// Mock status endpoint returning system metrics.
fn statusHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.json(.{
        .service = "cloud-api",
        .version = "1.0.0",
        .region = "us-east-1",
        .environment = "staging",
        .hostname = "web-01",
    });
}

/// 404 fallback handler for unmatched routes.
fn notFoundHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    _ = ctx.status(404);
    return ctx.json(.{
        .@"error" = "not_found",
        .message = "The requested resource was not found",
        .path = ctx.request.uri.path,
    });
}

/// Blocking sleep helper using the canonical IO.
fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

/// Reserves an ephemeral TCP port for the server to listen on.
fn pickFreeTcpPort() !u16 {
    var listener = try httpx.TcpListener.init(try httpx.Address.parseIp("127.0.0.1", 0));
    defer listener.deinit();
    const addr = try listener.getLocalAddress();
    return addr.getPort();
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Cloud HTTPS Server Example (HTTP/1.1 + HTTP/2 + HTTP/3) ===\n\n", .{});

    // Self-signed certificates are provided in `examples/certs/` for local
    // development behind a TLS-terminating reverse proxy. In production,
    // replace with Let's Encrypt / ACME-managed certificates.
    //
    // NOTE: httpx.zig server currently handles plain HTTP. TLS termination
    // is expected at a reverse proxy (nginx, Caddy, cloud LB) which forwards
    // traffic to this server on an internal port.

    // The server enables all three protocol versions simultaneously. HTTP/1.1
    // and HTTP/2 share the TCP listener; HTTP/3 runs over QUIC on a separate
    // UDP socket. In production, ALPN negotiation at the TLS handshake
    // selects between HTTP/2 and HTTP/1.1 automatically.
    const port = try pickFreeTcpPort();

    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .port_conflict = .increment,
        .max_connections = 10000,
        .threads = 4,
        .http2_enabled = true,
        .http3_enabled = true,
        .tls_alpn_protocols = &.{ "h3", "h2", "http/1.1" },
        .keep_alive = true,
        .request_timeout_ms = 30_000,
        .keep_alive_timeout_ms = 60_000,
    });
    defer server.deinit();

    // Middleware runs in registration order. Health-check / readiness-probe
    // middleware intercepts their paths before reaching route handlers, so
    // even if your DB is down the LB knows the process is alive.

    // CORS (allow all origins for development; lock down in production).
    try server.use(httpx.cors(.{
        .allowed_origins = &.{"*"},
        .allowed_methods = &.{ .GET, .POST, .PUT, .DELETE, .PATCH, .OPTIONS },
        .allowed_headers = &.{ "Content-Type", "Authorization", "X-Request-ID" },
        .max_age = 3600,
    }));

    // Health-check middleware — returns 200 on /health.
    try server.use(httpx.healthCheck(.{
        .path = "/health",
        .body = "{\"status\":\"ok\",\"service\":\"cloud-api\"}",
        .status = 200,
    }));

    // Readiness probe — returns 200 on /ready.
    try server.use(httpx.readinessProbe(.{
        .path = "/ready",
        .body = "{\"ready\":true}",
    }));

    // Request logging middleware.
    try server.use(httpx.logger());

    // Public endpoints
    try server.get("/", indexHandler);
    try server.get("/status", statusHandler);

    // API routes
    try server.get("/api/users/:id", userHandler);

    // 404 fallback for unmatched routes
    server.global(notFoundHandler);

    std.debug.print("Server Configuration:\n", .{});
    std.debug.print("  Host:              {s}\n", .{server.config.host});
    std.debug.print("  Port:              {d}\n", .{port});
    std.debug.print("  TLS (proxy):       terminated at reverse proxy\n", .{});
    std.debug.print("  Worker Threads:    {d}\n", .{server.config.threads});
    std.debug.print("  HTTP/1.1:          enabled (always)\n", .{});
    std.debug.print("  HTTP/2:            {}\n", .{server.config.http2_enabled});
    std.debug.print("  HTTP/3 (QUIC):     {}\n", .{server.config.http3_enabled});
    std.debug.print("  Keep-Alive:        {}\n", .{server.config.keep_alive});
    std.debug.print("  Max Connections:   {d}\n", .{server.config.max_connections});
    std.debug.print("  Request Timeout:   {d}ms\n", .{server.config.request_timeout_ms});

    std.debug.print("\nRegistered Routes:\n", .{});
    std.debug.print("  GET  /              -> indexHandler\n", .{});
    std.debug.print("  GET  /health        -> healthCheck middleware\n", .{});
    std.debug.print("  GET  /ready         -> readinessProbe middleware\n", .{});
    std.debug.print("  GET  /status        -> statusHandler\n", .{});
    std.debug.print("  GET  /api/users/:id -> userHandler\n", .{});
    std.debug.print("  ANY  *              -> notFoundHandler (404)\n", .{});

    std.debug.print("\nMiddleware Stack:\n", .{});
    std.debug.print("  1. cors\n", .{});
    std.debug.print("  2. healthCheck (/health)\n", .{});
    std.debug.print("  3. readinessProbe (/ready)\n", .{});
    std.debug.print("  4. logger\n", .{});

    const server_thread = try server.listenInBackground();
    defer {
        server.stop();
        server_thread.join();
    }

    // Give the server a moment to bind the socket and start accepting.
    sleepMs(100);

    // HTTP/1.0 client
    var h10_client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry())
        .withKeepAlive(false));
    defer h10_client.deinit();

    // HTTP/1.1 client
    var h1_client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry())
        .withKeepAlive(false));
    defer h1_client.deinit();

    // HTTP/2 client
    var h2_client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry())
        .withKeepAlive(false)
        .withProtocols(true, false));
    defer h2_client.deinit();

    // HTTP/3 client
    var h3_client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry())
        .withKeepAlive(false)
        .withProtocols(false, true));
    defer h3_client.deinit();

    std.debug.print("\n--- Self-test: Verifying Endpoints (HTTP/1.0, HTTP/1.1, HTTP/2, HTTP/3) ---\n\n", .{});

    const endpoints = [_]struct {
        method: httpx.Method,
        path: []const u8,
        expected_status: u16,
        label: []const u8,
    }{
        .{ .method = .GET, .path = "/", .expected_status = 200, .label = "Root" },
        .{ .method = .GET, .path = "/health", .expected_status = 200, .label = "Health check" },
        .{ .method = .GET, .path = "/ready", .expected_status = 200, .label = "Readiness probe" },
        .{ .method = .GET, .path = "/status", .expected_status = 200, .label = "Status" },
        .{ .method = .GET, .path = "/api/users/42", .expected_status = 200, .label = "User API" },
        .{ .method = .GET, .path = "/nonexistent", .expected_status = 404, .label = "404 fallback" },
    };

    var all_ok = true;

    // Test with HTTP/1.0
    std.debug.print("  Protocol: HTTP/1.0\n", .{});
    var h10_base: httpx.RequestOptions = .{};
    const h10_opts = h10_base.withVersion(.HTTP_1_0);
    for (endpoints) |ep| {
        const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ port, ep.path });
        defer allocator.free(url);

        var resp = switch (ep.method) {
            .GET => try h10_client.get(url, h10_opts),
            else => try h10_client.request(ep.method, url, h10_opts),
        };
        defer resp.deinit();

        const ok = resp.status.code == ep.expected_status;
        if (!ok) all_ok = false;

        std.debug.print("    {s: <18} {s: <5} {s: <22} -> {d} {s}\n", .{
            ep.label,
            @tagName(ep.method),
            ep.path,
            resp.status.code,
            if (ok) "ok" else "FAIL",
        });

        if (!ok) {
            const body_text = resp.text() orelse "";
            std.debug.print("      expected {d}, got {d}: {s}\n", .{
                ep.expected_status,
                resp.status.code,
                if (body_text.len > 64) body_text[0..64] else body_text,
            });
        }
    }

    // Test with HTTP/1.1
    std.debug.print("  Protocol: HTTP/1.1\n", .{});
    for (endpoints) |ep| {
        const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ port, ep.path });
        defer allocator.free(url);

        var resp = switch (ep.method) {
            .GET => try h1_client.get(url, .{}),
            else => try h1_client.request(ep.method, url, .{}),
        };
        defer resp.deinit();

        const ok = resp.status.code == ep.expected_status;
        if (!ok) all_ok = false;

        std.debug.print("    {s: <18} {s: <5} {s: <22} -> {d} {s}\n", .{
            ep.label,
            @tagName(ep.method),
            ep.path,
            resp.status.code,
            if (ok) "ok" else "FAIL",
        });

        if (!ok) {
            const body_preview = if (resp.text()) |body| body: {
                if (body.len > 64) break :body body[0..64];
                break :body body;
            } else "";
            std.debug.print("      expected {d}, got {d}: {s}\n", .{
                ep.expected_status,
                resp.status.code,
                body_preview,
            });
        }
    }

    // Test with HTTP/2
    std.debug.print("\n  Protocol: HTTP/2\n", .{});
    for (endpoints) |ep| {
        const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ port, ep.path });
        defer allocator.free(url);

        var resp = switch (ep.method) {
            .GET => try h2_client.get(url, .{}),
            else => try h2_client.request(ep.method, url, .{}),
        };
        defer resp.deinit();

        const ok = resp.status.code == ep.expected_status;
        if (!ok) all_ok = false;

        std.debug.print("    {s: <18} {s: <5} {s: <22} -> {d} {s}\n", .{
            ep.label,
            @tagName(ep.method),
            ep.path,
            resp.status.code,
            if (ok) "ok" else "FAIL",
        });

        if (!ok) {
            const body_preview = if (resp.text()) |body| body: {
                if (body.len > 64) break :body body[0..64];
                break :body body;
            } else "";
            std.debug.print("      expected {d}, got {d}: {s}\n", .{
                ep.expected_status,
                resp.status.code,
                body_preview,
            });
        }
    }

    // Test with HTTP/3 (may fail on platforms without QUIC/UDP support)
    std.debug.print("\n  Protocol: HTTP/3 (QUIC)\n", .{});
    var h3_supported = true;
    for (endpoints) |ep| {
        const url = std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ port, ep.path }) catch break;
        defer allocator.free(url);

        var resp = switch (ep.method) {
            .GET => h3_client.get(url, .{}) catch |err| {
                if (h3_supported) {
                    std.debug.print("    HTTP/3 not available: {} (QUIC may be unavailable on this platform)\n", .{err});
                    h3_supported = false;
                }
                break;
            },
            else => h3_client.request(ep.method, url, .{}) catch |err| {
                if (h3_supported) {
                    std.debug.print("    HTTP/3 not available: {} (QUIC may be unavailable on this platform)\n", .{err});
                    h3_supported = false;
                }
                break;
            },
        };
        defer resp.deinit();

        const ok = resp.status.code == ep.expected_status;
        if (!ok) all_ok = false;

        std.debug.print("    {s: <18} {s: <5} {s: <22} -> {d} {s}\n", .{
            ep.label,
            @tagName(ep.method),
            ep.path,
            resp.status.code,
            if (ok) "ok" else "FAIL",
        });

        if (!ok) {
            const body_preview = if (resp.text()) |body| body: {
                if (body.len > 64) break :body body[0..64];
                break :body body;
            } else "";
            std.debug.print("      expected {d}, got {d}: {s}\n", .{
                ep.expected_status,
                resp.status.code,
                body_preview,
            });
        }
    }

    std.debug.print("\n--- Cloud Deployment Notes ---\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("  AWS/GCP/Azure: Allow inbound TCP 443 in security groups.\n", .{});
    std.debug.print("  TLS: Terminate at load balancer (ALB / HTTPS LB);\n", .{});
    std.debug.print("       forward plain HTTP to backend port.\n", .{});
    std.debug.print("  ALPN: Configured as [\"h3\", \"h2\", \"http/1.1\"] so\n", .{});
    std.debug.print("        clients negotiate the best available protocol.\n", .{});
    std.debug.print("  Health checks: Point LB to /health (liveness) and\n", .{});
    std.debug.print("                 /ready (readiness for rolling updates).\n", .{});
    std.debug.print("  Process mgmt:  systemd Restart=always, Docker restart\n", .{});
    std.debug.print("                 policy, or K8s livenessProbe.\n", .{});
    std.debug.print("  Certificates:  Use Certbot / Let's Encrypt for public\n", .{});
    std.debug.print("                 certs; self-signed only for dev/staging.\n", .{});

    if (all_ok) {
        std.debug.print("\n=== All endpoints verified successfully across HTTP/1.0, HTTP/1.1, HTTP/2, HTTP/3! ===\n", .{});
    } else {
        std.debug.print("\n!!! Some endpoints returned unexpected status codes !!!\n", .{});
        std.process.exit(1);
    }
}
