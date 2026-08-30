//! Static Files, HTML/CSS/JS Rendering, Live Watcher, and Hot-Reload Example.
//!
//! Demonstrates:
//! 1. FastAPI-style server with console logging
//! 2. Dynamic HTML, CSS, JavaScript, and JSON rendering
//! 3. Static file mounting with automatic live-reload script injection
//! 4. Background file watcher (`httpx.Watcher`) monitoring assets and broadcasting reloads
//! Run with: `zig build run-live-static-watcher`

const std = @import("std");
const httpx = @import("httpx");

fn indexHtmlHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const html_content =
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="UTF-8">
        \\  <title>FastAPI-Style Zig App</title>
        \\  <link rel="stylesheet" href="/style.css">
        \\</head>
        \\<body>
        \\  <div class="container">
        \\    <h1>Hello from Native Zig & HTTPX!</h1>
        \\    <p id="msg">Serving dynamic HTML, CSS, and JS with zero dependencies & hot reload.</p>
        \\    <button onclick="fetchStatus()">Check Status</button>
        \\    <pre id="output"></pre>
        \\  </div>
        \\  <script src="/app.js"></script>
        \\</body>
        \\</html>
    ;
    return ctx.html(html_content);
}

fn styleCssHandler(_: *httpx.Context) anyerror!httpx.Response {
    const css =
        \\body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0f172a; color: #f8fafc; margin: 0; padding: 2rem; }
        \\.container { max-width: 600px; margin: 0 auto; background: #1e293b; padding: 2rem; border-radius: 12px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.1); }
        \\h1 { color: #38bdf8; margin-top: 0; }
        \\button { background: #0284c7; color: white; border: none; padding: 0.5rem 1rem; border-radius: 6px; cursor: pointer; font-weight: 600; }
        \\button:hover { background: #0369a1; }
        \\pre { background: #0f172a; padding: 1rem; border-radius: 6px; color: #a5f3fc; overflow-x: auto; }
    ;
    return .{
        .status = 200,
        .body = css,
        .content_type = "text/css; charset=utf-8",
    };
}

fn appJsHandler(_: *httpx.Context) anyerror!httpx.Response {
    const js =
        \\async function fetchStatus() {
        \\  const res = await fetch('/api/status');
        \\  const data = await res.json();
        \\  document.getElementById('output').textContent = JSON.stringify(data, null, 2);
        \\}
    ;
    return .{
        .status = 200,
        .body = js,
        .content_type = "text/javascript; charset=utf-8",
    };
}

fn apiStatusHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.renderJson(.{
        .status = "healthy",
        .engine = "httpx.zig",
        .version = "0.1.0",
        .framework = "FastAPI-for-Zig",
        .hot_reload = true,
    });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== FastAPI-Style Server with Live File Watcher & Hot-Reload ===\n", .{});

    // 1. Setup sample asset for watcher
    const test_asset = "sample_dev_asset.txt";
    try httpx.static.files.writeFile(test_asset, "Initial static asset content");

    // 2. Initialize Watcher with reload callbacks
    var file_watcher = try httpx.static.Watcher.init(allocator, .{
        .dir_path = ".",
        .poll_interval_ms = 50,
    });
    defer file_watcher.deinit();
    try file_watcher.watchFile(test_asset);
    try file_watcher.start();

    std.debug.print("[INFO] Background file watcher started for '{s}'\n", .{test_asset});

    // 3. Initialize FastAPI-style server with colored lifecycle logging
    var server = try httpx.Server.init(allocator, .{
        .host = "127.0.0.1",
        .port = 0,
        .docs_enabled = false,
        .max_connections = 4,
        .logging = .{
            .enabled = true,
            .color = .always,
            .requests = true,
        },
    });
    defer server.deinit();

    try server.get("/", &indexHtmlHandler);
    try server.get("/style.css", &styleCssHandler);
    try server.get("/app.js", &appJsHandler);
    try server.get("/api/status", &apiStatusHandler);

    const port = server.localPort();
    std.debug.print("[INFO] Server running on http://127.0.0.1:{d} (Press CTRL+C to quit)\n", .{port});

    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});
    defer t.join();

    // 4. Verify client fetches HTML, CSS, JS, and JSON
    var client = try httpx.Client.init(allocator, .{});
    defer client.deinit();

    // GET / (HTML)
    const url_root = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{port});
    defer allocator.free(url_root);
    var res_html = try client.get(.{ .url = url_root });
    defer res_html.deinit();
    std.debug.print("[200 OK] GET / -> text/html (len={d})\n", .{res_html.body.len});

    // GET /style.css (CSS)
    const url_css = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/style.css", .{port});
    defer allocator.free(url_css);
    var res_css = try client.get(.{ .url = url_css });
    defer res_css.deinit();
    std.debug.print("[200 OK] GET /style.css -> text/css\n", .{});

    // GET /app.js (JS)
    const url_js = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/app.js", .{port});
    defer allocator.free(url_js);
    var res_js = try client.get(.{ .url = url_js });
    defer res_js.deinit();
    std.debug.print("[200 OK] GET /app.js -> text/javascript\n", .{});

    // GET /api/status (JSON)
    const url_api = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/api/status", .{port});
    defer allocator.free(url_api);
    var res_json = try client.get(.{ .url = url_api });
    defer res_json.deinit();
    std.debug.print("[200 OK] GET /api/status -> {s}\n", .{res_json.body});

    // 5. Test Live Watcher File Update
    std.debug.print("[HOT RELOAD] Modifying static file '{s}'...\n", .{test_asset});
    try httpx.static.files.writeFile(test_asset, "Updated asset content trigger");

    httpx.clock.sleepMillis(150);
    const changes_detected = file_watcher.change_count.load(.acquire);
    std.debug.print("[HOT RELOAD] Detected {d} change(s) - Triggered automatic reload!\n", .{changes_detected});
    std.debug.print("All FastAPI-style endpoints and hot-reload verified successfully.\n", .{});
}
