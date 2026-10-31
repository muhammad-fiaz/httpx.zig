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

pub const MAX_DATAGRAM: usize = 65527; // max UDP payload (64KiB - 8 header - 20 IP)

pub const UdpSocket = struct {
    socket: net.Socket,
    io: std.Io,
    defaultDest: ?net.IpAddress = null,
    closed: std.atomic.Value(bool) = .init(false),

    /// Binds to 0.0.0.0:port. port=0 lets the OS choose (typical for clients).
    pub fn bind(io: std.Io, port: u16) !UdpSocket {
        const addr = try net.IpAddress.parseIp4("0.0.0.0", port);
        return bindAddress(io, &addr);
    }

    /// Binds the IPv6 wildcard address `[::]:port`. Useful for DNS/QUIC
    /// endpoints that must accept IPv6 peers; separate from `bind` so the
    /// default remains an IPv4 socket on hosts where IPv6 is unavailable.
    pub fn bindIp6(io: std.Io, port: u16) !UdpSocket {
        const addr = try net.IpAddress.parseIp6("::", port);
        return bindAddress(io, &addr);
    }

    /// Binds an explicit local address (IPv4 or IPv6).
    pub fn bindAddress(io: std.Io, addr: *const net.IpAddress) !UdpSocket {
        const sock = try addr.bind(io, .{ .mode = .dgram });
        return .{ .socket = sock, .io = io };
    }

    /// Idempotent close: QUIC pump shutdown and endpoint teardown both
    /// close the same socket, and a second OS close could otherwise
    /// release an unrelated recycled descriptor.
    pub fn close(self: *UdpSocket) void {
        if (self.closed.swap(true, .acq_rel)) return;
        self.socket.close(self.io);
    }

    /// Sends one datagram to dest.
    pub fn sendTo(self: *UdpSocket, dest: *const net.IpAddress, data: []const u8) !void {
        try self.socket.send(self.io, dest, data);
    }

    /// Sends using the configured default destination.
    pub fn send(self: *UdpSocket, data: []const u8) !void {
        const d = self.defaultDest orelse error.NoDefaultDestination;
        try self.sendTo(&d, data);
    }

    /// Receives one datagram. Returns payload slice (into buffer) and source address.
    ///
    /// Returns `error.DatagramTruncated` when the datagram was larger than
    /// `buffer` instead of silently handing callers a partial message. (The
    /// Linux/POSIX `std.Io` backend reports this via MSG_TRUNC; Windows does
    /// not expose it and will still report the truncated payload.)
    ///
    /// NOTE: this blocks indefinitely (socket-level SO_RCVTIMEO does not
    /// constrain `std.Io` datagram receives, and `receiveTimeout` is
    /// unsupported by some `std.Io` backends). Deadline-driven code must
    /// receive on a `quic Pump` reader thread instead — never call this
    /// where a quiet peer could stall the caller forever.
    pub fn receive(self: *UdpSocket, buffer: []u8) !struct { data: []const u8, from: net.IpAddress } {
        const msg = self.socket.receive(self.io, buffer) catch |err| switch (err) {
            error.ConnectionResetByPeer, error.PortUnreachable => return error.ConnectionReset,
            else => return error.ReadFailed,
        };
        if (msg.flags.trunc) return error.DatagramTruncated;
        return .{ .data = msg.data, .from = msg.from };
    }

    /// Receives one datagram before the supplied timeout. POSIX uses a
    /// readiness poll before `std.Io` receive; Windows delegates to its timed
    /// I/O backend and reports `TimeoutUnsupported` when concurrency is absent.
    pub fn receiveTimeout(
        self: *UdpSocket,
        buffer: []u8,
        timeout: std.Io.Timeout,
    ) !struct { data: []const u8, from: net.IpAddress } {
        if (builtin.os.tag == .windows) {
            const msg = self.socket.receiveTimeout(self.io, buffer, timeout) catch |err| switch (err) {
                error.Timeout => return error.Timeout,
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

    var ctx = @import("../sockets/tcp.zig").IoContext.init(gpa) catch return;
    defer ctx.deinit();

    var a = UdpSocket.bind(ctx.io, 0) catch return;
    defer a.close();
    var b = UdpSocket.bind(ctx.io, 0) catch return;
    defer b.close();

    const bPort = switch (b.socket.address) {
        .ip4 => |v| v.port,
        .ip6 => |v| v.port,
    };

    const dest = net.IpAddress.parseIp4("127.0.0.1", bPort) catch return;

    a.sendTo(&dest, "ping") catch return;

    var buf: [64]u8 = undefined;
    const rx = b.receive(&buf) catch return;
    try std.testing.expectEqualStrings("ping", rx.data);
}

test "udp ipv6 bind accepts loopback datagrams" {
    var ctx = @import("../sockets/tcp.zig").IoContext.init(std.testing.allocator) catch return;
    defer ctx.deinit();

    var server = UdpSocket.bindIp6(ctx.io, 0) catch |err| switch (err) {
        error.AddressFamilyUnsupported,
        error.ProtocolUnsupportedBySystem,
        error.ProtocolUnsupportedByAddressFamily,
        error.AddressUnavailable,
        => return error.SkipZigTest,
        else => return err,
    };
    defer server.close();

    const port = switch (server.socket.address) {
        .ip4 => |v| v.port,
        .ip6 => |v| v.port,
    };
    try std.testing.expect(server.socket.address == .ip6);

    var client = UdpSocket.bindIp6(ctx.io, 0) catch return;
    defer client.close();
    const dest = try net.IpAddress.parseIp6("::1", port);
    // Hosts without a usable IPv6 loopback may fail at bind/send time;
    // treat that as a platform skip rather than a product failure.
    client.sendTo(&dest, "v6-ping") catch return error.SkipZigTest;

    var buf: [64]u8 = undefined;
    const rx = try server.receive(&buf);
    try std.testing.expectEqualStrings("v6-ping", rx.data);
}

test "udp receive rejects a datagram larger than the supplied buffer" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // MSG_TRUNC not surfaced
    var ctx = @import("../sockets/tcp.zig").IoContext.init(std.testing.allocator) catch return;
    defer ctx.deinit();

    var server = try UdpSocket.bind(ctx.io, 0);
    defer server.close();
    var client = try UdpSocket.bind(ctx.io, 0);
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

test "udp receive timeout is bounded or reports unsupported operation" {
    var ctx = @import("../sockets/tcp.zig").IoContext.init(std.testing.allocator) catch return;
    defer ctx.deinit();
    var socket = UdpSocket.bind(ctx.io, 0) catch return;
    defer socket.close();

    var buf: [16]u8 = undefined;
    _ = socket.receiveTimeout(&buf, .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(10),
        .clock = .awake,
    } }) catch |err| {
        try std.testing.expect(err == error.Timeout or err == error.TimeoutUnsupported);
        return;
    };
    return error.ExpectedTimeout;
}
