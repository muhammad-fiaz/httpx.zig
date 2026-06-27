//! HTTP Auth Helpers Example
//!
//! Demonstrates built-in request auth helpers:
//! - RequestOptions.withBearerToken(...)
//! - RequestOptions.withBasicAuth(...)
//! - Request.setBearerAuth(...)
//! - Request.setBasicAuth(...)
//! and server-side Context helpers for reading auth/media info.

const std = @import("std");
const httpx = @import("httpx");

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

fn bearerHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    if (!ctx.acceptsJson()) {
        return ctx.status(406).json(.{ .message = "client must accept application/json" });
    }

    const token = ctx.bearerToken() orelse {
        return ctx.status(401).json(.{ .message = "missing bearer token" });
    };

    if (!std.mem.eql(u8, token, "demo-token")) {
        return ctx.status(401).json(.{ .message = "invalid bearer token" });
    }

    return ctx.json(.{ .kind = "bearer", .ok = true });
}

fn basicHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    if (!ctx.acceptsJson()) {
        return ctx.status(406).json(.{ .message = "client must accept application/json" });
    }

    const auth = ctx.authorization() orelse {
        return ctx.status(401).json(.{ .message = "missing basic auth" });
    };

    if (!std.mem.eql(u8, auth, "Basic ZGVtbzpwYXNz")) {
        return ctx.status(401).json(.{ .message = "invalid basic credentials" });
    }

    return ctx.json(.{ .kind = "basic", .ok = true });
}


pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== HTTP Auth Helpers Example ===\n\n", .{});

    const port = try pickFreeTcpPort();
    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .port_conflict = .fail,
        .keep_alive = false,
    });
    defer server.deinit();

    try server.get("/auth/bearer", bearerHandler);
    try server.get("/auth/basic", basicHandler);

    const server_thread = try server.listenInBackground();
    defer server_thread.join();
    defer server.stop();

    sleepMs(50);

    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry()));
    defer client.deinit();

    const bearer_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/auth/bearer", .{port});
    defer allocator.free(bearer_url);

    const basic_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/auth/basic", .{port});
    defer allocator.free(basic_url);

    const bearer_opts = httpx.RequestOptions.defaults()
        .withHeaders(&.{.{ "Accept", "application/json" }})
        .withBearerToken("demo-token");

    var bearer_response = try client.get(bearer_url, bearer_opts);
    defer bearer_response.deinit();

    std.debug.print("Bearer status: {d}\n", .{bearer_response.status.code});
    std.debug.print("Bearer body: {s}\n", .{bearer_response.text() orelse ""});

    const basic_opts = httpx.RequestOptions.defaults()
        .withHeaders(&.{.{ "Accept", "application/json" }})
        .withBasicAuth("demo", "pass");

    var basic_response = try client.get(basic_url, basic_opts);
    defer basic_response.deinit();

    std.debug.print("Basic status: {d}\n", .{basic_response.status.code});
    std.debug.print("Basic body: {s}\n", .{basic_response.text() orelse ""});

    // Manual request helper check.
    var req = try httpx.Request.init(allocator, .GET, bearer_url);
    defer req.deinit();
    try req.setBearerAuth("demo-token");
    std.debug.print("Manual request Authorization: {s}\n", .{req.headers.get(httpx.HeaderName.AUTHORIZATION).?});
}
