const std = @import("std");
const httpx = @import("httpx");

fn indexHandler(_: *httpx.Context) anyerror!httpx.Response {
    unreachable;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var router = httpx.Router.init(allocator);
    defer router.deinit();

    try router.get("/", indexHandler);
    try router.get("/users", indexHandler);
    try router.get("/users/:id", indexHandler);
    try router.get("/users/:userId/posts/:postId", indexHandler);
    try router.post("/users", indexHandler);
    try router.put("/users/:id", indexHandler);
    try router.delete("/users/:id", indexHandler);
    try router.patch("/users/:id", indexHandler);
    try router.head("/users/:id", indexHandler);
    try router.options("/users/:id", indexHandler);
    try router.trace("/debug", indexHandler);
    try router.connect("/tunnel", indexHandler);
    try router.get("/static/*", indexHandler);

    if (router.find(.GET, "/users/42")) |result| {
        defer allocator.free(result.params);
        std.debug.print("  GET /users/42 -> matched!\n", .{});
        std.debug.print("    Parameters: {d}\n", .{result.params.len});
        std.debug.print("    Expected: id = 42\n", .{});
    }

    if (router.find(.GET, "/users/123/posts/456")) |result| {
        defer allocator.free(result.params);
        std.debug.print("  GET /users/123/posts/456 -> matched!\n", .{});
        std.debug.print("    Parameters: {d}\n", .{result.params.len});
        std.debug.print("    Expected: userId = 123, postId = 456\n", .{});
    }

    if (router.find(.DELETE, "/users/99")) |result| {
        defer allocator.free(result.params);
        std.debug.print("  DELETE /users/99 -> matched!\n", .{});
    }

    if (router.find(.PATCH, "/users/1")) |result| {
        defer allocator.free(result.params);
        std.debug.print("  PATCH /users/1 -> matched!\n", .{});
    } else {
        std.debug.print("  PATCH /users/1 -> not found\n", .{});
    }

    if (router.find(.TRACE, "/debug")) |result| {
        defer allocator.free(result.params);
        std.debug.print("  TRACE /debug -> matched!\n", .{});
    }

    if (router.find(.CONNECT, "/tunnel")) |result| {
        defer allocator.free(result.params);
        std.debug.print("  CONNECT /tunnel -> matched!\n", .{});
    }

    var api_v1 = router.group("/api/v1");
    try api_v1.get("/users", indexHandler);
    try api_v1.post("/posts", indexHandler);
    try api_v1.patch("/users/:id", indexHandler);
    try api_v1.options("/users/:id", indexHandler);
    try api_v1.trace("/diag", indexHandler);
    try api_v1.connect("/tunnel", indexHandler);
}
