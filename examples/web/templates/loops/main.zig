const std = @import("std");
const httpx = @import("httpx");

const Service = struct {
    name: []const u8,
    host: []const u8,
    port: u16,
    status: []const u8,
};

fn loopsHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const services = [_]Service{
        .{ .name = "auth-service", .host = "10.0.0.1", .port = 8001, .status = "healthy" },
        .{ .name = "gateway", .host = "10.0.0.2", .port = 8080, .status = "healthy" },
        .{ .name = "payment-api", .host = "10.0.0.3", .port = 8002, .status = "healthy" },
        .{ .name = "cache-node", .host = "10.0.0.4", .port = 6379, .status = "healthy" },
    };

    return ctx.render("index.html", .{
        .title = "Cluster Service Registry",
        .services = services[0..],
    });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .templates = .{
            .directory = "examples/web/templates/loops/templates",
        },
    });
    defer server.deinit();

    try server.get("/", loopsHandler);

    const port = server.localPort();
    std.debug.print("Loops Template Server listening on http://127.0.0.1:{d}\n", .{port});

    const thread = try server.start();
    defer thread.join();

    // Client verification
    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});

    var res = try client.get(url, .{});
    defer res.deinit();

    std.debug.print("GET / -> Status {d}, Length {d} bytes\n", .{ res.status, res.body.len });
    std.debug.print("Rendered table preview:\n{s}\n", .{res.body[0..@min(res.body.len, 400)]});

    server.stop();
}
