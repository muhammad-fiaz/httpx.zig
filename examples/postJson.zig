const std = @import("std");
const httpx = @import("httpx");

const CreateUser = struct {
    name: []const u8,
    role: []const u8,
};

fn postHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    return .{
        .status = 200,
        .body = try std.fmt.allocPrint(ctx.allocator, "{{\"status\":\"created\",\"received\":{s}}}", .{ctx.body}),
        .contentType = "application/json",
    };
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
        .maxConnections = 1,
    });
    defer server.deinit();
    try server.router.add(.POST, "/post", postHandler, .{});
    const port = server.localPort();
    const thread = try server.start();
    defer thread.join();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var urlBuf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/post", .{port});

    // POST with typed JSON struct using unified fetch
    var response = try client.fetch(url, .{
        .method = .POST,
        .json = CreateUser{ .name = "Alice", .role = "developer" },
    });
    defer response.deinit();

    std.debug.print("Status: {d}\n", .{response.status});
    std.debug.print("Body: {s}\n", .{response.bytes()});
}
