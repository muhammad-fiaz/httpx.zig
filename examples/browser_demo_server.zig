//! Browser verification server for Chrome interaction and live reload testing.

const std = @import("std");
const httpx = @import("httpx");

const html_v1 =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="UTF-8">
    \\  <title>httpx.zig Live Demo</title>
    \\  <style>
    \\    body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: #0b0f19; color: #f1f5f9; padding: 2rem; margin: 0; }
    \\    .card { max-width: 650px; margin: 2rem auto; background: #1e293b; border-radius: 16px; padding: 2.5rem; box-shadow: 0 10px 25px rgba(0,0,0,0.5); border: 1px solid #334155; }
    \\    h1 { color: #38bdf8; margin-top: 0; font-size: 2rem; }
    \\    .badge { display: inline-block; background: #0369a1; color: #e0f2fe; padding: 0.25rem 0.75rem; border-radius: 9999px; font-weight: 600; font-size: 0.85rem; margin-bottom: 1.5rem; }
    \\    button { background: #0284c7; color: white; border: none; padding: 0.75rem 1.5rem; border-radius: 8px; font-size: 1rem; font-weight: 600; cursor: pointer; transition: background 0.2s; }
    \\    button:hover { background: #0369a1; }
    \\    pre { background: #0f172a; padding: 1.25rem; border-radius: 8px; color: #a5f3fc; border: 1px solid #1e293b; overflow-x: auto; margin-top: 1.5rem; }
    \\    .links { margin-top: 1.5rem; display: flex; gap: 1rem; flex-wrap: wrap; }
    \\    .links a { color: #38bdf8; text-decoration: none; font-weight: 500; }
    \\    .links a:hover { text-decoration: underline; }
    \\  </style>
    \\</head>
    \\<body>
    \\  <div class="card">
    \\    <span class="badge">Version 1.0 (Initial)</span>
    \\    <h1 id="main-title">httpx.zig Production HTTP Stack</h1>
    \\    <p id="desc">High-performance native Zig HTTP/1.1, HTTP/2, HTTP/3, TLS, and Web Framework.</p>
    \\    <button id="btn-status" onclick="loadStatus()">Fetch Server Status</button>
    \\    <pre id="status-output">Click the button above to check server health...</pre>
    \\    <div class="links">
    \\      <a id="link-json" href="/api/status" target="_blank">JSON Status API</a>
    \\      <a id="link-xml" href="/xml" target="_blank">XML Response</a>
    \\      <a id="link-rss" href="/rss.xml" target="_blank">RSS 2.0 Feed</a>
    \\      <a id="link-sitemap" href="/sitemap.xml" target="_blank">Sitemap XML</a>
    \\      <a id="link-robots" href="/robots.txt" target="_blank">robots.txt</a>
    \\    </div>
    \\  </div>
    \\  <script>
    \\    async function loadStatus() {
    \\      try {
    \\        const res = await fetch('/api/status');
    \\        const data = await res.json();
    \\        document.getElementById('status-output').textContent = JSON.stringify(data, null, 2);
    \\      } catch (err) {
    \\        document.getElementById('status-output').textContent = 'Error: ' + err.message;
    \\      }
    \\    }
    \\  </script>
    \\</body>
    \\</html>
;

const html_v2 =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="UTF-8">
    \\  <title>httpx.zig Live Demo (Hot-Reloaded)</title>
    \\  <style>
    \\    body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: #0b0f19; color: #f1f5f9; padding: 2rem; margin: 0; }
    \\    .card { max-width: 650px; margin: 2rem auto; background: #1e293b; border-radius: 16px; padding: 2.5rem; box-shadow: 0 10px 25px rgba(0,0,0,0.5); border: 2px solid #22c55e; }
    \\    h1 { color: #4ade80; margin-top: 0; font-size: 2rem; }
    \\    .badge { display: inline-block; background: #15803d; color: #dcfce7; padding: 0.25rem 0.75rem; border-radius: 9999px; font-weight: 600; font-size: 0.85rem; margin-bottom: 1.5rem; }
    \\    button { background: #16a34a; color: white; border: none; padding: 0.75rem 1.5rem; border-radius: 8px; font-size: 1rem; font-weight: 600; cursor: pointer; }
    \\    button:hover { background: #15803d; }
    \\    pre { background: #0f172a; padding: 1.25rem; border-radius: 8px; color: #bbf7d0; border: 1px solid #1e293b; overflow-x: auto; margin-top: 1.5rem; }
    \\    .links { margin-top: 1.5rem; display: flex; gap: 1rem; flex-wrap: wrap; }
    \\    .links a { color: #4ade80; text-decoration: none; font-weight: 500; }
    \\  </style>
    \\</head>
    \\<body>
    \\  <div class="card">
    \\    <span class="badge" id="version-badge">Version 2.0 (HOT RELOADED)</span>
    \\    <h1 id="main-title">Hot-Reload & Live Watcher Active!</h1>
    \\    <p id="desc">The live server has updated the page dynamically without restarting.</p>
    \\    <button id="btn-status" onclick="loadStatus()">Fetch Server Status</button>
    \\    <pre id="status-output">Hot reload successful! Live watcher verified.</pre>
    \\  </div>
    \\  <script>
    \\    async function loadStatus() {
    \\      const res = await fetch('/api/status');
    \\      const data = await res.json();
    \\      document.getElementById('status-output').textContent = JSON.stringify(data, null, 2);
    \\    }
    \\  </script>
    \\</body>
    \\</html>
;

var current_version = std.atomic.Value(u32).init(1);

fn indexHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const v = current_version.load(.acquire);
    if (v == 1) {
        return ctx.html(html_v1);
    } else {
        return ctx.html(html_v2);
    }
}

fn statusHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.renderJson(.{
        .status = "online",
        .engine = "httpx.zig",
        .protocols = [_][]const u8{ "HTTP/1.1", "HTTP/2", "HTTP/3", "QUIC", "TLS 1.3" },
        .version = if (current_version.load(.acquire) == 1) "1.0.0" else "2.0.0-reloaded",
        .uptime_ms = 42000,
        .hot_reload_active = true,
    });
}

fn xmlHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.xml("<response><status>ok</status><library>httpx.zig</library></response>");
}

fn rssHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.rss("<rss version=\"2.0\"><channel><title>httpx Feed</title></channel></rss>");
}

fn sitemapHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.sitemap("<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\"><url><loc>http://127.0.0.1:8089/</loc></url></urlset>");
}

fn robotsHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.robots("User-agent: *\nAllow: /\nSitemap: http://127.0.0.1:8089/sitemap.xml");
}

fn triggerReloadHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    current_version.store(2, .release);
    return ctx.renderJson(.{ .reloaded = true, .version = 2 });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try httpx.Server.init(allocator, .{
        .host = "127.0.0.1",
        .port = 8089,
    });
    defer server.deinit();

    try server.get("/", indexHandler);
    try server.get("/api/status", statusHandler);
    try server.get("/xml", xmlHandler);
    try server.get("/rss.xml", rssHandler);
    try server.get("/sitemap.xml", sitemapHandler);
    try server.get("/robots.txt", robotsHandler);
    try server.post("/api/trigger-reload", triggerReloadHandler);

    std.debug.print("Demo server listening on http://127.0.0.1:8089\n", .{});
    server.run();
}
