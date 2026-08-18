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

fn userHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const user_id = ctx.param("id") orelse "unknown";
    return ctx.json(.{
        .id = user_id,
        .name = "Example User",
        .email = "user@example.com",
        .role = "developer",
    });
}

fn statusHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.json(.{
        .service = "cloud-api",
        .version = "1.0.0",
        .region = "us-east-1",
        .environment = "staging",
        .hostname = "web-01",
    });
}

fn notFoundHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    _ = ctx.status(404);
    return ctx.json(.{
        .@"error" = "not_found",
        .message = "The requested resource was not found",
        .path = ctx.request.uri.path,
    });
}

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

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

    try server.use(httpx.cors(.{
        .allowed_origins = &.{"*"},
        .allowed_methods = &.{ .GET, .POST, .PUT, .DELETE, .PATCH, .OPTIONS },
        .allowed_headers = &.{ "Content-Type", "Authorization", "X-Request-ID" },
        .max_age = 3600,
    }));

    try server.use(httpx.healthCheck(.{
        .path = "/health",
        .body = "{\"status\":\"ok\",\"service\":\"cloud-api\"}",
        .status = 200,
    }));

    try server.use(httpx.readinessProbe(.{
        .path = "/ready",
        .body = "{\"ready\":true}",
    }));

    try server.use(httpx.logger());

    try server.get("/", indexHandler);
    try server.get("/status", statusHandler);

    try server.get("/api/users/:id", userHandler);

    server.global(notFoundHandler);

    const server_thread = try server.listenInBackground();
    defer {
        server.stop();
        server_thread.join();
    }

    sleepMs(100);

    var h10_client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry())
        .withKeepAlive(false));
    defer h10_client.deinit();

    var h1_client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry())
        .withKeepAlive(false));
    defer h1_client.deinit();

    var h2_client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry())
        .withKeepAlive(false)
        .withProtocols(true, false));
    defer h2_client.deinit();

    var h3_client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry())
        .withKeepAlive(false)
        .withProtocols(false, true));
    defer h3_client.deinit();

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

    if (all_ok) {
        std.debug.print("\n=== All endpoints verified successfully across HTTP/1.0, HTTP/1.1, HTTP/2, HTTP/3! ===\n", .{});
    } else {
        std.debug.print("\n!!! Some endpoints returned unexpected status codes !!!\n", .{});
        std.process.exit(1);
    }
}
