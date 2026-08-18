const std = @import("std");
const httpx = @import("httpx");

const site_root = "examples/multi_page_site/site";

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

fn contentTypeForPath(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    return "application/octet-stream";
}

fn serveRelativePath(ctx: *httpx.Context, rel_path: []const u8) anyerror!httpx.Response {
    if (std.mem.indexOf(u8, rel_path, "..") != null or std.mem.indexOfScalar(u8, rel_path, '\\') != null) {
        return ctx.status(400).text("Invalid path");
    }

    var full_path_buf: [1024]u8 = undefined;
    const full_path = std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ site_root, rel_path }) catch {
        return ctx.status(414).text("Path too long");
    };

    var resp = try ctx.fileAs(full_path, contentTypeForPath(rel_path));
    try resp.headers.set("Cache-Control", "no-cache");
    return resp;
}

fn homeHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return serveRelativePath(ctx, "index.html");
}

fn aboutHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return serveRelativePath(ctx, "about.html");
}

fn contactHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return serveRelativePath(ctx, "contact.html");
}

fn logoHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return serveRelativePath(ctx, "assets/images/httpx.zig-transparent.png");
}

fn staticHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const prefix = "/static/";
    if (!std.mem.startsWith(u8, ctx.request.uri.path, prefix)) {
        return ctx.status(400).text("Invalid static route");
    }

    const suffix = ctx.request.uri.path[prefix.len..];
    if (suffix.len == 0) {
        return ctx.status(400).text("Missing static path");
    }

    var rel_buf: [1024]u8 = undefined;
    const rel_path = std.fmt.bufPrint(&rel_buf, "assets/{s}", .{suffix}) catch {
        return ctx.status(414).text("Path too long");
    };

    return serveRelativePath(ctx, rel_path);
}

fn redirectHomeHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.redirect("/", 302);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const port = try pickFreeTcpPort();

    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .port_conflict = .fail,
        .keep_alive = false,
        .request_timeout_ms = 10_000,
    });
    defer server.deinit();

    try server.get("/", homeHandler);
    try server.get("/about", aboutHandler);
    try server.get("/contact", contactHandler);
    try server.get("/logo", logoHandler);
    try server.get("/go-home", redirectHomeHandler);
    try server.get("/static/*", staticHandler);

    const server_thread = try server.listenInBackground();
    sleepMs(100);

    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry()));
    defer client.deinit();

    const base_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port});
    defer allocator.free(base_url);

    const home_url = try std.fmt.allocPrint(allocator, "{s}/", .{base_url});
    defer allocator.free(home_url);
    const about_url = try std.fmt.allocPrint(allocator, "{s}/about", .{base_url});
    defer allocator.free(about_url);

    var resp1 = try client.get(home_url, .{});
    defer resp1.deinit();
    std.debug.print("\nGET / -> status: {d}\n", .{resp1.status.code});

    var resp2 = try client.get(about_url, .{});
    defer resp2.deinit();
    std.debug.print("GET /about -> status: {d}\n", .{resp2.status.code});

    server.stop();
    server_thread.join();
}
