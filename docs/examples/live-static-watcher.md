# Example: Live Static Watcher

Demonstrates liveStaticWatcher.zig using the canonical HTTPX API.

## Complete Example

```zig
//! Static Files, HTML/CSS/JS Rendering, Live Watcher, and Hot-Reload Example.
//!
//! Demonstrates:
//! 1. Server with console logging
//! 2. Dynamic HTML, CSS, JavaScript, and JSON rendering
//! 3. Static file mounting with automatic live-reload script injection
//! 4. Background file watcher (`httpx.Watcher`) monitoring assets and broadcasting reloads
//! Run with: `zig build run-live-static-watcher`

const std = @import("std");
const httpx = @import("httpx");

fn indexHtmlHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    const htmlContent =
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="UTF-8">
        \\  <title>Zig App</title>
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
    return ctx.html(htmlContent);
}

fn styleCssHandler(_: *httpx.router.Context) anyerror!httpx.router.Response {
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
        .contentType = "text/css; charset=utf-8",
    };
}

fn appJsHandler(_: *httpx.router.Context) anyerror!httpx.router.Response {
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
        .contentType = "text/javascript; charset=utf-8",
    };
}

fn apiStatusHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    return ctx.renderJson(.{
        .status = "healthy",
        .engine = "httpx.zig",
        .version = "0.1.0",
        .framework = "httpx.zig",
        .hotReload = true,
    });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    std.debug.print("=== Server with Live File Watcher & Hot-Reload ===\n", .{});

    // 1. Setup sample asset for watcher
    const testAsset = "sample_dev_asset.txt";
    try httpx.static.files.writeFile(testAsset, "Initial static asset content");

    // 2. Initialize Watcher with reload callbacks
    var fileWatcher = try httpx.static.Watcher.init(allocator, io, .{
        .dirPath = ".",
        .pollIntervalMs = 50,
    });
    defer fileWatcher.deinit();
    try fileWatcher.watchFile(testAsset);
    try fileWatcher.start();

    std.debug.print("[INFO] Background file watcher started for '{s}'\n", .{testAsset});

    // 3. Initialize server with colored lifecycle logging
    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
        .maxConnections = 4,
        .logging = .{},
    });
    defer server.deinit();

    try server.get("/", indexHtmlHandler);
    try server.get("/style.css", styleCssHandler);
    try server.get("/app.js", appJsHandler);
    try server.get("/api/status", apiStatusHandler);

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
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    // GET / (HTML)
    const urlRoot = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{port});
    defer allocator.free(urlRoot);
    var resHtml = try client.get(urlRoot, .{});
    defer resHtml.deinit();
    std.debug.print("[200 OK] GET / -> text/html (len={d})\n", .{resHtml.body.len});

    // GET /style.css (CSS)
    const urlCss = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/style.css", .{port});
    defer allocator.free(urlCss);
    var resCss = try client.get(urlCss, .{});
    defer resCss.deinit();
    std.debug.print("[200 OK] GET /style.css -> text/css\n", .{});

    // GET /app.js (JS)
    const urlJs = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/app.js", .{port});
    defer allocator.free(urlJs);
    var resJs = try client.get(urlJs, .{});
    defer resJs.deinit();
    std.debug.print("[200 OK] GET /app.js -> text/javascript\n", .{});

    // GET /api/status (JSON)
    const urlApi = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/api/status", .{port});
    defer allocator.free(urlApi);
    var resJson = try client.get(urlApi, .{});
    defer resJson.deinit();
    std.debug.print("[200 OK] GET /api/status -> {s}\n", .{resJson.body});

    // 5. Test Live Watcher File Update
    std.debug.print("[HOT RELOAD] Modifying static file '{s}'...\n", .{testAsset});
    try httpx.fs.writeFile(testAsset, "Updated asset content trigger");

    httpx.clock.sleepMillis(io, 150);
    while (fileWatcher.next()) |event| {
        std.debug.print("[HOT RELOAD] Event: path='{s}', kind={s}, strategy={s}\n", .{
            event.path,
            @tagName(event.kind),
            @tagName(event.strategy),
        });
    }
    const changesDetected = fileWatcher.changeCount();
    std.debug.print("[HOT RELOAD] Detected {d} change(s) - Triggered automatic reload!\n", .{changesDetected});
    std.debug.print("All endpoints and hot-reload verified successfully.\n", .{});
}
```

## Expected Output

```text
=== Server with Live File Watcher & Hot-Reload ===
[INFO] Background file watcher started for 'sample_dev_asset.txt'
[INFO] Server running on http://127.0.0.1:54321 (Press CTRL+C to quit)
[200 OK] GET / -> text/html (len=512)
[200 OK] GET /style.css -> text/css
[200 OK] GET /app.js -> text/javascript
[200 OK] GET /api/status -> {"status":"healthy","engine":"httpx.zig","version":"0.1.0","framework":"httpx.zig","hotReload":true}
[HOT RELOAD] Modifying static file 'sample_dev_asset.txt'...
[HOT RELOAD] Event: path='sample_dev_asset.txt', kind=modified, strategy=poll
[HOT RELOAD] Detected 1 change(s) - Triggered automatic reload!
All endpoints and hot-reload verified successfully.
```

The port number, HTML byte length, and watcher event details vary per run; the JSON body shape matches the `apiStatusHandler` response above.

## How to Run

```bash
zig build run-live-static-watcher
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
