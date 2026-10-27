//! HTTP/3 client transport over live QUIC (RFC 9114).
//!
//! Runs request/response exchanges over an established QUIC connection.
//! All inbound stream bytes are routed through
//! `connection.Connection`, so control/QPACK streams, SETTINGS,
//! multi-section responses, trailers, and QPACK blocking are handled by
//! the same state machine the server uses.
//!
//! Scope (documented, not hidden):
//!   * The transport multiplexes requests with `startRequest`/`waitAll`;
//!     the high-level client still opens one QUIC connection per request
//!     (no H3 pooling yet).
//!   * Request bodies are sent as buffered DATA frames; streaming uploads are
//!     not provided by this one-shot client API.
//!   * A GOAWAY before opening a stream fails new requests. A GOAWAY that
//!     arrives after streams are open marks every exchange above its
//!     last-stream identifier as rejected; it is never retried on a new
//!     connection implicitly.
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
const transportTls = @import("../tls/tlsTransport.zig");
const tlsSession = @import("../tls/tlsSession.zig");
const bodySourceMod = @import("../../common/bodySource.zig");
const semanticsMod = @import("../http1/semantics.zig");
pub const BodySource = bodySourceMod.BodySource;
pub const SliceReader = bodySourceMod.SliceReader;
pub const CallbackReader = bodySourceMod.CallbackReader;

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

    pub fn wireCallbacks(self: *Client) void {
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
        self.ep.conn.cbs = .{
            .ctx = self,
            .onStreamData = onQuicStream,
            .onStreamReset = onQuicReset,
        };
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
        self.wireCallbacks();
        try self.h3.sendControl(self.ep.conn, nowMs);
        try self.h3.sendQpackPrefixes(self.ep.conn, nowMs);
        self.controlDone = true;
    }

    fn pumpQpack(self: *Client, nowMs: u64) !void {
        try self.h3.pumpQpack(self.ep.conn, nowMs);
    }

    fn sendStreamCheckedWithPump(
        self: *Client,
        sid: u64,
        offset: *u64,
        bytes: []const u8,
        fin: bool,
        pump: ?*quicEp.Pump,
        dest: std.Io.net.IpAddress,
        deadlineMs: u64,
    ) !void {
        const conn = self.ep.conn;
        const startMs: u64 = @intCast(clockMod.monotonicMillis(self.ep.io));

        if (bytes.len == 0) {
            while (true) {
                const nowMs: u64 = @intCast(clockMod.monotonicMillis(self.ep.io));
                if (nowMs -| startMs > deadlineMs) return error.Timeout;
                conn.sendStreamChecked(sid, offset.*, "", fin, nowMs) catch |e| switch (e) {
                    error.SendBlocked => {
                        _ = try self.ep.flush(dest);
                        if (pump) |p| {
                            try quicHs.feedPumped(self.ep, p, dest, 50, nowMs);
                            try self.pumpQpack(nowMs);
                        } else {
                            return error.SendBlocked;
                        }
                        continue;
                    },
                    else => return e,
                };
                _ = try self.ep.flush(dest);
                return;
            }
        }

        var cursor: usize = 0;
        while (cursor < bytes.len) {
            const nowMs: u64 = @intCast(clockMod.monotonicMillis(self.ep.io));
            if (nowMs -| startMs > deadlineMs) return error.Timeout;

            const streamLim = conn.maxStreamData.get(sid) orelse conn.initialSendWindowForStream(sid);
            const streamAvail = if (streamLim > offset.*) streamLim - offset.* else 0;
            const connAvail = if (conn.maxDataRemote > conn.dataSent) conn.maxDataRemote - conn.dataSent else 0;
            const ccLimit = conn.cc.bytesInFlightLimit();
            const ccAvail = if (ccLimit > conn.bytesInFlight + 128) ccLimit - (conn.bytesInFlight + 128) else 0;
            const credit = @min(streamAvail, @min(connAvail, ccAvail));

            if (credit == 0) {
                _ = try self.ep.flush(dest);
                if (pump) |p| {
                    try quicHs.feedPumped(self.ep, p, dest, 50, nowMs);
                    try self.pumpQpack(nowMs);
                    if (conn.state == .closed or conn.state == .draining) return error.ConnectionClosed;
                    continue;
                } else {
                    return error.SendBlocked;
                }
            }

            const toSend = @min(bytes.len - cursor, @min(credit, 1200));
            const chunk = bytes[cursor .. cursor + toSend];
            const isLastChunk = (cursor + toSend == bytes.len) and fin;

            conn.sendStreamChecked(sid, offset.*, chunk, isLastChunk, nowMs) catch |e| switch (e) {
                error.SendBlocked => {
                    _ = try self.ep.flush(dest);
                    if (pump) |p| {
                        try quicHs.feedPumped(self.ep, p, dest, 50, nowMs);
                        try self.pumpQpack(nowMs);
                        if (conn.state == .closed or conn.state == .draining) return error.ConnectionClosed;
                        continue;
                    } else {
                        return error.SendBlocked;
                    }
                },
                else => return e,
            };

            offset.* += toSend;
            cursor += toSend;
            _ = try self.ep.flush(dest);
        }
    }

    /// Starts one request/response exchange with streaming body upload support
    /// over live QUIC, respecting flow control, backpressure, Content-Length, and trailers.
    pub fn startRequestStreaming(
        self: *Client,
        method: []const u8,
        scheme: []const u8,
        authority: []const u8,
        path: []const u8,
        extra: []const Header,
        bodySource: ?BodySource,
        pump: ?*quicEp.Pump,
        dest: std.Io.net.IpAddress,
        deadlineMs: u64,
        maxBytes: usize,
    ) !u64 {
        const a = self.allocator;
        if (self.responses.count() == 0) self.ioError = null;

        if (std.mem.eql(u8, method, "CONNECT") and bodySource != null and (bodySource.?.contentLength == null or bodySource.?.contentLength.? != 0)) {
            return error.ProtocolViolation;
        }

        self.ep.conn.cbs = .{
            .ctx = self,
            .onStreamData = onQuicStream,
            .onStreamReset = onQuicReset,
        };

        const now0: u64 = @intCast(clockMod.monotonicMillis(self.ep.io));
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
        defer {
            for (qextra.items) |f| a.free(f.name);
            qextra.deinit(a);
        }

        const bodyLen: ?u64 = if (bodySource) |bs| bs.contentLength else null;
        for (extra) |h| {
            if (h.name.len == 0 or h.name[0] == ':') continue;
            if (std.ascii.eqlIgnoreCase(h.name, "connection") or
                std.ascii.eqlIgnoreCase(h.name, "keep-alive") or
                std.ascii.eqlIgnoreCase(h.name, "proxy-connection") or
                std.ascii.eqlIgnoreCase(h.name, "transfer-encoding") or
                std.ascii.eqlIgnoreCase(h.name, "upgrade"))
            {
                continue;
            }
            if (std.ascii.eqlIgnoreCase(h.name, "te") and
                !std.ascii.eqlIgnoreCase(h.value, "trailers"))
            {
                continue;
            }
            if (std.ascii.eqlIgnoreCase(h.name, "content-length")) {
                const declared = std.fmt.parseInt(u64, h.value, 10) catch return error.ProtocolViolation;
                if (bodyLen) |actual| {
                    if (declared != actual) return error.ProtocolViolation;
                } else if (declared != 0) {
                    return error.ProtocolViolation;
                }
                continue;
            }
            const lower = try std.ascii.allocLowerString(a, h.name);
            errdefer a.free(lower);
            try qextra.append(a, .{ .name = lower, .value = h.value });
        }
        if (bodyLen) |n| {
            var clBuf: [20]u8 = undefined;
            const cl = clBuf[0..std.fmt.printInt(&clBuf, n, 10, .lower, .{})];
            const name = try a.dupe(u8, "content-length");
            errdefer a.free(name);
            try qextra.append(a, .{ .name = name, .value = cl });
        }
        var rs = self.h3.createRequestStream(sid);
        if (std.mem.eql(u8, method, "HEAD")) self.h3.markRequestHead(sid);
        if (std.mem.eql(u8, method, "CONNECT")) self.h3.markRequestConnect(sid);
        const head = try rs.buildRequestHeaders(method, scheme, authority, path, qextra.items);
        defer a.free(head);

        try self.pumpQpack(now0);
        _ = try self.ep.flush(dest);

        var streamOff: u64 = 0;
        if (bodySource == null) {
            try self.sendStreamCheckedWithPump(sid, &streamOff, head, true, pump, dest, deadlineMs);
        } else {
            var bs = bodySource.?;
            const hasKnownZeroLen = bs.contentLength != null and bs.contentLength.? == 0;

            if (hasKnownZeroLen) {
                const rawTrailers = try bs.getTrailers(a);
                defer if (rawTrailers) |t| a.free(t);
                if (rawTrailers != null and rawTrailers.?.len > 0) {
                    try self.sendStreamCheckedWithPump(sid, &streamOff, head, false, pump, dest, deadlineMs);
                    var qtrailers = std.ArrayList(h3qpack.FieldLine).empty;
                    defer {
                        for (qtrailers.items) |f| a.free(f.name);
                        qtrailers.deinit(a);
                    }
                    for (rawTrailers.?) |th| {
                        if (!semanticsMod.trailerAllowed(th.name)) continue;
                        const lower = try a.alloc(u8, th.name.len);
                        for (th.name, 0..) |c, i| lower[i] = std.ascii.toLower(c);
                        try qtrailers.append(a, .{ .name = lower, .value = th.value });
                    }
                    if (qtrailers.items.len > 0) {
                        const thead = try rs.buildTrailers(qtrailers.items);
                        defer a.free(thead);
                        try self.pumpQpack(now0);
                        try self.sendStreamCheckedWithPump(sid, &streamOff, thead, true, pump, dest, deadlineMs);
                    } else {
                        try self.sendStreamCheckedWithPump(sid, &streamOff, head, true, pump, dest, deadlineMs);
                    }
                } else {
                    try self.sendStreamCheckedWithPump(sid, &streamOff, head, true, pump, dest, deadlineMs);
                }
            } else {
                try self.sendStreamCheckedWithPump(sid, &streamOff, head, false, pump, dest, deadlineMs);

                var readBuf: [16 * 1024]u8 = undefined;
                var totalProduced: u64 = 0;

                while (true) {
                    const nRead = bs.read(&readBuf) catch |e| return e;
                    if (nRead > 0) {
                        if (bs.contentLength) |expected| {
                            if (totalProduced + nRead > expected) {
                                return error.ProtocolViolation;
                            }
                        }
                        totalProduced += nRead;

                        var fh: [16]u8 = undefined;
                        const fhLen = try h3frame.encodeFrameHeader(&fh, @backingInt(h3frame.FrameType.data), nRead);
                        try self.sendStreamCheckedWithPump(sid, &streamOff, fh[0..fhLen], false, pump, dest, deadlineMs);
                        try self.sendStreamCheckedWithPump(sid, &streamOff, readBuf[0..nRead], false, pump, dest, deadlineMs);
                    } else {
                        if (bs.contentLength) |expected| {
                            if (totalProduced != expected) {
                                return error.ProtocolViolation;
                            }
                        }
                        const rawTrailers = try bs.getTrailers(a);
                        defer if (rawTrailers) |t| a.free(t);
                        if (rawTrailers != null and rawTrailers.?.len > 0) {
                            var qtrailers = std.ArrayList(h3qpack.FieldLine).empty;
                            defer {
                                for (qtrailers.items) |f| a.free(f.name);
                                qtrailers.deinit(a);
                            }
                            for (rawTrailers.?) |th| {
                                if (!semanticsMod.trailerAllowed(th.name)) continue;
                                const lower = try a.alloc(u8, th.name.len);
                                for (th.name, 0..) |c, i| lower[i] = std.ascii.toLower(c);
                                try qtrailers.append(a, .{ .name = lower, .value = th.value });
                            }
                            if (qtrailers.items.len > 0) {
                                const thead = try rs.buildTrailers(qtrailers.items);
                                defer a.free(thead);
                                try self.pumpQpack(now0);
                                try self.sendStreamCheckedWithPump(sid, &streamOff, thead, true, pump, dest, deadlineMs);
                            } else {
                                try self.sendStreamCheckedWithPump(sid, &streamOff, "", true, pump, dest, deadlineMs);
                            }
                        } else {
                            try self.sendStreamCheckedWithPump(sid, &streamOff, "", true, pump, dest, deadlineMs);
                        }
                        break;
                    }
                }
            }
        }
        return sid;
    }

    /// Starts one request/response exchange over an already-started pump and
    /// returns its QUIC stream ID. Supports in-memory or empty bodies.
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
        if (body) |b| {
            var sr = SliceReader.init(b);
            return self.startRequestStreaming(method, scheme, authority, path, extra, sr.source(), null, dest, 30_000, maxBytes);
        } else {
            return self.startRequestStreaming(method, scheme, authority, path, extra, null, null, dest, 30_000, maxBytes);
        }
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
        const start: u64 = @intCast(clockMod.monotonicMillis(self.ep.io));
        while (true) {
            if (self.h3.fatalError != null) return error.ProtocolViolation;
            if (self.ioError) |e| return e;
            const r = self.responses.getPtr(sid) orelse return error.ProtocolViolation;
            if (r.oom) return error.OutOfMemory;
            if (r.overflow) return error.ResponseTooLarge;
            if (r.failed) {
                if (r.resetCode) |_| {
                    const resetNow: u64 = @intCast(clockMod.monotonicMillis(self.ep.io));
                    self.h3.resetStream(self.ep.conn, sid, .requestCancelled, resetNow) catch {};
                    // Cancellation feedback must be sent promptly after the
                    // local reset so the peer can release QPACK references.
                    self.h3.pumpQpack(self.ep.conn, resetNow) catch {};
                    _ = self.ep.flush(dest) catch {};
                }
                return error.ProtocolViolation;
            }
            if (r.done) break;

            const now: u64 = @intCast(clockMod.monotonicMillis(self.ep.io));
            if (now -| start > deadlineMs) return error.Timeout;
            const remain = deadlineMs -| (now -| start);
            try quicHs.feedPumped(self.ep, pump, dest, @min(remain, 100), now);

            // Flush encoder instructions and decoder acknowledgments
            // produced by the bytes just fed, then put them on the wire.
            try self.pumpQpack(@intCast(clockMod.monotonicMillis(self.ep.io)));
            _ = try self.ep.flush(dest);

            if (self.ep.conn.state == .closed or self.ep.conn.state == .draining) {
                return error.TruncatedResponse;
            }
        }
        // A response can complete inside a feed that already happened
        // before this call; drain any decoder acknowledgments it staged
        // before releasing the request stream state.
        try self.pumpQpack(@intCast(clockMod.monotonicMillis(self.ep.io)));
        _ = try self.ep.flush(dest);
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
        if (body) |b| {
            var sr = SliceReader.init(b);
            return self.requestStreaming(method, scheme, authority, path, extra, sr.source(), pump, dest, deadlineMs, maxBytes);
        } else {
            return self.requestStreaming(method, scheme, authority, path, extra, null, pump, dest, deadlineMs, maxBytes);
        }
    }

    /// One streaming request/response exchange over an already-started pump.
    pub fn requestStreaming(
        self: *Client,
        method: []const u8,
        scheme: []const u8,
        authority: []const u8,
        path: []const u8,
        extra: []const Header,
        bodySource: ?BodySource,
        pump: *quicEp.Pump,
        dest: std.Io.net.IpAddress,
        deadlineMs: u64,
        maxBytes: usize,
    ) !H3Response {
        const sid = try self.startRequestStreaming(
            method,
            scheme,
            authority,
            path,
            extra,
            bodySource,
            pump,
            dest,
            deadlineMs,
            maxBytes,
        );
        return self.waitResponse(sid, pump, dest, deadlineMs);
    }

    fn discardResponse(self: *Client, sid: u64) void {
        if (self.responses.fetchRemove(sid)) |kv| {
            var r = kv.value;
            r.deinit(self.allocator);
        }
        self.h3.discardRequestStream(sid);
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
        self.h3.discardRequestStream(sid);
        return .{
            .status = status,
            .headers = headers,
            .trailers = trailers,
            .body = body,
            .allocator = a,
        };
    }
};

var nextPooledConnId: std.atomic.Value(usize) = .init(1);

/// A long-lived, reusable HTTP/3 connection managed by the client connection pool.
/// Holds the underlying QUIC connection, TLS handshake driver, background datagram pump,
/// and HTTP/3 client protocol state.
pub const PooledConn = struct {
    allocator: Allocator,
    io: std.Io,
    conn: *quicConn.Connection,
    ep: quicEp.Endpoint,
    driver: *quicHs.Driver,
    pump: quicEp.Pump,
    client: *Client,
    dest: std.Io.net.IpAddress,
    createdAtMs: i64,
    id: usize,
    handshakeCount: u32 = 1,

    pub const ConnectOptions = struct {
        verify: transportTls.VerifyMode = .caBundle,
        caPem: ?[]const u8 = null,
        session: ?*const tlsSession.ClientSession = null,
        earlyData: bool = false,
        sessionOut: ?*tlsSession.ClientSession = null,
        timeoutMs: u64 = 30_000,
    };

    pub fn connect(
        allocator: Allocator,
        io: std.Io,
        host: []const u8,
        port: u16,
        dest: std.Io.net.IpAddress,
        opts: ConnectOptions,
    ) !*PooledConn {
        _ = port;
        const self = try allocator.create(PooledConn);
        errdefer allocator.destroy(self);

        const conn = try quicConn.Connection.init(allocator, io, .client, .{});
        errdefer conn.deinit();

        const ep = try quicEp.Endpoint.init(allocator, io, conn, .{});

        const driver = try allocator.create(quicHs.Driver);
        errdefer allocator.destroy(driver);
        driver.* = quicHs.Driver.initClient(io, allocator, .{
            .host = host,
            .verify = opts.verify,
            .caPem = opts.caPem,
            .session = opts.session,
            .earlyData = opts.earlyData,
            .sessionOut = opts.sessionOut,
        });
        errdefer driver.deinit();

        conn.tls = .{
            .ctx = driver,
            .start = quicHs.Driver.clientStart,
            .onData = quicHs.Driver.onData,
        };

        const client = try allocator.create(Client);
        errdefer allocator.destroy(client);

        const now = clockMod.monotonicMillis(io);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .conn = conn,
            .ep = ep,
            .driver = driver,
            .pump = .{},
            .client = client,
            .dest = dest,
            .createdAtMs = now,
            .id = nextPooledConnId.fetchAdd(1, .monotonic),
            .handshakeCount = 1,
        };
        errdefer self.ep.deinit();

        self.client.* = Client.init(allocator, &self.ep);
        errdefer self.client.deinit();

        self.client.wireCallbacks();

        try self.pump.start(&self.ep, allocator);
        errdefer self.pump.stop();

        quicHs.performHandshake(&self.ep, &self.pump, self.driver, null, null, null, dest, opts.timeoutMs) catch |e| {
            return mapHandshakeError(e, self.driver.detail);
        };

        const now0: u64 = @intCast(clockMod.monotonicMillis(io));
        try self.client.setupStreams(now0);
        _ = try self.ep.flush(dest);

        return self;
    }

    pub fn deinit(self: *PooledConn) void {
        self.pump.stop();
        self.client.deinit();
        self.allocator.destroy(self.client);
        self.ep.deinit();
        self.driver.deinit();
        self.allocator.destroy(self.driver);
        self.conn.deinit();
        self.allocator.destroy(self);
    }

    pub fn isReusable(self: *PooledConn) bool {
        // Drain any incoming datagrams with zero timeout to catch peer CONNECTION_CLOSE
        const nowMs: u64 = @intCast(clockMod.monotonicMillis(self.io));
        while (true) {
            const rx = self.pump.next(0) catch break;
            if (rx) |d| {
                defer self.pump.allocator.free(d.data);
                self.ep.peer = d.from;
                self.conn.receiveDatagram(d.data, nowMs) catch {};
            } else break;
        }

        if (self.conn.state == .closed or self.conn.state == .closing or self.conn.state == .draining) return false;
        if (self.client.h3.fatalError != null) return false;
        if (self.client.h3.goawayReceived or self.client.h3.goawaySent) return false;
        if (self.client.ioError != null) return false;
        if (self.conn.maxStreamsBidiRemote > 0 and (self.client.h3.nextBidiId / 4) >= self.conn.maxStreamsBidiRemote) return false;
        return true;
    }

    pub fn request(
        self: *PooledConn,
        method: []const u8,
        scheme: []const u8,
        authority: []const u8,
        path: []const u8,
        extra: []const Header,
        body: ?[]const u8,
        deadlineMs: u64,
        maxBytes: usize,
    ) !H3Response {
        return self.client.request(
            method,
            scheme,
            authority,
            path,
            extra,
            body,
            &self.pump,
            self.dest,
            deadlineMs,
            maxBytes,
        );
    }

    pub fn requestStreaming(
        self: *PooledConn,
        method: []const u8,
        scheme: []const u8,
        authority: []const u8,
        path: []const u8,
        extra: []const Header,
        bodySource: ?BodySource,
        deadlineMs: u64,
        maxBytes: usize,
    ) !H3Response {
        return self.client.requestStreaming(
            method,
            scheme,
            authority,
            path,
            extra,
            bodySource,
            &self.pump,
            self.dest,
            deadlineMs,
            maxBytes,
        );
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

/// Maps QUIC/driver failures onto the H3 error set, preserving the
/// driver's precise cause (ALPN vs certificate vs generic).
pub fn mapHandshakeError(err: anyerror, detail: quicHs.Detail) Error {
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
