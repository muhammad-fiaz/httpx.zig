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
    secret_code: []const u8,
};

// 1. Custom 404 HTML handler
fn customNotFound(ctx: *httpx.Context) anyerror!httpx.Response {
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
fn customErrorHandler(ctx: *httpx.Context, err: anyerror) anyerror!httpx.Response {
    return try ctx.renderJsonStatus(500, .{
        .status = 500,
        .error_name = @errorName(err),
        .message = "An unhandled server exception occurred.",
    });
}

// Public Route
fn handlePublic(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.html("<h1>Public Area</h1><p>Welcome to the open web server.</p>");
}

// Bearer Token Protected Route
fn handleRestrictedBearer(ctx: *httpx.Context) anyerror!httpx.Response {
    const token = ctx.bearerToken() orelse {
        return ctx.htmlStatus(401, "<h1>401 Unauthorized</h1><p>Missing or invalid Bearer token.</p>");
    };

    if (!std.mem.eql(u8, token, "secret-token-xyz")) {
        return ctx.htmlStatus(403, "<h1>403 Forbidden</h1><p>Invalid credentials provided.</p>");
    }

    return try ctx.renderJson(SecretData{
        .role = "admin",
        .secret_code = "ALPHA-OMEGA-99",
    });
}

// Basic Auth Protected Route
fn handleRestrictedBasic(ctx: *httpx.Context) anyerror!httpx.Response {
    const creds = ctx.basicAuth() orelse {
        return ctx.htmlStatus(401, "<h1>401 Unauthorized</h1><p>Missing Basic Auth credentials.</p>");
    };

    if (!std.mem.eql(u8, creds.username, "admin") or !std.mem.eql(u8, creds.password, "pass123")) {
        return ctx.htmlStatus(403, "<h1>403 Forbidden</h1><p>Invalid username or password.</p>");
    }

    return try ctx.renderJson(SecretData{
        .role = "manager",
        .secret_code = "BETA-KAPPA-42",
    });
}

// Route that deliberately throws an error to trigger customErrorHandler
fn handleFaulty(ctx: *httpx.Context) anyerror!httpx.Response {
    _ = ctx;
    return error.DatabaseUnavailable;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Initialize Server
    var server = try httpx.Server.init(allocator, .{
        .host = "127.0.0.1",
        .port = 0,
        .docs_enabled = false,
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
    const server_thread = try std.Thread.spawn(.{}, (struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    }).run, .{&server});
    defer {
        server.requestShutdown();
        server_thread.join();
    }

    std.debug.print("=== Custom Error & Auth Security Validation ===\n", .{});

    // 2. Validate Custom 404 HTML Page
    {
        var url_buf: [128]u8 = undefined;
        const not_found_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/invalid/path/404", .{port});
        var resp = try httpx.get(.{ .url = not_found_url });
        defer resp.deinit();

        std.debug.print("1. Custom 404 Response Status: {d}\n", .{resp.status});
        std.debug.print("   Contains Custom HTML: {}\n", .{std.mem.indexOf(u8, resp.body, "404 - Custom Page Not Found") != null});
    }

    // 3. Validate Custom 500 Error Envelope
    {
        var url_buf: [128]u8 = undefined;
        const faulty_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/v1/faulty", .{port});
        var resp = try httpx.get(.{ .url = faulty_url });
        defer resp.deinit();

        std.debug.print("2. Custom 500 Response Status: {d}\n", .{resp.status});
        std.debug.print("   Contains JSON Error: {}\n", .{std.mem.indexOf(u8, resp.body, "DatabaseUnavailable") != null});
    }

    // 4. Validate Bearer Auth - Unauthorized (No Token)
    {
        var url_buf: [128]u8 = undefined;
        const bearer_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/v1/protected/bearer", .{port});
        var resp = try httpx.get(.{ .url = bearer_url });
        defer resp.deinit();

        std.debug.print("3. Missing Bearer Token Status: {d}\n", .{resp.status});
    }

    // 5. Validate Bearer Auth - Authorized (Valid Token)
    {
        var url_buf: [128]u8 = undefined;
        const bearer_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/v1/protected/bearer", .{port});
        var resp = try httpx.get(.{
            .url = bearer_url,
            .bearer_auth = "secret-token-xyz",
        });
        defer resp.deinit();

        std.debug.print("4. Valid Bearer Token Status: {d}\n", .{resp.status});
        std.debug.print("   Protected Payload: {s}\n", .{resp.body});
    }

    // 6. Validate Basic Auth - Authorized (Valid Credentials)
    {
        var url_buf: [128]u8 = undefined;
        const basic_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/v1/protected/basic", .{port});
        var resp = try httpx.get(.{
            .url = basic_url,
            .basic_auth = "admin:pass123",
        });
        defer resp.deinit();

        std.debug.print("5. Valid Basic Auth Status: {d}\n", .{resp.status});
        std.debug.print("   Protected Payload: {s}\n", .{resp.body});
    }

    std.debug.print("Custom Error Pages, 404 Fallback & Auth validation completed successfully.\n", .{});
}
