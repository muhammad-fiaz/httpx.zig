//! HTTP/3 connection (RFC 9114).
//!
//! Manages control stream lifecycle, SETTINGS exchange, and request/response
//! on bidirectional streams. Transport (QUIC) integration via Conn interface.
//!
//! References:
//!   - RFC 9114 Section 3 — HTTP/3 Connection
//!   - RFC 9114 Section 4.2 — Control Stream (SETTINGS)
//!   - RFC 9114 Section 7.2 — HTTP/3 Frame Types
//!   - RFC 9114 Section 8.1 — HTTP/3 Error Codes
//!   - RFC 9000 — QUIC: A UDP-Based Multiplexed and Secure Transport

const std = @import("std");
const Allocator = std.mem.Allocator;
const frameMod = @import("frame.zig");
const qpackMod = @import("qpack.zig");
const varint = @import("../quic/varint.zig");
const h3stream = @import("stream.zig");

pub const CONTROL_STREAM_TYPE: u64 = 0x00;
pub const PUSH_STREAM_TYPE: u64 = 0x01;

pub const Error = error{
    ProtocolViolation,
    StreamClosed,
    InvalidSettings,
    OutOfMemory,
};

/// A single HTTP/3 message exchange on a bidirectional stream.
///
/// The QPACK encoder is borrowed from the owning `Connection` (never
/// copied): encoder state (dynamic table, insert count, pending
/// instructions) is per-connection, and copying the struct would
/// double-free the table. The stream must not outlive its connection.
pub const RequestStream = struct {
    id: u64,
    allocator: Allocator,
    qpack: *qpackMod.Encoder,

    /// Builds HEADERS frame payload for a response.
    pub fn buildResponseHeaders(
        self: *RequestStream,
        statusCode: u16,
        headers: []const qpackMod.FieldLine,
    ) ![]u8 {
        var block = std.ArrayList(u8).empty;
        errdefer block.deinit(self.allocator);

        // Field representations first; the section prefix needs the
        // final Required Insert Count, which is only known afterwards.
        self.qpack.beginSection();

        // Status pseudo-header
        var codeBuf: [4]u8 = undefined;
        const codeStr = std.fmt.bufPrint(&codeBuf, "{d}", .{statusCode}) catch "500";
        try self.qpack.encodeField(&block, ":status", codeStr);

        for (headers) |h| {
            if (std.mem.startsWith(u8, h.name, ":")) continue; // skip other pseudos
            try self.qpack.encodeField(&block, h.name, h.value);
        }

        const ric = self.qpack.sectionRic();
        var prefix = std.ArrayList(u8).empty;
        defer prefix.deinit(self.allocator);
        try self.qpack.encodePrefix(&prefix, ric, ric);

        // Wrap in HEADERS frame
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        var fh: [16]u8 = undefined;
        const n = try frameMod.encodeFrameHeader(&fh, @backingInt(frameMod.FrameType.headers), prefix.items.len + block.items.len);
        try out.appendSlice(self.allocator, fh[0..n]);
        try out.appendSlice(self.allocator, prefix.items);
        try out.appendSlice(self.allocator, block.items);
        block.deinit(self.allocator);
        return out.toOwnedSlice(self.allocator);
    }

    /// Builds an HTTP/3 request HEADERS frame with the required pseudo
    /// headers. The QPACK section prefix carries the real Required
    /// Insert Count (zero while the encoder stays static-only).
    pub fn buildRequestHeaders(
        self: *RequestStream,
        method: []const u8,
        scheme: []const u8,
        authority: []const u8,
        path: []const u8,
        headers: []const qpackMod.FieldLine,
    ) ![]u8 {
        var block = std.ArrayList(u8).empty;
        errdefer block.deinit(self.allocator);
        self.qpack.beginSection();
        try self.qpack.encodeField(&block, ":method", method);
        try self.qpack.encodeField(&block, ":scheme", scheme);
        try self.qpack.encodeField(&block, ":authority", authority);
        try self.qpack.encodeField(&block, ":path", path);
        for (headers) |h| {
            if (std.mem.startsWith(u8, h.name, ":")) return error.InvalidHeader;
            try self.qpack.encodeField(&block, h.name, h.value);
        }

        const ric = self.qpack.sectionRic();
        var prefix = std.ArrayList(u8).empty;
        defer prefix.deinit(self.allocator);
        try self.qpack.encodePrefix(&prefix, ric, ric);

        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        var fh: [16]u8 = undefined;
        const n = try frameMod.encodeFrameHeader(&fh, @backingInt(frameMod.FrameType.headers), prefix.items.len + block.items.len);
        try out.appendSlice(self.allocator, fh[0..n]);
        try out.appendSlice(self.allocator, prefix.items);
        try out.appendSlice(self.allocator, block.items);
        block.deinit(self.allocator);
        return out.toOwnedSlice(self.allocator);
    }

    /// Builds DATA frame payload.
    pub fn buildData(self: *RequestStream, body: []const u8) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        var fh: [16]u8 = undefined;
        const n = try frameMod.encodeFrameHeader(&fh, @backingInt(frameMod.FrameType.data), body.len);
        try out.appendSlice(self.allocator, fh[0..n]);
        try out.appendSlice(self.allocator, body);
        return out.toOwnedSlice(self.allocator);
    }
};

/// Control stream builder - SETTINGS frame.
pub fn buildSettingsFrame(allocator: Allocator, entries: []const frameMod.SettingEntry) ![]u8 {
    const payload = try frameMod.buildSettingsPayload(allocator, entries);
    defer allocator.free(payload);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    // Stream type prefix (control = 0)
    var vb: [16]u8 = undefined;
    var n = try varint.encode(&vb, CONTROL_STREAM_TYPE);
    try out.appendSlice(allocator, vb[0..n]);

    // SETTINGS frame
    n = try frameMod.encodeFrameHeader(&vb, @backingInt(frameMod.FrameType.settings), payload.len);
    try out.appendSlice(allocator, vb[0..n]);
    try out.appendSlice(allocator, payload);
    return out.toOwnedSlice(allocator);
}

/// Builds a QPACK encoder stream type prefix.
pub fn buildQpackEncoderStreamPrefix(allocator: Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var vb: [16]u8 = undefined;
    const n = try varint.encode(&vb, frameMod.UniStreamType.qpackEncoder);
    try out.appendSlice(allocator, vb[0..n]);
    return out.toOwnedSlice(allocator);
}

/// Builds a QPACK decoder stream type prefix.
pub fn buildQpackDecoderStreamPrefix(allocator: Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var vb: [16]u8 = undefined;
    const n = try varint.encode(&vb, frameMod.UniStreamType.qpackDecoder);
    try out.appendSlice(allocator, vb[0..n]);
    return out.toOwnedSlice(allocator);
}

pub const PeerSettings = struct {
    maxFieldSectionSize: u64 = 16384,
    qpackMaxTableCapacity: u64 = 0,
    qpackBlockedStreams: u64 = 0,
    enableConnectProtocol: u64 = 0,
    h3Datagram: u64 = 0,
};

/// Canonical settings type (re-exported as `httpx.http3.Settings`).
pub const Settings = PeerSettings;

/// HTTP/3 connection state machine. Manages control stream lifecycle,
/// SETTINGS exchange, QPACK integration, and stream multiplexing.
///
/// The QUIC transport is deliberately duck-typed (`quic: anytype` on the
/// send methods): anything with `sendStreamChecked`, `sendResetStream`
/// and a `sendStreamEnd` map works, so unit tests drive a recording mock
/// while production passes the real QUIC connection. No import of the
/// QUIC module here also keeps the module graph acyclic.
pub const Connection = struct {
    allocator: Allocator,
    role: Role,

    // Settings
    localSettings: PeerSettings = .{},
    peerSettings: PeerSettings = .{},
    settingsSent: bool = false,
    settingsReceived: bool = false,
    controlStreamStarted: bool = false,
    /// Precise H3 error for the next failed control-frame callback.
    controlError: ?frameMod.H3Error = null,
    /// Connection-level protocol failure (control-stream error or QPACK
    /// blocked-stream limit exceeded). Callers must stop the connection.
    fatalError: ?frameMod.H3Error = null,

    // QPACK state
    qenc: qpackMod.Encoder,
    qdec: qpackMod.Decoder,

    // GOAWAY and push tracking
    goawaySent: bool = false,
    goawayReceived: bool = false,
    goawayStreamId: u64 = 0,
    maxPushId: u64 = 0,

    // Stream tracking
    nextBidiId: u64,
    nextUniId: u64,

    /// Live H3 streams by QUIC stream ID (request/response exchanges in
    /// progress plus our unidirectional streams being fed).
    streams: std.AutoHashMap(u64, h3stream.Stream) = undefined,
    /// Peer's unidirectional streams by kind (duplicates are rejected).
    controlIn: ?u64 = null,
    encoderIn: ?u64 = null,
    decoderIn: ?u64 = null,
    /// Our unidirectional streams once opened.
    controlOut: ?u64 = null,
    encoderOut: ?u64 = null,
    decoderOut: ?u64 = null,
    /// Outward events for the runtime (client/server engine).
    cbs: Callbacks = .{},
    /// Precise failure for a stream that could never be created
    /// (peer opened an illegal stream ID); the runtime drains this to
    /// reset/close with the right code.
    streamError: ?StreamError = null,

    pub const Role = h3stream.Role;

    /// Runtime-facing connection events.
    pub const Callbacks = struct {
        ctx: ?*anyopaque = null,
        onHeaders: ?*const fn (ctx: ?*anyopaque, sid: u64, fields: []const qpackMod.FieldLine, interim: bool) void = null,
        onData: ?*const fn (ctx: ?*anyopaque, sid: u64, data: []const u8) void = null,
        onTrailers: ?*const fn (ctx: ?*anyopaque, sid: u64, fields: []const qpackMod.FieldLine) void = null,
        onMessageEnd: ?*const fn (ctx: ?*anyopaque, sid: u64) void = null,
        onStreamReset: ?*const fn (ctx: ?*anyopaque, sid: u64, code: u64) void = null,
        /// A stream failed the H3 state machine; reset it with `code`.
        onH3Error: ?*const fn (ctx: ?*anyopaque, sid: u64, code: frameMod.H3Error) void = null,
        /// Peer GOAWAY processed; stop opening streams at/above the ID.
        onGoaway: ?*const fn (ctx: ?*anyopaque, lastStreamId: u64) void = null,
    };

    pub const StreamError = struct {
        sid: u64,
        code: frameMod.H3Error,
    };

    pub fn init(allocator: Allocator, role: Role) Connection {
        const initiatorBit: u64 = if (role == .client) 0 else 1;
        var self = Connection{
            .allocator = allocator,
            .role = role,
            // Advertise a useful dynamic QPACK table by default. Zero
            // would force every peer to static/literal encoding and
            // leave the dynamic decoder unexercised in production.
            .localSettings = .{
                .qpackMaxTableCapacity = 4096,
                .qpackBlockedStreams = 16,
            },
            .qenc = qpackMod.Encoder.init(allocator),
            .qdec = qpackMod.Decoder.init(allocator),
            .nextBidiId = initiatorBit,
            .nextUniId = initiatorBit | 2,
        };
        self.streams = std.AutoHashMap(u64, h3stream.Stream).init(allocator);
        return self;
    }

    pub fn deinit(self: *Connection) void {
        var it = self.streams.valueIterator();
        while (it.next()) |stp| stp.deinit();
        self.streams.deinit();
        self.qenc.deinit();
        self.qdec.deinit();
    }

    /// Drains a pending precise stream failure for the runtime to reset
    /// or close with (null when none).
    pub fn takeStreamError(self: *Connection) ?StreamError {
        const e = self.streamError;
        self.streamError = null;
        return e;
    }

    /// Builds the control stream SETTINGS frame to send.
    pub fn buildControlStream(self: *Connection) ![]u8 {
        // Commit our decoder state to what we advertise: the peer may
        // use dynamic references up to our capacity from here on.
        // Once-only: re-sizing mid-connection would drop live entries.
        if (!self.settingsSent) {
            self.qdec.setMaxTableCapacity(std.math.cast(usize, self.localSettings.qpackMaxTableCapacity) orelse 0);
            self.qdec.setMaxFieldSectionSize(self.localSettings.maxFieldSectionSize);
        }

        var entries: [4]frameMod.SettingEntry = undefined;
        var count: usize = 0;

        entries[count] = .{ .id = 0x6, .value = self.localSettings.maxFieldSectionSize };
        count += 1;

        if (self.localSettings.qpackMaxTableCapacity > 0) {
            entries[count] = .{ .id = 0x1, .value = self.localSettings.qpackMaxTableCapacity };
            count += 1;
        }

        if (self.localSettings.qpackBlockedStreams > 0) {
            entries[count] = .{ .id = 0x7, .value = self.localSettings.qpackBlockedStreams };
            count += 1;
        }

        const result = try buildSettingsFrame(self.allocator, entries[0..count]);
        self.settingsSent = true;
        return result;
    }

    /// Processes an incoming SETTINGS frame from the peer's control stream.
    pub fn processPeerSettings(self: *Connection, settingsEntries: []const frameMod.SettingEntry) !void {
        if (self.settingsReceived) return Error.InvalidSettings;
        var seenQpackCapacity = false;
        var seenMaxFieldSection = false;
        var seenBlockedStreams = false;
        var seenConnect = false;
        var seenDatagram = false;
        for (settingsEntries) |entry| {
            switch (entry.id) {
                0x1 => {
                    if (seenQpackCapacity) return Error.InvalidSettings;
                    seenQpackCapacity = true;
                    self.peerSettings.qpackMaxTableCapacity = entry.value;
                },
                0x2 => return Error.InvalidSettings, // ENABLE_PUSH is forbidden in HTTP/3.
                0x6 => {
                    if (seenMaxFieldSection) return Error.InvalidSettings;
                    seenMaxFieldSection = true;
                    self.peerSettings.maxFieldSectionSize = entry.value;
                },
                0x7 => {
                    if (seenBlockedStreams) return Error.InvalidSettings;
                    seenBlockedStreams = true;
                    self.peerSettings.qpackBlockedStreams = entry.value;
                },
                0x8 => {
                    if (seenConnect) return Error.InvalidSettings;
                    seenConnect = true;
                    if (entry.value > 1) return Error.InvalidSettings;
                    self.peerSettings.enableConnectProtocol = entry.value;
                },
                0x33 => {
                    if (seenDatagram) return Error.InvalidSettings;
                    seenDatagram = true;
                    if (entry.value > 1) return Error.InvalidSettings;
                    self.peerSettings.h3Datagram = entry.value;
                },
                else => {},
            }
        }
        self.qenc.setMaxTableCapacity(std.math.cast(usize, self.peerSettings.qpackMaxTableCapacity) orelse return Error.InvalidSettings);
        self.settingsReceived = true;
    }

    /// Builds a GOAWAY frame (stream ID varint payload).
    pub fn buildGoawayFrame(self: *Connection, streamId: u64) ![]u8 {
        const out = try frameMod.encodeSingleVarintFrame(
            self.allocator,
            @backingInt(frameMod.FrameType.goaway),
            streamId,
        );
        self.goawaySent = true;
        self.goawayStreamId = streamId;
        return out;
    }

    /// Processes one frame received on the HTTP/3 control stream.
    ///
    /// Request-stream frames such as DATA and HEADERS are forbidden here.
    /// SETTINGS is accepted exactly once; integer-valued control frames are
    /// shape-validated and handled.
    pub fn processControlFrame(self: *Connection, frameType: u64, payload: []const u8) !void {
        self.controlStreamStarted = true;
        self.controlError = null;
        if (!self.settingsReceived and frameType != 0x4) {
            self.controlError = .missingSettings;
            return Error.InvalidSettings;
        }
        switch (frameType) {
            0x0, 0x1, 0x5 => {
                self.controlError = .frameUnexpected; // DATA, HEADERS, PUSH_PROMISE
                return Error.ProtocolViolation;
            },
            0x4 => {
                const entries = frameMod.parseSettingsPayload(payload, self.allocator) catch |e| switch (e) {
                    error.OutOfMemory => return Error.OutOfMemory,
                    else => {
                        self.controlError = .settingsError;
                        return Error.InvalidSettings;
                    },
                };
                defer self.allocator.free(entries);
                self.processPeerSettings(entries) catch |e| {
                    self.controlError = if (e == Error.OutOfMemory) .internalError else .settingsError;
                    return e;
                };
            },
            0x7 => {
                if (self.role == .server) {
                    self.controlError = .frameUnexpected;
                    return Error.ProtocolViolation;
                }
                const sid = frameMod.decodeSingleVarintPayload(payload) catch {
                    self.controlError = .frameError;
                    return Error.ProtocolViolation;
                };
                if ((sid & 0x3) != 0) {
                    self.controlError = .idError;
                    return Error.ProtocolViolation;
                }
                if (self.goawayReceived and sid > self.goawayStreamId) {
                    self.controlError = .idError;
                    return Error.ProtocolViolation;
                }
                self.goawayReceived = true;
                self.goawayStreamId = sid;
            },
            0x3, 0xD => {
                if (self.role == .client) {
                    self.controlError = .frameUnexpected;
                    return Error.ProtocolViolation;
                }
                const entries = frameMod.validateFramePayload(self.allocator, frameType, payload) catch |e| switch (e) {
                    error.OutOfMemory => return Error.OutOfMemory,
                    else => {
                        self.controlError = .frameError;
                        return Error.ProtocolViolation;
                    },
                };
                self.allocator.free(entries);
                if (frameType == 0xD) {
                    const pid = frameMod.decodeSingleVarintPayload(payload) catch {
                        self.controlError = .frameError;
                        return Error.ProtocolViolation;
                    };
                    if (pid > self.maxPushId) self.maxPushId = pid;
                }
            },
            else => {}, // Unknown control frames are ignored per RFC 9114.
        }
    }

    /// Allocates the next bidirectional stream ID.
    pub fn nextBidiStreamId(self: *Connection) u64 {
        const id = self.nextBidiId;
        self.nextBidiId += 4;
        return id;
    }

    /// Allocates the next unidirectional stream ID.
    pub fn nextUniStreamId(self: *Connection) u64 {
        const id = self.nextUniId;
        self.nextUniId += 4;
        return id;
    }

    pub fn createRequestStream(self: *Connection, streamId: u64) RequestStream {
        return .{
            .id = streamId,
            .allocator = self.allocator,
            .qpack = &self.qenc,
        };
    }

    /// Builds the callback set H3Streams get, forwarding into this
    /// connection (which applies control state) and then the runtime.
    fn streamCallbacks(self: *Connection) h3stream.Callbacks {
        return .{
            .ctx = self,
            .onHeaders = fwdHeaders,
            .onData = fwdData,
            .onTrailers = fwdTrailers,
            .onMessageEnd = fwdMessageEnd,
            .onControlFrame = fwdControlFrame,
            .onUniType = fwdUniType,
            .onReset = fwdStreamReset,
            .onError = fwdStreamError,
        };
    }

    fn fwdHeaders(ctx: ?*anyopaque, sid: u64, fields: []const qpackMod.FieldLine, interim: bool) void {
        const self: *Connection = @ptrCast(@alignCast(ctx.?));
        if (self.cbs.onHeaders) |cb| cb(self.cbs.ctx, sid, fields, interim);
    }

    fn fwdData(ctx: ?*anyopaque, sid: u64, data: []const u8) void {
        const self: *Connection = @ptrCast(@alignCast(ctx.?));
        if (self.cbs.onData) |cb| cb(self.cbs.ctx, sid, data);
    }

    fn fwdTrailers(ctx: ?*anyopaque, sid: u64, fields: []const qpackMod.FieldLine) void {
        const self: *Connection = @ptrCast(@alignCast(ctx.?));
        if (self.cbs.onTrailers) |cb| cb(self.cbs.ctx, sid, fields);
    }

    fn fwdMessageEnd(ctx: ?*anyopaque, sid: u64) void {
        const self: *Connection = @ptrCast(@alignCast(ctx.?));
        if (self.cbs.onMessageEnd) |cb| cb(self.cbs.ctx, sid);
    }

    fn fwdStreamReset(ctx: ?*anyopaque, sid: u64, code: u64) void {
        const self: *Connection = @ptrCast(@alignCast(ctx.?));
        if (self.cbs.onStreamReset) |cb| cb(self.cbs.ctx, sid, code);
    }

    fn fwdStreamError(ctx: ?*anyopaque, sid: u64, code: frameMod.H3Error) void {
        const self: *Connection = @ptrCast(@alignCast(ctx.?));
        if (self.streams.getPtr(sid)) |stp| {
            switch (stp.uniKindKnown() orelse .undecided) {
                .control, .qpackEncoder, .qpackDecoder => {
                    if (self.fatalError == null) self.fatalError = code;
                },
                else => {},
            }
        }
        if (self.cbs.onH3Error) |cb| cb(self.cbs.ctx, sid, code);
    }

    fn fwdUniType(_: ?*anyopaque, _: u64, _: u64) void {
        // Observability only; duplicate/push validation happens in
        // feedQuic, which owns the kind tracking.
    }

    fn fwdControlFrame(ctx: ?*anyopaque, sid: u64, frameType: u64, payload: []const u8) void {
        const self: *Connection = @ptrCast(@alignCast(ctx.?));
        const hadGoaway = self.goawayReceived;
        self.processControlFrame(frameType, payload) catch |e| {
            const code: frameMod.H3Error = self.controlError orelse switch (e) {
                error.InvalidSettings => .settingsError,
                error.OutOfMemory => .internalError,
                else => .frameUnexpected,
            };
            self.controlError = null;
            if (self.fatalError == null) self.fatalError = code;
            if (self.streams.getPtr(sid)) |stp| stp.failExtern(code);
            return;
        };
        if (!hadGoaway and self.goawayReceived) {
            if (self.cbs.onGoaway) |cb| cb(self.cbs.ctx, self.goawayStreamId);
        }
    }

    /// Feeds bytes the QUIC layer received on `sid`. Creates the H3
    /// stream on first sight (validating peer stream IDs); precise
    /// failures for uncreatable streams are reported via
    /// `takeStreamError`, per-stream failures via `onH3Error`.
    pub fn feedQuic(self: *Connection, sid: u64, data: []const u8, fin: bool) Error!void {
        if (self.streams.getPtr(sid)) |stp| {
            stp.feed(data, fin);
            self.checkCriticalClosed(sid, fin);
            self.checkBlockedLimit();
            return;
        }
        if (h3stream.checkPeerStreamId(self.role, sid)) |code| {
            self.streamError = .{ .sid = sid, .code = code };
            return Error.ProtocolViolation;
        }
        const bidi = (sid & 0x02) == 0;
        const mode: h3stream.StreamMode = if (bidi) blk: {
            // Only the server receives peer-initiated bidi streams;
            // client bidi streams are created locally at open time.
            if (self.role != .server) {
                self.streamError = .{ .sid = sid, .code = .streamCreationError };
                return Error.ProtocolViolation;
            }
            break :blk .requestRecv;
        } else .uni;
        if (!bidi) {
            // Reject duplicate critical streams and push streams before
            // creating state when the type arrives complete in this
            // feed (fragmented types fall through to the post-feed
            // check below).
            if (h3stream.parseUniType(data) catch null) |t| {
                const preDup = switch (t.streamType) {
                    0x00 => self.controlIn != null,
                    0x02 => self.encoderIn != null,
                    0x03 => self.decoderIn != null,
                    else => false,
                };
                if (t.streamType == 0x01 or preDup) {
                    const code: frameMod.H3Error = if (t.streamType == 0x01) .frameUnexpected else .streamCreationError;
                    self.streamError = .{ .sid = sid, .code = code };
                    return Error.ProtocolViolation;
                }
            }
        }
        var st = h3stream.Stream.init(
            self.allocator,
            sid,
            mode,
            self.role,
            self.streamCallbacks(),
            &self.qdec,
            &self.qenc,
        );
        errdefer st.deinit();
        try self.streams.put(sid, st);
        const stp = self.streams.getPtr(sid).?;
        stp.feed(data, fin);
        if (stp.failed) {
            var dead = self.streams.fetchRemove(sid).?;
            dead.value.deinit();
            return;
        }
        // Track peer unidirectional streams; duplicates and push
        // streams are rejected (the pre-creation check above catches
        // complete first feeds; this covers fragmented type varints).
        if (!bidi) {
            if (stp.uniKindKnown()) |kind| {
                const dup = switch (kind) {
                    .control => self.controlIn != null,
                    .qpackEncoder => self.encoderIn != null,
                    .qpackDecoder => self.decoderIn != null,
                    else => false,
                };
                if (kind == .push or dup) {
                    if (!stp.failed) {
                        const code: frameMod.H3Error = if (kind == .push) .frameUnexpected else .streamCreationError;
                        stp.failExtern(code);
                    }
                    var gone = self.streams.fetchRemove(sid).?;
                    gone.value.deinit();
                    return;
                }
                switch (kind) {
                    .control => self.controlIn = sid,
                    .qpackEncoder => self.encoderIn = sid,
                    .qpackDecoder => self.decoderIn = sid,
                    else => {},
                }
            }
        }
        self.checkCriticalClosed(sid, fin);
        self.checkBlockedLimit();
    }

    fn checkCriticalClosed(self: *Connection, sid: u64, fin: bool) void {
        if (!fin or self.fatalError != null) return;
        if (sid == self.controlIn or sid == self.encoderIn or sid == self.decoderIn) {
            self.fatalError = .closedCriticalStream;
        }
    }

    /// Signals a QUIC-level reset received for `sid`. Unknown streams
    /// are ignored (nothing to abandon).
    pub fn onQuicReset(self: *Connection, sid: u64, code: u64) void {
        if (self.streams.getPtr(sid)) |stp| stp.onQuicReset(code);
    }

    /// Retries every section parked on QPACK blocking (call after
    /// feeding encoder-stream bytes), then enforces the advertised
    /// blocked-stream limit.
    pub fn retryBlockedStreams(self: *Connection) void {
        var it = self.streams.valueIterator();
        while (it.next()) |stp| stp.retryBlocked();
        self.checkBlockedLimit();
    }

    /// Returns and clears the pending connection-level error, if any.
    pub fn takeFatalError(self: *Connection) ?frameMod.H3Error {
        const err = self.fatalError;
        self.fatalError = null;
        return err;
    }

    fn checkBlockedLimit(self: *Connection) void {
        if (self.fatalError != null) return;
        var blocked: u64 = 0;
        var it = self.streams.valueIterator();
        while (it.next()) |stp| {
            if (stp.blocked) blocked += 1;
        }
        if (blocked > self.localSettings.qpackBlockedStreams) {
            self.fatalError = .qpackGeneralError;
        }
    }

    /// Concatenates staged decoder-stream acknowledgments from every
    /// stream; the runtime sends them on our decoder stream. Always
    /// owned (free even when empty).
    pub fn drainDecoderAcks(self: *Connection) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        var it = self.streams.valueIterator();
        while (it.next()) |stp| {
            if (stp.decoderAck.items.len == 0) continue;
            const ack = try stp.takeDecoderAck();
            defer self.allocator.free(ack);
            try out.appendSlice(self.allocator, ack);
        }
        if (out.items.len == 0) return try self.allocator.dupe(u8, &.{});
        return out.toOwnedSlice(self.allocator);
    }

    /// Opens a client request stream, tracking it for the inbound
    /// response. Fails when the peer went away.
    pub fn openRequestStream(self: *Connection) Error!u64 {
        if (self.role != .client) return Error.StreamClosed;
        if (self.goawayReceived) return Error.StreamClosed;
        const sid = self.nextBidiStreamId();
        errdefer {
            self.nextBidiId -= 4;
        }
        var st = h3stream.Stream.init(
            self.allocator,
            sid,
            .responseRecv,
            self.role,
            self.streamCallbacks(),
            &self.qdec,
            &self.qenc,
        );
        errdefer st.deinit();
        try self.streams.put(sid, st);
        return sid;
    }

    /// Sends already-built bytes on `sid` at the current send offset.
    /// `quic` is the QUIC connection (duck-typed for tests).
    pub fn sendStreamBytes(self: *Connection, quic: anytype, sid: u64, bytes: []const u8, fin: bool, nowMs: u64) !void {
        const off = quic.sendStreamEnd.get(sid) orelse 0;
        try quic.sendStreamChecked(sid, off, bytes, fin, nowMs);
        _ = self;
    }

    /// Sends our control stream (SETTINGS) on a fresh uni stream.
    pub fn sendControl(self: *Connection, quic: anytype, nowMs: u64) !void {
        const bytes = try self.buildControlStream();
        defer self.allocator.free(bytes);
        const sid = self.nextUniStreamId();
        errdefer {
            self.nextUniId -= 4;
        }
        try quic.sendStreamChecked(sid, 0, bytes, false, nowMs);
        self.controlOut = sid;
    }

    /// Sends empty QPACK encoder/decoder stream prefixes.
    pub fn sendQpackPrefixes(self: *Connection, quic: anytype, nowMs: u64) !void {
        const enc = try buildQpackEncoderStreamPrefix(self.allocator);
        defer self.allocator.free(enc);
        const esid = self.nextUniStreamId();
        errdefer {
            self.nextUniId -= 4;
        }
        try quic.sendStreamChecked(esid, 0, enc, false, nowMs);
        self.encoderOut = esid;
        const dec = try buildQpackDecoderStreamPrefix(self.allocator);
        defer self.allocator.free(dec);
        const dsid = self.nextUniStreamId();
        errdefer {
            self.nextUniId -= 4;
        }
        try quic.sendStreamChecked(dsid, 0, dec, false, nowMs);
        self.decoderOut = dsid;
    }

    /// Flushes pending encoder-stream instructions onto our encoder
    /// stream (must follow `sendQpackPrefixes`).
    pub fn flushQpackEncoder(self: *Connection, quic: anytype, nowMs: u64) !void {
        const esid = self.encoderOut orelse return Error.StreamClosed;
        const bytes = try self.qenc.takeEncoderBytes();
        defer self.allocator.free(bytes);
        if (bytes.len == 0) return;
        const off = quic.sendStreamEnd.get(esid) orelse 0;
        try quic.sendStreamChecked(esid, off, bytes, false, nowMs);
    }

    /// Flushes encoder instructions plus staged decoder acknowledgments.
    pub fn pumpQpack(self: *Connection, quic: anytype, nowMs: u64) !void {
        try self.flushQpackEncoder(quic, nowMs);
        const dsid = self.decoderOut orelse return;
        const ack = try self.drainDecoderAcks();
        defer self.allocator.free(ack);
        if (ack.len == 0) return;
        const off = quic.sendStreamEnd.get(dsid) orelse 0;
        try quic.sendStreamChecked(dsid, off, ack, false, nowMs);
    }

    /// Sends GOAWAY on our control stream.
    pub fn sendGoaway(self: *Connection, quic: anytype, lastSid: u64, nowMs: u64) !void {
        const cs = self.controlOut orelse return Error.StreamClosed;
        const bytes = try self.buildGoawayFrame(lastSid);
        defer self.allocator.free(bytes);
        const off = quic.sendStreamEnd.get(cs) orelse 0;
        try quic.sendStreamChecked(cs, off, bytes, false, nowMs);
    }

    /// Resets `sid` with an H3 code at the current send offset and
    /// stops tracking the stream for inbound bytes.
    pub fn resetStream(self: *Connection, quic: anytype, sid: u64, code: frameMod.H3Error, nowMs: u64) !void {
        const finalSize = quic.sendStreamEnd.get(sid) orelse 0;
        try quic.sendResetStream(sid, @backingInt(code), finalSize, nowMs);
        if (self.streams.getPtr(sid)) |stp| stp.failed = true;
    }
};

// Tests

const MockQuic = struct {
    allocator: Allocator,
    sent: std.ArrayList(MockSent) = .empty,
    resets: std.ArrayList(MockReset) = .empty,
    sendStreamEnd: std.AutoHashMap(u64, u64) = undefined,

    const MockSent = struct { sid: u64, off: u64, len: usize, firstByte: u8, fin: bool };
    const MockReset = struct { sid: u64, code: u64, finalSize: u64 };

    fn init(a: Allocator) MockQuic {
        var m = MockQuic{ .allocator = a };
        m.sendStreamEnd = std.AutoHashMap(u64, u64).init(a);
        return m;
    }

    fn deinit(self: *MockQuic) void {
        self.sent.deinit(self.allocator);
        self.resets.deinit(self.allocator);
        self.sendStreamEnd.deinit();
    }

    pub fn sendStreamChecked(self: *MockQuic, sid: u64, off: u64, data: []const u8, fin: bool, nowMs: u64) !void {
        _ = nowMs;
        try self.sent.append(self.allocator, .{
            .sid = sid,
            .off = off,
            .len = data.len,
            .firstByte = if (data.len > 0) data[0] else 0,
            .fin = fin,
        });
        const prev = self.sendStreamEnd.get(sid) orelse 0;
        if (off + data.len > prev) try self.sendStreamEnd.put(sid, off + data.len);
    }

    pub fn sendResetStream(self: *MockQuic, sid: u64, code: u64, finalSize: u64, nowMs: u64) !void {
        _ = nowMs;
        try self.resets.append(self.allocator, .{ .sid = sid, .code = code, .finalSize = finalSize });
    }
};

const ConnRec = struct {
    headers: usize = 0,
    dataBytes: usize = 0,
    ends: usize = 0,
    resets: usize = 0,
    h3Errors: usize = 0,
    lastH3Error: ?frameMod.H3Error = null,
    lastH3ErrorSid: u64 = 0,
    goaways: usize = 0,
    lastGoaway: u64 = 0,

    fn cbs(self: *ConnRec) Connection.Callbacks {
        return .{
            .ctx = self,
            .onHeaders = onH,
            .onData = onD,
            .onMessageEnd = onE,
            .onStreamReset = onR,
            .onH3Error = onHE,
            .onGoaway = onG,
        };
    }
    fn onH(ctx: ?*anyopaque, sid: u64, fields: []const qpackMod.FieldLine, interim: bool) void {
        _ = sid;
        _ = fields;
        _ = interim;
        const r: *ConnRec = @ptrCast(@alignCast(ctx.?));
        r.headers += 1;
    }
    fn onD(ctx: ?*anyopaque, sid: u64, data: []const u8) void {
        _ = sid;
        const r: *ConnRec = @ptrCast(@alignCast(ctx.?));
        r.dataBytes += data.len;
    }
    fn onE(ctx: ?*anyopaque, sid: u64) void {
        _ = sid;
        const r: *ConnRec = @ptrCast(@alignCast(ctx.?));
        r.ends += 1;
    }
    fn onR(ctx: ?*anyopaque, sid: u64, code: u64) void {
        _ = sid;
        _ = code;
        const r: *ConnRec = @ptrCast(@alignCast(ctx.?));
        r.resets += 1;
    }
    fn onHE(ctx: ?*anyopaque, sid: u64, code: frameMod.H3Error) void {
        const r: *ConnRec = @ptrCast(@alignCast(ctx.?));
        r.h3Errors += 1;
        r.lastH3Error = code;
        r.lastH3ErrorSid = sid;
    }
    fn onG(ctx: ?*anyopaque, lastStreamId: u64) void {
        const r: *ConnRec = @ptrCast(@alignCast(ctx.?));
        r.goaways += 1;
        r.lastGoaway = lastStreamId;
    }
};

test "h3conn demuxes uni streams and rejects duplicates" {
    const a = std.testing.allocator;
    var rec = ConnRec{};
    var conn = Connection.init(a, .server);
    defer conn.deinit();
    conn.cbs = rec.cbs();

    const ctrl = try conn.buildControlStream();
    defer a.free(ctrl);
    try conn.feedQuic(2, ctrl, false);
    try std.testing.expectEqual(@as(?u64, 2), conn.controlIn);
    try std.testing.expect(conn.settingsReceived);
    try std.testing.expect(rec.lastH3Error == null);

    // A second control stream is a creation error, reported precisely
    // without creating state.
    try std.testing.expectError(Error.ProtocolViolation, conn.feedQuic(6, ctrl, false));
    const dupErr = conn.takeStreamError().?;
    try std.testing.expectEqual(@as(u64, 6), dupErr.sid);
    try std.testing.expectEqual(frameMod.H3Error.streamCreationError, dupErr.code);
    try std.testing.expect(!conn.streams.contains(6));

    // Push streams are rejected under the no-push policy.
    try std.testing.expectError(Error.ProtocolViolation, conn.feedQuic(10, &.{0x01}, false));
    const pushErr = conn.takeStreamError().?;
    try std.testing.expectEqual(@as(u64, 10), pushErr.sid);
    try std.testing.expectEqual(frameMod.H3Error.frameUnexpected, pushErr.code);
    try std.testing.expect(!conn.streams.contains(10));

    // A peer-owned illegal ID surfaces through takeStreamError.
    try std.testing.expectError(Error.ProtocolViolation, conn.feedQuic(3, &.{0x00}, false));
    const se = conn.takeStreamError().?;
    try std.testing.expectEqual(@as(u64, 3), se.sid);
    try std.testing.expectEqual(frameMod.H3Error.streamCreationError, se.code);
    try std.testing.expect(conn.takeStreamError() == null);
}

test "h3conn routes bidi request bytes to events" {
    const a = std.testing.allocator;
    var rec = ConnRec{};
    var conn = Connection.init(a, .server);
    defer conn.deinit();
    conn.cbs = rec.cbs();

    var rs = conn.createRequestStream(999);
    // buildRequestHeaders returns a complete HEADERS frame already.
    const hf = try rs.buildRequestHeaders("GET", "https", "example.com", "/", &.{});
    defer a.free(hf);
    var dfb: [16]u8 = undefined;
    const dn = try frameMod.encodeFrameHeader(&dfb, 0x0, 2);
    var wire = std.ArrayList(u8).empty;
    defer wire.deinit(a);
    try wire.appendSlice(a, hf);
    try wire.appendSlice(a, dfb[0..dn]);
    try wire.appendSlice(a, "hi");
    try conn.feedQuic(0, wire.items, true);
    try std.testing.expect(rec.lastH3Error == null);
    try std.testing.expectEqual(@as(usize, 1), rec.headers);
    try std.testing.expectEqual(@as(usize, 2), rec.dataBytes);
    try std.testing.expectEqual(@as(usize, 1), rec.ends);
    try std.testing.expect(conn.streams.contains(0));
}

test "h3conn send path offsets prefixes and goaway gating" {
    const a = std.testing.allocator;
    var rec = ConnRec{};
    var conn = Connection.init(a, .client);
    defer conn.deinit();
    conn.cbs = rec.cbs();
    var mq = MockQuic.init(a);
    defer mq.deinit();

    try conn.sendControl(&mq, 100);
    try std.testing.expectEqual(@as(?u64, 2), conn.controlOut);
    try std.testing.expectEqual(@as(u64, 2), mq.sent.items[0].sid);
    try std.testing.expectEqual(@as(u8, 0x00), mq.sent.items[0].firstByte);

    try conn.sendQpackPrefixes(&mq, 101);
    try std.testing.expectEqual(@as(?u64, 6), conn.encoderOut);
    try std.testing.expectEqual(@as(?u64, 10), conn.decoderOut);
    try std.testing.expectEqual(@as(u8, 0x02), mq.sent.items[1].firstByte);
    try std.testing.expectEqual(@as(u8, 0x03), mq.sent.items[2].firstByte);

    const sid = try conn.openRequestStream();
    try std.testing.expectEqual(@as(u64, 0), sid);
    try conn.sendStreamBytes(&mq, sid, "HEAD", false, 102);
    try conn.sendStreamBytes(&mq, sid, "ERS", true, 103);
    try std.testing.expectEqual(@as(u64, 0), mq.sent.items[3].off);
    try std.testing.expectEqual(@as(u64, 4), mq.sent.items[4].off);

    try conn.sendGoaway(&mq, 0, 104);
    try std.testing.expect(conn.goawaySent);

    // Peer GOAWAY arrives on the peer's control stream: runtime is told
    // and no further streams open.
    const go = try conn.buildGoawayFrame(0);
    defer a.free(go);
    var peerCtrl = std.ArrayList(u8).empty;
    defer peerCtrl.deinit(a);
    try peerCtrl.append(a, 0x00);
    const peerSettings = try conn.buildControlStream();
    defer a.free(peerSettings);
    try peerCtrl.appendSlice(a, peerSettings[1..]); // settings frame without our type prefix
    try peerCtrl.appendSlice(a, go);
    try conn.feedQuic(3, peerCtrl.items, false);
    try std.testing.expect(conn.goawayReceived);
    try std.testing.expectEqual(@as(usize, 1), rec.goaways);
    try std.testing.expectEqual(@as(u64, 0), rec.lastGoaway);
    try std.testing.expectError(Error.StreamClosed, conn.openRequestStream());
}

test "h3conn reset sends offset and drops the stream" {
    const a = std.testing.allocator;
    var rec = ConnRec{};
    var conn = Connection.init(a, .client);
    defer conn.deinit();
    conn.cbs = rec.cbs();
    var mq = MockQuic.init(a);
    defer mq.deinit();

    const sid = try conn.openRequestStream();
    const body = (@as([100]u8, @splat(0xAA)));
    try conn.sendStreamBytes(&mq, sid, &body, false, 100);
    try conn.resetStream(&mq, sid, .requestCancelled, 101);
    try std.testing.expectEqual(@as(usize, 1), mq.resets.items.len);
    try std.testing.expectEqual(sid, mq.resets.items[0].sid);
    try std.testing.expectEqual(@as(u64, 0x10C), mq.resets.items[0].code);
    try std.testing.expectEqual(@as(u64, 100), mq.resets.items[0].finalSize);
    // Inbound bytes afterwards are ignored, not delivered.
    try conn.feedQuic(sid, "late", false);
    try std.testing.expectEqual(@as(usize, 0), rec.dataBytes);
    try std.testing.expect(rec.lastH3Error == null);
}

test "h3conn decoder acks drain concatenated" {
    const a = std.testing.allocator;
    var rec = ConnRec{};
    var conn = Connection.init(a, .server);
    defer conn.deinit();
    conn.cbs = rec.cbs();
    conn.localSettings.qpackMaxTableCapacity = 4096;
    var mq = MockQuic.init(a);
    defer mq.deinit();
    try conn.sendControl(&mq, 100); // commits our decoder sizing

    var penc = qpackMod.Encoder.init(a);
    defer penc.deinit();
    penc.setMaxTableCapacity(4096);
    penc.beginSection();
    var f1 = std.ArrayList(u8).empty;
    defer f1.deinit(a);
    try penc.encodeField(&f1, ":method", "GET");
    try penc.encodeField(&f1, ":scheme", "https");
    try penc.encodeField(&f1, ":authority", "example.com");
    try penc.encodeField(&f1, ":path", "/one");
    try penc.encodeField(&f1, "x-n", "v1");
    const ric1 = penc.sectionRic();
    var s1 = std.ArrayList(u8).empty;
    defer s1.deinit(a);
    try penc.encodePrefix(&s1, ric1, ric1);
    try s1.appendSlice(a, f1.items);
    penc.beginSection();
    var f2 = std.ArrayList(u8).empty;
    defer f2.deinit(a);
    try penc.encodeField(&f2, ":method", "GET");
    try penc.encodeField(&f2, ":scheme", "https");
    try penc.encodeField(&f2, ":authority", "example.com");
    try penc.encodeField(&f2, ":path", "/two");
    try penc.encodeField(&f2, "x-n", "v1");
    const ric2 = penc.sectionRic();
    var s2 = std.ArrayList(u8).empty;
    defer s2.deinit(a);
    try penc.encodePrefix(&s2, ric2, ric2);
    try s2.appendSlice(a, f2.items);
    const encBytes = try penc.takeEncoderBytes();
    defer a.free(encBytes);

    var ewire = std.ArrayList(u8).empty;
    defer ewire.deinit(a);
    try ewire.append(a, 0x02);
    try ewire.appendSlice(a, encBytes);
    try conn.feedQuic(6, ewire.items, false);

    const wrap = struct {
        fn f(a2: Allocator, section: []const u8) ![]u8 {
            var out = std.ArrayList(u8).empty;
            errdefer out.deinit(a2);
            var fh: [16]u8 = undefined;
            const n = try frameMod.encodeFrameHeader(&fh, 0x1, section.len);
            try out.appendSlice(a2, fh[0..n]);
            try out.appendSlice(a2, section);
            return out.toOwnedSlice(a2);
        }
    };
    const w1 = try wrap.f(a, s1.items);
    defer a.free(w1);
    const w2 = try wrap.f(a, s2.items);
    defer a.free(w2);
    try conn.feedQuic(0, w1, true);
    try conn.feedQuic(4, w2, true);
    try std.testing.expectEqual(@as(usize, 2), rec.headers);
    try std.testing.expectEqual(@as(usize, 2), rec.ends);
    const ack = try conn.drainDecoderAcks();
    defer a.free(ack);
    // One SectionAck per dynamic section, hash-map order: {0x80} for
    // stream 0 and {0x84} for stream 4 (7-bit prefix holds small IDs).
    try std.testing.expectEqual(@as(usize, 2), ack.len);
    var saw80 = false;
    var saw84 = false;
    for (ack) |b| {
        if (b == 0x80) saw80 = true;
        if (b == 0x84) saw84 = true;
    }
    try std.testing.expect(saw80 and saw84);
}

test "h3conn blocked streams retry together" {
    const a = std.testing.allocator;
    var rec = ConnRec{};
    var conn = Connection.init(a, .server);
    defer conn.deinit();
    conn.cbs = rec.cbs();
    conn.localSettings.qpackMaxTableCapacity = 4096;
    var mq = MockQuic.init(a);
    defer mq.deinit();
    try conn.sendControl(&mq, 100);

    var penc = qpackMod.Encoder.init(a);
    defer penc.deinit();
    penc.setMaxTableCapacity(4096);
    penc.beginSection();
    var f1 = std.ArrayList(u8).empty;
    defer f1.deinit(a);
    try penc.encodeField(&f1, ":method", "GET");
    try penc.encodeField(&f1, ":scheme", "https");
    try penc.encodeField(&f1, ":authority", "example.com");
    try penc.encodeField(&f1, ":path", "/a");
    try penc.encodeField(&f1, "x-b", "1");
    const ric = penc.sectionRic();
    var s1 = std.ArrayList(u8).empty;
    defer s1.deinit(a);
    try penc.encodePrefix(&s1, ric, ric);
    try s1.appendSlice(a, f1.items);
    const encBytes = try penc.takeEncoderBytes();
    defer a.free(encBytes);

    var hfb: [16]u8 = undefined;
    const hn = try frameMod.encodeFrameHeader(&hfb, 0x1, s1.items.len);
    var wire = std.ArrayList(u8).empty;
    defer wire.deinit(a);
    try wire.appendSlice(a, hfb[0..hn]);
    try wire.appendSlice(a, s1.items);
    // Same dynamic section on two streams before any encoder bytes.
    try conn.feedQuic(0, wire.items, false);
    try conn.feedQuic(4, wire.items, false);
    try std.testing.expectEqual(@as(usize, 0), rec.headers);

    var ewire = std.ArrayList(u8).empty;
    defer ewire.deinit(a);
    try ewire.append(a, 0x02);
    try ewire.appendSlice(a, encBytes);
    try conn.feedQuic(6, ewire.items, false);
    conn.retryBlockedStreams();
    try std.testing.expectEqual(@as(usize, 2), rec.headers);
}

test "h3conn enforces the advertised qpack blocked stream limit" {
    const a = std.testing.allocator;
    var conn = Connection.init(a, .server);
    defer conn.deinit();
    conn.localSettings.qpackMaxTableCapacity = 4096;
    conn.localSettings.qpackBlockedStreams = 1;
    var mq = MockQuic.init(a);
    defer mq.deinit();
    try conn.sendControl(&mq, 100);

    var penc = qpackMod.Encoder.init(a);
    defer penc.deinit();
    penc.setMaxTableCapacity(4096);
    penc.beginSection();
    var fields = std.ArrayList(u8).empty;
    defer fields.deinit(a);
    try penc.encodeField(&fields, ":method", "GET");
    try penc.encodeField(&fields, ":scheme", "https");
    try penc.encodeField(&fields, ":authority", "example.com");
    try penc.encodeField(&fields, ":path", "/");
    try penc.encodeField(&fields, "x-blocked", "1");
    const ric = penc.sectionRic();
    var section = std.ArrayList(u8).empty;
    defer section.deinit(a);
    try penc.encodePrefix(&section, ric, ric);
    try section.appendSlice(a, fields.items);

    var hfb: [16]u8 = undefined;
    const hn = try frameMod.encodeFrameHeader(&hfb, 0x1, section.items.len);
    var wire = std.ArrayList(u8).empty;
    defer wire.deinit(a);
    try wire.appendSlice(a, hfb[0..hn]);
    try wire.appendSlice(a, section.items);

    try conn.feedQuic(0, wire.items, false);
    try std.testing.expect(conn.fatalError == null);
    try conn.feedQuic(4, wire.items, false);
    try std.testing.expectEqual(frameMod.H3Error.qpackGeneralError, conn.takeFatalError().?);
}

test "h3conn closing a critical stream is fatal" {
    const a = std.testing.allocator;
    var conn = Connection.init(a, .server);
    defer conn.deinit();
    const ctrl = try conn.buildControlStream();
    defer a.free(ctrl);
    try conn.feedQuic(2, ctrl, true);
    try std.testing.expectEqual(frameMod.H3Error.closedCriticalStream, conn.takeFatalError().?);
}

test "settings frame structure" {
    const a = std.testing.allocator;
    const entries = [_]frameMod.SettingEntry{
        .{ .id = 0x6, .value = 16384 }, // maxFieldSectionSize
    };
    const f = try buildSettingsFrame(a, &entries);
    defer a.free(f);

    // First byte: control stream type varint
    try std.testing.expectEqual(@as(u8, 0x00), f[0]);
    // Second byte: settings frame type
    try std.testing.expectEqual(@as(u8, 0x04), f[1]);
}

test "connection deinit releases qpack dynamic tables" {
    const a = std.testing.allocator;
    var c = Connection.init(a, .client);
    c.qenc.setMaxTableCapacity(256);
    c.qdec.setMaxTableCapacity(256);
    _ = try c.qenc.dyn.?.insert(a, "x-test", "encoder");
    _ = try c.qdec.dyn.?.insert(a, "x-test", "decoder");
    c.deinit();
}

test "qpack capacity changes release the previous table" {
    const a = std.testing.allocator;
    var c = Connection.init(a, .client);
    c.qenc.setMaxTableCapacity(256);
    c.qdec.setMaxTableCapacity(256);
    _ = try c.qenc.dyn.?.insert(a, "x-old", "encoder");
    _ = try c.qdec.dyn.?.insert(a, "x-old", "decoder");
    c.qenc.setMaxTableCapacity(512);
    c.qdec.setMaxTableCapacity(512);
    c.qenc.setMaxTableCapacity(0);
    c.qdec.setMaxTableCapacity(0);
    c.deinit();
}

test "request stream builds valid HEADERS + DATA" {
    const a = std.testing.allocator;
    var qenc = qpackMod.Encoder.init(a);
    defer qenc.deinit();
    var rs = RequestStream{
        .id = 4,
        .allocator = a,
        .qpack = &qenc,
    };

    const hdrs = [_]qpackMod.FieldLine{
        .{ .name = "content-type", .value = "text/plain" },
    };
    const headFrame = try rs.buildResponseHeaders(200, &hdrs);
    defer a.free(headFrame);

    // Frame type should be HEADERS (0x01)
    try std.testing.expectEqual(@as(u8, 0x01), headFrame[0]);
    var frameOffset: usize = 0;
    const headerFrame = try frameMod.parseFrame(headFrame, &frameOffset);
    var decoder = qpackMod.Decoder.init(a);
    const decoded = try decoder.decodeSectionCounted(headerFrame.payload, 0, null);
    defer decoder.freeFields(decoded);
    try std.testing.expectEqual(@as(usize, 2), decoded.len);
    try std.testing.expectEqualStrings(":status", decoded[0].name);
    try std.testing.expectEqualStrings("200", decoded[0].value);

    const dataFrame = try rs.buildData("hello");
    defer a.free(dataFrame);
    try std.testing.expectEqual(@as(u8, 0x00), dataFrame[0]); // DATA
    try std.testing.expectEqual(@as(u8, 'h'), dataFrame[dataFrame.len - 5]);
}

test "request stream builds decodable request headers" {
    const a = std.testing.allocator;
    var qenc = qpackMod.Encoder.init(a);
    defer qenc.deinit();
    var rs = RequestStream{ .id = 0, .allocator = a, .qpack = &qenc };
    const headers = [_]qpackMod.FieldLine{.{ .name = "user-agent", .value = "httpx" }};
    const encoded = try rs.buildRequestHeaders("GET", "https", "example.test", "/", &headers);
    defer a.free(encoded);

    var offset: usize = 0;
    const frame = try frameMod.parseFrame(encoded, &offset);
    var dec = qpackMod.Decoder.init(a);
    const fields = try dec.decodeSectionCounted(frame.payload, 0, null);
    defer dec.freeFields(fields);
    try std.testing.expectEqual(@as(usize, 5), fields.len);
    try std.testing.expectEqualStrings(":method", fields[0].name);
    try std.testing.expectEqualStrings("GET", fields[0].value);
    try std.testing.expectEqualStrings(":path", fields[3].name);
}

test "connection builds and processes settings" {
    const a = std.testing.allocator;
    var conn = Connection.init(a, .client);
    defer conn.deinit();

    // Build control stream
    const ctrl = try conn.buildControlStream();
    defer a.free(ctrl);

    // First byte should be control stream type 0x00
    try std.testing.expectEqual(@as(u8, 0x00), ctrl[0]);

    // Process peer settings
    const entries = [_]frameMod.SettingEntry{
        .{ .id = 0x6, .value = 8192 },
        .{ .id = 0x7, .value = 100 },
    };
    try conn.processPeerSettings(&entries);
    try std.testing.expectEqual(@as(u64, 8192), conn.peerSettings.maxFieldSectionSize);
    try std.testing.expectEqual(@as(u64, 100), conn.peerSettings.qpackBlockedStreams);
}

test "http3 rejects duplicate and forbidden settings" {
    const a = std.testing.allocator;
    var duplicate = Connection.init(a, .client);
    defer duplicate.deinit();
    const dup = [_]frameMod.SettingEntry{
        .{ .id = 0x6, .value = 8192 },
        .{ .id = 0x6, .value = 4096 },
    };
    try std.testing.expectError(Error.InvalidSettings, duplicate.processPeerSettings(&dup));

    var forbidden = Connection.init(a, .client);
    defer forbidden.deinit();
    const enablePush = [_]frameMod.SettingEntry{.{ .id = 0x2, .value = 0 }};
    try std.testing.expectError(Error.InvalidSettings, forbidden.processPeerSettings(&enablePush));
}

test "http3 control stream rejects request frames and accepts settings" {
    const a = std.testing.allocator;
    var c = Connection.init(a, .server);
    defer c.deinit();
    try std.testing.expectError(Error.InvalidSettings, c.processControlFrame(0x0, ""));

    const entries = [_]frameMod.SettingEntry{.{ .id = 0x6, .value = 4096 }};
    const encoded = try frameMod.buildSettingsPayload(a, &entries);
    defer a.free(encoded);
    try c.processControlFrame(0x4, encoded);
    try std.testing.expect(c.settingsReceived);
    try std.testing.expectError(Error.InvalidSettings, c.processControlFrame(0x4, encoded));
}

test "http3 goaway validates role and client stream parity" {
    const a = std.testing.allocator;
    const entries = [_]frameMod.SettingEntry{.{ .id = 0x6, .value = 4096 }};
    const encoded = try frameMod.buildSettingsPayload(a, &entries);
    defer a.free(encoded);

    var vb: [8]u8 = undefined;

    var client = Connection.init(a, .client);
    defer client.deinit();
    try client.processControlFrame(0x4, encoded);
    const bad = try varint.encode(&vb, 1);
    try std.testing.expectError(Error.ProtocolViolation, client.processControlFrame(0x7, vb[0..bad]));
    try std.testing.expectEqual(frameMod.H3Error.idError, client.controlError.?);
    const ok = try varint.encode(&vb, 0);
    try client.processControlFrame(0x7, vb[0..ok]);
    try std.testing.expect(client.goawayReceived);
    const regress = try varint.encode(&vb, 4);
    try std.testing.expectError(Error.ProtocolViolation, client.processControlFrame(0x7, vb[0..regress]));

    var server = Connection.init(a, .server);
    defer server.deinit();
    try server.processControlFrame(0x4, encoded);
    try std.testing.expectError(Error.ProtocolViolation, server.processControlFrame(0x7, vb[0..ok]));
    try std.testing.expectEqual(frameMod.H3Error.frameUnexpected, server.controlError.?);
}

test "http3 client rejects server-only control frames" {
    const a = std.testing.allocator;
    const entries = [_]frameMod.SettingEntry{.{ .id = 0x6, .value = 4096 }};
    const encoded = try frameMod.buildSettingsPayload(a, &entries);
    defer a.free(encoded);

    var c = Connection.init(a, .client);
    defer c.deinit();
    try c.processControlFrame(0x4, encoded);
    var vb: [8]u8 = undefined;
    const n = try varint.encode(&vb, 0);
    try std.testing.expectError(Error.ProtocolViolation, c.processControlFrame(0x3, vb[0..n]));
    try std.testing.expectEqual(frameMod.H3Error.frameUnexpected, c.controlError.?);
}

test "connection allocates stream IDs" {
    const a = std.testing.allocator;
    var conn = Connection.init(a, .client);
    defer conn.deinit();

    const s0 = conn.nextBidiStreamId();
    const s1 = conn.nextBidiStreamId();
    const s2 = conn.nextUniStreamId();
    try std.testing.expectEqual(@as(u64, 0), s0);
    try std.testing.expectEqual(@as(u64, 4), s1);
    try std.testing.expectEqual(@as(u64, 2), s2);
    try std.testing.expect((s0 & 3) == 0 and (s2 & 3) == 2);

    var server = Connection.init(a, .server);
    defer server.deinit();
    try std.testing.expectEqual(@as(u64, 1), server.nextBidiStreamId());
    try std.testing.expectEqual(@as(u64, 3), server.nextUniStreamId());
}
