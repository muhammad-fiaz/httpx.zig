//! Real loopback integration tests for the WebSocket stack.
//!
//! These use the production HTTP server, the real TCP transport and the real
//! client — no mocks. Signal handling is disabled so a test run never touches
//! process-wide handlers.

const std = @import("std");
const httpServer = @import("../../server/httpServer.zig");
const httpClient = @import("../../client/httpClient.zig");
const router = @import("../router/router.zig");
const clientMod = @import("websocketClient.zig");
const serverMod = @import("websocketServer.zig");

fn echoRoute(ctx: *router.Context) anyerror!router.Response {
    try serverMod.accept(ctx, .{
        .auth = .{ .scheme = .bearer, .token = "test-token" },
        .callbacks = .{ .onMessage = echoMessage },
    });
    return .{};
}

fn openRoute(ctx: *router.Context) anyerror!router.Response {
    try serverMod.accept(ctx, .{
        .callbacks = .{ .onMessage = echoMessage },
    });
    return .{};
}

fn echoMessage(session: *serverMod.Session, message: *serverMod.Message, _: ?*anyopaque) anyerror!void {
    switch (message.kind) {
        .text => try session.sendText(message.data),
        .binary => try session.sendBinary(message.data),
    }
}

fn startServer(server: *httpServer.Server) !std.Thread {
    try server.get("/ws", echoRoute);
    try server.get("/ws-open", openRoute);
    return std.Thread.spawn(.{}, struct {
        fn run(s: *httpServer.Server) void {
            s.run();
        }
    }.run, .{server});
}

test "websocket client and server exchange text over loopback" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var server = try httpServer.Server.init(std.testing.allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .signals = .{ .enabled = false },
        .limits = .{ .maxConns = 4, .maxActive = 4 },
    });
    defer server.deinit();

    const thread = try startServer(&server);
    defer thread.join();

    var urlBuf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&urlBuf, "ws://127.0.0.1:{d}/ws", .{server.localPort()});

    var client = try clientMod.Client.init(std.testing.allocator, io, .{
        .auth = .{ .scheme = .bearer, .token = "test-token" },
        .connectMs = 5_000,
    });
    defer client.deinit();

    var session = try client.connect(url);
    defer session.deinit();

    try session.sendText("ping");
    const reply = (try session.receiveText()) orelse return error.UnexpectedClose;
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("ping", reply);

    try session.sendBinary(&[_]u8{ 1, 2, 3, 4 });
    const binary = (try session.receiveBinary()) orelse return error.UnexpectedClose;
    defer std.testing.allocator.free(binary);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, binary);

    try session.close(1000, "done");

    server.requestShutdown();
}

test "websocket server rejects invalid bearer credentials" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var server = try httpServer.Server.init(std.testing.allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .signals = .{ .enabled = false },
        .limits = .{ .maxConns = 4, .maxActive = 4 },
    });
    defer server.deinit();

    const thread = try startServer(&server);
    defer thread.join();

    var urlBuf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&urlBuf, "ws://127.0.0.1:{d}/ws", .{server.localPort()});

    var client = try clientMod.Client.init(std.testing.allocator, io, .{
        .auth = .{ .scheme = .bearer, .token = "wrong-token" },
        .connectMs = 5_000,
    });
    defer client.deinit();

    try std.testing.expectError(error.HandshakeFailed, client.connect(url));

    server.requestShutdown();
}

test "websocket server rejects a non-upgrade request" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var server = try httpServer.Server.init(std.testing.allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .signals = .{ .enabled = false },
        .limits = .{ .maxConns = 4, .maxActive = 4 },
    });
    defer server.deinit();

    const thread = try startServer(&server);
    defer thread.join();

    var urlBuf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}/ws-open", .{server.localPort()});

    // A plain HTTP GET without upgrade headers must fail the handshake with a
    // complete 400 response and no takeover.
    var client = httpClient.Client.init(std.testing.allocator, io, .{});
    defer client.deinit();
    var res = try client.get(url, .{});
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 400), res.status);

    server.requestShutdown();
}
