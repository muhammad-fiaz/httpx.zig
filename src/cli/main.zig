const std = @import("std");
const httpx = @import("httpx");
const args = @import("args");

fn indexHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return ctx.render("index.html", .{
        .title = "HTTPX",
        .message = "Welcome to HTTPX Native Templates!",
        .version = "0.2.0",
    }) catch {
        // If template engine is not available or index.html is missing, return friendly landing page
        return ctx.html(
            \\<!DOCTYPE html>
            \\<html>
            \\<head><title>HTTPX Server</title>
            \\<style>body{font-family:system-ui,sans-serif;background:#0f172a;color:#f8fafc;padding:3rem;margin:0}h1{color:#38bdf8}code{background:#1e293b;padding:0.2rem 0.4rem;border-radius:4px}</style>
            \\</head>
            \\<body>
            \\<h1>HTTPX Server</h1>
            \\<p>Server is running. Place your templates in <code>templates/index.html</code> to customize this page.</p>
            \\</body>
            \\</html>
        );
    };
}

fn healthHandler(_: *httpx.Context) anyerror!httpx.Response {
    return .{
        .status = 200,
        .body = "{\"status\":\"ok\",\"service\":\"httpx\"}",
        .content_type = "application/json",
    };
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var ap = try args.ArgumentParser.init(allocator, .{
        .name = "httpx",
        .version = "0.2.0",
        .description = "HTTPX production-grade web framework & development server",
    });
    defer ap.deinit();

    // Server options
    try ap.addOption("host", .{
        .short = 'H',
        .help = "Host address to bind (default: 127.0.0.1)",
        .default = "127.0.0.1",
    });
    try ap.addOption("port", .{
        .short = 'p',
        .help = "Port to bind (default: 8080)",
        .default = "8080",
    });
    try ap.addOption("backlog", .{
        .help = "Socket listen backlog (default: 128)",
        .default = "128",
    });
    try ap.addOption("workers", .{
        .help = "Maximum concurrent connections (default: 0 = unlimited)",
        .default = "0",
    });

    // Web & Templates options
    try ap.addOption("templates", .{
        .help = "Path to templates directory (default: templates)",
        .default = "templates",
    });
    try ap.addFlag("no-templates", .{
        .help = "Disable template engine",
    });
    try ap.addOption("static", .{
        .help = "Mount directory for static assets (e.g. static/)",
    });
    try ap.addOption("spa", .{
        .help = "Mount directory for Single Page Application fallback",
    });

    // Development & Watching
    try ap.addFlag("watch", .{
        .help = "Enable development file watcher for live changes (default: true)",
    });
    try ap.addFlag("no-watch", .{
        .help = "Disable development file watcher",
    });
    try ap.addFlag("reload", .{
        .help = "Enable browser live reload (default: true if watch enabled)",
    });
    try ap.addFlag("no-reload", .{
        .help = "Disable browser live reload",
    });

    // Protocols & Security
    try ap.addFlag("https", .{
        .help = "Enable TLS / HTTPS",
    });
    try ap.addOption("cert", .{
        .help = "Path to TLS certificate file",
    });
    try ap.addOption("key", .{
        .help = "Path to TLS private key file",
    });
    try ap.addFlag("http1", .{
        .help = "Enable HTTP/1.1 (default: true)",
    });
    try ap.addFlag("http2", .{
        .help = "Enable HTTP/2 cleartext / ALPN (default: true)",
    });
    try ap.addFlag("http3", .{
        .help = "Enable HTTP/3 over QUIC (default: false)",
    });

    // Logging & Observability
    try ap.addOption("log-level", .{
        .help = "Minimum logging level (debug, info, warn, error)",
        .default = "info",
    });

    // Retrieve raw args to handle optional 'serve' subcommand cleanly
    const raw_args = try init.minimal.args.toSlice(init.arena.allocator());

    // Skip argv[0], and if argv[1] is "serve", skip that too
    var parse_slice: []const [:0]const u8 = raw_args[1..];
    if (parse_slice.len > 0 and std.mem.eql(u8, parse_slice[0], "serve")) {
        parse_slice = parse_slice[1..];
    }

    var result = ap.parse(parse_slice) catch |err| {
        if (err == error.HelpRequested) {
            try ap.printHelp();
            return;
        }
        if (err == error.VersionRequested) {
            std.debug.print("httpx version {s}\n", .{ap.getVersion()});
            return;
        }
        std.debug.print("Error: {s}\n", .{@errorName(err)});
        try ap.printHelp();
        std.process.exit(1);
    };
    defer result.deinit();

    const host = result.getOrString("host", "127.0.0.1");
    const port_i = result.getInt("port") orelse 8080;
    const port: u16 = if (port_i > 0 and port_i <= 65535) @intCast(port_i) else 8080;
    const backlog_i = result.getInt("backlog") orelse 128;
    const workers_i = result.getInt("workers") orelse 0;

    const no_templates = result.getBool("no-templates") orelse false;
    const templates_dir = result.getOrString("templates", "templates");

    // Watcher defaults to true in CLI development server unless --no-watch is given
    const no_watch = result.getBool("no-watch") orelse false;
    const watch_flag = result.getBool("watch") orelse false;
    const watch_enabled = if (no_watch) false else (if (watch_flag) true else true);

    const no_reload = result.getBool("no-reload") orelse false;
    const reload_flag = result.getBool("reload") orelse false;
    const reload_enabled = if (no_reload) false else (if (reload_flag) true else watch_enabled);

    const static_dir = result.getString("static");
    const spa_dir = result.getString("spa");

    // Build ServerConfig
    var server_cfg = httpx.ServerConfig{
        .host = host,
        .port = port,
        .max_port_attempts = 10,
        .max_connections = if (workers_i > 0) @intCast(workers_i) else 0,
        .watch = watch_enabled,
        .watch_dir = templates_dir,
        .live_reload = reload_enabled,
    };
    _ = backlog_i;

    if (no_templates) {
        server_cfg.templates = .{ .enabled = false };
    } else {
        server_cfg.templates = .{
            .directory = templates_dir,
            .enabled = true,
        };
    }

    // Initialize Server
    var server = try httpx.Server.init(allocator, io, server_cfg);
    defer server.deinit();

    // Register default routes
    try server.get("/", indexHandler);
    try server.get("/health", healthHandler);

    if (static_dir) |sdir| {
        server.static("/static", sdir) catch |err| {
            std.debug.print("Warning: failed to mount static dir '{s}': {s}\n", .{ sdir, @errorName(err) });
        };
    }

    if (spa_dir) |spadir| {
        server.spa("/", spadir) catch |err| {
            std.debug.print("Warning: failed to mount SPA dir '{s}': {s}\n", .{ spadir, @errorName(err) });
        };
    }

    const local_port = server.localPort();

    std.debug.print(
        \\
        \\  _   _ _____ _____ ______  __
        \\ | | | |_   _|_   _| ___ \ \/ /
        \\ | |_| | | |   | | | |_/ / >  < 
        \\ |  _  | | |   | | |  __/ / /\ \
        \\ |_| |_| |_|   |_| |_|   /_/  \_\  v0.2.0
        \\
        \\ HTTPX Server running at: http://{s}:{d}
        \\ - Templates: {s} ({s})
        \\ - File Watcher: {s}
        \\ - Live Reload: {s}
        \\ - Static Files: {s}
        \\
        \\ Press Ctrl+C to stop.
        \\
    , .{
        host,
        local_port,
        templates_dir,
        if (no_templates) "disabled" else "enabled",
        if (watch_enabled) "enabled" else "disabled",
        if (reload_enabled) "enabled" else "disabled",
        static_dir orelse "none",
    });

    server.run();
}
