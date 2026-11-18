//! WebSocket client over loopback using `httpx.websocket.Client`.
//!
//! Build with: `zig build example-websocket-client`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .signals = .{ .enabled = false },
    });
    defer server.deinit();

    try server.get("/ws", wsHandler);

    const port = server.localPort();
    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const thread = try std.Thread.spawn(.{}, ServerThread.run, .{&server});

    var urlBuf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&urlBuf, "ws://127.0.0.1:{d}/ws", .{port});

    var client = try httpx.websocket.Client.init(allocator, io, .{
        .connectMs = 5_000,
        .auth = .{ .scheme = .bearer, .token = "demo-token" },
    });
    defer client.deinit();

    var session = try client.connect(url);
    defer session.deinit();

    try session.sendText("hello over websocket");
    if (try session.receiveText()) |reply| {
        defer allocator.free(reply);
        std.debug.print("received: {s}\n", .{reply});
    }
    try session.close(1000, "done");

    server.requestShutdown();
    thread.join();
}

fn wsHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    try httpx.websocket.accept(ctx, .{
        .auth = .{ .scheme = .bearer, .token = "demo-token" },
        .callbacks = .{ .onMessage = echo },
    });
    return .{};
}

fn echo(session: *httpx.websocket.Session, message: *httpx.websocket.Message, _: ?*anyopaque) anyerror!void {
    try session.sendText(message.data);
}
