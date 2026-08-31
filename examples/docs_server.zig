const std = @import("std");
const httpx = @import("httpx");

pub const std_options: std.Options = .{
    .unexpected_error_tracing = false,
};

fn listItemsHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.renderJson(.{
        .items = &[_]struct { id: u32, name: []const u8, price: f64 }{
            .{ .id = 101, .name = "Pro Router Widget", .price = 49.99 },
            .{ .id = 102, .name = "Async SSE Streamer", .price = 19.99 },
            .{ .id = 103, .name = "QUIC Protocol Engine", .price = 99.00 },
        },
        .count = @as(usize, 3),
    });
}

fn getItemHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const item_id = ctx.param("id") orelse "0";
    return ctx.renderJson(.{
        .id = item_id,
        .name = "Queried Item",
        .status = "available",
        .engine = "httpx.zig",
    });
}

fn homePageHandler(_: *httpx.Context) anyerror!httpx.Response {
    const html =
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="UTF-8">
        \\  <title>httpx.zig - Fast, Modern Web Engine</title>
        \\  <style>
        \\    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0b0f19; color: #f3f4f6; margin: 0; padding: 2rem; }
        \\    .card { max-width: 850px; margin: 2rem auto; background: #111827; padding: 2.5rem; border-radius: 16px; border: 1px solid #1f2937; box-shadow: 0 10px 25px -5px rgba(0,0,0,0.5); }
        \\    h1 { color: #f7a41d; font-size: 2rem; }
        \\    a { color: #38bdf8; text-decoration: none; }
        \\    a:hover { text-decoration: underline; }
        \\    .badge { display: inline-block; background: #1e40af; color: #93c5fd; padding: 0.25rem 0.75rem; border-radius: 9999px; font-size: 0.875rem; margin-right: 0.5rem; }
        \\  </style>
        \\</head>
        \\<body>
        \\  <div class="card">
        \\    <h1>httpx.zig</h1>
        \\    <p>Production-ready HTTP/1.x, HTTP/2, HTTP/3 client &amp; server for Zig.</p>
        \\    <div>
        \\      <span class="badge">HTTP/1.1</span>
        \\      <span class="badge">HTTP/2</span>
        \\      <span class="badge">HTTP/3</span>
        \\      <span class="badge">TLS 1.3</span>
        \\      <span class="badge">QUIC</span>
        \\    </div>
        \\    <br>
        \\    <p><a href="/docs">Swagger UI</a> &middot; <a href="/redoc">ReDoc</a> &middot; <a href="/scalar">Scalar</a> &middot; <a href="/graphiql">GraphiQL</a></p>
        \\    <p><a href="/openapi.json">OpenAPI 3.1 Spec</a></p>
        \\  </div>
        \\</body>
        \\</html>
    ;
    return .{
        .status = 200,
        .body = html,
        .content_type = "text/html; charset=utf-8",
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Starting httpx Documentation & API Server ===\n", .{});

    var server = try httpx.Server.init(allocator, .{
        .host = "127.0.0.1",
        .port = 0,
        .docs_enabled = true,
        .docs = .{
            .title = "HTTPX Modern API Suite",
            .version = "0.2.0",
            .description = "Full-featured native HTTP server with OpenAPI & GraphQL documentation.",
            .swagger = .{ .enabled = true, .route = "/docs", .title = "Swagger UI" },
            .redoc = .{ .enabled = true, .route = "/redoc", .title = "ReDoc" },
            .scalar = .{ .enabled = true, .route = "/scalar", .title = "Scalar Reference" },
            .graphiql = .{ .enabled = true, .route = "/graphiql", .graphql_endpoint = "/graphql", .title = "GraphiQL IDE" },
        },
        .max_connections = 5,
        .logging = .{
            .enabled = true,
            .color = .never,
        },
    });
    defer server.deinit();

    try server.get("/", homePageHandler);
    try server.get("/api/items", listItemsHandler);
    try server.get("/api/items/:id", getItemHandler);

    const port = server.localPort();
    std.debug.print("[INFO] Server started on http://127.0.0.1:{d}\n", .{port});

    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, ServerThread.run, .{&server});

    var client = try httpx.Client.init(allocator, .{});
    defer client.deinit();

    var url_buf: [128]u8 = undefined;
    const url_items = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/items", .{port});
    var res = try client.get(url_items);
    std.debug.print("GET /api/items -> status={d}, body={s}\n", .{ res.status, res.body });
    res.deinit();

    server.requestShutdown();
    t.join();
    httpx.docs.unmount();
    std.debug.print("Docs server verification completed successfully.\n", .{});
}
