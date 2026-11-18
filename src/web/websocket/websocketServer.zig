//! WebSocket server integration for the HTTP router.
//!
//! A route handler marks the request as a WebSocket upgrade with
//! `accept(ctx, .{ .callbacks = ... })`. The HTTP layer then stops treating the
//! connection as HTTP: it runs the opening handshake and the message loop on
//! the connection's worker, using the same TCP/TLS stream that carried the
//! request. Bytes already read past the HTTP head are handed to the session, so
//! clients may send frames immediately after the upgrade request.
//!
//! Ownership: the HTTP connection worker keeps sole ownership of the socket.
//! The session borrows it and is destroyed when the message loop ends; the
//! worker performs the single final close.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zigantic");
const routerMod = @import("../router/router.zig");
const Context = routerMod.Context;
const parseMod = @import("../../common/parse.zig");
const handshakeMod = @import("websocketHandshake.zig");
const sessionMod = @import("websocketSession.zig");
const deflateMod = @import("websocketDeflate.zig");
const authMod = @import("websocketAuth.zig");

fn typedSchema(comptime T: type) type {
    return z.custom(T, .{ .check = struct {
        fn accept(_: T) bool {
            return true;
        }
    }.accept });
}

pub const Session = sessionMod.Session;
pub const Message = sessionMod.Message;
pub const CloseInfo = sessionMod.CloseInfo;
pub const UpgradeTransport = routerMod.UpgradeTransport;

pub const Callbacks = struct {
    /// Opaque pointer forwarded to every callback.
    context: ?*anyopaque = null,
    onOpen: ?*const fn (session: *Session, context: ?*anyopaque) anyerror!void = null,
    /// Runs for each complete text/binary message. `message` is borrowed for
    /// the duration of the call only; call `message.deinit()` to keep it.
    onMessage: ?*const fn (session: *Session, message: *Message, context: ?*anyopaque) anyerror!void = null,
    onClose: ?*const fn (session: *Session, info: CloseInfo, context: ?*anyopaque) void = null,
};

const ConfigSchema = z.objectOf(.{
    .subprotocols = z.withDefault(z.array(z.string(.{}), .{}), &.{}),
    .compression = z.withDefault(z.boolean(.{}), false),
    .originCheck = z.withDefault(typedSchema(?*const fn (ctx: *Context) bool), null),
    .session = z.withDefault(sessionMod.ConfigSchema, .{}),
    .callbacks = z.withDefault(typedSchema(Callbacks), .{}),
    .auth = z.withDefault(authMod.ConfigSchema, .{}),
}, .{});
pub const Config = ConfigSchema.Value;

const State = struct {
    allocator: Allocator,
    config: Config,
    key: []const u8,
    acceptValue: [28]u8,
    subprotocol: ?[]const u8 = null,
    compression: bool = false,
    /// Non-zero when validation failed; the takeover handler sends this error.
    errorStatus: u16 = 0,
    errorText: []const u8 = "",
};

/// Marks the request as a WebSocket upgrade. Returns immediately; the
/// handshake and session run after the route handler returns.
///
/// Handshake failures are reported on the wire (400/403/426) instead of
/// becoming route errors, so callers normally write:
///
/// ```zig
/// try httpx.websocket.accept(ctx, .{ .callbacks = .{ .onMessage = onMessage } });
/// return .{};
/// ```
pub fn accept(ctx: *Context, config: Config) !void {
    const scratch = ctx.allocator;
    const state = try scratch.create(State);
    state.* = .{
        .allocator = ctx.baseAllocator orelse scratch,
        .config = config,
        .key = "",
        .acceptValue = undefined,
    };
    state.config.subprotocols = try copySubprotocols(scratch, config.subprotocols);

    if (config.originCheck) |hook| {
        if (!hook(ctx)) {
            state.errorStatus = 403;
            state.errorText = "origin not allowed";
            ctx.takeOver(.{ .handler = run, .userData = state });
            return;
        }
    }

    if (!authMod.verify(config.auth, headerValue(ctx, "Authorization") orelse "")) {
        state.errorStatus = 401;
        state.errorText = "authentication required";
        ctx.takeOver(.{ .handler = run, .userData = state });
        return;
    }

    const upgradeValue = headerValue(ctx, "Upgrade") orelse "";
    const connectionValue = headerValue(ctx, "Connection") orelse "";
    if (ctx.method != .GET or
        !parseMod.hasToken(upgradeValue, "websocket") or
        !parseMod.hasToken(connectionValue, "Upgrade"))
    {
        state.errorStatus = 400;
        state.errorText = "expected a WebSocket upgrade request";
        ctx.takeOver(.{ .handler = run, .userData = state });
        return;
    }

    const version = std.mem.trim(u8, headerValue(ctx, "Sec-WebSocket-Version") orelse "", " \t");
    if (!std.mem.eql(u8, version, "13")) {
        state.errorStatus = 426;
        state.errorText = "unsupported WebSocket version";
        ctx.takeOver(.{ .handler = run, .userData = state });
        return;
    }

    const rawKey = std.mem.trim(u8, headerValue(ctx, "Sec-WebSocket-Key") orelse "", " \t");
    const decodedLen = std.base64.standard.Decoder.calcSizeForSlice(rawKey) catch 0;
    if (decodedLen != 16) {
        state.errorStatus = 400;
        state.errorText = "invalid Sec-WebSocket-Key";
        ctx.takeOver(.{ .handler = run, .userData = state });
        return;
    }
    state.key = try scratch.dupe(u8, rawKey);
    handshakeMod.computeAccept(state.key, &state.acceptValue);

    if (headerValue(ctx, "Sec-WebSocket-Protocol")) |offered| {
        state.subprotocol = selectSubprotocol(scratch, state.config.subprotocols, offered);
    }

    if (config.compression) {
        if (headerValue(ctx, "Sec-WebSocket-Extensions")) |offered| {
            state.compression = parseMod.hasToken(offered, deflateMod.EXTENSION_NAME);
        }
    }

    ctx.takeOver(.{ .handler = run, .userData = state });
}

fn copySubprotocols(allocator: Allocator, values: []const []const u8) ![]const []const u8 {
    if (values.len == 0) return &.{};
    const out = try allocator.alloc([]const u8, values.len);
    for (values, 0..) |value, index| {
        out[index] = try allocator.dupe(u8, value);
    }
    return out;
}

fn selectSubprotocol(allocator: Allocator, supported: []const []const u8, offered: []const u8) ?[]const u8 {
    var rest = offered;
    while (rest.len > 0) {
        const comma = std.mem.indexOfScalar(u8, rest, ',');
        const token = std.mem.trim(u8, if (comma) |index| rest[0..index] else rest, " \t");
        for (supported) |candidate| {
            if (std.mem.eql(u8, candidate, token)) {
                return allocator.dupe(u8, candidate) catch null;
            }
        }
        if (comma) |index| rest = rest[index + 1 ..] else break;
    }
    return null;
}

pub fn headerValue(ctx: *const Context, name: []const u8) ?[]const u8 {
    for (ctx.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn run(ctx: *Context, transport: UpgradeTransport, buffered: []const u8) anyerror!void {
    const rawState = ctx.upgrade orelse return error.MissingUpgrade;
    const state: *State = @ptrCast(@alignCast(rawState.userData orelse return error.MissingUpgrade));

    if (state.errorStatus != 0) {
        sendHttpError(transport, state.errorStatus, state.errorText, state.config.auth) catch {};
        return;
    }

    var head = std.ArrayList(u8).empty;
    defer head.deinit(ctx.allocator);
    try head.appendSlice(ctx.allocator, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ");
    try head.appendSlice(ctx.allocator, state.acceptValue[0..]);
    try head.appendSlice(ctx.allocator, "\r\n");
    if (state.subprotocol) |protocol| {
        try head.appendSlice(ctx.allocator, "Sec-WebSocket-Protocol: ");
        try head.appendSlice(ctx.allocator, protocol);
        try head.appendSlice(ctx.allocator, "\r\n");
    }
    if (state.compression) {
        try head.appendSlice(ctx.allocator, "Sec-WebSocket-Extensions: permessage-deflate; server_no_context_takeover; client_no_context_takeover\r\n");
    }
    try head.appendSlice(ctx.allocator, "\r\n");
    try transport.writeAll(head.items);

    var session = try Session.init(
        state.allocator,
        ctx.io,
        transport,
        state.config.session,
        .{
            .role = .server,
            .initial = buffered,
            .compression = state.compression,
        },
    );
    defer session.deinit();

    const callbacks = state.config.callbacks;
    if (callbacks.onOpen) |onOpen| {
        onOpen(&session, callbacks.context) catch {
            session.close(1011, "internal error") catch {};
            return;
        };
    }

    while (session.isOpen()) {
        const event = session.receiveEvent() catch |err| {
            switch (err) {
                error.ConnectionClosed, error.NotOpen => {},
                else => session.close(1011, "internal error") catch {},
            }
            break;
        };
        switch (event) {
            .text => |data| {
                var message = Message{ .allocator = state.allocator, .kind = .text, .data = data };
                defer message.deinit();
                if (callbacks.onMessage) |onMessage| {
                    onMessage(&session, &message, callbacks.context) catch {
                        session.close(1011, "internal error") catch {};
                        break;
                    };
                }
            },
            .binary => |data| {
                var message = Message{ .allocator = state.allocator, .kind = .binary, .data = data };
                defer message.deinit();
                if (callbacks.onMessage) |onMessage| {
                    onMessage(&session, &message, callbacks.context) catch {
                        session.close(1011, "internal error") catch {};
                        break;
                    };
                }
            },
            .ping => |data| state.allocator.free(data),
            .pong => |data| state.allocator.free(data),
            .close => |info| {
                if (callbacks.onClose) |onClose| onClose(&session, info, callbacks.context);
                state.allocator.free(info.reason);
                break;
            },
        }
    }

    if (session.isOpen()) session.close(1000, "") catch {};
}

fn sendHttpError(transport: UpgradeTransport, status: u16, text: []const u8, auth: authMod.Config) !void {
    var extraBuf: [128]u8 = undefined;
    var headBuf: [512]u8 = undefined;
    const reason = if (status == 426) "Upgrade Required" else if (status == 403) "Forbidden" else if (status == 401) "Unauthorized" else "Bad Request";
    const extra = if (status == 426)
        "Sec-WebSocket-Version: 13\r\n"
    else if (status == 401)
        try std.fmt.bufPrint(&extraBuf, "WWW-Authenticate: {s}\r\n", .{authMod.challenge(auth)})
    else
        "";
    const head = try std.fmt.bufPrint(
        &headBuf,
        "HTTP/1.1 {d} {s}\r\nConnection: close\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\n{s}\r\n{s}",
        .{ status, reason, text.len, extra, text },
    );
    try transport.writeAll(head);
}
