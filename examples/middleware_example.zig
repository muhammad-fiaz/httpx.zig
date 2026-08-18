const std = @import("std");
const httpx = @import("httpx");

fn apiHandler(_: *httpx.Context) anyerror!httpx.Response {
    unreachable;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = httpx.Server.init(allocator);
    defer server.deinit();

    try server.use(httpx.logger());
    try server.use(httpx.cors(.{
        .allowed_origins = &.{"http://httpbun.com"},
        .allowed_methods = &.{ .GET, .POST, .PUT, .DELETE },
        .allow_credentials = true,
    }));
    try server.use(httpx.rateLimit(.{
        .max_requests = 100,
        .window_ms = 60_000,
    }));
    try server.use(httpx.helmet());
    try server.use(httpx.middleware.compression());

    try server.get("/api/data", apiHandler);

    for (server.middleware.items, 0..) |mw, i| {
        std.debug.print("  {d}. {s}\n", .{ i + 1, mw.name });
    }
}
