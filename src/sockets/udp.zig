//! UDP socket wrapper over std.Io.net for DNS and QUIC transports.
//!
//! Connectionless send/receive with optional default destination so callers
//! can treat a DNS resolver or QUIC connection as a simple pipe.
//!
//! References:
//!   - RFC 768 — User Datagram Protocol (UDP)
//!   - RFC 1035 Section 2.3.4 — UDP DNS Messages
//!   - RFC 9000 Section 9.1 — QUIC Packet Connection (UDP-based)

const std = @import("std");
const builtin = @import("builtin");
const net = std.Io.net;
const Allocator = std.mem.Allocator;
const sysMod = @import("sys.zig");
const z = @import("zigantic");

/// Schema for a value zigantic cannot inspect structurally (function
/// pointers, opaque pointers, fixed byte arrays). Type-checked only.
fn typedSchema(comptime T: type) type {
    return z.custom(T, .{ .check = struct {
        fn accept(_: T) bool {
            return true;
        }
    }.accept });
}

pub const MAX_DATAGRAM: usize = 65527; // max UDP payload (64KiB - 8 header - 20 IP)

pub const Socket = struct {
    /// Socket configuration. `address` binds that explicit local address;
    /// null binds the `port` on all IPv4 interfaces. `port = 0` lets the
    /// OS choose an ephemeral port.
    const ConfigSchema = z.objectOf(.{
        .address = z.optional(typedSchema(net.IpAddress)),
        .port = z.withDefault(z.integer(u16, .{}), 0),
    }, .{});
    pub const Config = ConfigSchema.Value;

    socket: net.Socket,
    io: std.Io,
    /// Owner allocator, stored by `init` for explicit ownership. Sockets
    /// built with the lower-level `bind`/`bindAddress` carry no allocator;
    /// prefer `init(allocator, io, .{})` so ownership is always explicit.
    allocator: Allocator = undefined,
    defaultDest: ?net.IpAddress = null,
    closed: std.atomic.Value(bool) = .init(false),

    /// Creates a UDP socket from an explicit allocator, `std.Io`, and one
    /// inline `.{}`.
    pub fn init(allocator: Allocator, io: std.Io, cfg: Config) !Socket {
        var sock = if (cfg.address) |addr| try bindAddress(io, &addr) else try bind(io, cfg.port);
        sock.allocator = allocator;
        return sock;
    }

    /// Binds to 0.0.0.0:port. port=0 lets the OS choose (typical for clients).
    pub fn bind(io: std.Io, port: u16) !Socket {
        const addr = try net.IpAddress.parseIp4("0.0.0.0", port);
        return bindAddress(io, &addr);
    }

    /// Binds the IPv6 wildcard address `[::]:port`. Useful for DNS/QUIC
    /// endpoints that must accept IPv6 peers; separate from `bind` so the
    /// default remains an IPv4 socket on hosts where IPv6 is unavailable.
    pub fn bindIp6(io: std.Io, port: u16) !Socket {
        const addr = try net.IpAddress.parseIp6("::", port);
        return bindAddress(io, &addr);
    }

    /// Binds an explicit local address (IPv4 or IPv6).
    pub fn bindAddress(io: std.Io, addr: *const net.IpAddress) !Socket {
        const sock = try addr.bind(io, .{ .mode = .dgram });
        return .{ .socket = sock, .io = io };
    }

    /// Idempotent close: QUIC pump shutdown and endpoint teardown both
    /// close the same socket, and a second OS close could otherwise
    /// release an unrelated recycled descriptor.
    pub fn close(self: *Socket) void {
        if (self.closed.swap(true, .acq_rel)) return;
        self.socket.close(self.io);
    }

    /// Sends one datagram to dest.
    pub fn sendTo(self: *Socket, dest: *const net.IpAddress, data: []const u8) !void {
        try self.socket.send(self.io, dest, data);
    }

    /// Sends using the configured default destination.
    pub fn send(self: *Socket, data: []const u8) !void {
        const d = self.defaultDest orelse error.NoDefaultDestination;
        try self.sendTo(&d, data);
    }

    /// Receives one datagram. Returns payload slice (into buffer) and source address.
    ///
    /// Returns `error.DatagramTruncated` when the datagram was larger than
    /// `buffer` instead of silently handing callers a partial message.
    ///
    /// NOTE: this blocks indefinitely (socket-level SO_RCVTIMEO does not
    /// constrain `std.Io` datagram receives, and `receiveTimeout` is
    /// unsupported by some `std.Io` backends). Deadline-driven code must
    /// receive on a `quic Pump` reader thread instead — never call this
    /// where a quiet peer could stall the caller forever.
    pub fn receive(self: *Socket, buffer: []u8) !struct { data: []const u8, from: net.IpAddress } {
        const msg = self.socket.receive(self.io, buffer) catch |err| switch (err) {
            error.MessageOversize => return error.DatagramTruncated,
            error.ConnectionResetByPeer, error.PortUnreachable => return error.ConnectionReset,
            else => return error.ReadFailed,
        };
        if (msg.flags.trunc) return error.DatagramTruncated;
        return .{ .data = msg.data, .from = msg.from };
    }

    /// Receives one datagram before the supplied timeout. A readiness poll
    /// avoids requiring concurrent `std.Io` operations on Windows.
    pub fn receiveTimeout(
        self: *Socket,
        buffer: []u8,
        timeout: std.Io.Timeout,
    ) !struct { data: []const u8, from: net.IpAddress } {
        if (builtin.os.tag == .windows) {
            const msg = self.socket.receiveTimeout(self.io, buffer, timeout) catch |err| switch (err) {
                error.Timeout => return error.Timeout,
                error.MessageOversize => return error.DatagramTruncated,
                error.ConnectionResetByPeer, error.PortUnreachable => return error.ConnectionReset,
                error.ConcurrencyUnavailable => return error.TimeoutUnsupported,
                else => return error.ReadFailed,
            };
            if (msg.flags.trunc) return error.DatagramTruncated;
            return .{ .data = msg.data, .from = msg.from };
        }

        const deadline = timeout.toTimestamp(self.io);
        while (true) {
            if (deadline) |until| {
                const ns = until.durationFromNow(self.io).raw.nanoseconds;
                if (ns <= 0) return error.Timeout;
                var waitMs = @divTrunc(ns, std.time.ns_per_ms);
                if (@rem(ns, std.time.ns_per_ms) != 0) waitMs += 1;
                const boundedMs: u31 = @intCast(@min(waitMs, std.math.maxInt(u31)));
                const ready = sysMod.waitReadable(self.socket.handle, boundedMs) catch return error.ReadFailed;
                if (!ready) continue;
            }
            const msg = self.socket.receive(self.io, buffer) catch |err| switch (err) {
                error.MessageOversize => return error.DatagramTruncated,
                error.ConnectionResetByPeer, error.PortUnreachable => return error.ConnectionReset,
                else => return error.ReadFailed,
            };
            if (msg.flags.trunc) return error.DatagramTruncated;
            return .{ .data = msg.data, .from = msg.from };
        }
    }
};

test "udp bind and local datagram echo" {
    // Bind two UDP sockets on loopback and exchange a datagram
    var gpaState: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpaState.deinit();
    const gpa = gpaState.allocator();

    var ctx = try @import("../sockets/tcp.zig").IoContext.init(gpa);
    defer ctx.deinit();

    var a = try Socket.bind(ctx.io, 0);
    defer a.close();
    var b = try Socket.bind(ctx.io, 0);
    defer b.close();

    const bPort = switch (b.socket.address) {
        .ip4 => |v| v.port,
        .ip6 => |v| v.port,
    };

    const dest = try net.IpAddress.parseIp4("127.0.0.1", bPort);

    try a.sendTo(&dest, "ping");

    var buf: [64]u8 = undefined;
    const rx = try b.receive(&buf);
    try std.testing.expectEqualStrings("ping", rx.data);
}

test "udp ipv6 bind accepts loopback datagrams" {
    var ctx = try @import("../sockets/tcp.zig").IoContext.init(std.testing.allocator);
    defer ctx.deinit();

    var server = try Socket.bindIp6(ctx.io, 0);
    defer server.close();

    const port = switch (server.socket.address) {
        .ip4 => |v| v.port,
        .ip6 => |v| v.port,
    };
    try std.testing.expect(server.socket.address == .ip6);

    var client = try Socket.bindIp6(ctx.io, 0);
    defer client.close();
    const dest = try net.IpAddress.parseIp6("::1", port);
    try client.sendTo(&dest, "v6-ping");

    var buf: [64]u8 = undefined;
    const rx = try server.receive(&buf);
    try std.testing.expectEqualStrings("v6-ping", rx.data);
}

test "udp receive rejects a datagram larger than the supplied buffer" {
    var ctx = try @import("../sockets/tcp.zig").IoContext.init(std.testing.allocator);
    defer ctx.deinit();

    var server = try Socket.bind(ctx.io, 0);
    defer server.close();
    var client = try Socket.bind(ctx.io, 0);
    defer client.close();

    const port = switch (server.socket.address) {
        .ip4 => |v| v.port,
        .ip6 => |v| v.port,
    };
    const dest = try net.IpAddress.parseIp4("127.0.0.1", port);
    try client.sendTo(&dest, "0123456789");

    var small: [4]u8 = undefined;
    try std.testing.expectError(error.DatagramTruncated, server.receive(&small));
}

test "udp timed receive rejects a datagram larger than the supplied buffer" {
    var ctx = try @import("../sockets/tcp.zig").IoContext.init(std.testing.allocator);
    defer ctx.deinit();

    var server = try Socket.bind(ctx.io, 0);
    defer server.close();
    var client = try Socket.bind(ctx.io, 0);
    defer client.close();

    const port = switch (server.socket.address) {
        .ip4 => |v| v.port,
        .ip6 => |v| v.port,
    };
    const dest = try net.IpAddress.parseIp4("127.0.0.1", port);
    try client.sendTo(&dest, "0123456789");

    var small: [4]u8 = undefined;
    const timed = server.receiveTimeout(&small, .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(100),
        .clock = .awake,
    } });
    if (builtin.os.tag == .windows) {
        try std.testing.expectError(error.TimeoutUnsupported, timed);
    } else {
        try std.testing.expectError(error.DatagramTruncated, timed);
    }
}

test "udp receive timeout returns timeout or reports backend limitation" {
    var ctx = try @import("../sockets/tcp.zig").IoContext.init(std.testing.allocator);
    defer ctx.deinit();
    var socket = try Socket.bind(ctx.io, 0);
    defer socket.close();

    var buf: [16]u8 = undefined;
    const timed = socket.receiveTimeout(&buf, .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(10),
        .clock = .awake,
    } });
    if (builtin.os.tag == .windows) {
        try std.testing.expectError(error.TimeoutUnsupported, timed);
    } else {
        try std.testing.expectError(error.Timeout, timed);
    }
}
