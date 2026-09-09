//! Example: complete embedded + filesystem website with file-based routing.
//!
//! Covers in one runnable program:
//!   individual + recursive embedded assets, embedded templates, file
//!   routes, clean + extension URLs, trailing-slash modes, .html/.htm,
//!   index routes, slugs, custom + dynamic routes, navigation, static
//!   assets, SPA coexistence, code routes, watcher + live reload (fs mode)
//!   and single-executable production mode (embedded).
//!
//! Run embedded (default): `zig build run-website`
//! Run from filesystem:    `zig build run-website -- --fs`

const std = @import("std");
const httpx = @import("httpx");

const embedded = @import("embed_website");

fn health(_: *httpx.Context) anyerror!httpx.Response {
    return .{ .status = 200, .body = @constCast("{\"status\":\"ok\"}") };
}

fn apiUsers(_: *httpx.Context) anyerror!httpx.Response {
    return .{ .status = 200, .body = @constCast("[{\"id\":1}]") };
}

fn check(client: *httpx.Client, url: []const u8, want_status: u16, want_body_part: ?[]const u8) !void {
    var res = try client.get(url, .{});
    defer res.deinit();
    if (res.status != want_status) {
        std.debug.print("FAIL {s}: status {d}, want {d}\n", .{ url, res.status, want_status });
        return error.CheckFailed;
    }
    if (want_body_part) |part| {
        if (std.mem.indexOf(u8, res.body, part) == null) {
            std.debug.print("FAIL {s}: body missing '{s}'\n", .{ url, part });
            return error.CheckFailed;
        }
    }
    std.debug.print("ok {s} -> {d}\n", .{ url, res.status });
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var use_fs = false;
    const raw_args = try init.minimal.args.toSlice(init.arena.allocator());
    for (raw_args[1..]) |a| {
        if (std.mem.eql(u8, a, "--fs")) use_fs = true;
    }

    std.debug.print("==> HTTPX website demo ({s} mode)\n", .{if (use_fs) "filesystem" else "embedded"});

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
    });
    defer server.deinit();

    // Code routes first: exact matches always win over generated routes.
    try server.get("/health", health);
    try server.get("/api/users", apiUsers);

    var site = if (use_fs)
        try httpx.Site.init(allocator, io, .{ .filesystem = "examples/website/dist" }, .{
            .custom = &.{
                .{ .file = "about/company.htm", .route = "/company", .name = "company" },
            },
        })
    else
        try httpx.Site.init(allocator, io, .{ .embedded = &embedded.files }, .{
            .watch = false,
            .reload = false,
            .custom = &.{
                .{ .file = "about/company.htm", .route = "/company", .name = "company" },
            },
        });
    defer site.deinit();
    try site.mount(&server);

    for (site.collisions()) |c| {
        std.debug.print("collision {s}: {s} wins over {s}\n", .{ c.route, c.winner, c.loser });
    }

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

    var url_buf: [256]u8 = undefined;
    const base = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{port});

    const Case = struct { path: []const u8, status: u16, body: ?[]const u8 };
    const cases = [_]Case{
        .{ .path = "/", .status = 200, .body = null },
        .{ .path = "/about", .status = 200, .body = "About" },
        .{ .path = "/about/", .status = 200, .body = "About" },
        .{ .path = "/about/team", .status = 200, .body = "Team" },
        .{ .path = "/about/team.html", .status = 200, .body = "Team" },
        .{ .path = "/company", .status = 200, .body = "Company" },
        .{ .path = "/blog", .status = 200, .body = "Blog" },
        .{ .path = "/blog/hello-world", .status = 200, .body = "Hello World" },
        .{ .path = "/users/42", .status = 200, .body = "User page" },
        .{ .path = "/assets/css/app.css", .status = 200, .body = "font-family" },
        .{ .path = "/assets/images/logo.svg", .status = 200, .body = "<svg" },
        .{ .path = "/health", .status = 200, .body = "ok" },
        .{ .path = "/api/users", .status = 200, .body = "\"id\":1" },
        .{ .path = "/nope", .status = 404, .body = null },
    };
    for (cases) |c| {
        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base, c.path });
        defer allocator.free(url);
        try check(&client, url, c.status, c.body);
    }

    // Navigation resolves through canonical route metadata.
    const home_url = try site.urlFor("home", .{}, null);
    defer allocator.free(home_url);
    const user_url = try site.urlFor("users.{id}", .{ .id = 7 }, null);
    defer allocator.free(user_url);
    std.debug.print("nav home={s} user={s}\n", .{ home_url, user_url });

    std.debug.print("website verification successful.\n", .{});
    server.stop();

    if (!use_fs) httpx.assets.globalStore(allocator).deinit();
}
