//! WebSocket client (`ws://` and `wss://`) over the shared TCP/TLS stack.
//!
//! The returned `Session` owns its socket (and TLS state for `wss://`).
//! `Session.deinit` performs the single final close; `Session.close` performs
//! the RFC 6455 close handshake first.
//!
//! References:
//!   - RFC 6455 Section 4 — Opening Handshake (client)
//!   - RFC 3986 — URI parsing shared with the HTTP client

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zigantic");
const uriMod = @import("../../common/uri.zig");
const addressMod = @import("../../net/address.zig");
const resolveMod = @import("../../net/resolve.zig");
const tcp = @import("../../sockets/tcp.zig");
const tlsClientMod = @import("../../protocols/tls/tlsClient.zig");
const tlsTransportMod = @import("../../protocols/tls/tlsTransport.zig");
const streamMod = @import("../../common/stream.zig");
const Stream = streamMod.Stream;
const handshakeMod = @import("websocketHandshake.zig");
const frameMod = @import("websocketFrame.zig");
const deflateMod = @import("websocketDeflate.zig");
const authMod = @import("websocketAuth.zig");
const sessionMod = @import("websocketSession.zig");

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

pub const Error = error{
    UnsupportedScheme,
    InvalidUrl,
    ResolveFailed,
    ConnectFailed,
    HandshakeFailed,
    HandshakeTooLarge,
    TlsFailed,
    OutOfMemory,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

const ConfigSchema = z.objectOf(.{
    .headers = z.withDefault(z.array(typedSchema(Header), .{}), &.{}),
    .subprotocols = z.withDefault(z.array(z.string(.{}), .{}), &.{}),
    .compression = z.withDefault(z.boolean(.{}), false),
    .connectMs = z.withDefault(z.integer(u32, .{}), 10_000),
    .maxHead = z.withDefault(z.positiveInt(usize, .{}), 32 * 1024),
    .verify = z.withDefault(z.enumType(tlsTransportMod.VerifyMode, .{}), .caBundle),
    .caPem = z.optional(z.string(.{})),
    .session = z.withDefault(sessionMod.ConfigSchema, .{}),
    .auth = z.withDefault(authMod.ConfigSchema, .{}),
}, .{});
pub const Config = ConfigSchema.Value;

/// Reusable WebSocket client. `init` stores the allocator, `std.Io` and
/// configuration once; every `connect` reuses them.
pub const Client = struct {
    allocator: Allocator,
    io: std.Io,
    config: Config,

    pub fn init(allocator: Allocator, io: std.Io, config: Config) !Client {
        var scratch: [4096]u8 = undefined;
        const issue = z.checkFirst(ConfigSchema, config, &scratch, .{}) catch
            return error.InvalidConfig;
        if (issue != null) return error.InvalidConfig;
        return .{ .allocator = allocator, .io = io, .config = config };
    }

    pub fn deinit(self: *Client) void {
        self.* = undefined;
    }

    pub fn connect(self: *const Client, url: []const u8) !Session {
        return open(self.allocator, self.io, url, self.config);
    }
};

/// Opens a WebSocket connection. On success the returned session owns the
/// socket; release it with `deinit`.
pub fn open(allocator: Allocator, io: std.Io, url: []const u8, config: Config) !Session {
    {
        var scratch: [4096]u8 = undefined;
        const issue = z.checkFirst(ConfigSchema, config, &scratch, .{}) catch
            return error.InvalidConfig;
        if (issue != null) return error.InvalidConfig;
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const uri = uriMod.parse(url) catch return Error.InvalidUrl;
    const secure = std.ascii.eqlIgnoreCase(uri.scheme, "wss");
    const plain = std.ascii.eqlIgnoreCase(uri.scheme, "ws");
    if (!secure and !plain) return Error.UnsupportedScheme;

    const port = uriMod.effectivePort(&uri);
    if (port == 0) return Error.InvalidUrl;

    const socket = try connectTcp(io, scratch, uri.host, port, secure, config.connectMs);

    const owner = allocator.create(OwnedTransport) catch {
        socket.close();
        return Error.OutOfMemory;
    };
    owner.* = .{
        .allocator = allocator,
        .io = io,
        .socket = socket,
    };
    errdefer owner.destroy();

    if (secure) {
        const client = allocator.create(tlsClientMod.Client) catch return Error.OutOfMemory;
        client.* = tlsClientMod.Client.init(allocator, io, .{
            .verify = config.verify,
            .caPem = config.caPem,
            .alpn = &.{.@"http/1.1"},
        }) catch {
            allocator.destroy(client);
            return Error.TlsFailed;
        };
        owner.tlsClient = client;
        owner.tls = client.connect(&owner.socket, uri.host, .{}) catch return Error.TlsFailed;
    }

    const stream = owner.stream();
    try handshake(allocator, io, scratch, stream, &uri, secure, config, owner);

    var session = Session.init(
        allocator,
        io,
        stream,
        config.session,
        .{
            .role = .client,
            .initial = owner.initial,
            .compression = owner.compression,
        },
    ) catch return Error.HandshakeFailed;
    owner.initial = &.{};
    session.owner = .{ .context = owner, .destroyFn = OwnedTransport.destroyOpaque };
    return session;
}

fn connectTcp(
    io: std.Io,
    scratch: Allocator,
    host: []const u8,
    port: u16,
    secure: bool,
    timeoutMs: u32,
) !tcp.Socket {
    _ = timeoutMs;
    if (addressMod.Address.parseIp(host)) |parsed| {
        var addr = parsed;
        addr.port = port;
        return connectOne(io, &addr, secure) catch Error.ConnectFailed;
    } else |_| {}

    var resolver = resolveMod.Resolver.init(scratch, io);
    const addresses = resolver.lookup(host, .{ .port = port }) catch return Error.ResolveFailed;
    if (addresses.len == 0) return Error.ResolveFailed;
    for (addresses) |*address| {
        var addr = address.*;
        addr.port = port;
        return connectOne(io, &addr, secure) catch continue;
    }
    return Error.ConnectFailed;
}

fn connectOne(io: std.Io, address: *const addressMod.Address, secure: bool) !tcp.Socket {
    if (secure) return tcp.connectAddressStream(io, address);
    return tcp.connectAddress(io, address);
}

const OwnedTransport = struct {
    allocator: Allocator,
    io: std.Io,
    socket: tcp.Socket,
    tls: ?tlsClientMod.Client.Connection = null,
    tlsClient: ?*tlsClientMod.Client = null,
    initial: []const u8 = "",
    compression: bool = false,

    fn stream(self: *OwnedTransport) Stream {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable: Stream.VTable = .{
        .read = read,
        .writeAll = writeAll,
        .setReadTimeoutMs = setReadTimeout,
        .setWriteTimeoutMs = setWriteTimeout,
        .peerAddress = peerAddress,
        .isTls = isTls,
    };

    fn read(context: *anyopaque, buf: []u8) anyerror!usize {
        const self: *OwnedTransport = @ptrCast(@alignCast(context));
        if (self.tls) |*tls| return tls.read(buf);
        return self.socket.read(buf);
    }

    fn writeAll(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *OwnedTransport = @ptrCast(@alignCast(context));
        if (self.tls) |*tls| return tls.writeAll(bytes);
        return self.socket.writeAll(bytes);
    }

    fn setReadTimeout(context: *anyopaque, timeoutMs: u32) void {
        const self: *OwnedTransport = @ptrCast(@alignCast(context));
        self.socket.setReadTimeoutMs(timeoutMs);
    }

    fn setWriteTimeout(context: *anyopaque, timeoutMs: u32) void {
        const self: *OwnedTransport = @ptrCast(@alignCast(context));
        self.socket.setWriteTimeoutMs(timeoutMs);
    }

    fn peerAddress(context: *anyopaque) []const u8 {
        const self: *OwnedTransport = @ptrCast(@alignCast(context));
        return self.socket.peerAddress();
    }

    fn isTls(context: *anyopaque) bool {
        const self: *OwnedTransport = @ptrCast(@alignCast(context));
        return self.tls != null;
    }

    fn destroy(self: *OwnedTransport) void {
        if (self.tls) |*tls| tls.deinit();
        self.socket.close();
        if (self.tlsClient) |client| {
            client.deinit();
            self.allocator.destroy(client);
        }
        if (self.initial.len > 0) self.allocator.free(self.initial);
        self.allocator.destroy(self);
    }

    fn destroyOpaque(context: *anyopaque) void {
        const self: *OwnedTransport = @ptrCast(@alignCast(context));
        self.destroy();
    }
};

fn handshake(
    allocator: Allocator,
    io: std.Io,
    scratch: Allocator,
    stream: Stream,
    uri: *const uriMod.Uri,
    secure: bool,
    config: Config,
    owner: *OwnedTransport,
) !void {
    var keyBuf: [24]u8 = undefined;
    var rawKey: [16]u8 = undefined;
    io.random(&rawKey);
    const key = std.base64.standard.Encoder.encode(&keyBuf, &rawKey);

    var authorityBuf: [512]u8 = undefined;
    const authority = uriMod.authority(uri, &authorityBuf) catch return Error.InvalidUrl;

    var target: []const u8 = uri.path;
    if (uri.query.len > 0) {
        target = std.fmt.allocPrint(scratch, "{s}?{s}", .{ uri.path, uri.query }) catch return Error.OutOfMemory;
    }

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(scratch);
    for (config.headers) |header| {
        const line = std.fmt.allocPrint(scratch, "{s}: {s}", .{ header.name, header.value }) catch return Error.OutOfMemory;
        lines.append(scratch, line) catch return Error.OutOfMemory;
    }
    if (authMod.clientHeaderValue(scratch, config.auth) catch return Error.OutOfMemory) |value| {
        const line = std.fmt.allocPrint(scratch, "Authorization: {s}", .{value}) catch return Error.OutOfMemory;
        lines.append(scratch, line) catch return Error.OutOfMemory;
    }
    if (config.subprotocols.len > 0) {
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(scratch);
        for (config.subprotocols, 0..) |protocol, index| {
            if (index != 0) joined.appendSlice(scratch, ", ") catch return Error.OutOfMemory;
            joined.appendSlice(scratch, protocol) catch return Error.OutOfMemory;
        }
        const line = std.fmt.allocPrint(scratch, "Sec-WebSocket-Protocol: {s}", .{joined.items}) catch return Error.OutOfMemory;
        lines.append(scratch, line) catch return Error.OutOfMemory;
    }
    if (config.compression) {
        const offer = deflateMod.formatOffer(scratch, .{}) catch return Error.OutOfMemory;
        const line = std.fmt.allocPrint(scratch, "Sec-WebSocket-Extensions: {s}", .{offer}) catch return Error.OutOfMemory;
        lines.append(scratch, line) catch return Error.OutOfMemory;
    }

    const request = handshakeMod.buildUpgradeRequest(scratch, authority, target, key, lines.items) catch return Error.OutOfMemory;
    stream.writeAll(request) catch return Error.HandshakeFailed;

    const cap = config.maxHead;
    const buffer = allocator.alloc(u8, cap) catch return Error.OutOfMemory;
    defer allocator.free(buffer);

    stream.setReadTimeoutMs(config.connectMs);
    var filled: usize = 0;
    var headEnd: usize = 0;
    while (filled < buffer.len) {
        if (std.mem.indexOf(u8, buffer[0..filled], "\r\n\r\n")) |index| {
            headEnd = index + 4;
            break;
        }
        const n = stream.read(buffer[filled..]) catch return Error.HandshakeFailed;
        if (n == 0) return Error.HandshakeFailed;
        filled += n;
    }
    if (headEnd == 0) return Error.HandshakeTooLarge;

    var expected: [28]u8 = undefined;
    handshakeMod.computeAccept(key, &expected);
    const head = buffer[0..headEnd];
    if (!handshakeMod.validateUpgradeResponse(head, &expected)) return Error.HandshakeFailed;

    const selected = headerValue(head, "sec-websocket-protocol");
    if (selected) |protocolValue| {
        const protocol = std.mem.trim(u8, protocolValue, " \t");
        if (!containsSubprotocol(config.subprotocols, protocol)) return Error.HandshakeFailed;
    }

    if (config.compression) {
        if (headerValue(head, "sec-websocket-extensions")) |extensions| {
            owner.compression = deflateMod.parseNegotiatedExtension(extensions) != null;
        }
    }

    owner.initial = allocator.dupe(u8, buffer[headEnd..filled]) catch return Error.OutOfMemory;
    _ = secure;
}

fn containsSubprotocol(offered: []const []const u8, selected: []const u8) bool {
    for (offered) |protocol| {
        if (std.mem.eql(u8, protocol, selected)) return true;
    }
    return false;
}

fn headerValue(head: []const u8, lowerName: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < head.len) {
        const end = std.mem.indexOfPos(u8, head, pos, "\r\n") orelse return null;
        const line = head[pos..end];
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            const name = std.mem.trim(u8, line[0..colon], " \t");
            if (std.ascii.eqlIgnoreCase(name, lowerName)) {
                return std.mem.trim(u8, line[colon + 1 ..], " \t");
            }
        }
        pos = end + 2;
    }
    return null;
}

/// Alias retained as the module-level entry point.
pub const connect = open;
