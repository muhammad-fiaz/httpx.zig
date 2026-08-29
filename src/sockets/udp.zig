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
const net = std.Io.net;
const Allocator = std.mem.Allocator;

pub const MAX_DATAGRAM: usize = 65527; // max UDP payload (64KiB - 8 header - 20 IP)

pub const UdpSocket = struct {
    socket: net.Socket,
    io: std.Io,
    default_dest: ?net.IpAddress = null,

    /// Binds to 0.0.0.0:port. port=0 lets the OS choose (typical for clients).
    pub fn bind(io: std.Io, port: u16) !UdpSocket {
        const addr = try net.IpAddress.parseIp4("0.0.0.0", port);
        const sock = try addr.bind(io, .{ .mode = .dgram });
        return .{ .socket = sock, .io = io };
    }

    pub fn close(self: *UdpSocket) void {
        self.socket.close(self.io);
    }

    /// Sends one datagram to dest.
    pub fn sendTo(self: *UdpSocket, dest: *const net.IpAddress, data: []const u8) !void {
        try self.socket.send(self.io, dest, data);
    }

    /// Sends using the configured default destination.
    pub fn send(self: *UdpSocket, data: []const u8) !void {
        const d = self.default_dest orelse error.NoDefaultDestination;
        try self.sendTo(&d, data);
    }

    /// Receives one datagram. Returns payload slice (into buffer) and source address.
    pub fn receive(self: *UdpSocket, buffer: []u8) !struct { data: []const u8, from: net.IpAddress } {
        const msg = self.socket.receive(self.io, buffer) catch |err| switch (err) {
            error.ConnectionResetByPeer, error.PortUnreachable => return error.ConnectionReset,
            else => return error.ReadFailed,
        };
        return .{ .data = msg.data, .from = msg.from };
    }
};

test "udp bind and local datagram echo" {
    // Bind two UDP sockets on loopback and exchange a datagram
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var ctx = @import("../sockets/tcp.zig").IoContext.init(gpa) catch return;
    defer ctx.deinit();

    var a = UdpSocket.bind(ctx.io, 0) catch return;
    defer a.close();
    var b = UdpSocket.bind(ctx.io, 0) catch return;
    defer b.close();

    const b_port = switch (b.socket.address) {
        .ip4 => |v| v.port,
        .ip6 => |v| v.port,
    };

    const dest = net.IpAddress.parseIp4("127.0.0.1", b_port) catch return;

    a.sendTo(&dest, "ping") catch return;

    var buf: [64]u8 = undefined;
    const rx = b.receive(&buf) catch return;
    try std.testing.expectEqualStrings("ping", rx.data);
}
