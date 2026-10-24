//! Auth and Custom Error Handling Example
//!
//! Demonstrates:
//!   - Bearer token & Basic authentication
//!   - Nested/restricted route protection
//!   - Custom 404 HTML fallback page
//!   - Custom 500 error envelope
//!   - Client-side verification of valid, invalid, and unauthorized requests

const std = @import("std");
const httpx = @import("httpx");

// Protected data model
const SecretData = struct {
    role: []const u8,
    secretCode: []const u8,
};

// 1. Custom 404 HTML handler
fn customNotFound(ctx: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    return ctx.htmlStatus(404,
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>404 Not Found</title></head>
        \\<body style="font-family:sans-serif; text-align:center; padding:50px;">
        \\  <h1 style="color:#e11d48;">404 - Custom Page Not Found</h1>
        \\  <p>The requested endpoint does not exist on this server.</p>
        \\</body>
        \\</html>
    );
}

// 2. Custom 500 / Exception handler
fn customErrorHandler(ctx: *httpx.web.router.Context, err: anyerror) anyerror!httpx.web.router.Response {
    return try ctx.renderJsonStatus(500, .{
        .status = 500,
        .errorName = @errorName(err),
        .message = "An unhandled server exception occurred.",
    });
}

// Public Route
fn handlePublic(ctx: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    return ctx.html("<h1>Public Area</h1><p>Welcome to the open web server.</p>");
}

// Bearer Token Protected Route
fn handleRestrictedBearer(ctx: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    const token = ctx.bearerToken() orelse {
        return ctx.htmlStatus(401, "<h1>401 Unauthorized</h1><p>Missing or invalid Bearer token.</p>");
    };

    if (!std.mem.eql(u8, token, "secret-token-xyz")) {
        return ctx.htmlStatus(403, "<h1>403 Forbidden</h1><p>Invalid credentials provided.</p>");
    }

    return try ctx.renderJson(SecretData{
        .role = "admin",
        .secretCode = "ALPHA-OMEGA-99",
    });
}

// Basic Auth Protected Route
fn handleRestrictedBasic(ctx: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    const creds = ctx.basicAuth() orelse {
        return ctx.htmlStatus(401, "<h1>401 Unauthorized</h1><p>Missing Basic Auth credentials.</p>");
    };

    if (!std.mem.eql(u8, creds.username, "admin") or !std.mem.eql(u8, creds.password, "pass123")) {
        return ctx.htmlStatus(403, "<h1>403 Forbidden</h1><p>Invalid username or password.</p>");
    }

    return try ctx.renderJson(SecretData{
        .role = "manager",
        .secretCode = "BETA-KAPPA-42",
    });
}

// Route that deliberately throws an error to trigger customErrorHandler
fn handleFaulty(ctx: *httpx.web.router.Context) anyerror!httpx.web.router.Response {
    _ = ctx;
    return error.DatabaseUnavailable;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    // 1. Initialize Server
    var server = try httpx.server.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
    });
    defer server.deinit();

    // Set custom error and 404 handlers
    server.setNotFoundHandler(customNotFound);
    server.setErrorHandler(customErrorHandler);

    // Register routes
    try server.get("/public", handlePublic);
    try server.get("/api/v1/protected/bearer", handleRestrictedBearer);
    try server.get("/api/v1/protected/basic", handleRestrictedBasic);
    try server.get("/api/v1/faulty", handleFaulty);

    // Spawn server accept loop on a background thread
    const port = server.localPort();
    const serverThread = try std.Thread.spawn(.{}, (struct {
        fn run(s: *httpx.server.Server) void {
            s.run();
        }
    }).run, .{&server});
    defer {
        server.requestShutdown();
        serverThread.join();
    }

    std.debug.print("=== Custom Error & Auth Security Validation ===\n", .{});

    // 2. Validate Custom 404 HTML Page
    {
        var urlBuf: [128]u8 = undefined;
        const notFoundUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/invalid/path/404", .{port});
        var resp = try client.get(notFoundUrl, .{});
        defer resp.deinit();

        std.debug.print("1. Custom 404 Response Status: {d}\n", .{resp.status});
        std.debug.print("   Contains Custom HTML: {}\n", .{std.mem.indexOf(u8, resp.body, "404 - Custom Page Not Found") != null});
    }

    // 3. Validate Custom 500 Error Envelope
    {
        var urlBuf: [128]u8 = undefined;
        const faultyUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/api/v1/faulty", .{port});
        var resp = try client.get(faultyUrl, .{});
        defer resp.deinit();

        std.debug.print("2. Custom 500 Response Status: {d}\n", .{resp.status});
        std.debug.print("   Contains JSON Error: {}\n", .{std.mem.indexOf(u8, resp.body, "DatabaseUnavailable") != null});
    }

    // 4. Validate Bearer Auth - Unauthorized (No Token)
    {
        var urlBuf: [128]u8 = undefined;
        const bearerUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/api/v1/protected/bearer", .{port});
        var resp = try client.get(bearerUrl, .{});
        defer resp.deinit();

        std.debug.print("3. Missing Bearer Token Status: {d}\n", .{resp.status});
    }

    // 5. Validate Bearer Auth - Authorized (Valid Token)
    {
        var urlBuf: [128]u8 = undefined;
        const bearerUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/api/v1/protected/bearer", .{port});
        var resp = try client.get(bearerUrl, .{
            .bearerAuth = "secret-token-xyz",
        });
        defer resp.deinit();

        std.debug.print("4. Valid Bearer Token Status: {d}\n", .{resp.status});
        std.debug.print("   Protected Payload: {s}\n", .{resp.body});
    }

    // 6. Validate Basic Auth - Authorized (Valid Credentials)
    {
        var urlBuf: [128]u8 = undefined;
        const basicUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/api/v1/protected/basic", .{port});
        var resp = try client.get(basicUrl, .{
            .basicAuth = "admin:pass123",
        });
        defer resp.deinit();

        std.debug.print("5. Valid Basic Auth Status: {d}\n", .{resp.status});
        std.debug.print("   Protected Payload: {s}\n", .{resp.body});
    }

    std.debug.print("Custom Error Pages, 404 Fallback & Auth validation completed successfully.\n", .{});
}
