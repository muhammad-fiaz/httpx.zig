//! HTTP/3 client transport over live QUIC (RFC 9114).
//!
//! Runs one request/response exchange over an established QUIC
//! connection: control + QPACK unidirectional streams, then a
//! client-initiated bidirectional stream carrying HEADERS (+FIN for
//! bodyless requests) and collecting the response HEADERS + DATA.
//!
//! Scope (documented, not hidden):
//!   * One request per connection for now (no H3 pooling yet); the
//!     struct is shaped so pooling can reuse it later.
//!   * Response QPACK sections must decode with connection state plus
//!     the static table: servers using dynamic-table insertions that
//!     require decoder-stream traffic will fail the decode loudly.
//!   * Request bodies are not sent yet (GET/HEAD-style exchanges).
//!   * GOAWAY is not specially handled: a connection that goes away
//!     mid-request surfaces as a truncated response error.
//!
//! Pumping: `request` drives our endpoint and, when `peer` is set, an
//! in-process peer endpoint too (loopback tests/examples). Against an
//! external server `peer` is null and only our socket is pumped.

const std = @import("std");
const Allocator = std.mem.Allocator;
const quic_conn = @import("../quic/connection.zig");
const quic_ep = @import("../quic/transport.zig");
const quic_hs = @import("../quic/handshake.zig");
const h3conn = @import("connection.zig");
const h3frame = @import("frame.zig");
const h3qpack = @import("qpack.zig");
const clock_mod = @import("../../common/clock.zig");

pub const Error = error{
    HandshakeFailed,
    AlpnMismatch,
    TlsCertificateNotVerified,
    TlsHandshakeFailed,
    Timeout,
    TruncatedResponse,
    ResponseTooLarge,
    ProtocolViolation,
    OutOfMemory,
};

pub const Header = struct { name: []const u8, value: []const u8 };

pub const H3Response = struct {
    status: u16,
    headers: []Header,
    body: []u8,
    allocator: Allocator,

    pub fn deinit(self: *H3Response) void {
        for (self.headers) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.allocator.free(self.headers);
        self.allocator.free(self.body);
    }
};

/// Accumulates one response stream's bytes until FIN.
const RespState = struct {
    sid: u64 = std.math.maxInt(u64),
    buf: std.ArrayList(u8) = .empty,
    fin: bool = false,
    overflow: bool = false,
    status: u16 = 0,
    head_done: bool = false,
};

pub const Client = struct {
    allocator: Allocator,
    ep: *quic_ep.Endpoint,
    h3: h3conn.Connection,
    control_done: bool = false,
    resp: RespState = .{},
    max_bytes: usize = 64 * 1024 * 1024,

    pub fn init(allocator: Allocator, ep: *quic_ep.Endpoint) Client {
        return .{ .allocator = allocator, .ep = ep, .h3 = h3conn.Connection.init(allocator, .client) };
    }

    pub fn deinit(self: *Client) void {
        self.h3.deinit();
        self.resp.buf.deinit(self.allocator);
    }

    fn onStream(ctx: ?*anyopaque, sid: u64, data: []const u8, fin: bool) void {
        const self: *Client = @ptrCast(@alignCast(ctx.?));
        if (sid != self.resp.sid) return;
        if (self.resp.buf.items.len + data.len > self.max_bytes) {
            self.resp.overflow = true;
            return;
        }
        self.resp.buf.appendSlice(self.allocator, data) catch {
            self.resp.overflow = true;
            return;
        };
        if (fin) self.resp.fin = true;
    }

    /// Sends our control + QPACK unidirectional streams (once per conn).
    fn setupStreams(self: *Client, nowMs: u64) !void {
        if (self.control_done) return;
        const a = self.allocator;
        const ctl = try self.h3.buildControlStream();
        defer a.free(ctl);
        try sendStream(self.ep.conn, 2, 0, ctl, false, nowMs);
        const enc = try h3conn.buildQpackEncoderStreamPrefix(a);
        defer a.free(enc);
        try sendStream(self.ep.conn, 6, 0, enc, false, nowMs);
        const dec = try h3conn.buildQpackDecoderStreamPrefix(a);
        defer a.free(dec);
        try sendStream(self.ep.conn, 10, 0, dec, false, nowMs);
        self.control_done = true;
    }

    /// One GET-style exchange over an already-started pump. Against an
    /// external server the peer pumps itself; in loopback tests the
    /// server thread runs its own pump concurrently.
    pub fn request(
        self: *Client,
        method: []const u8,
        scheme: []const u8,
        authority: []const u8,
        path: []const u8,
        extra: []const Header,
        pump: *quic_ep.Pump,
        dest: std.Io.net.IpAddress,
        deadlineMs: u64,
    ) !H3Response {
        const a = self.allocator;
        self.ep.conn.cbs = .{ .ctx = self, .onStreamData = onStream };
        try self.setupStreams(@intCast(clock_mod.millisNow()));
        _ = try self.ep.flush(dest);

        const sid = self.h3.nextBidiStreamId();
        self.resp = .{ .sid = sid };
        var rs = h3conn.RequestStream{ .id = sid, .allocator = a, .qpack = h3qpack.Encoder.init(a) };
        defer rs.qpack.deinit();
        var qextra = std.ArrayList(h3qpack.FieldLine).empty;
        defer qextra.deinit(a);
        for (extra) |h| try qextra.append(a, .{ .name = h.name, .value = h.value });
        const head = try rs.buildRequestHeaders(method, scheme, authority, path, qextra.items);
        defer a.free(head);
        try sendStream(self.ep.conn, sid, 0, head, true, @intCast(clock_mod.millisNow()));
        _ = try self.ep.flush(dest);

        const start: u64 = @intCast(clock_mod.millisNow());
        while (true) {
            const now: u64 = @intCast(clock_mod.millisNow());
            if (now -| start > deadlineMs) return error.Timeout;
            const remain = deadlineMs -| (now -| start);
            try quic_hs.feedPumped(self.ep, pump, dest, @min(remain, 1000), now);
            if (self.resp.overflow) return error.ResponseTooLarge;
            if (self.resp.fin) break;
            if (self.ep.conn.state == .closed or self.ep.conn.state == .draining) {
                return error.TruncatedResponse;
            }
        }
        return self.parseResponse();
    }

    fn parseResponse(self: *Client) !H3Response {
        const a = self.allocator;
        var headers = std.ArrayList(Header).empty;
        errdefer {
            for (headers.items) |h| {
                a.free(h.name);
                a.free(h.value);
            }
            headers.deinit(a);
        }
        var body = std.ArrayList(u8).empty;
        errdefer body.deinit(a);
        var status: u16 = 0;
        const bytes = self.resp.buf.items;
        var off: usize = 0;
        while (off < bytes.len) {
            const fr = try h3frame.parseFrame(bytes, &off);
            if (fr.frameType == 0x1) {
                const fields = try self.h3.qdec.decodeSectionWithPrefix(fr.payload);
                defer self.h3.qdec.freeFields(fields);
                for (fields) |f| {
                    if (std.mem.eql(u8, f.name, ":status")) {
                        status = try std.fmt.parseInt(u16, f.value, 10);
                        continue;
                    }
                    if (std.mem.startsWith(u8, f.name, ":")) continue;
                    try headers.append(a, .{
                        .name = try a.dupe(u8, f.name),
                        .value = try a.dupe(u8, f.value),
                    });
                }
            } else if (fr.frameType == 0x0) {
                try body.appendSlice(a, fr.payload);
            } else {
                return error.ProtocolViolation;
            }
        }
        if (status == 0) return error.TruncatedResponse;
        return .{
            .status = status,
            .headers = try headers.toOwnedSlice(a),
            .body = try body.toOwnedSlice(a),
            .allocator = a,
        };
    }
};

/// Sends `bytes` as one QUIC STREAM frame on `sid`.
fn sendStream(conn: *quic_conn.Connection, sid: u64, offset: u64, bytes: []const u8, fin: bool, nowMs: u64) !void {
    const B = struct {
        var s_id: u64 = 0;
        var s_off: u64 = 0;
        var s_fin: bool = false;
        var s_data: []const u8 = "";
        pub fn build(gpa: Allocator, payload: *std.ArrayList(u8)) quic_conn.Error!void {
            @import("../quic/frames.zig").encode(payload, gpa, .{ .stream = .{ .id = s_id, .offset = s_off, .data = s_data, .fin = s_fin } }) catch
                return quic_conn.Error.OutOfMemory;
        }
    };
    B.s_id = sid;
    B.s_off = offset;
    B.s_fin = fin;
    B.s_data = bytes;
    try conn.sendFrames(.application, B.build, nowMs);
}

/// Maps QUIC/driver failures onto the H3 error set, preserving the
/// driver's precise cause (ALPN vs certificate vs generic).
pub fn mapHandshakeError(err: anyerror, detail: quic_hs.Driver.Detail) Error {
    return switch (err) {
        error.OutOfMemory => Error.OutOfMemory,
        error.HandshakeTimeout => Error.Timeout,
        else => switch (detail) {
            .alpn_mismatch => Error.AlpnMismatch,
            .cert_failed => Error.TlsCertificateNotVerified,
            else => Error.TlsHandshakeFailed,
        },
    };
}
