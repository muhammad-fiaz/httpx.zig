//! Example: Single-File Server with Embedded Static Assets & Templates
//!
//! Demonstrates:
//! 1. Embedding static files into the .exe with @embedFile (zero disk I/O)
//! 2. Registering them in httpx.assets so server.static serves from memory
//! 3. Rendering a template resolved from the embedded registry
//! 4. Identical handler API as filesystem mode (see static_site.zig)
//!
//! Run with: `zig build run-static-embedded`

const std = @import("std");
const httpx = @import("httpx");

const index_html = @embedFile("static/index.html");
const styles_css = @embedFile("static/styles.css");
const app_js = @embedFile("static/app.js");

fn hello(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.render("greet.html", .{ .name = "Embedded" });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    std.debug.print("==> HTTPX Single-File Embedded Server Demo\n\n", .{});

    // 1. Register embedded assets (logical web paths, served from memory).
    try httpx.assets.registerEmbedded(allocator, "index.html", index_html, null);
    try httpx.assets.registerEmbedded(allocator, "styles.css", styles_css, null);
    try httpx.assets.registerEmbedded(allocator, "app.js", app_js, null);
    try httpx.assets.registerEmbedded(allocator, "greet.html", "<h1>Hello, {{ name }}!</h1>", null);
    std.debug.print("Registered {d} embedded assets\n", .{httpx.assets.globalStore(allocator).count()});

    // 2. Same server API as filesystem mode; embedded hits resolve first.
    // Explicit .templates keeps the engine alive even without a templates/
    // directory on disk: the loader consults the embedded registry first.
    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
        .max_connections = 4,
        .templates = .{ .enabled = true },
    });
    defer server.deinit();

    try server.static("/", "examples/static");
    try server.get("/hello", hello);

    const port = server.localPort();

    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});
    defer t.join();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    // 3. Verify embedded static file serving.
    const root_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{port});
    defer allocator.free(root_url);

    var res = try client.get(root_url, .{});
    defer res.deinit();
    std.debug.print("GET / -> Status: {d}, Length: {d}\n", .{ res.status, res.body.len });

    // 4. Verify embedded template rendering.
    const hello_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/hello", .{port});
    defer allocator.free(hello_url);

    var res2 = try client.get(hello_url, .{});
    defer res2.deinit();
    std.debug.print("GET /hello -> Status: {d}, Body: {s}\n", .{ res2.status, res2.body });

    std.debug.print("\nSingle-file embedded verification successful.\n", .{});
    server.stop();

    // Release global registry keys/etags owned by the debug allocator.
    httpx.assets.globalStore(allocator).deinit();
}
