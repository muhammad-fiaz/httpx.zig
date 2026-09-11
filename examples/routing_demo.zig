//! Framework routing demo: typed parameters, slugs, catch-all paths,
//! route groups, mounted routers, named routes + reversing, struct binding,
//! 404/405 handling — all verified live over loopback.
//!
//! Run with: `zig build run-routing-demo`

const std = @import("std");
const httpx = @import("httpx");

fn userHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const id = ctx.paramInt("id") orelse return .{ .status = 400, .body = "bad id" };
    var buf: [32]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "user={d}", .{id});
    return .{ .status = 200, .body = try ctx.allocator.dupe(u8, body) };
}

fn postHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const P = struct {
        userId: u64,
        postId: u64,
    };
    const p = ctx.bindParams(P) catch return .{ .status = 400, .body = "bad params" };
    var buf: [64]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "user={d} post={d}", .{ p.userId, p.postId });
    return .{ .status = 200, .body = try ctx.allocator.dupe(u8, body) };
}

fn slugHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const slug = ctx.param("slug") orelse "none";
    var buf: [96]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "slug={s}", .{slug});
    return .{ .status = 200, .body = try ctx.allocator.dupe(u8, body) };
}

fn fileHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const path = ctx.param("path") orelse "none";
    var buf: [128]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "file={s}", .{path});
    return .{ .status = 200, .body = try ctx.allocator.dupe(u8, body) };
}

fn linkHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    _ = ctx;
    return .{ .status = 200, .body = "link ok" };
}

fn check(cond: bool, comptime label: []const u8) !void {
    if (!cond) {
        std.debug.print("FAIL: {s}\n", .{label});
        return error.CheckFailed;
    }
    std.debug.print("ok: {s}\n", .{label});
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
        .maxConnections = 32,
    });
    defer server.deinit();

    // Grouped API routes with a shared prefix.
    const api = server.group("/api", .{});
    try api.get("/users/{id:int}", userHandler, .{ .name = "api-user" });
    try api.get("/users/{userId:int}/posts/{postId:int}", postHandler, .{ .name = "api-post" });

    // Mounted sub-router.
    var blog = httpx.Router.init(allocator);
    defer blog.deinit();
    try blog.get("/{slug:slug}", slugHandler, .{});
    try server.mount("/blog", &blog, .{});

    // Catch-all + reversing demo routes.
    try server.get("/files/{path:path}", fileHandler);
    try server.get("/link", linkHandler);

    // URL reversing uses the same compiled metadata as matching.
    const profile_url = try server.router.url("api-user", .{ .id = 7 });
    defer allocator.free(profile_url);
    try check(std.mem.eql(u8, profile_url, "/api/users/7"), "reverse api-user");

    const port = server.localPort();
    const Runner = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const t = try std.Thread.spawn(.{}, Runner.run, .{&server});
    defer t.join();
    defer server.stop();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var url_buf: [96]u8 = undefined;
    const get = struct {
        fn run(c: *httpx.Client, url: []const u8) !struct {
            status: u16,
            body: []u8,
        } {
            var r = try c.get(url, .{});
            defer r.deinit();
            return .{ .status = r.status, .body = try c.allocator.dupe(u8, r.body) };
        }
    }.run;

    const url1 = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/users/42", .{port});
    const r1 = try get(&client, url1);
    defer allocator.free(r1.body);
    try check(r1.status == 200 and std.mem.eql(u8, r1.body, "user=42"), "GET typed int");

    const url2 = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/users/abc", .{port});
    const r2 = try get(&client, url2);
    defer allocator.free(r2.body);
    try check(r2.status == 404, "GET int rejects abc");

    const url3 = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/api/users/3/posts/4", .{port});
    const r3 = try get(&client, url3);
    defer allocator.free(r3.body);
    try check(r3.status == 200 and std.mem.eql(u8, r3.body, "user=3 post=4"), "GET struct binding");

    const url4 = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/blog/hello-world", .{port});
    const r4 = try get(&client, url4);
    defer allocator.free(r4.body);
    try check(r4.status == 200 and std.mem.eql(u8, r4.body, "slug=hello-world"), "GET mounted slug");

    const url5 = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/files/a/b/c.txt", .{port});
    const r5 = try get(&client, url5);
    defer allocator.free(r5.body);
    try check(r5.status == 200 and std.mem.eql(u8, r5.body, "file=a/b/c.txt"), "GET catch-all");

    // POST where only GET exists -> 405 + Allow.
    const url6 = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/link", .{port});
    var r6 = try client.post(url6, .{});
    defer r6.deinit();
    try check(r6.status == 405, "POST /link is 405");
    try check(r6.header("Allow") != null, "405 carries Allow");

    const url7 = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/missing", .{port});
    const r7 = try get(&client, url7);
    defer allocator.free(r7.body);
    try check(r7.status == 404, "GET missing is 404");

    std.debug.print("ROUTING DEMO VERIFICATION PASSED\n", .{});
}
