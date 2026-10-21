//! HTTP/3 client transport over live QUIC (RFC 9114).
//!
//! Runs one request/response exchange over an established QUIC
//! connection. All inbound stream bytes are routed through
//! `connection.Connection`, so control/QPACK streams, SETTINGS,
//! multi-section responses, trailers, and QPACK blocking are handled by
//! the same state machine the server uses.
//!
//! Scope (documented, not hidden):
//!   * One request per connection for now (no H3 pooling yet); the
//!     struct is shaped so pooling can reuse it later.
//!   * Request bodies are sent as buffered DATA frames; streaming uploads are
//!     not provided by this one-shot client API.
//!   * A peer GOAWAY received after the request stream opened does not
//!     cancel the in-flight exchange; GOAWAY before opening fails the
//!     request instead of silently retrying on a new connection.
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
const h3qpack = @import("qpack.zig");
const h3frame = @import("frame.zig");
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
    trailers: []Header,
    body: []u8,
    allocator: Allocator,

    pub fn deinit(self: *H3Response) void {
        freeHeaders(self.allocator, self.headers);
        freeHeaders(self.allocator, self.trailers);
        self.allocator.free(self.body);
    }
};

fn freeHeaders(allocator: Allocator, headers: []Header) void {
    for (headers) |h| {
        allocator.free(h.name);
        allocator.free(h.value);
    }
    allocator.free(headers);
}

/// Accumulates one response stream's events. Field strings and body
/// bytes are copied because the H3 callback slices are borrowed.
const RespState = struct {
    sid: u64 = std.math.maxInt(u64),
    status: u16 = 0,
    headers: std.ArrayList(Header) = .empty,
    trailers: std.ArrayList(Header) = .empty,
    body: std.ArrayList(u8) = .empty,
    headerBytes: usize = 0,
    maxBytes: usize = 64 * 1024 * 1024,
    maxHeaderBytes: usize = 1024 * 1024,
    done: bool = false,
    failed: bool = false,
    overflow: bool = false,
    oom: bool = false,
    resetCode: ?u64 = null,
    h3Error: ?h3frame.H3Error = null,
    goawayRejected: bool = false,

    fn deinit(self: *RespState, allocator: Allocator) void {
        for (self.headers.items) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        self.headers.deinit(allocator);
        for (self.trailers.items) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        self.trailers.deinit(allocator);
        self.body.deinit(allocator);
    }
};
pub const Client = struct {
    allocator: Allocator,
    ep: *quicEp.Endpoint,
    h3: h3conn.Connection,
    controlDone: bool = false,
    responses: std.AutoHashMap(u64, RespState),
    maxBytes: usize = 64 * 1024 * 1024,
    maxHeaderBytes: usize = 1024 * 1024,
    ioError: ?anyerror = null,

    pub fn init(allocator: Allocator, ep: *quicEp.Endpoint) Client {
        return .{
            .allocator = allocator,
            .ep = ep,
            .h3 = h3conn.Connection.init(allocator, .client),
            .responses = std.AutoHashMap(u64, RespState).init(allocator),
        };
    }

    pub fn deinit(self: *Client) void {
        var it = self.responses.valueIterator();
        while (it.next()) |r| r.deinit(self.allocator);
        self.responses.deinit();
        self.h3.deinit();
    }

    fn onQuicStream(ctx: ?*anyopaque, sid: u64, data: []const u8, fin: bool) void {
        const self: *Client = @ptrCast(@alignCast(ctx.?));
        self.h3.feedQuic(sid, data, fin) catch {
            if (self.h3.takeStreamError()) |se| self.failStream(se.sid, se.code);
            if (self.h3.fatalError != null) self.ioError = error.ProtocolViolation;
            return;
        };
        if (self.h3.takeStreamError()) |se| self.failStream(se.sid, se.code);
        // Encoder-stream inserts may have unblocked request sections.
        self.h3.retryBlockedStreams();
        if (self.h3.fatalError != null) self.ioError = error.ProtocolViolation;
    }

    fn failStream(self: *Client, sid: u64, code: h3frame.H3Error) void {
        if (self.responses.getPtr(sid)) |r| {
            r.failed = true;
            r.h3Error = code;
        }
    }

    fn onQuicReset(ctx: ?*anyopaque, sid: u64, code: u64) void {
        const self: *Client = @ptrCast(@alignCast(ctx.?));
        self.h3.onQuicReset(sid, code);
        if (self.responses.getPtr(sid)) |r| {
            r.failed = true;
            r.resetCode = code;
        }
    }

    fn onHeaders(ctx: ?*anyopaque, sid: u64, fields: []const h3qpack.FieldLine, interim: bool) void {
        const self: *Client = @ptrCast(@alignCast(ctx.?));
        const r = self.responses.getPtr(sid) orelse return;
        if (r.failed) return;
        if (interim) return; // 1xx metadata is informational only.

        var status: ?[]const u8 = null;
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, ":status")) status = f.value;
        }
        const raw = status orelse {
            r.failed = true;
            return;
        };
        r.status = std.fmt.parseInt(u16, raw, 10) catch {
            r.failed = true;
            return;
        };
        self.copyFields(r, &r.headers, fields);
    }

    fn onData(ctx: ?*anyopaque, sid: u64, data: []const u8) void {
        const self: *Client = @ptrCast(@alignCast(ctx.?));
        const r = self.responses.getPtr(sid) orelse return;
        if (r.failed) return;
        if (data.len > r.maxBytes -| r.body.items.len) {
            r.overflow = true;
            return;
        }
        r.body.appendSlice(self.allocator, data) catch {
            r.oom = true;
        };
    }

    fn onTrailers(ctx: ?*anyopaque, sid: u64, fields: []const h3qpack.FieldLine) void {
        const self: *Client = @ptrCast(@alignCast(ctx.?));
        const r = self.responses.getPtr(sid) orelse return;
        if (r.failed) return;
        self.copyFields(r, &r.trailers, fields);
    }

    fn onMessageEnd(ctx: ?*anyopaque, sid: u64) void {
        const self: *Client = @ptrCast(@alignCast(ctx.?));
        const r = self.responses.getPtr(sid) orelse return;
        r.done = true;
    }

    fn onH3Error(ctx: ?*anyopaque, sid: u64, code: h3frame.H3Error) void {
        const self: *Client = @ptrCast(@alignCast(ctx.?));
        const r = self.responses.getPtr(sid) orelse return;
        r.failed = true;
        r.h3Error = code;
    }

    fn onGoaway(ctx: ?*anyopaque, lastSid: u64) void {
        const self: *Client = @ptrCast(@alignCast(ctx.?));
        var it = self.responses.valueIterator();
        while (it.next()) |r| {
            if (r.sid <= lastSid or r.done) continue;
            r.failed = true;
            r.goawayRejected = true;
        }
    }
    fn copyFields(self: *Client, r: *RespState, list: *std.ArrayList(Header), fields: []const h3qpack.FieldLine) void {
        for (fields) |f| {
            if (f.name.len > 0 and f.name[0] == ':') continue;
            r.headerBytes +|= f.name.len +| f.value.len;
            if (r.headerBytes > r.maxHeaderBytes) {
                r.overflow = true;
                return;
            }
            const name = self.allocator.dupe(u8, f.name) catch {
                r.oom = true;
                return;
            };
            const value = self.allocator.dupe(u8, f.value) catch {
                self.allocator.free(name);
                r.oom = true;
                return;
            };
            list.append(self.allocator, .{ .name = name, .value = value }) catch {
                self.allocator.free(name);
                self.allocator.free(value);
                r.oom = true;
                return;
            };
        }
    }

    /// Sends our control + QPACK unidirectional streams (once per conn).
    fn setupStreams(self: *Client, nowMs: u64) !void {
        if (self.controlDone) return;
        self.h3.cbs = .{
            .ctx = self,
            .onHeaders = onHeaders,
            .onData = onData,
            .onTrailers = onTrailers,
            .onMessageEnd = onMessageEnd,
            .onStreamReset = onQuicReset,
            .onH3Error = onH3Error,
            .onGoaway = onGoaway,
        };
        try self.h3.sendControl(self.ep.conn, nowMs);
        try self.h3.sendQpackPrefixes(self.ep.conn, nowMs);
        self.controlDone = true;
    }

    fn pumpQpack(self: *Client, nowMs: u64) !void {
        try self.h3.pumpQpack(self.ep.conn, nowMs);
    }

    /// Starts one request/response exchange over an already-started pump and
    /// returns its QUIC stream ID. Multiple calls on the same `Client`
    /// multiplex requests concurrently; call `waitResponse`/`waitAll` to
    /// collect the results. Supports request and response bodies.
    pub fn startRequest(
        self: *Client,
        method: []const u8,
        scheme: []const u8,
        authority: []const u8,
        path: []const u8,
        extra: []const Header,
        body: ?[]const u8,
        dest: std.Io.net.IpAddress,
        maxBytes: usize,
    ) !u64 {
        const a = self.allocator;
        if (self.responses.count() == 0) self.ioError = null;
        self.ep.conn.cbs = .{
            .ctx = self,
            .onStreamData = onQuicStream,
            .onStreamReset = onQuicReset,
        };

        const now0: u64 = @intCast(clockMod.monotonicMillis());
        try self.setupStreams(now0);
        _ = try self.ep.flush(dest);

        const sid = try self.h3.openRequestStream();
        errdefer self.discardResponse(sid);
        try self.responses.put(sid, .{
            .sid = sid,
            .maxBytes = @min(maxBytes, 64 * 1024 * 1024),
            .maxHeaderBytes = self.maxHeaderBytes,
        });

        var qextra = std.ArrayList(h3qpack.FieldLine).empty;
        defer qextra.deinit(a);
        for (extra) |h| try qextra.append(a, .{ .name = h.name, .value = h.value });
        var rs = self.h3.createRequestStream(sid);
        const head = try rs.buildRequestHeaders(method, scheme, authority, path, qextra.items);
        defer a.free(head);

        // Encoder-stream instructions referenced by this section must be
        // queued before (or concurrently with) the request HEADERS.
        try self.pumpQpack(now0);
        _ = try self.ep.flush(dest);

        const hasBody = body != null and body.?.len > 0;
        if (!hasBody) {
            try sendStream(self.ep.conn, sid, 0, head, true, now0);
            _ = try self.ep.flush(dest);
        } else {
            const dhead = try rs.buildData(body.?);
            defer a.free(dhead);

            var streamOff: u64 = 0;
            try sendStream(self.ep.conn, sid, streamOff, head, false, now0);
            streamOff += head.len;
            _ = try self.ep.flush(dest);

            // Chunk the H3 DATA frame across QUIC packets if large (MTU
            // friendly, <= 1200 bytes per chunk).
            var bodyCursor: usize = 0;
            const maxChunkSize: usize = 1200;
            while (bodyCursor < dhead.len) {
                const chunkEnd = @min(bodyCursor + maxChunkSize, dhead.len);
                const chunk = dhead[bodyCursor..chunkEnd];
                const isFinal = chunkEnd == dhead.len;
                try sendStream(self.ep.conn, sid, streamOff, chunk, isFinal, now0);
                streamOff += chunk.len;
                bodyCursor = chunkEnd;
                _ = try self.ep.flush(dest);
            }
        }
        return sid;
    }

    /// Waits for one started request and returns its response. On error the
    /// per-stream response state is discarded; other multiplexed requests
    /// remain collectible.
    pub fn waitResponse(
        self: *Client,
        sid: u64,
        pump: *quicEp.Pump,
        dest: std.Io.net.IpAddress,
        deadlineMs: u64,
    ) !H3Response {
        errdefer self.discardResponse(sid);
        const start: u64 = @intCast(clockMod.monotonicMillis());
        while (true) {
            if (self.h3.fatalError != null) return error.ProtocolViolation;
            if (self.ioError) |e| return e;
            const r = self.responses.getPtr(sid) orelse return error.ProtocolViolation;
            if (r.oom) return error.OutOfMemory;
            if (r.overflow) return error.ResponseTooLarge;
            if (r.failed) {
                if (r.resetCode) |_| {
                    self.h3.resetStream(self.ep.conn, sid, .requestCancelled, @intCast(clockMod.monotonicMillis())) catch {};
                }
                return error.ProtocolViolation;
            }
            if (r.done) break;

            const now: u64 = @intCast(clockMod.monotonicMillis());
            if (now -| start > deadlineMs) return error.Timeout;
            const remain = deadlineMs -| (now -| start);
            try quicHs.feedPumped(self.ep, pump, dest, @min(remain, 100), now);

            // Flush encoder instructions and decoder acknowledgments
            // produced by the bytes just fed, then put them on the wire.
            try self.pumpQpack(@intCast(clockMod.monotonicMillis()));
            _ = try self.ep.flush(dest);

            if (self.ep.conn.state == .closed or self.ep.conn.state == .draining) {
                return error.TruncatedResponse;
            }
        }
        return self.toResponse(sid);
    }

    /// Waits for several started requests. The returned slice and each
    /// response are caller-owned; free it with `freeResponses`.
    pub fn waitAll(
        self: *Client,
        sids: []const u64,
        pump: *quicEp.Pump,
        dest: std.Io.net.IpAddress,
        deadlineMs: u64,
    ) ![]H3Response {
        const out = try self.allocator.alloc(H3Response, sids.len);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |*r| r.deinit();
            self.allocator.free(out);
        }
        for (sids) |sid| {
            out[filled] = try self.waitResponse(sid, pump, dest, deadlineMs);
            filled += 1;
        }
        return out;
    }

    pub fn freeResponses(self: *Client, responses: []H3Response) void {
        for (responses) |*r| r.deinit();
        self.allocator.free(responses);
    }

    /// One request/response exchange over an already-started pump.
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
        const sid = try self.startRequest(method, scheme, authority, path, extra, body, dest, maxBytes);
        return self.waitResponse(sid, pump, dest, deadlineMs);
    }

    fn discardResponse(self: *Client, sid: u64) void {
        if (self.responses.fetchRemove(sid)) |kv| {
            var r = kv.value;
            r.deinit(self.allocator);
        }
    }

    fn toResponse(self: *Client, sid: u64) !H3Response {
        const r = self.responses.getPtr(sid) orelse return error.ProtocolViolation;
        if (r.status == 0) return error.TruncatedResponse;
        const a = self.allocator;
        const headers = try r.headers.toOwnedSlice(a);
        errdefer freeHeaders(a, headers);
        const trailers = try r.trailers.toOwnedSlice(a);
        errdefer freeHeaders(a, trailers);
        const body = try r.body.toOwnedSlice(a);
        const status = r.status;
        _ = self.responses.remove(sid);
        return .{
            .status = status,
            .headers = headers,
            .trailers = trailers,
            .body = body,
            .allocator = a,
        };
    }
};
test "http3 response collector rejects a chunk beyond its configured limit" {
    const a = std.testing.allocator;
    var endpoint: quicEp.Endpoint = undefined;
    var client = Client.init(a, &endpoint);
    defer client.deinit();
    try client.responses.put(0, .{ .sid = 0, .maxBytes = 3 });

    Client.onData(&client, 0, "data");

    const r = client.responses.getPtr(0).?;
    try std.testing.expect(r.overflow);
    try std.testing.expectEqual(@as(usize, 0), r.body.items.len);
}

test "http3 response collector caps header bytes and copies fields" {
    const a = std.testing.allocator;
    var endpoint: quicEp.Endpoint = undefined;
    var client = Client.init(a, &endpoint);
    defer client.deinit();
    try client.responses.put(0, .{ .sid = 0, .maxHeaderBytes = 8 });

    const fields = [_]h3qpack.FieldLine{
        .{ .name = ":status", .value = "200" },
        .{ .name = "x-a", .value = "1234" },
    };
    Client.onHeaders(&client, 0, &fields, false);
    const r = client.responses.getPtr(0).?;
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqual(@as(usize, 1), r.headers.items.len);
    try std.testing.expectEqualStrings("x-a", r.headers.items[0].name);
    try std.testing.expectEqualStrings("1234", r.headers.items[0].value);

    const more = [_]h3qpack.FieldLine{
        .{ .name = ":status", .value = "200" },
        .{ .name = "x-b", .value = "12345" },
    };
    Client.onHeaders(&client, 0, &more, false);
    try std.testing.expect(r.overflow);
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
