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
//!   * Request bodies are sent as buffered DATA frames; streaming uploads are
//!     not provided by this one-shot client API.
//!   * GOAWAY is not specially handled: a connection that goes away
//!     mid-request surfaces as a truncated response error.
//!
//! Pumping: `request` drives our endpoint and, when `peer` is set, an
//! in-process peer endpoint too (loopback tests/examples). Against an
//! external server `peer` is null and only our socket is pumped.

const std = @import("std");
const Allocator = std.mem.Allocator;
const quicConn = @import("../quic/connection.zig");
const quicEp = @import("../quic/transport.zig");
const quicHs = @import("../quic/handshake.zig");
const h3conn = @import("connection.zig");
const h3frame = @import("frame.zig");
const h3qpack = @import("qpack.zig");
const clockMod = @import("../../common/clock.zig");

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
    headDone: bool = false,
};

pub const Client = struct {
    allocator: Allocator,
    ep: *quicEp.Endpoint,
    h3: h3conn.Connection,
    controlDone: bool = false,
    resp: RespState = .{},
    maxBytes: usize = 64 * 1024 * 1024,

    pub fn init(allocator: Allocator, ep: *quicEp.Endpoint) Client {
        return .{ .allocator = allocator, .ep = ep, .h3 = h3conn.Connection.init(allocator, .client) };
    }

    pub fn deinit(self: *Client) void {
        self.h3.deinit();
        self.resp.buf.deinit(self.allocator);
    }

    fn onStream(ctx: ?*anyopaque, sid: u64, data: []const u8, fin: bool) void {
        const self: *Client = @ptrCast(@alignCast(ctx.?));
        if (sid != self.resp.sid) return;
        if (data.len > self.maxBytes -| self.resp.buf.items.len) {
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
        if (self.controlDone) return;
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
        self.controlDone = true;
    }

    /// One request/response exchange over an already-started pump. Supports
    /// request and response bodies (GET, POST, PUT, DELETE, PATCH, etc.).
    /// Against an external server the peer pumps itself; in loopback tests
    /// the server thread runs its own pump concurrently.
    pub fn request(
        self: *Client,
        method: []const u8,
        scheme: []const u8,
        authority: []const u8,
        path: []const u8,
        extra: []const Header,
        body: ?[]const u8,
        pump: *quicEp.Pump,
        dest: std.Io.net.IpAddress,
        deadlineMs: u64,
        maxBytes: usize,
    ) !H3Response {
        self.maxBytes = @min(maxBytes, 64 * 1024 * 1024);
        const a = self.allocator;
        self.ep.conn.cbs = .{ .ctx = self, .onStreamData = onStream };
        try self.setupStreams(@intCast(clockMod.millisNow()));
        _ = try self.ep.flush(dest);

        const sid = self.h3.nextBidiStreamId();
        self.resp = .{ .sid = sid };
        var qenc = h3qpack.Encoder.init(a);
        defer qenc.deinit();
        var rs = h3conn.RequestStream{ .id = sid, .allocator = a, .qpack = &qenc };
        var qextra = std.ArrayList(h3qpack.FieldLine).empty;
        defer qextra.deinit(a);
        for (extra) |h| try qextra.append(a, .{ .name = h.name, .value = h.value });
        const head = try rs.buildRequestHeaders(method, scheme, authority, path, qextra.items);
        defer a.free(head);

        const hasBody = body != null and body.?.len > 0;
        if (!hasBody) {
            try sendStream(self.ep.conn, sid, 0, head, true, @intCast(clockMod.millisNow()));
            _ = try self.ep.flush(dest);
        } else {
            const bodyBytes = body.?;
            const dhead = try rs.buildData(bodyBytes);
            defer a.free(dhead);

            var streamOff: u64 = 0;
            try sendStream(self.ep.conn, sid, streamOff, head, false, @intCast(clockMod.millisNow()));
            streamOff += head.len;
            _ = try self.ep.flush(dest);

            // Chunk the H3 DATA frame across QUIC packets if large (MTU friendly, <= 1200 bytes per chunk)
            var bodyCursor: usize = 0;
            const maxChunkSize: usize = 1200;
            while (bodyCursor < dhead.len) {
                const chunkEnd = @min(bodyCursor + maxChunkSize, dhead.len);
                const chunk = dhead[bodyCursor..chunkEnd];
                const isFinal = chunkEnd == dhead.len;
                try sendStream(self.ep.conn, sid, streamOff, chunk, isFinal, @intCast(clockMod.millisNow()));
                streamOff += chunk.len;
                bodyCursor = chunkEnd;
                _ = try self.ep.flush(dest);
            }
        }

        const start: u64 = @intCast(clockMod.millisNow());
        while (true) {
            const now: u64 = @intCast(clockMod.millisNow());
            if (now -| start > deadlineMs) return error.Timeout;
            const remain = deadlineMs -| (now -| start);
            try quicHs.feedPumped(self.ep, pump, dest, @min(remain, 1000), now);
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
            if (h3frame.checkFrameAllowed(.requestBidi, fr.frameType)) |_| {
                return error.ProtocolViolation;
            }
            if (fr.frameType == 0x1) {
                const fields = try self.h3.qdec.decodeSectionCounted(fr.payload, 0, null);
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
                // Unknown/extension frames allowed on request streams per RFC 9114 Section 7.2.8:
                // payload already skipped past by parseFrame.
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

test "http3 response collector rejects a chunk beyond its configured limit" {
    const a = std.testing.allocator;
    var endpoint: quicEp.Endpoint = undefined;
    var client = Client.init(a, &endpoint);
    defer client.deinit();
    client.maxBytes = 3;
    client.resp.sid = 0;

    Client.onStream(&client, 0, "data", true);

    try std.testing.expect(client.resp.overflow);
    try std.testing.expectEqual(@as(usize, 0), client.resp.buf.items.len);
}

/// Sends `bytes` as one QUIC STREAM frame on `sid`.
fn sendStream(conn: *quicConn.Connection, sid: u64, offset: u64, bytes: []const u8, fin: bool, nowMs: u64) !void {
    const B = struct {
        var sId: u64 = 0;
        var sOff: u64 = 0;
        var sFin: bool = false;
        var sData: []const u8 = "";
        pub fn build(gpa: Allocator, payload: *std.ArrayList(u8)) quicConn.Error!void {
            @import("../quic/frames.zig").encode(payload, gpa, .{ .stream = .{ .id = sId, .offset = sOff, .data = sData, .fin = sFin } }) catch
                return quicConn.Error.OutOfMemory;
        }
    };
    B.sId = sid;
    B.sOff = offset;
    B.sFin = fin;
    B.sData = bytes;
    try conn.sendFrames(.application, B.build, nowMs);
}

/// Maps QUIC/driver failures onto the H3 error set, preserving the
/// driver's precise cause (ALPN vs certificate vs generic).
pub fn mapHandshakeError(err: anyerror, detail: quicHs.Driver.Detail) Error {
    return switch (err) {
        error.OutOfMemory => Error.OutOfMemory,
        error.HandshakeTimeout => Error.Timeout,
        else => switch (detail) {
            .alpnMismatch => Error.AlpnMismatch,
            .certFailed => Error.TlsCertificateNotVerified,
            else => Error.TlsHandshakeFailed,
        },
    };
}
