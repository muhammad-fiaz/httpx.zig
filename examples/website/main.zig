//! File-based website served entirely by `httpx.Server`.
//!
//! The file routes, static assets, and templates are enabled through the
//! `.site` option of `httpx.Server.init`: a filesystem directory in
//! development, or an explicit embedded-file manifest in production.
//! Mounting happens in `run()`, after the code routes below, so explicit
//! handlers always win over generated routes.
//!
//! Run embedded (default): `zig build run-website`
//! Run from filesystem:    `zig build run-website -- --fs`

const std = @import("std");
const httpx = @import("httpx");

// Embedded files, listed explicitly: one entry per file under dist/.
const embedded = [_]httpx.assets.EmbeddedFile{
    .{ .path = "index.html", .content = @embedFile("dist/index.html") },
    .{ .path = "blog/hello-world.html", .content = @embedFile("dist/blog/hello-world.html") },
    .{ .path = "blog/index.html", .content = @embedFile("dist/blog/index.html") },
    .{ .path = "about/company.htm", .content = @embedFile("dist/about/company.htm") },
    .{ .path = "about/index.html", .content = @embedFile("dist/about/index.html") },
    .{ .path = "about/team.html", .content = @embedFile("dist/about/team.html") },
    .{ .path = "users/[id].html", .content = @embedFile("dist/users/[id].html") },
    .{ .path = "templates/layout.html", .content = @embedFile("dist/templates/layout.html") },
    .{ .path = "templates/components/footer.html", .content = @embedFile("dist/templates/components/footer.html") },
    .{ .path = "templates/components/header.html", .content = @embedFile("dist/templates/components/header.html") },
    .{ .path = "assets/css/app.css", .content = @embedFile("dist/assets/css/app.css") },
    .{ .path = "assets/images/logo.svg", .content = @embedFile("dist/assets/images/logo.svg") },
    .{ .path = "assets/js/app.js", .content = @embedFile("dist/assets/js/app.js") },
};

fn health(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return .{ .status = 200, .body = "{\"status\":\"ok\"}", .contentType = "application/json" };
}

fn apiUsers(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return .{ .status = 200, .body = "[{\"id\":1}]", .contentType = "application/json" };
}

fn check(client: *httpx.Client, url: []const u8, wantStatus: u16, wantBodyPart: ?[]const u8) !void {
    var res = try client.get(url, .{});
    defer res.deinit();
    if (res.status != wantStatus) {
        std.debug.print("FAIL {s}: status {d}, want {d}\n", .{ url, res.status, wantStatus });
        return error.CheckFailed;
    }
    if (wantBodyPart) |part| {
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

    var useFs = false;
    const rawArgs = try init.minimal.args.toSlice(init.arena.allocator());
    for (rawArgs[1..]) |a| {
        if (std.mem.eql(u8, a, "--fs")) useFs = true;
    }

    var server = if (useFs)
        try httpx.Server.init(allocator, io, .{
            .host = "127.0.0.1",
            .port = 0,
            .enableDocs = false,
            .site = .{
                .filesystem = "examples/website/dist",
            },
        })
    else
        try httpx.Server.init(allocator, io, .{
            .host = "127.0.0.1",
            .port = 0,
            .enableDocs = false,
            .site = .{
                .embedded = &embedded,
                .watch = false,
                .reload = false,
            },
        });
    defer server.deinit();

    // Code routes first: exact matches always win over generated routes.
    try server.get("/health", .{ .handler = health });
    try server.get("/api/users", .{ .handler = apiUsers });

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

    var urlBuf: [256]u8 = undefined;
    const base = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}", .{port});

    const Case = struct { path: []const u8, status: u16, body: ?[]const u8 };
    const cases = [_]Case{
        .{ .path = "/", .status = 200, .body = null },
        .{ .path = "/about", .status = 200, .body = "About" },
        .{ .path = "/about/", .status = 200, .body = "About" },
        .{ .path = "/about/team", .status = 200, .body = "Team" },
        .{ .path = "/about/team.html", .status = 200, .body = "Team" },
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

    server.requestShutdown();

    if (!useFs) httpx.assets.globalStore(allocator).deinit();
}
