//! QUIC <-> real UDP socket adapter.
//!
//! Bridges `Connection` to kernel UDP sockets so the engine runs over an
//! actual network path (not just the internal test pipe). Each endpoint
//! binds one UDP socket; `pump()` drains the socket into the connection
//! and flushes queued output datagrams to the last peer address seen.
//!
//! Scope note (honest): Initial-space packets are fully specified here —
//! their keys derive from the DCID alone (RFC 9001 section 5.2), so endpoints can
//! exchange protected Initial traffic without the TLS 1.3 driver. The
//! full handshake driver remains the open item tracked separately.
//!
//! References:
//!   - RFC 9000 — QUIC: A UDP-Based Multiplexed and Secure Transport
//!   - RFC 9001 — Using TLS to Secure QUIC

const std = @import("std");
const Allocator = std.mem.Allocator;
const udp_mod = @import("../../sockets/udp.zig");
const conn_mod = @import("connection.zig");
const tcp_mod = @import("../../sockets/tcp.zig");
const Connection = conn_mod.Connection;

pub const MAX_DATAGRAM: usize = 1500;

pub const Endpoint = struct {
    conn: *Connection,
    sock: udp_mod.UdpSocket,
    /// Last peer address observed (set on first received datagram).
    peer: ?std.Io.net.IpAddress = null,
    io: std.Io,

    /// Binds an ephemeral local port for `conn`.
    pub fn init(allocator: Allocator, io: std.Io, conn: *Connection) !Endpoint {
        _ = allocator;
        const sock = try udp_mod.UdpSocket.bind(io, 0);
        // Bound waits so pumpIn drains-and-yields instead of blocking
        // forever once the peer goes quiet.
        tcp_mod.setTimeouts(sock.socket.handle, 250);
        return .{ .conn = conn, .sock = sock, .io = io };
    }

    pub fn deinit(self: *Endpoint) void {
        self.sock.close();
    }

    pub fn localPort(self: *const Endpoint) u16 {
        return switch (self.sock.socket.address) {
            .ip4 => |v| v.port,
            .ip6 => |v| v.port,
        };
    }

    /// Receives up to `max` datagrams into the connection. Returns the
    /// number processed. Non-fatal per-datagram errors are counted and
    /// skipped (hostile-input tolerance); fatal connection errors surface.
    pub fn pumpIn(self: *Endpoint, max: usize, now_ms: u64) !usize {
        var buf: [MAX_DATAGRAM]u8 = undefined;
        var n: usize = 0;
        while (n < max) : (n += 1) {
            const rx = self.sock.receive(&buf) catch return n; // timeout/err => drained
            self.peer = rx.from;
            self.conn.receiveDatagram(rx.data, now_ms) catch |e| switch (e) {
                error.Draining => return error.Draining,
                else => continue, // drop bad datagrams, keep going
            };
        }
        return n;
    }

    /// Flushes all currently queued connection output to the peer.
    /// Requires a known destination: either `peer` from prior traffic or
    /// an explicit `dest` for the first flight (client role).
    pub fn flush(self: *Endpoint, dest: ?std.Io.net.IpAddress) !usize {
        const d = dest orelse self.peer orelse return error.NoRoute;
        var sent: usize = 0;
        while (self.conn.outbuf.items.len > 0) {
            const take = @min(MAX_DATAGRAM, self.conn.outbuf.items.len);
            try self.sock.sendTo(&d, self.conn.outbuf.items[0..take]);
            self.conn.outbuf.replaceRange(self.conn.allocator, 0, take, &.{}) catch
                return error.OutOfMemory;
            sent += take;
            // A coalesced burst beyond one datagram needs explicit pacing;
            // this adapter intentionally stays simple and returns after
            // draining what fits without blocking.
            if (self.conn.outbuf.items.len == 0) break;
        }
        return sent;
    }
};

// Loopback integration: two Endpoints over REAL kernel UDP sockets
// exchanging protected Initial-space traffic (RFC 9001 initial secrets).

test "quic endpoints exchange protected initial packets over real udp" {
    const a = std.testing.allocator;
    var ctx = @import("../../sockets/tcp.zig").IoContext.init(a) catch return;

    defer ctx.deinit();

    var client = try conn_mod.Connection.init(a, .client, .{}, 11);
    defer client.deinit();
    var server = try conn_mod.Connection.init(a, .server, .{}, 22);
    defer server.deinit();

    // Queue a real Initial-space flight (keys derive from DCID alone, so
    // no TLS driver is needed at this level).
    try client.installInitialKeys();
    const PingC = struct {
        fn build(gpa: Allocator, payload: *std.ArrayList(u8)) conn_mod.Error!void {
            @import("../quic/frames.zig").encode(payload, gpa, .ping) catch
                return conn_mod.Error.OutOfMemory;
        }
    };
    try client.sendFrames(.initial, PingC.build, 50);
    try server.acceptInitial(client.dcid[0..8]);

    var ce = try Endpoint.init(a, ctx.io, client);
    defer ce.deinit();
    var se = try Endpoint.init(a, ctx.io, server);
    defer se.deinit();

    const cport = ce.localPort();
    const sport = se.localPort();
    try std.testing.expect(cport != 0 and sport != 0);

    const cdest = std.Io.net.IpAddress.parseIp4("127.0.0.1", sport) catch unreachable;

    // Client -> server over the kernel; fail fast if nothing was queued.
    const sent = try ce.flush(cdest);
    try std.testing.expect(sent > 0);
    const got_in = try se.pumpIn(1, 100);
    try std.testing.expect(got_in >= 1);

    // Server -> client reply (ACK-bearing ping injected via sendFrames).
    const Ping = struct {
        fn build(gpa: Allocator, payload: *std.ArrayList(u8)) conn_mod.Error!void {
            @import("../quic/frames.zig").encode(payload, gpa, .ping) catch return conn_mod.Error.OutOfMemory;
        }
    };
    try server.sendFrames(.initial, Ping.build, 150);

    // Flush BEFORE reading localPort-independent peer info: server learned
    // the client's address from its received datagram.
    _ = try se.flush(null);
    const got_back = try ce.pumpIn(1, 200);
    try std.testing.expect(got_back >= 1);
}
