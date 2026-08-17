//! Static File Server Example
//!
//! Demonstrates:
//! - serving explicit single-file static routes
//! - serving directory-based wildcard static routes
//! - redirects using httpx.zig response helpers

const std = @import("std");
const httpx = @import("httpx");

const site_root = "examples/multi_page_site/site";
const assets_root = "examples/multi_page_site/site/assets";
const custom_mime_mappings = [_]httpx.MimeMapping{
    .{ .ext = ".geojson", .mime = "application/geo+json" },
    .{ .ext = ".glb", .mime = "model/gltf-binary" },
};

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

fn serveFileWithType(ctx: *httpx.Context, path: []const u8) anyerror!httpx.Response {
    const fallback = httpx.mimeTypeFromPath(path);
    const content_type = httpx.mimeTypeFromPathWith(path, &custom_mime_mappings, fallback);
    const ext = std.fs.path.extension(path);
    const cache_control = if (std.mem.eql(u8, ext, ".html"))
        "no-cache"
    else
        "public, max-age=300";

    return ctx.fileWithOptions(path, .{
        .content_type = content_type,
        .cache_control = cache_control,
        .add_etag = true,
        .conditional_get = true,
    });
}

fn serveSitePath(ctx: *httpx.Context, rel_path: []const u8) anyerror!httpx.Response {
    if (std.mem.indexOf(u8, rel_path, "..") != null or std.mem.indexOfScalar(u8, rel_path, '\\') != null) {
        return ctx.status(400).text("Invalid path");
    }

    var path_buf: [1024]u8 = undefined;
    const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ site_root, rel_path }) catch {
        return ctx.status(414).text("Path too long");
    };

    return serveFileWithType(ctx, full_path);
}

fn serveAssetsPath(ctx: *httpx.Context, rel_path: []const u8) anyerror!httpx.Response {
    if (std.mem.indexOf(u8, rel_path, "..") != null or std.mem.indexOfScalar(u8, rel_path, '\\') != null) {
        return ctx.status(400).text("Invalid path");
    }

    var path_buf: [1024]u8 = undefined;
    const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ assets_root, rel_path }) catch {
        return ctx.status(414).text("Path too long");
    };

    return serveFileWithType(ctx, full_path);
}

fn homeHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.html(
        \\<h1>httpx.zig static files demo</h1>
        \\<p>This demo focuses on static file serving patterns.</p>
        \\<ul>
        \\  <li><a href="/logo">File route: /logo</a></li>
        \\  <li><a href="/styles.css">File route: /styles.css</a></li>
        \\  <li><a href="/assets/styles.css">Directory route: /assets/*</a></li>
        \\  <li><a href="/images/httpx.zig-transparent.png">Directory route: /images/*</a></li>
        \\  <li><a href="/site-home">Full page from site folder</a></li>
        \\  <li><a href="/go-home">Redirect route</a></li>
        \\  <li>Static files include ETag + conditional GET support.</li>
        \\</ul>
    );
}

fn siteHomeHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return serveSitePath(ctx, "index.html");
}

fn logoHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return serveAssetsPath(ctx, "images/httpx.zig-transparent.png");
}

fn cssFileHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return serveAssetsPath(ctx, "styles.css");
}

fn jsFileHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return serveAssetsPath(ctx, "app.js");
}

fn assetsByPrefixHandler(ctx: *httpx.Context, prefix: []const u8) anyerror!httpx.Response {
    if (!std.mem.startsWith(u8, ctx.request.uri.path, prefix)) {
        return ctx.status(400).text("Invalid asset route");
    }
    const wildcard = ctx.request.uri.path[prefix.len..];
    if (wildcard.len == 0) {
        return ctx.status(400).text("Missing asset path");
    }

    if (std.mem.indexOf(u8, wildcard, "..") != null or
        std.mem.indexOfScalar(u8, wildcard, '\\') != null)
    {
        return ctx.status(400).text("Invalid asset path");
    }

    var rel_buf: [1024]u8 = undefined;
    const rel_path = std.fmt.bufPrint(&rel_buf, "assets/{s}", .{wildcard}) catch {
        return ctx.status(414).text("Path too long");
    };

    return serveSitePath(ctx, rel_path);
}

fn assetsHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return assetsByPrefixHandler(ctx, "/assets/");
}

fn imagesHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const prefix = "/images/";
    if (!std.mem.startsWith(u8, ctx.request.uri.path, prefix)) {
        return ctx.status(400).text("Invalid image route");
    }
    const wildcard = ctx.request.uri.path[prefix.len..];
    if (wildcard.len == 0) {
        return ctx.status(400).text("Missing image path");
    }

    var rel_buf: [1024]u8 = undefined;
    const rel_path = std.fmt.bufPrint(&rel_buf, "images/{s}", .{wildcard}) catch {
        return ctx.status(414).text("Path too long");
    };

    return serveAssetsPath(ctx, rel_path);
}

fn redirectHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.redirect("/", 302);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Static File Server Example ===\n\n", .{});

    const port = try pickFreeTcpPort();
    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .port_conflict = .fail,
        .keep_alive = false,
    });
    defer server.deinit();

    try server.get("/", homeHandler);
    try server.get("/site-home", siteHomeHandler);
    try server.get("/logo", logoHandler);
    try server.get("/styles.css", cssFileHandler);
    try server.get("/app.js", jsFileHandler);
    try server.get("/assets/*", assetsHandler);
    try server.get("/images/*", imagesHandler);
    try server.get("/go-home", redirectHandler);

    std.debug.print("Registered routes:\n", .{});
    std.debug.print("  GET /               -> demo index (HTML response)\n", .{});
    std.debug.print("  GET /site-home      -> explicit file route to site index.html\n", .{});
    std.debug.print("  GET /logo           -> explicit file route to site image\n", .{});
    std.debug.print("  GET /styles.css     -> explicit file route to site CSS\n", .{});
    std.debug.print("  GET /app.js         -> explicit file route to site JS\n", .{});
    std.debug.print("  GET /assets/*       -> directory wildcard route to assets root\n", .{});
    std.debug.print("  GET /images/*       -> directory wildcard route to image directory\n", .{});
    std.debug.print("  GET /go-home        -> redirect('/')\n", .{});

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

    var resp = try client.get(home_url, .{});
    defer resp.deinit();
    std.debug.print("\nGET / -> status: {d}\n", .{resp.status.code});
    const body = resp.text() orelse "";
    if (std.mem.indexOf(u8, body, "static files demo") != null) {
        std.debug.print("Home page contains expected content\n", .{});
    }

    std.debug.print("\nStatic file routes verified!\n", .{});

    server.stop();
    server_thread.join();
}
