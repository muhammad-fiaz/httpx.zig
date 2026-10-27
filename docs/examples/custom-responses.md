# Example: Custom Responses

Demonstrates customResponses.zig using the canonical HTTPX API.

## Complete Example

```zig
//! Custom responses example: Demonstrates rich responses including HTML, JSON,
//! plain text, XML, RSS, Atom, robots.txt, sitemap.xml, binary octet stream, and custom status/headers.

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0, // Pick ephemeral port for testing
        .maxConnections = 9,
    });
    defer server.deinit();

    // 1. HTML response
    try server.get("/html", struct {
        fn handle(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
            return ctx.html("<!DOCTYPE html><html><body><h1>Hello HTML</h1></body></html>");
        }
    }.handle);

    // 2. JSON response
    try server.get("/json", struct {
        fn handle(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
            return ctx.renderJson(.{
                .status = "ok",
                .version = "1.0.0",
                .features = [_][]const u8{ "html", "json", "xml", "rss", "atom", "sitemap", "robots" },
            });
        }
    }.handle);

    // 3. Plain text response
    try server.get("/text", struct {
        fn handle(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
            return ctx.text("This is plain text response.");
        }
    }.handle);

    // 4. XML response
    try server.get("/xml", struct {
        fn handle(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
            return ctx.xml(
                \\<?xml version="1.0" encoding="UTF-8"?>
                \\<response>
                \\  <status>success</status>
                \\  <data>custom xml payload</data>
                \\</response>
            );
        }
    }.handle);

    // 5. RSS 2.0 Feed
    try server.get("/rss.xml", struct {
        fn handle(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
            return ctx.rss(
                \\<?xml version="1.0" encoding="UTF-8" ?>
                \\<rss version="2.0">
                \\<channel>
                \\  <title>httpx.zig Updates</title>
                \\  <link>https://github.com/muhammad-fiaz/httpx.zig</link>
                \\  <description>Latest news about httpx.zig</description>
                \\  <item>
                \\    <title>v1.0.0 Released</title>
                \\    <link>https://github.com/muhammad-fiaz/httpx.zig/releases/tag/v1.0.0</link>
                \\    <description>HTTP stack for Zig</description>
                \\  </item>
                \\</channel>
                \\</rss>
            );
        }
    }.handle);

    // 6. Atom Feed
    try server.get("/atom.xml", struct {
        fn handle(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
            return ctx.atom(
                \\<?xml version="1.0" encoding="utf-8"?>
                \\<feed xmlns="http://www.w3.org/2005/Atom">
                \\  <title>httpx.zig Atom Feed</title>
                \\  <id>urn:uuid:60a76c80-d399-11d9-b91C-0003939e0af6</id>
                \\  <updated>2026-08-30T00:00:00Z</updated>
                \\</feed>
            );
        }
    }.handle);

    // 7. robots.txt
    try server.get("/robots.txt", struct {
        fn handle(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
            return ctx.robots(
                \\User-agent: *
                \\Allow: /
                \\Disallow: /admin/
                \\Sitemap: http://127.0.0.1/sitemap.xml
            );
        }
    }.handle);

    // 8. sitemap.xml
    try server.get("/sitemap.xml", struct {
        fn handle(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
            return ctx.sitemap(
                \\<?xml version="1.0" encoding="UTF-8"?>
                \\<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
                \\  <url>
                \\    <loc>http://127.0.0.1/</loc>
                \\    <priority>1.0</priority>
                \\  </url>
                \\</urlset>
            );
        }
    }.handle);

    // 9. Binary Octet Stream
    try server.get("/binary", struct {
        fn handle(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
            const bytes = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }; // PNG magic bytes
            return ctx.binary(&bytes, "application/octet-stream");
        }
    }.handle);

    // 10. Custom status code and content-type
    try server.get("/custom", struct {
        fn handle(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
            return ctx.custom(201, "application/vnd.api+json", "{\"data\":{\"type\":\"item\",\"id\":\"42\"}}");
        }
    }.handle);

    const port = server.localPort();
    std.debug.print("=== Custom HTTP Responses Server running on 127.0.0.1:{d} ===\n", .{port});

    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});

    var spin: usize = 0;
    while (spin < 1000) : (spin += 1) std.Thread.yield() catch {};

    // Test client requests to verify each custom response format
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    // Verify /html
    var urlBuf: [128]u8 = undefined;
    const htmlUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/html", .{port});
    var res = try client.get(htmlUrl, .{});
    std.debug.print("1. GET /html -> status={d}, content-type={?s}\n", .{ res.status, res.header("content-type") });
    res.deinit();

    // Verify /json
    const jsonUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/json", .{port});
    res = try client.get(jsonUrl, .{});
    std.debug.print("2. GET /json -> status={d}, content-type={?s}, body={s}\n", .{ res.status, res.header("content-type"), res.body });
    res.deinit();

    // Verify /xml
    const xmlUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/xml", .{port});
    res = try client.get(xmlUrl, .{});
    std.debug.print("3. GET /xml -> status={d}, content-type={?s}\n", .{ res.status, res.header("content-type") });
    res.deinit();

    // Verify /rss.xml
    const rssUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/rss.xml", .{port});
    res = try client.get(rssUrl, .{});
    std.debug.print("4. GET /rss.xml -> status={d}, content-type={?s}\n", .{ res.status, res.header("content-type") });
    res.deinit();

    // Verify /atom.xml
    const atomUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/atom.xml", .{port});
    res = try client.get(atomUrl, .{});
    std.debug.print("5. GET /atom.xml -> status={d}, content-type={?s}\n", .{ res.status, res.header("content-type") });
    res.deinit();

    // Verify /robots.txt
    const robotsUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/robots.txt", .{port});
    res = try client.get(robotsUrl, .{});
    std.debug.print("6. GET /robots.txt -> status={d}, content-type={?s}\n", .{ res.status, res.header("content-type") });
    res.deinit();

    // Verify /sitemap.xml
    const sitemapUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/sitemap.xml", .{port});
    res = try client.get(sitemapUrl, .{});
    std.debug.print("7. GET /sitemap.xml -> status={d}, content-type={?s}\n", .{ res.status, res.header("content-type") });
    res.deinit();

    // Verify /binary
    const binaryUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/binary", .{port});
    res = try client.get(binaryUrl, .{});
    std.debug.print("8. GET /binary -> status={d}, content-type={?s}, bytes_len={d}\n", .{ res.status, res.header("content-type"), res.body.len });
    res.deinit();

    // Verify /custom
    const customUrl = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/custom", .{port});
    res = try client.get(customUrl, .{});
    std.debug.print("9. GET /custom -> status={d}, content-type={?s}\n", .{ res.status, res.header("content-type") });
    res.deinit();

    t.join();
    std.debug.print("Custom HTTP Responses verification completed successfully.\n", .{});
}
```

## Expected Output

```text
=== Custom HTTP Responses Server running on 127.0.0.1:54321 ===
1. GET /html -> status=200, content-type=text/html
2. GET /json -> status=200, content-type=application/json, body={"status":"ok","version":"1.0.0","features":["html","json","xml","rss","atom","sitemap","robots"]}
3. GET /xml -> status=200, content-type=application/xml
4. GET /rss.xml -> status=200, content-type=application/rss+xml
5. GET /atom.xml -> status=200, content-type=application/atom+xml
6. GET /robots.txt -> status=200, content-type=text/plain
7. GET /sitemap.xml -> status=200, content-type=application/xml
8. GET /binary -> status=200, content-type=application/octet-stream, bytes_len=8
9. GET /custom -> status=201, content-type=application/vnd.api+json
Custom HTTP Responses verification completed successfully.
```

The port is ephemeral so it varies on every run; bodies show representative values and the binary length reflects the 8 PNG magic bytes served by the example.

## How to Run

```bash
zig build run-custom-responses
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
