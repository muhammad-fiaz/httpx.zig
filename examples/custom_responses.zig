//! Custom responses example: Demonstrates rich responses including HTML, JSON,
//! plain text, XML, RSS, Atom, robots.txt, sitemap.xml, binary octet stream, and custom status/headers.

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try httpx.Server.init(allocator, .{
        .host = "127.0.0.1",
        .port = 0, // Pick ephemeral port for testing
        .max_connections = 9,
    });
    defer server.deinit();

    // 1. HTML response
    try server.get("/html", struct {
        fn handle(ctx: *httpx.Context) anyerror!httpx.Response {
            return ctx.html("<!DOCTYPE html><html><body><h1>Hello HTML</h1></body></html>");
        }
    }.handle);

    // 2. JSON response
    try server.get("/json", struct {
        fn handle(ctx: *httpx.Context) anyerror!httpx.Response {
            return ctx.renderJson(.{
                .status = "ok",
                .version = "1.0.0",
                .features = [_][]const u8{ "html", "json", "xml", "rss", "atom", "sitemap", "robots" },
            });
        }
    }.handle);

    // 3. Plain text response
    try server.get("/text", struct {
        fn handle(ctx: *httpx.Context) anyerror!httpx.Response {
            return ctx.text("This is plain text response.");
        }
    }.handle);

    // 4. XML response
    try server.get("/xml", struct {
        fn handle(ctx: *httpx.Context) anyerror!httpx.Response {
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
        fn handle(ctx: *httpx.Context) anyerror!httpx.Response {
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
                \\    <description>Production ready HTTP stack for Zig</description>
                \\  </item>
                \\</channel>
                \\</rss>
            );
        }
    }.handle);

    // 6. Atom Feed
    try server.get("/atom.xml", struct {
        fn handle(ctx: *httpx.Context) anyerror!httpx.Response {
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
        fn handle(ctx: *httpx.Context) anyerror!httpx.Response {
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
        fn handle(ctx: *httpx.Context) anyerror!httpx.Response {
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
        fn handle(ctx: *httpx.Context) anyerror!httpx.Response {
            const bytes = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }; // PNG magic bytes
            return ctx.binary(&bytes, "application/octet-stream");
        }
    }.handle);

    // 10. Custom status code and content-type
    try server.get("/custom", struct {
        fn handle(ctx: *httpx.Context) anyerror!httpx.Response {
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
    var client = try httpx.Client.init(allocator, .{});
    defer client.deinit();

    // Verify /html
    var url_buf: [128]u8 = undefined;
    const html_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/html", .{port});
    var res = try client.get(html_url);
    std.debug.print("1. GET /html -> status={d}, content-type={?s}\n", .{ res.status, res.header("content-type") });
    res.deinit();

    // Verify /json
    const json_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/json", .{port});
    res = try client.get(json_url);
    std.debug.print("2. GET /json -> status={d}, content-type={?s}, body={s}\n", .{ res.status, res.header("content-type"), res.body });
    res.deinit();

    // Verify /xml
    const xml_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/xml", .{port});
    res = try client.get(xml_url);
    std.debug.print("3. GET /xml -> status={d}, content-type={?s}\n", .{ res.status, res.header("content-type") });
    res.deinit();

    // Verify /rss.xml
    const rss_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/rss.xml", .{port});
    res = try client.get(rss_url);
    std.debug.print("4. GET /rss.xml -> status={d}, content-type={?s}\n", .{ res.status, res.header("content-type") });
    res.deinit();

    // Verify /atom.xml
    const atom_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/atom.xml", .{port});
    res = try client.get(atom_url);
    std.debug.print("5. GET /atom.xml -> status={d}, content-type={?s}\n", .{ res.status, res.header("content-type") });
    res.deinit();

    // Verify /robots.txt
    const robots_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/robots.txt", .{port});
    res = try client.get(robots_url);
    std.debug.print("6. GET /robots.txt -> status={d}, content-type={?s}\n", .{ res.status, res.header("content-type") });
    res.deinit();

    // Verify /sitemap.xml
    const sitemap_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/sitemap.xml", .{port});
    res = try client.get(sitemap_url);
    std.debug.print("7. GET /sitemap.xml -> status={d}, content-type={?s}\n", .{ res.status, res.header("content-type") });
    res.deinit();

    // Verify /binary
    const binary_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/binary", .{port});
    res = try client.get(binary_url);
    std.debug.print("8. GET /binary -> status={d}, content-type={?s}, bytes_len={d}\n", .{ res.status, res.header("content-type"), res.body.len });
    res.deinit();

    // Verify /custom
    const custom_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/custom", .{port});
    res = try client.get(custom_url);
    std.debug.print("9. GET /custom -> status={d}, content-type={?s}\n", .{ res.status, res.header("content-type") });
    res.deinit();

    t.join();
    std.debug.print("Custom HTTP Responses verification completed successfully.\n", .{});
}
