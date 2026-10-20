//! HTTP/3 stream layer (RFC 9114 Sections 6-8).
//!
//! Per-stream receive reassembly, unidirectional stream dispatch, and the
//! request/response HTTP state machines: frame ordering, trailers,
//! pseudo-header validation, content-length accounting, and QPACK section
//! handling (blocked sections park and retry after encoder data arrives).
//!
//! Parsing lives here; policy state (settings, GOAWAY monotonicity,
//! duplicate critical streams, stream maps) lives in the connection
//! layer, which feeds QUIC bytes in and drains `(Section Ack)` bytes out.
//! Protocol violations surface as `onError` carrying the H3 wire error
//! code; the connection layer maps them to QUIC resets and closes.
//!
//! References:
//!   - RFC 9114 Section 6 — HTTP/3 streams (control, QPACK, push)
//!   - RFC 9114 Section 7 — HTTP/3 frames and stream-type legality
//!   - RFC 9114 Section 8 — HTTP/3 error codes
//!   - RFC 9114 Section 4 — HTTP message exchanges and trailers
//!   - RFC 9204 Section 4.5 — QPACK field sections

const std = @import("std");
const Allocator = std.mem.Allocator;
const frameMod = @import("frame.zig");
const qpackMod = @import("qpack.zig");
const quicVarint = @import("../quic/varint.zig");

pub const H3Error = frameMod.H3Error;
pub const FieldLine = qpackMod.FieldLine;

pub const Role = enum { client, server };

/// Which half of the exchange this stream receives.
pub const StreamMode = enum {
    /// Server side: the peer sends a request.
    requestRecv,
    /// Client side: the peer sends a response.
    responseRecv,
    /// Unidirectional stream; the type varint is parsed from the stream.
    uni,
};

/// HTTP message phase on a request/response stream.
pub const HttpState = enum {
    needHeaders,
    headers,
    data,
    trailers,
    done,
};

/// Unidirectional stream kind once the type varint is parsed.
pub const UniKind = enum {
    undecided,
    control,
    qpackEncoder,
    qpackDecoder,
    push,
    unknown,
};

pub const Callbacks = struct {
    ctx: ?*anyopaque = null,
    onHeaders: ?*const fn (ctx: ?*anyopaque, sid: u64, fields: []const FieldLine, interim: bool) void = null,
    onData: ?*const fn (ctx: ?*anyopaque, sid: u64, data: []const u8) void = null,
    onTrailers: ?*const fn (ctx: ?*anyopaque, sid: u64, fields: []const FieldLine) void = null,
    onMessageEnd: ?*const fn (ctx: ?*anyopaque, sid: u64) void = null,
    /// A complete control-stream frame ready for connection state.
    onControlFrame: ?*const fn (ctx: ?*anyopaque, sid: u64, frameType: u64, payload: []const u8) void = null,
    /// Fired once the unidirectional type varint parses, before any
    /// other processing, so the connection layer can reject duplicate
    /// critical streams via `failExtern`.
    onUniType: ?*const fn (ctx: ?*anyopaque, sid: u64, streamType: u64) void = null,
    onReset: ?*const fn (ctx: ?*anyopaque, sid: u64, code: u64) void = null,
    onError: ?*const fn (ctx: ?*anyopaque, sid: u64, code: H3Error) void = null,
};

pub const Error = error{
    StreamClosed,
    OutOfMemory,
};

/// Validates that the peer may open `sid`: HTTP/3 servers never initiate
/// bidirectional streams, and unidirectional streams must be
/// peer-initiated. Returns the connection error on misuse, null when ok.
pub fn checkPeerStreamId(ourRole: Role, sid: u64) ?H3Error {
    const bidi = (sid & 0x02) == 0;
    const clientInit = (sid & 0x01) == 0;
    if (bidi) {
        // Only clients initiate request streams.
        if (ourRole == .client) return .streamCreationError;
        if (!clientInit) return .streamCreationError;
        return null;
    }
    // Unidirectional: the peer must own the stream.
    if (ourRole == .client and clientInit) return .streamCreationError;
    if (ourRole == .server and !clientInit) return .streamCreationError;
    return null;
}

/// Parses a unidirectional stream type varint. Returns
/// `error.Truncated` when more bytes are needed.
pub fn parseUniType(data: []const u8) frameMod.Error!struct { streamType: u64, len: usize } {
    var off: usize = 0;
    const t = quicVarint.decode(data, &off) catch |e| switch (e) {
        error.Truncated => return frameMod.Error.Truncated,
        else => return frameMod.Error.InvalidFrame,
    };
    return .{ .streamType = t, .len = off };
}

/// Finds the first field with `name`, or null.
pub fn findField(fields: []const FieldLine, name: []const u8) ?[]const u8 {
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.value;
    }
    return null;
}

pub const Stream = struct {
    allocator: Allocator,
    id: u64,
    mode: StreamMode,
    role: Role,
    cbs: Callbacks,
    qdec: *qpackMod.Decoder,
    qenc: *qpackMod.Encoder,

    buf: std.ArrayList(u8) = .empty,
    /// Parse cursor: bytes before it are delivered or skipped.
    off: usize = 0,
    /// QUIC stream FIN observed.
    fin: bool = false,
    failed: bool = false,
    done: bool = false,

    uniKind: UniKind = .undecided,
    httpState: HttpState = .needHeaders,
    /// A QPACK section parked on `error.Blocked`; retried when encoder
    /// data arrives or more stream bytes feed in.
    blocked: bool = false,
    /// SETTINGS seen on this control stream (SETTINGS-first rule).
    controlSawSettings: bool = false,
    /// Extended-CONNECT allowed by peer settings (connection sets this).
    connectAllowed: bool = false,
    /// Decoder-stream acknowledgments staged by dynamic decodes; the
    /// connection layer drains these onto the decoder stream.
    decoderAck: std.ArrayList(u8) = .empty,
    /// Bytes of unknown unidirectional type skipped (visibility for
    /// future excessive-load accounting).
    unknownSkipped: u64 = 0,

    // HTTP message validation state.
    contentLength: ?u64 = null,
    bodyReceived: u64 = 0,

    pub fn init(
        allocator: Allocator,
        id: u64,
        mode: StreamMode,
        role: Role,
        cbs: Callbacks,
        qdec: *qpackMod.Decoder,
        qenc: *qpackMod.Encoder,
    ) Stream {
        return .{
            .allocator = allocator,
            .id = id,
            .mode = mode,
            .role = role,
            .cbs = cbs,
            .qdec = qdec,
            .qenc = qenc,
        };
    }

    pub fn deinit(self: *Stream) void {
        self.buf.deinit(self.allocator);
        self.decoderAck.deinit(self.allocator);
    }

    /// Takes staged decoder-stream acknowledgment bytes; caller sends
    /// them on the decoder stream, then frees the slice (always owned,
    /// even when empty).
    pub fn takeDecoderAck(self: *Stream) ![]u8 {
        if (self.decoderAck.items.len == 0) return try self.allocator.dupe(u8, &.{});
        return try self.decoderAck.toOwnedSlice(self.allocator);
    }

    /// The parsed unidirectional kind, or null while undecided (type
    /// varint incomplete). The connection layer uses this to track
    /// duplicate critical streams.
    pub fn uniKindKnown(self: *const Stream) ?UniKind {
        if (self.mode != .uni or self.uniKind == .undecided) return null;
        return self.uniKind;
    }

    /// Forces the stream into the failed state from the outside (e.g.
    /// duplicate critical stream detected by the connection layer).
    pub fn failExtern(self: *Stream, code: H3Error) void {
        self.fail(code);
    }

    /// Signals a QUIC-level reset received for this stream.
    pub fn onQuicReset(self: *Stream, code: u64) void {
        if (self.failed or self.done) return;
        self.failed = true;
        if (self.cbs.onReset) |cb| cb(self.cbs.ctx, self.id, code);
    }

    /// Feeds received stream bytes (`fin` = QUIC FIN observed).
    pub fn feed(self: *Stream, data: []const u8, fin: bool) void {
        if (self.failed or self.done) return;
        self.buf.appendSlice(self.allocator, data) catch {
            self.fail(.internalError);
            return;
        };
        if (fin) self.fin = true;
        self.parse();
        self.compactConsumed();
        if (self.done or self.failed) {
            self.buf.deinit(self.allocator);
            self.buf = .empty;
            self.off = 0;
        }
    }

    /// Drop bytes already parsed so a long lived request stream does not
    /// retain its full history after each feed.
    fn compactConsumed(self: *Stream) void {
        if (self.off == 0) return;
        const remaining = self.buf.items.len - self.off;
        if (remaining > 0) std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[self.off..]);
        self.buf.items.len = remaining;
        self.off = 0;
    }

    /// Retries a section parked on `error.Blocked` after encoder-stream
    /// bytes arrived. No-op unless blocked.
    pub fn retryBlocked(self: *Stream) void {
        if (!self.blocked or self.failed or self.done) return;
        self.blocked = false;
        self.parse();
    }

    fn fail(self: *Stream, code: H3Error) void {
        if (self.failed or self.done) return;
        self.failed = true;
        if (self.cbs.onError) |cb| cb(self.cbs.ctx, self.id, code);
    }

    fn finishMessage(self: *Stream) void {
        self.done = true;
        if (self.cbs.onMessageEnd) |cb| cb(self.cbs.ctx, self.id);
    }

    fn parse(self: *Stream) void {
        if (self.failed or self.done) return;
        if (self.mode == .uni) {
            self.parseUni();
            return;
        }
        self.parseBidi();
    }

    fn parseUni(self: *Stream) void {
        if (self.uniKind == .undecided) {
            const avail = self.buf.items[self.off..];
            const t = parseUniType(avail) catch |e| switch (e) {
                error.Truncated => {
                    if (self.fin) self.fail(.frameError);
                    return;
                },
                else => {
                    self.fail(.frameError);
                    return;
                },
            };
            self.off += t.len;
            if (self.cbs.onUniType) |cb| cb(self.cbs.ctx, self.id, t.streamType);
            if (self.failed) return; // connection rejected (duplicates)
            self.uniKind = switch (t.streamType) {
                0x00 => .control,
                0x02 => .qpackEncoder,
                0x03 => .qpackDecoder,
                0x01 => {
                    // No-push policy: push streams are rejected.
                    self.fail(.frameUnexpected);
                    return;
                },
                else => .unknown,
            };
        }
        switch (self.uniKind) {
            .undecided => unreachable,
            .control => self.parseControl(),
            .qpackEncoder => self.parseQpackEncoder(),
            .qpackDecoder => self.parseQpackDecoder(),
            .push => unreachable, // failed at type parse
            .unknown => {
                // Unknown unidirectional types: consume and ignore.
                self.unknownSkipped +|= self.buf.items.len - self.off;
                self.off = self.buf.items.len;
                if (self.fin) self.done = true;
            },
        }
    }

    fn parseControl(self: *Stream) void {
        while (self.off < self.buf.items.len) {
            const start = self.off;
            const header = frameMod.parseFrameHeader(self.buf.items, &self.off) catch |e| switch (e) {
                error.Truncated => {
                    self.off = start;
                    if (self.fin) self.fail(.frameError);
                    return;
                },
                else => {
                    self.fail(.frameError);
                    return;
                },
            };
            const n = std.math.cast(usize, header.length) orelse {
                self.fail(.frameError);
                return;
            };
            if (self.buf.items.len - self.off < n) {
                self.off = start;
                if (self.fin) self.fail(.frameError);
                return;
            }
            const payload = self.buf.items[self.off..][0..n];
            self.off += n;
            if (frameMod.checkFrameAllowed(.control, header.frameType)) |code| {
                self.fail(code);
                return;
            }
            if (header.frameType == 0x4 and self.controlSawSettings) {
                // Second SETTINGS: connection state rejects it; flag here
                // so the error surfaces even without the connection layer.
                self.fail(.settingsError);
                return;
            }
            if (header.frameType == 0x4) self.controlSawSettings = true;
            if (!self.controlSawSettings) {
                self.fail(.missingSettings);
                return;
            }
            if (self.cbs.onControlFrame) |cb| cb(self.cbs.ctx, self.id, header.frameType, payload);
            if (self.failed) return; // connection rejected synchronously
        }
        if (self.fin) {
            // A control stream never ends cleanly; FIN is abrupt.
            self.fail(.closedCriticalStream);
        }
    }

    fn parseQpackEncoder(self: *Stream) void {
        const avail = self.buf.items[self.off..];
        if (avail.len == 0) {
            if (self.fin) self.done = true;
            return;
        }
        self.qdec.readEncoderStream(avail, self.fin) catch {
            self.fail(.qpackEncoderStreamError);
            return;
        };
        // readEncoderStream buffers internally; everything fed is consumed.
        self.off = self.buf.items.len;
        if (self.fin) self.done = true;
    }

    fn parseQpackDecoder(self: *Stream) void {
        const avail = self.buf.items[self.off..];
        if (avail.len == 0) {
            if (self.fin) self.done = true;
            return;
        }
        self.qenc.readDecoderStream(avail, self.fin) catch {
            self.fail(.qpackDecoderStreamError);
            return;
        };
        self.off = self.buf.items.len;
        if (self.fin) self.done = true;
    }

    fn parseBidi(self: *Stream) void {
        while (self.off < self.buf.items.len) {
            const start = self.off;
            const header = frameMod.parseFrameHeader(self.buf.items, &self.off) catch |e| switch (e) {
                error.Truncated => {
                    self.off = start;
                    if (self.fin) self.fail(.frameError);
                    return;
                },
                else => {
                    self.fail(.frameError);
                    return;
                },
            };
            const n = std.math.cast(usize, header.length) orelse {
                self.fail(.frameError);
                return;
            };
            if (self.buf.items.len - self.off < n) {
                self.off = start;
                if (self.fin) self.fail(.frameError);
                return;
            }
            const payload = self.buf.items[self.off..][0..n];
            self.off += n;
            if (frameMod.checkFrameAllowed(.requestBidi, header.frameType)) |code| {
                self.fail(code);
                return;
            }
            self.dispatchBidiFrame(header.frameType, payload);
            if (self.blocked) {
                // Parked on a QPACK-blocked section: rewind so the
                // section bytes are retried, then stop until unblocked.
                self.off = start;
                return;
            }
            if (self.failed or self.done) return;
        }
        if (self.fin) self.endOfStream();
    }

    fn dispatchBidiFrame(self: *Stream, frameType: u64, payload: []const u8) void {
        switch (frameType) {
            0x1 => self.onHeadersFrame(payload),
            0x0 => self.onDataFrame(payload),
            else => {}, // unknown: length-skipped above
        }
    }

    fn onHeadersFrame(self: *Stream, payload: []const u8) void {
        const fields = self.qdec.decodeSectionCounted(payload, self.id, &self.decoderAck) catch |e| switch (e) {
            error.Blocked => {
                // Park: the section bytes stay at the cursor; the
                // connection layer retries after encoder data arrives.
                self.blocked = true;
                return;
            },
            else => {
                // 0x200: QPACK decompression failure on a request stream.
                self.fail(.qpackGeneralError);
                return;
            },
        };
        defer self.qdec.freeFields(fields);
        self.blocked = false;

        if (self.httpState == .needHeaders) {
            if (self.mode == .requestRecv) {
                if (self.validateRequest(fields)) |code| {
                    self.fail(code);
                    return;
                }
                self.httpState = .headers;
                if (self.cbs.onHeaders) |cb| cb(self.cbs.ctx, self.id, fields, false);
            } else {
                // 1xx sections keep the stream in needHeaders (a DATA
                // frame before the final HEADERS is malformed); the
                // final HEADERS moves to .headers via the same path.
                const interim = isInterimStatus(fields);
                if (self.validateResponse(fields, interim)) |code| {
                    self.fail(code);
                    return;
                }
                if (!interim) self.httpState = .headers;
                if (self.cbs.onHeaders) |cb| cb(self.cbs.ctx, self.id, fields, interim);
            }
            return;
        }
        if (self.httpState == .headers or self.httpState == .data) {
            // Second HEADERS section: trailers (legal with or without a
            // DATA frame in between).
            if (self.validateTrailers(fields)) |code| {
                self.fail(code);
                return;
            }
            self.httpState = .trailers;
            if (self.cbs.onTrailers) |cb| cb(self.cbs.ctx, self.id, fields);
            return;
        }
        // HEADERS in data/trailers/done state.
        self.fail(.messageError);
    }

    fn onDataFrame(self: *Stream, payload: []const u8) void {
        if (self.httpState != .headers and self.httpState != .data) {
            self.fail(.messageError);
            return;
        }
        self.httpState = .data;
        if (self.contentLength) |expected| {
            self.bodyReceived +|= payload.len;
            if (self.bodyReceived > expected) {
                self.fail(.messageError);
                return;
            }
        } else {
            self.bodyReceived +|= payload.len;
        }
        if (self.cbs.onData) |cb| cb(self.cbs.ctx, self.id, payload);
    }

    fn endOfStream(self: *Stream) void {
        // Stream FIN with a partial frame already failed above; an empty
        // stream (or FIN before any HEADERS) is malformed messaging.
        if (self.httpState == .needHeaders) {
            self.fail(.messageError);
            return;
        }
        if (self.contentLength) |expected| {
            if (self.bodyReceived != expected) {
                self.fail(.messageError);
                return;
            }
        }
        self.finishMessage();
    }

    /// True when the fields carry a 1xx informational status.
    fn isInterimStatus(fields: []const FieldLine) bool {
        const status = findField(fields, ":status") orelse return false;
        if (status.len != 3 or status[0] != '1') return false;
        for (status[1..]) |c| {
            if (c < '0' or c > '9') return false;
        }
        return true;
    }

    /// Validates request HEADERS; null when valid, else the H3 error.
    fn validateRequest(self: *Stream, fields: []const FieldLine) ?H3Error {
        var seenRegular = false;
        var method: ?[]const u8 = null;
        var scheme: ?[]const u8 = null;
        var authority: ?[]const u8 = null;
        var path: ?[]const u8 = null;
        var protocol: ?[]const u8 = null;
        var host: ?[]const u8 = null;
        for (fields) |f| {
            if (f.name.len == 0) return .messageError;
            for (f.name) |c| {
                if (c >= 'A' and c <= 'Z') return .messageError;
            }
            if (f.name[0] == ':') {
                if (seenRegular) return .messageError;
                if (std.mem.eql(u8, f.name, ":method")) {
                    if (method != null or f.value.len == 0) return .messageError;
                    for (f.value) |c| {
                        if (c <= ' ' or c == 0x7F) return .messageError;
                    }
                    method = f.value;
                } else if (std.mem.eql(u8, f.name, ":scheme")) {
                    if (scheme != null) return .messageError;
                    scheme = f.value;
                } else if (std.mem.eql(u8, f.name, ":authority")) {
                    if (authority != null or f.value.len == 0) return .messageError;
                    authority = f.value;
                } else if (std.mem.eql(u8, f.name, ":path")) {
                    if (path != null or f.value.len == 0) return .messageError;
                    path = f.value;
                } else if (std.mem.eql(u8, f.name, ":protocol")) {
                    if (protocol != null) return .messageError;
                    protocol = f.value;
                } else {
                    return .messageError; // unknown pseudo-header
                }
            } else {
                seenRegular = true;
                if (std.mem.eql(u8, f.name, "host")) {
                    if (host != null) return .messageError;
                    host = f.value;
                }
                if (self.checkRegularHeader(f.name, f.value)) |code| return code;
            }
        }
        const m = method orelse return .messageError;
        const isConnect = std.mem.eql(u8, m, "CONNECT");
        if (isConnect) {
            // CONNECT omits :scheme/:path and requires :authority.
            if (scheme != null or path != null) return .messageError;
            if (authority == null) return .messageError;
            if (protocol != null and !self.connectAllowed) return .messageError;
        } else {
            if (scheme == null or path == null) return .messageError;
            if (authority == null and host == null) return .messageError;
            if (protocol != null) return .messageError;
            const p = path.?;
            if (p.len == 0) return .messageError;
            if (p[0] != '/' and !(p.len == 1 and p[0] == '*')) return .messageError;
            if (p[0] == '*' and !std.mem.eql(u8, m, "OPTIONS")) return .messageError;
        }
        if (self.captureContentLength(fields)) |code| return code;
        return null;
    }

    fn validateResponse(self: *Stream, fields: []const FieldLine, interim: bool) ?H3Error {
        var seenRegular = false;
        var status: ?[]const u8 = null;
        for (fields) |f| {
            if (f.name.len == 0) return .messageError;
            for (f.name) |c| {
                if (c >= 'A' and c <= 'Z') return .messageError;
            }
            if (f.name[0] == ':') {
                if (seenRegular) return .messageError;
                if (std.mem.eql(u8, f.name, ":status")) {
                    if (status != null) return .messageError;
                    if (f.value.len != 3) return .messageError;
                    for (f.value) |c| {
                        if (c < '0' or c > '9') return .messageError;
                    }
                    const code = (f.value[0] - '0') * 100 + (f.value[1] - '0') * 10 + (f.value[2] - '0');
                    if (code < 100 or code > 999) return .messageError;
                    const is1xx = f.value[0] == '1';
                    if (interim != is1xx) return .messageError;
                    status = f.value;
                } else {
                    return .messageError; // unknown pseudo-header
                }
            } else {
                seenRegular = true;
                if (self.checkRegularHeader(f.name, f.value)) |code| return code;
            }
        }
        if (status == null) return .messageError;
        if (!interim) {
            if (self.captureContentLength(fields)) |code| return code;
        }
        return null;
    }

    fn validateTrailers(self: *Stream, fields: []const FieldLine) ?H3Error {
        for (fields) |f| {
            if (f.name.len == 0) return .messageError;
            if (f.name[0] == ':') return .messageError; // no pseudos in trailers
            for (f.name) |c| {
                if (c >= 'A' and c <= 'Z') return .messageError;
            }
            if (self.checkRegularHeader(f.name, f.value)) |code| return code;
        }
        return null;
    }

    fn checkRegularHeader(_: *Stream, name: []const u8, value: []const u8) ?H3Error {
        if (std.mem.eql(u8, name, "connection") or
            std.mem.eql(u8, name, "keep-alive") or
            std.mem.eql(u8, name, "proxy-connection") or
            std.mem.eql(u8, name, "transfer-encoding") or
            std.mem.eql(u8, name, "upgrade"))
        {
            return .messageError;
        }
        if (std.mem.eql(u8, name, "te") and !std.mem.eql(u8, value, "trailers")) {
            return .messageError;
        }
        return null;
    }

    fn captureContentLength(self: *Stream, fields: []const FieldLine) ?H3Error {
        var seen: ?[]const u8 = null;
        for (fields) |f| {
            if (!std.mem.eql(u8, f.name, "content-length")) continue;
            if (f.value.len == 0) return .messageError;
            for (f.value) |c| {
                if (c < '0' or c > '9') return .messageError;
            }
            if (seen) |prev| {
                if (!std.mem.eql(u8, prev, f.value)) return .messageError;
                continue;
            }
            seen = f.value;
        }
        if (seen) |v| {
            self.contentLength = std.fmt.parseInt(u64, v, 10) catch return .messageError;
        }
        return null;
    }
};

test "HTTP/3 stream releases consumed bytes after incremental feed" {
    const a = std.testing.allocator;
    var qdec = qpackMod.Decoder.init(a);
    defer qdec.deinit();
    var qenc = qpackMod.Encoder.init(a);
    defer qenc.deinit();
    var stream = Stream.init(a, 3, .uni, .client, .{}, &qdec, &qenc);
    defer stream.deinit();

    stream.feed(&.{ 0x21, 'a', 'b', 'c' }, false);
    try std.testing.expectEqual(@as(usize, 0), stream.buf.items.len);
    try std.testing.expectEqual(@as(usize, 0), stream.off);
    try std.testing.expectEqual(@as(u64, 3), stream.unknownSkipped);
}

// Tests

const TestRec = struct {
    headers: usize = 0,
    interim: usize = 0,
    dataBytes: usize = 0,
    trailers: usize = 0,
    ends: usize = 0,
    controlFrames: usize = 0,
    lastControlType: u64 = 0,
    uniTypes: usize = 0,
    lastUniType: u64 = 0,
    lastErr: ?H3Error = null,
    sawGet: bool = false,

    fn cbs(self: *TestRec) Callbacks {
        return .{
            .ctx = self,
            .onHeaders = onH,
            .onData = onD,
            .onTrailers = onT,
            .onMessageEnd = onE,
            .onControlFrame = onC,
            .onUniType = onU,
            .onError = onErr,
        };
    }
    fn onH(ctx: ?*anyopaque, sid: u64, fields: []const FieldLine, interim: bool) void {
        _ = sid;
        const r: *TestRec = @ptrCast(@alignCast(ctx.?));
        r.headers += 1;
        if (interim) r.interim += 1;
        if (findField(fields, ":method")) |m| {
            if (std.mem.eql(u8, m, "GET")) r.sawGet = true;
        }
    }
    fn onD(ctx: ?*anyopaque, sid: u64, data: []const u8) void {
        _ = sid;
        const r: *TestRec = @ptrCast(@alignCast(ctx.?));
        r.dataBytes += data.len;
    }
    fn onT(ctx: ?*anyopaque, sid: u64, fields: []const FieldLine) void {
        _ = sid;
        _ = fields;
        const r: *TestRec = @ptrCast(@alignCast(ctx.?));
        r.trailers += 1;
    }
    fn onE(ctx: ?*anyopaque, sid: u64) void {
        _ = sid;
        const r: *TestRec = @ptrCast(@alignCast(ctx.?));
        r.ends += 1;
    }
    fn onC(ctx: ?*anyopaque, sid: u64, frameType: u64, payload: []const u8) void {
        _ = sid;
        _ = payload;
        const r: *TestRec = @ptrCast(@alignCast(ctx.?));
        r.controlFrames += 1;
        r.lastControlType = frameType;
    }
    fn onU(ctx: ?*anyopaque, sid: u64, streamType: u64) void {
        _ = sid;
        const r: *TestRec = @ptrCast(@alignCast(ctx.?));
        r.uniTypes += 1;
        r.lastUniType = streamType;
    }
    fn onErr(ctx: ?*anyopaque, sid: u64, code: H3Error) void {
        _ = sid;
        const r: *TestRec = @ptrCast(@alignCast(ctx.?));
        r.lastErr = code;
    }
};

fn testFrame(a: Allocator, ftype: u64, payload: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    var fh: [16]u8 = undefined;
    const n = try frameMod.encodeFrameHeader(&fh, ftype, payload.len);
    try out.appendSlice(a, fh[0..n]);
    try out.appendSlice(a, payload);
    return out.toOwnedSlice(a);
}

fn testSection(
    a: Allocator,
    enc: *qpackMod.Encoder,
    heads: []const [2][]const u8,
) ![]u8 {
    var block = std.ArrayList(u8).empty;
    defer block.deinit(a);
    enc.beginSection();
    for (heads) |h| try enc.encodeField(&block, h[0], h[1]);
    const ric = enc.sectionRic();
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    try enc.encodePrefix(&out, ric, ric);
    try out.appendSlice(a, block.items);
    return out.toOwnedSlice(a);
}

fn testBidi(a: Allocator, rec: *TestRec, sid: u64, mode: StreamMode, qdec: *qpackMod.Decoder, qenc: *qpackMod.Encoder) Stream {
    return Stream.init(a, sid, mode, if (mode == .requestRecv) .server else .client, rec.cbs(), qdec, qenc);
}

test "h3stream control accepts settings then rejects data" {
    const a = std.testing.allocator;
    var rec = TestRec{};
    var qdec = qpackMod.Decoder.init(a);
    defer qdec.deinit();
    var qenc = qpackMod.Encoder.init(a);
    defer qenc.deinit();
    var s = Stream.init(a, 2, .uni, .server, rec.cbs(), &qdec, &qenc);
    defer s.deinit();

    var settingsPayload = std.ArrayList(u8).empty;
    defer settingsPayload.deinit(a);
    try settingsPayload.append(a, 0x00); // control type
    const entries = [_]frameMod.SettingEntry{.{ .id = 0x6, .value = 4096 }};
    const sp = try frameMod.buildSettingsPayload(a, &entries);
    defer a.free(sp);
    const sf = try testFrame(a, 0x4, sp);
    defer a.free(sf);
    try settingsPayload.appendSlice(a, sf);
    s.feed(settingsPayload.items, false);
    try std.testing.expectEqual(@as(usize, 1), rec.uniTypes);
    try std.testing.expectEqual(@as(usize, 1), rec.controlFrames);
    try std.testing.expectEqual(@as(u64, 0x4), rec.lastControlType);
    try std.testing.expect(rec.lastErr == null);

    const df = try testFrame(a, 0x0, "x");
    defer a.free(df);
    s.feed(df, false);
    try std.testing.expectEqual(H3Error.frameUnexpected, rec.lastErr.?);
}

test "h3stream fragmented uni type then unknown skip" {
    const a = std.testing.allocator;
    var rec = TestRec{};
    var qdec = qpackMod.Decoder.init(a);
    defer qdec.deinit();
    var qenc = qpackMod.Encoder.init(a);
    defer qenc.deinit();
    var s = Stream.init(a, 3, .uni, .client, rec.cbs(), &qdec, &qenc);
    defer s.deinit();

    s.feed(&.{0x40}, false); // 2-byte varint, incomplete
    try std.testing.expectEqual(@as(usize, 0), rec.uniTypes);
    try std.testing.expect(rec.lastErr == null);
    s.feed(&.{ 0x40, 0x05, 'h', 'e', 'l', 'l', 'o' }, true); // type 64
    try std.testing.expectEqual(@as(usize, 1), rec.uniTypes);
    try std.testing.expectEqual(@as(u64, 64), rec.lastUniType);
    try std.testing.expect(rec.lastErr == null);
    try std.testing.expect(s.done);

    // Truncated type at FIN is a frame error.
    var rec2 = TestRec{};
    var s2 = Stream.init(a, 7, .uni, .client, rec2.cbs(), &qdec, &qenc);
    defer s2.deinit();
    s2.feed(&.{0x40}, true);
    try std.testing.expectEqual(H3Error.frameError, rec2.lastErr.?);
}

test "h3stream push streams are rejected" {
    const a = std.testing.allocator;
    var rec = TestRec{};
    var qdec = qpackMod.Decoder.init(a);
    defer qdec.deinit();
    var qenc = qpackMod.Encoder.init(a);
    defer qenc.deinit();
    var s = Stream.init(a, 2, .uni, .server, rec.cbs(), &qdec, &qenc);
    defer s.deinit();
    s.feed(&.{0x01}, false);
    try std.testing.expectEqual(H3Error.frameUnexpected, rec.lastErr.?);
}

test "h3stream request headers data fin" {
    const a = std.testing.allocator;
    var rec = TestRec{};
    var qdec = qpackMod.Decoder.init(a);
    defer qdec.deinit();
    var qenc = qpackMod.Encoder.init(a);
    defer qenc.deinit();
    var qencPeer = qpackMod.Encoder.init(a);
    defer qencPeer.deinit();
    var s = testBidi(a, &rec, 0, .requestRecv, &qdec, &qenc);
    defer s.deinit();

    const section = try testSection(a, &qencPeer, &.{
        .{ ":method", "GET" },
        .{ ":scheme", "https" },
        .{ ":authority", "example.com" },
        .{ ":path", "/" },
    });
    defer a.free(section);
    const hf = try testFrame(a, 0x1, section);
    defer a.free(hf);
    const df = try testFrame(a, 0x0, "hi");
    defer a.free(df);
    var wire = std.ArrayList(u8).empty;
    defer wire.deinit(a);
    try wire.appendSlice(a, hf);
    try wire.appendSlice(a, df);
    s.feed(wire.items, true);
    try std.testing.expect(rec.lastErr == null);
    try std.testing.expectEqual(@as(usize, 1), rec.headers);
    try std.testing.expect(rec.sawGet);
    try std.testing.expectEqual(@as(usize, 2), rec.dataBytes);
    try std.testing.expectEqual(@as(usize, 1), rec.ends);
}

test "h3stream trailers delivered after data" {
    const a = std.testing.allocator;
    var rec = TestRec{};
    var qdec = qpackMod.Decoder.init(a);
    defer qdec.deinit();
    var qenc = qpackMod.Encoder.init(a);
    defer qenc.deinit();
    var qp = qpackMod.Encoder.init(a);
    defer qp.deinit();
    var s = testBidi(a, &rec, 0, .requestRecv, &qdec, &qenc);
    defer s.deinit();

    const h1 = try testSection(a, &qp, &.{ .{ ":method", "POST" }, .{ ":scheme", "https" }, .{ ":authority", "x" }, .{ ":path", "/" } });
    defer a.free(h1);
    const h2 = try testSection(a, &qp, &.{.{ "x-trailer", "1" }});
    defer a.free(h2);
    const f1 = try testFrame(a, 0x1, h1);
    defer a.free(f1);
    const fd = try testFrame(a, 0x0, "body");
    defer a.free(fd);
    const f2 = try testFrame(a, 0x1, h2);
    defer a.free(f2);
    var wire = std.ArrayList(u8).empty;
    defer wire.deinit(a);
    try wire.appendSlice(a, f1);
    try wire.appendSlice(a, fd);
    try wire.appendSlice(a, f2);
    s.feed(wire.items, true);
    try std.testing.expect(rec.lastErr == null);
    try std.testing.expectEqual(@as(usize, 1), rec.headers);
    try std.testing.expectEqual(@as(usize, 4), rec.dataBytes);
    try std.testing.expectEqual(@as(usize, 1), rec.trailers);
    try std.testing.expectEqual(@as(usize, 1), rec.ends);
}

test "h3stream interim 1xx then final" {
    const a = std.testing.allocator;
    var rec = TestRec{};
    var qdec = qpackMod.Decoder.init(a);
    defer qdec.deinit();
    var qenc = qpackMod.Encoder.init(a);
    defer qenc.deinit();
    var qp = qpackMod.Encoder.init(a);
    defer qp.deinit();
    var s = testBidi(a, &rec, 0, .responseRecv, &qdec, &qenc);
    defer s.deinit();

    const h1 = try testSection(a, &qp, &.{.{ ":status", "103" }});
    defer a.free(h1);
    const h2 = try testSection(a, &qp, &.{ .{ ":status", "200" }, .{ "content-length", "2" } });
    defer a.free(h2);
    const f1 = try testFrame(a, 0x1, h1);
    defer a.free(f1);
    const f2 = try testFrame(a, 0x1, h2);
    defer a.free(f2);
    const fd = try testFrame(a, 0x0, "ok");
    defer a.free(fd);
    var wire = std.ArrayList(u8).empty;
    defer wire.deinit(a);
    try wire.appendSlice(a, f1);
    try wire.appendSlice(a, f2);
    try wire.appendSlice(a, fd);
    s.feed(wire.items, true);
    try std.testing.expect(rec.lastErr == null);
    try std.testing.expectEqual(@as(usize, 2), rec.headers);
    try std.testing.expectEqual(@as(usize, 1), rec.interim);
    try std.testing.expectEqual(@as(usize, 2), rec.dataBytes);
    try std.testing.expectEqual(@as(usize, 1), rec.ends);
}

test "h3stream data before headers is malformed" {
    const a = std.testing.allocator;
    var rec = TestRec{};
    var qdec = qpackMod.Decoder.init(a);
    defer qdec.deinit();
    var qenc = qpackMod.Encoder.init(a);
    defer qenc.deinit();
    var s = testBidi(a, &rec, 0, .requestRecv, &qdec, &qenc);
    defer s.deinit();
    const df = try testFrame(a, 0x0, "early");
    defer a.free(df);
    s.feed(df, false);
    try std.testing.expectEqual(H3Error.messageError, rec.lastErr.?);
}

test "h3stream header validation matrix" {
    const a = std.testing.allocator;
    const Case = struct { heads: []const [2][]const u8, ok: bool };
    const cases = [_]Case{
        // Duplicate pseudo-header.
        .{ .heads = &.{ .{ ":method", "GET" }, .{ ":method", "POST" }, .{ ":scheme", "https" }, .{ ":authority", "x" }, .{ ":path", "/" } }, .ok = false },
        // Uppercase field name.
        .{ .heads = &.{ .{ ":method", "GET" }, .{ ":scheme", "https" }, .{ ":authority", "x" }, .{ ":path", "/" }, .{ "X-Bad", "v" } }, .ok = false },
        // Forbidden connection header.
        .{ .heads = &.{ .{ ":method", "GET" }, .{ ":scheme", "https" }, .{ ":authority", "x" }, .{ ":path", "/" }, .{ "connection", "close" } }, .ok = false },
        // Missing :path.
        .{ .heads = &.{ .{ ":method", "GET" }, .{ ":scheme", "https" }, .{ ":authority", "x" } }, .ok = false },
        // Unknown pseudo-header.
        .{ .heads = &.{ .{ ":method", "GET" }, .{ ":scheme", "https" }, .{ ":authority", "x" }, .{ ":path", "/" }, .{ ":foo", "bar" } }, .ok = false },
        // Pseudo-header after a regular one.
        .{ .heads = &.{ .{ "x-a", "1" }, .{ ":method", "GET" }, .{ ":scheme", "https" }, .{ ":authority", "x" }, .{ ":path", "/" } }, .ok = false },
        // Non-numeric content-length.
        .{ .heads = &.{ .{ ":method", "GET" }, .{ ":scheme", "https" }, .{ ":authority", "x" }, .{ ":path", "/" }, .{ "content-length", "abc" } }, .ok = false },
        // Relative path without leading slash.
        .{ .heads = &.{ .{ ":method", "GET" }, .{ ":scheme", "https" }, .{ ":authority", "x" }, .{ ":path", "nope" } }, .ok = false },
        // Asterisk path only valid for OPTIONS.
        .{ .heads = &.{ .{ ":method", "GET" }, .{ ":scheme", "https" }, .{ ":authority", "x" }, .{ ":path", "*" } }, .ok = false },
        // OPTIONS asterisk form is valid.
        .{ .heads = &.{ .{ ":method", "OPTIONS" }, .{ ":scheme", "https" }, .{ ":authority", "x" }, .{ ":path", "*" } }, .ok = true },
        // Minimal valid GET.
        .{ .heads = &.{ .{ ":method", "GET" }, .{ ":scheme", "https" }, .{ ":authority", "x" }, .{ ":path", "/" } }, .ok = true },
    };
    for (cases) |c| {
        var rec = TestRec{};
        var qdec = qpackMod.Decoder.init(a);
        defer qdec.deinit();
        var qenc = qpackMod.Encoder.init(a);
        defer qenc.deinit();
        var qp = qpackMod.Encoder.init(a);
        defer qp.deinit();
        var s = testBidi(a, &rec, 0, .requestRecv, &qdec, &qenc);
        defer s.deinit();
        const section = try testSection(a, &qp, c.heads);
        defer a.free(section);
        const hf = try testFrame(a, 0x1, section);
        defer a.free(hf);
        s.feed(hf, true);
        if (c.ok) {
            try std.testing.expect(rec.lastErr == null);
            try std.testing.expectEqual(@as(usize, 1), rec.ends);
        } else {
            try std.testing.expectEqual(H3Error.messageError, rec.lastErr.?);
        }
    }
}

test "h3stream content length mismatch fails at fin" {
    const a = std.testing.allocator;
    var rec = TestRec{};
    var qdec = qpackMod.Decoder.init(a);
    defer qdec.deinit();
    var qenc = qpackMod.Encoder.init(a);
    defer qenc.deinit();
    var qp = qpackMod.Encoder.init(a);
    defer qp.deinit();
    var s = testBidi(a, &rec, 0, .requestRecv, &qdec, &qenc);
    defer s.deinit();
    const section = try testSection(a, &qp, &.{ .{ ":method", "POST" }, .{ ":scheme", "https" }, .{ ":authority", "x" }, .{ ":path", "/" }, .{ "content-length", "10" } });
    defer a.free(section);
    const hf = try testFrame(a, 0x1, section);
    defer a.free(hf);
    const df = try testFrame(a, 0x0, "hi");
    defer a.free(df);
    var wire = std.ArrayList(u8).empty;
    defer wire.deinit(a);
    try wire.appendSlice(a, hf);
    try wire.appendSlice(a, df);
    s.feed(wire.items, true); // declares 10, delivers 2
    try std.testing.expectEqual(H3Error.messageError, rec.lastErr.?);
}

test "h3stream qpack blocked parks then resumes" {
    const a = std.testing.allocator;
    var rec = TestRec{};
    var qdec = qpackMod.Decoder.init(a);
    defer qdec.deinit();
    qdec.setMaxTableCapacity(4096);
    var qenc = qpackMod.Encoder.init(a);
    defer qenc.deinit();
    var s = testBidi(a, &rec, 0, .requestRecv, &qdec, &qenc);
    defer s.deinit();

    // Peer encoder side (shares nothing with our decoder yet): a full
    // valid request whose last field is dynamic.
    var penc = qpackMod.Encoder.init(a);
    defer penc.deinit();
    penc.setMaxTableCapacity(4096);
    penc.beginSection();
    var field = std.ArrayList(u8).empty;
    defer field.deinit(a);
    try penc.encodeField(&field, ":method", "GET");
    try penc.encodeField(&field, ":scheme", "https");
    try penc.encodeField(&field, ":authority", "example.com");
    try penc.encodeField(&field, ":path", "/");
    try penc.encodeField(&field, "x-dynamic", "d");
    const ric = penc.sectionRic();
    var section = std.ArrayList(u8).empty;
    defer section.deinit(a);
    try penc.encodePrefix(&section, ric, ric);
    try section.appendSlice(a, field.items);
    const encBytes = try penc.takeEncoderBytes();
    defer a.free(encBytes);

    const hf = try testFrame(a, 0x1, section.items);
    defer a.free(hf);
    s.feed(hf, false);
    try std.testing.expect(s.blocked);
    try std.testing.expectEqual(@as(usize, 0), rec.headers);
    try std.testing.expect(rec.lastErr == null);

    // Encoder bytes arrive on the encoder stream; the bidi retries.
    var es = Stream.init(a, 6, .uni, .server, rec.cbs(), &qdec, &qenc);
    defer es.deinit();
    var ewire = std.ArrayList(u8).empty;
    defer ewire.deinit(a);
    try ewire.append(a, 0x02);
    try ewire.appendSlice(a, encBytes);
    es.feed(ewire.items, false);
    try std.testing.expect(rec.lastErr == null);
    s.retryBlocked();
    try std.testing.expect(!s.blocked);
    try std.testing.expectEqual(@as(usize, 1), rec.headers);
    try std.testing.expect(rec.sawGet);
    const ack = try s.takeDecoderAck();
    defer a.free(ack);
    try std.testing.expect(ack.len > 0);
}

test "h3stream fin mid-frame and empty fin" {
    const a = std.testing.allocator;
    var rec = TestRec{};
    var qdec = qpackMod.Decoder.init(a);
    defer qdec.deinit();
    var qenc = qpackMod.Encoder.init(a);
    defer qenc.deinit();
    var s = testBidi(a, &rec, 0, .requestRecv, &qdec, &qenc);
    defer s.deinit();
    // HEADERS header declares 10 payload bytes, stream ends after 2.
    s.feed(&.{ 0x01, 0x0A, 0x00, 0x00 }, true);
    try std.testing.expectEqual(H3Error.frameError, rec.lastErr.?);

    var rec2 = TestRec{};
    var s2 = testBidi(a, &rec2, 4, .requestRecv, &qdec, &qenc);
    defer s2.deinit();
    s2.feed(&.{}, true);
    try std.testing.expectEqual(H3Error.messageError, rec2.lastErr.?);
}

test "h3stream check peer stream ids" {
    try std.testing.expect(checkPeerStreamId(.server, 0) == null);
    try std.testing.expect(checkPeerStreamId(.server, 4) == null);
    try std.testing.expect(checkPeerStreamId(.server, 1) != null);
    try std.testing.expect(checkPeerStreamId(.server, 2) == null);
    try std.testing.expect(checkPeerStreamId(.server, 3) != null);
    try std.testing.expect(checkPeerStreamId(.client, 0) != null);
    try std.testing.expect(checkPeerStreamId(.client, 3) == null);
    try std.testing.expect(checkPeerStreamId(.client, 2) != null);
}
