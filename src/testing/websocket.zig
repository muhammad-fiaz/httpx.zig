//! Loopback WebSocket echo server for client-side development testing.
//!
//! `httpx.testing.websocket.EchoServer` wraps `httpx.testing.Server`, so tests
//! exercise the real HTTP server, the real TCP transport, and the real
//! WebSocket handshake. Nothing is mocked. Signal handling is disabled by
//! default so a test run never touches process-wide handlers.
//!
//! ```zig
//! var server = try httpx.testing.websocket.EchoServer.init(allocator, io, .{});
//! defer server.deinit();
//! try server.start();
//!
//! var urlBuf: [128]u8 = undefined;
//! const url = try server.url("/ws", &urlBuf);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const testingServer = @import("server.zig");
const httpClient = @import("../client/httpClient.zig");
const router = @import("../web/router/router.zig");
const authMod = @import("../web/websocket/websocketAuth.zig");
const clientMod = @import("../web/websocket/websocketClient.zig");
const serverMod = @import("../web/websocket/websocketServer.zig");

/// Configuration for `EchoServer`.
pub const Config = struct {
    /// Bearer token required by the echo route. `null` disables authentication.
    token: ?[]const u8 = "test-token",
    /// Echo route path, opened with bearer authentication when `token` is set.
    path: []const u8 = "/ws",
    /// Unauthenticated echo route path.
    openPath: []const u8 = "/ws-open",
    /// Maximum total connections accepted by the server.
    maxConnections: usize = 4,
    /// Maximum simultaneously active connections.
    maxActive: usize = 4,
    /// Keep the production signal handlers enabled. Tests should leave this
    /// false; long-running local development servers may set it to true.
    signalHandling: bool = false,
};

const RouteState = struct {
    auth: authMod.Config,
};

fn echoMessage(session: *serverMod.Session, message: *serverMod.Message, _: ?*anyopaque) anyerror!void {
    switch (message.kind) {
        .text => try session.sendText(message.data),
        .binary => try session.sendBinary(message.data),
    }
}

fn echoRoute(ctx: *router.Context) anyerror!router.Response {
    const state: *RouteState = @ptrCast(@alignCast(ctx.userData orelse return error.MissingRouteState));
    try serverMod.accept(ctx, .{
        .auth = state.auth,
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

/// A real loopback WebSocket server that echoes text and binary messages.
pub const EchoServer = struct {
    server: testingServer.Server,
    state: *RouteState,
    allocator: Allocator,
    cfg: Config,

    /// Binds a loopback listener and installs the echo routes. The server is
    /// not serving until `start` is called.
    pub fn init(allocator: Allocator, io: std.Io, cfg: Config) !EchoServer {
        var server = try testingServer.Server.init(allocator, io, .{
            .signals = .{ .enabled = cfg.signalHandling },
            .limits = .{
                .maxConnections = cfg.maxConnections,
                .maxActive = cfg.maxActive,
            },
        });
        errdefer server.deinit();

        const state = try allocator.create(RouteState);
        errdefer allocator.destroy(state);
        state.* = .{
            .auth = if (cfg.token) |token|
                .{ .scheme = .bearer, .token = token }
            else
                .{},
        };

        try server.route(cfg.path, .{ .handler = echoRoute, .userData = state });
        try server.route(cfg.openPath, .{ .handler = openRoute });

        return .{
            .server = server,
            .state = state,
            .allocator = allocator,
            .cfg = cfg,
        };
    }

    /// Stops the server, releases every route, and destroys the listener.
    pub fn deinit(self: *EchoServer) void {
        self.server.deinit();
        self.allocator.destroy(self.state);
        self.* = undefined;
    }

    /// Starts serving in the background. Readiness is deterministic: the
    /// listener is already bound by `init`.
    pub fn start(self: *EchoServer) !void {
        try self.server.start();
    }

    /// Stops serving and joins the background thread. Safe to call repeatedly.
    pub fn stop(self: *EchoServer) void {
        self.server.stop();
    }

    /// OS-assigned listener port.
    pub fn port(self: *const EchoServer) u16 {
        return self.server.localPort();
    }

    /// Formats a `ws://127.0.0.1:<port><path>` URL into `buffer`.
    pub fn url(self: *const EchoServer, path: []const u8, buffer: []u8) ![]const u8 {
        if (path.len == 0 or path[0] != '/') return error.InvalidPath;
        return std.fmt.bufPrint(buffer, "ws://127.0.0.1:{d}{s}", .{ self.port(), path });
    }

    /// Formats an `http://127.0.0.1:<port><path>` URL into `buffer`.
    pub fn httpUrl(self: *const EchoServer, path: []const u8, buffer: []u8) ![]const u8 {
        if (path.len == 0 or path[0] != '/') return error.InvalidPath;
        return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}{s}", .{ self.port(), path });
    }
};

// Tests

test "echo server exchanges text and binary over loopback" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var server = try EchoServer.init(std.testing.allocator, io, .{});
    defer server.deinit();
    try server.start();
    defer server.stop();

    var urlBuf: [128]u8 = undefined;
    const url = try server.url(server.cfg.path, &urlBuf);

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
}

test "echo server rejects invalid bearer credentials" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var server = try EchoServer.init(std.testing.allocator, io, .{});
    defer server.deinit();
    try server.start();
    defer server.stop();

    var urlBuf: [128]u8 = undefined;
    const url = try server.url(server.cfg.path, &urlBuf);

    var client = try clientMod.Client.init(std.testing.allocator, io, .{
        .auth = .{ .scheme = .bearer, .token = "wrong-token" },
        .connectMs = 5_000,
    });
    defer client.deinit();

    try std.testing.expectError(error.HandshakeFailed, client.connect(url));
}

test "echo server rejects a non-upgrade request" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var server = try EchoServer.init(std.testing.allocator, io, .{});
    defer server.deinit();
    try server.start();
    defer server.stop();

    var urlBuf: [128]u8 = undefined;
    const url = try server.httpUrl(server.cfg.openPath, &urlBuf);

    // A plain HTTP GET without upgrade headers must fail the handshake with a
    // complete 400 response and no takeover.
    var client = httpClient.Client.init(std.testing.allocator, io, .{});
    defer client.deinit();
    var res = try client.get(url, .{});
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 400), res.status);
}
