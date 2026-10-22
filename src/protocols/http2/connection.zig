//! HTTP/2 connection engine (RFC 9113) with its own session state machine:
//! preface validation, SETTINGS exchange with ACK tracking, CONTINUATION
//! assembly, complete flow-control accounting, GOAWAY graceful shutdown,
//! PING keepalive, and strict error escalation.
//!
//! I/O model: feed() accepts arbitrary network chunks; outbound frames
//! accumulate in `outbound` which the owner flushes to the wire. Protocol
//! violations queue a terminating GOAWAY and surface as a returned error.
//!
//! References:
//!   - RFC 9113 Section 2 — HTTP/2 Connection Preface
//!   - RFC 9113 Section 4 — Frames (frame format, flags)
//!   - RFC 9113 Section 5 — Streams (stream lifecycle, dependencies)
//!   - RFC 9113 Section 5.3 — Stream Priority
//!   - RFC 9113 Section 5.4 — Error Handling (GOAWAY, RST_STREAM)
//!   - RFC 9113 Section 6 — Frame Definitions (DATA, HEADERS, SETTINGS, etc.)
//!   - RFC 9113 Section 7 — HTTP/2 Error Codes
//!   - RFC 9113 Section 8.1 — Field Name Requirements (lowercase)
//!   - RFC 7541 — HPACK: Header Compression for HTTP/2

const std = @import("std");
const Allocator = std.mem.Allocator;
const frameMod = @import("frame.zig");
const hpackMod = @import("hpack.zig");
const streamMod = @import("stream.zig");

const FrameHeader = frameMod.FrameHeader;
const FrameType = frameMod.FrameType;
const Flags = frameMod.Flags;
const Stream = streamMod.Stream;
const ErrorCode = streamMod.ErrorCode;

pub const Error = frameMod.Error || hpackMod.Error || streamMod.Stream.RecvError || error{
    ProtocolViolation,
    FlowControlError,
    CompressionError,
    FrameSizeExceeded,
    StreamClosed,
    HeaderListTooLarge,
    MaxConcurrentStreams,
    OutOfMemory,
};

pub const DEFAULT_HEADER_TABLE_SIZE: u32 = 4096;
pub const DEFAULT_MAX_CONCURRENT: u32 = 100;
pub const DEFAULT_INITIAL_WINDOW: u32 = 65535;
/// Finite decoded header-list budget applied to both complete and continued
/// field blocks. This also bounds wire bytes retained before HPACK decoding.
pub const DEFAULT_MAX_HEADER_LIST: u32 = 64 * 1024;
/// Independent cap for encoded HEADERS plus CONTINUATION bytes retained
/// before HPACK decoding. SETTINGS_MAX_HEADER_LIST_SIZE covers decoded size.
pub const DEFAULT_MAX_HEADER_BLOCK_BYTES: usize = 256 * 1024;
/// The connection-level flow-control window is fixed at 65535 and is not
/// affected by SETTINGS_INITIAL_WINDOW_SIZE (RFC 9113 Section 6.9.2).
pub const DEFAULT_CONNECTION_WINDOW: i64 = 65535;

/// One direction of SETTINGS.
pub const Settings = struct {
    headerTableSize: u32 = DEFAULT_HEADER_TABLE_SIZE,
    enablePush: u32 = 1,
    maxConcurrentStreams: u32 = DEFAULT_MAX_CONCURRENT,
    initialWindowSize: u32 = DEFAULT_INITIAL_WINDOW,
    maxFrameSize: u32 = frameMod.DEFAULT_MAX_FRAME_SIZE,
    maxHeaderListSize: u32 = DEFAULT_MAX_HEADER_LIST,

    pub fn entries(self: *const Settings) [6]frameMod.SettingEntry {
        return .{
            .{ .id = @backingInt(frameMod.SettingsId.headerTableSize), .value = self.headerTableSize },
            .{ .id = @backingInt(frameMod.SettingsId.enablePush), .value = self.enablePush },
            .{ .id = @backingInt(frameMod.SettingsId.maxConcurrentStreams), .value = self.maxConcurrentStreams },
            .{ .id = @backingInt(frameMod.SettingsId.initialWindowSize), .value = self.initialWindowSize },
            .{ .id = @backingInt(frameMod.SettingsId.maxFrameSize), .value = self.maxFrameSize },
            .{ .id = @backingInt(frameMod.SettingsId.maxHeaderListSize), .value = self.maxHeaderListSize },
        };
    }
};

// Callbacks

pub const Callbacks = struct {
    ctx: ?*anyopaque = null,
    /// Complete header list decoded for `sid`.
    onHeaders: ?*const fn (ctx: ?*anyopaque, sid: u31, fields: []hpackMod.HeaderField, endStream: bool) anyerror!void = null,
    /// DATA payload chunk (already de-padded).
    onData: ?*const fn (ctx: ?*anyopaque, sid: u31, data: []const u8) anyerror!void = null,
    /// Stream fully consumed our side (END_STREAM received).
    onStreamEnd: ?*const fn (ctx: ?*anyopaque, sid: u31) anyerror!void = null,
    onReset: ?*const fn (ctx: ?*anyopaque, sid: u31, code: u32) void = null,
    onPingAck: ?*const fn (ctx: ?*anyopaque, opaqueData: [8]u8) void = null,
    onGoaway: ?*const fn (ctx: ?*anyopaque, lastSid: u31, code: u32, debug: []const u8) void = null,
};

// Session

pub const Role = enum { client, server };

pub const Session = struct {
    allocator: Allocator,
    role: Role,
    cbs: Callbacks = .{},

    // Inbound reassembly.
    inbuf: std.ArrayList(u8) = .empty,
    prefaceDone: bool = false,
    /// When set, ONLY CONTINUATION frames for this stream are legal next.
    continuationSid: ?u31 = null,
    continuationStream: ?*Stream = null,
    /// Error code to apply after a discarded block's CONTINUATION chain.
    continuationRefuse: ?ErrorCode = null,

    // HPACK contexts (connection-wide).
    hdec: hpackMod.Decoder,
    henc: hpackMod.Encoder,

    streams: std.AutoHashMap(u31, *Stream),
    /// Peer-initiated streams currently open (server role).
    activePeerStreams: usize = 0,
    /// Locally initiated streams currently open (client role).
    activeLocalStreams: usize = 0,

    localSettings: Settings = .{},
    peerSettings: Settings = .{},
    settingsAcked: bool = false,
    /// The first frame of a connection must be SETTINGS (RFC 9113 3.4).
    receivedFirstSettings: bool = false,
    handshakeStarted: bool = false,

    nextStreamId: u32 = 1,
    largestPeerStream: u31 = 0,
    largestLocalStream: u31 = 0,

    connSendWindow: i64 = DEFAULT_CONNECTION_WINDOW,
    connRecvWindow: i64 = DEFAULT_CONNECTION_WINDOW,
    connRecvPending: i64 = 0,

    goawaySent: bool = false,
    goawayLastSidSent: u31 = 0x7FFFFFFF,
    goawayReceived: bool = false,
    closed: bool = false,
    awaitingSettingsAck: bool = false,

    /// END_STREAM flag carried by an in-progress HEADERS/CONTINUATION chain.
    continuationEndStream: bool = false,
    maxHeaderBlockBytes: usize = DEFAULT_MAX_HEADER_BLOCK_BYTES,
    /// Last stream ID accepted by the peer's most recent GOAWAY.
    goawayLastStream: ?u31 = null,

    outbound: std.ArrayList(u8) = .empty,

    pub fn init(allocator: Allocator, role: Role, cbs: Callbacks) !Session {
        var s = Session{
            .allocator = allocator,
            .role = role,
            .cbs = cbs,
            .hdec = undefined,
            .henc = undefined,
            .streams = std.AutoHashMap(u31, *Stream).init(allocator),
        };
        // A client disables server push: PUSH_PROMISE is not implemented,
        // so advertising ENABLE_PUSH=0 keeps peers from sending one.
        if (role == .client) s.localSettings.enablePush = 0;
        s.hdec = hpackMod.Decoder.init(allocator);
        s.hdec.maxHeaderList = s.localSettings.maxHeaderListSize;
        s.hdec.setProtocolMaxSize(s.localSettings.headerTableSize);
        s.henc = hpackMod.Encoder.init(allocator);
        return s;
    }

    pub fn deinit(self: *Session) void {
        var it = self.streams.valueIterator();
        while (it.next()) |sp| {
            sp.*.deinit();
            self.allocator.destroy(sp.*);
        }
        self.streams.deinit();
        self.hdec.deinit();
        self.henc.deinit();
        self.inbuf.deinit(self.allocator);
        self.outbound.deinit(self.allocator);
    }

    /// Client: emit magic + initial SETTINGS. Server: initial SETTINGS.
    pub fn startHandshake(self: *Session) !void {
        if (self.handshakeStarted) return Error.ProtocolViolation;
        self.handshakeStarted = true;
        // Reflect any local SETTINGS changed between init and the handshake.
        self.hdec.maxHeaderList = self.localSettings.maxHeaderListSize;
        self.hdec.setProtocolMaxSize(self.localSettings.headerTableSize);
        if (self.role == .client) {
            try self.outbound.appendSlice(self.allocator, frameMod.CONNECTION_PREFACE);
        }
        try self.sendInitialSettings();
    }

    fn sendInitialSettings(self: *Session) !void {
        // A server MUST NOT send ENABLE_PUSH (RFC 9113 Section 6.5.2);
        // a client sends it to disable server push.
        var es: [6]frameMod.SettingEntry = undefined;
        var n: usize = 0;
        for (self.localSettings.entries()) |e| {
            if (self.role == .server and e.id == @backingInt(frameMod.SettingsId.enablePush)) continue;
            es[n] = e;
            n += 1;
        }
        try frameMod.writeSettings(&self.outbound, self.allocator, es[0..n]);
        self.awaitingSettingsAck = true;
    }

    /// Stable stream pointer lookup (map stores heap-allocated streams).
    fn streamPtr(self: *Session, sid: u31) ?*Stream {
        if (self.streams.getPtr(sid)) |pp| return pp.*;
        return null;
    }

    /// Feeds network bytes; processes every complete frame contained.
    pub fn feed(self: *Session, data: []const u8) Error!void {
        try self.inbuf.appendSlice(self.allocator, data);

        if (!self.prefaceDone) {
            if (self.role == .server) {
                try self.consumePreface();
                if (!self.prefaceDone) return;
            } else {
                // Clients sent the magic themselves; peer sends SETTINGS.
                self.prefaceDone = true;
            }
        }

        while (true) {
            if (self.inbuf.items.len < frameMod.FRAME_HEADER_SIZE) return;
            var hdrBytes: [9]u8 = undefined;
            @memcpy(&hdrBytes, self.inbuf.items[0..9]);
            const hdr = FrameHeader.parse(&hdrBytes);

            if (@as(usize, hdr.length) > self.localSettings.maxFrameSize) {
                return self.connError(.frameSizeError);
            }

            const total = 9 + @as(usize, hdr.length);
            if (self.inbuf.items.len < total) return;

            const payload = self.inbuf.items[9..total];

            // RFC 9113 Section 3.4: the first frame of a connection MUST
            // be SETTINGS. Anything else is a connection error.
            if (!self.receivedFirstSettings) {
                if (hdr.frameType != .settings or hdr.hasAck()) {
                    return self.connError(.protocolError);
                }
                self.receivedFirstSettings = true;
            }

            // Stream-id legality up front.
            switch (hdr.frameType) {
                .data, .headers, .priority, .rstStream, .continuation, .pushPromise => {
                    if (hdr.streamId == 0) return self.connError(.protocolError);
                },
                .settings, .ping, .goaway => {
                    if (hdr.streamId != 0) return self.connError(.protocolError);
                },
                else => {},
            }

            // CONTINUATION exclusivity rule.
            if (self.continuationSid != null) {
                if (hdr.frameType != .continuation or hdr.streamId != self.continuationSid.?) {
                    return self.connError(.protocolError);
                }
            } else if (hdr.frameType == .continuation) {
                return self.connError(.protocolError);
            }

            const parsed = frameMod.Frame.parse(hdr, payload, self.allocator) catch |e| switch (e) {
                error.OutOfMemory => return Error.OutOfMemory,
                // Frame size violations map to FRAME_SIZE_ERROR; all other
                // parse failures (bad stream id, bad payload) are PROTOCOL_ERROR.
                error.FrameTooLarge, error.FrameSizeError => return self.connError(.frameSizeError),
                error.StreamFrameSizeError => {
                    if (self.streamPtr(hdr.streamId) != null) {
                        try self.resetStream(hdr.streamId, .frameSizeError);
                    }
                    return self.consumeInvalidFrame(hdr);
                },
                error.StreamProtocolError => {
                    if (self.streamPtr(hdr.streamId) != null) {
                        try self.resetStream(hdr.streamId, .protocolError);
                    }
                    return self.consumeInvalidFrame(hdr);
                },
                else => return self.connError(.protocolError),
            };
            defer if (!hdr.hasAck() and parsed == .settings) {
                self.allocator.free(parsed.settings);
            };

            try self.handleFrame(hdr, parsed);

            // Consume processed bytes.
            const n = total;
            std.mem.copyForwards(u8, self.inbuf.items[0 .. self.inbuf.items.len - n], self.inbuf.items[n..]);
            self.inbuf.shrinkRetainingCapacity(self.inbuf.items.len - n);

            if (self.closed) return;
        }
    }

    fn consumeInvalidFrame(self: *Session, hdr: FrameHeader) Error!void {
        const n = 9 + @as(usize, hdr.length);
        std.mem.copyForwards(u8, self.inbuf.items[0 .. self.inbuf.items.len - n], self.inbuf.items[n..]);
        self.inbuf.shrinkRetainingCapacity(self.inbuf.items.len - n);
    }

    fn consumePreface(self: *Session) Error!void {
        const want = frameMod.CONNECTION_PREFACE.len;
        const buf = self.inbuf.items;
        const cmpLen = @min(buf.len, want);
        if (!std.mem.eql(u8, buf[0..cmpLen], frameMod.CONNECTION_PREFACE[0..cmpLen])) {
            return Error.ProtocolViolation;
        }
        if (buf.len < want) return;
        // Consume the preface bytes so frame parsing starts at offset 0.
        std.mem.copyForwards(u8, buf[0 .. buf.len - want], buf[want..]);
        self.inbuf.shrinkRetainingCapacity(buf.len - want);
        self.prefaceDone = true;
    }

    fn handleFrame(self: *Session, hdr: FrameHeader, f: frameMod.Frame) Error!void {
        switch (f) {
            .settings => |entries| {
                if (hdr.hasAck()) {
                    if (!self.awaitingSettingsAck) return self.connError(.protocolError);
                    self.awaitingSettingsAck = false;
                    self.settingsAcked = true;
                    return;
                }
                try self.applyPeerSettings(entries);
                try frameMod.writeSettingsAck(&self.outbound, self.allocator);
            },
            .headers => |h| try self.handleHeadersStart(hdr.streamId, h.block, h.endHeaders, h.endStream, h.selfDependency),
            .continuation => |c| try self.handleContinuation(hdr.streamId, c.block, c.endHeaders),
            .data => |d| try self.handleData(hdr.streamId, d.flowLen, d.data, d.endStream),
            .rstStream => |r| {
                if (self.streamPtr(hdr.streamId)) |st| {
                    st.onRecvRst();
                    if (self.cbs.onReset) |cb| cb(self.cbs.ctx, hdr.streamId, r.errorCode);
                    // A reset stream pending CONTINUATIONs must not leave
                    // a dangling reassembly pointer behind.
                    if (self.continuationStream) |cs| {
                        if (cs.id == hdr.streamId) {
                            self.continuationStream = null;
                            self.continuationSid = null;
                        }
                    }
                    try self.removeStream(hdr.streamId);
                } else if (!self.isKnownStreamId(hdr.streamId)) {
                    // RST_STREAM cannot create a stream. On an idle stream
                    // it is a connection-level PROTOCOL_ERROR (RFC 9113 5.4.1).
                    return self.connError(.protocolError);
                }
                // RST_STREAM for a closed stream is ignored.
            },
            .windowUpdate => |w| try self.handleWindowUpdate(hdr.streamId, w.increment),
            .ping => |p| {
                if (!hdr.hasAck()) {
                    try frameMod.writePing(&self.outbound, self.allocator, true, p.opaqueData);
                } else if (self.cbs.onPingAck) |cb| {
                    cb(self.cbs.ctx, p.opaqueData);
                }
            },
            .goaway => |g| {
                self.goawayReceived = true;
                if (self.goawayLastStream) |previous| {
                    self.goawayLastStream = @min(previous, g.lastStreamId);
                } else {
                    self.goawayLastStream = g.lastStreamId;
                }
                // A GOAWAY from a server only refuses client-initiated
                // streams above its last-stream-id. Server-local (push)
                // streams are unaffected; this implementation never opens
                // them. Collect first because removal invalidates iterators.
                if (self.role == .client) {
                    var refused = std.ArrayList(u31).empty;
                    defer refused.deinit(self.allocator);
                    var it = self.streams.valueIterator();
                    while (it.next()) |sp| {
                        if (sp.*.id > g.lastStreamId) {
                            sp.*.onRecvRst();
                            if (self.cbs.onReset) |cb| cb(self.cbs.ctx, sp.*.id, @backingInt(ErrorCode.refusedStream));
                            refused.append(self.allocator, sp.*.id) catch return Error.OutOfMemory;
                        }
                    }
                    for (refused.items) |sid| self.removeStream(sid) catch {};
                }
                if (self.cbs.onGoaway) |cb| cb(self.cbs.ctx, g.lastStreamId, g.errorCode, g.debugData);
            },
            .priority => {
                // Priority tolerated and ignored (RFC 9113 Section 5.3, deprecated).
            },
            .pushPromise => {
                // Server receiving PUSH_PROMISE from client is always a
                // connection error; client may receive it only if push is
                // enabled. Reserved states not yet fully implemented so
                // enabled push is tolerated and ignored.
                if (self.role == .server) return self.connError(.protocolError);
                if (self.localSettings.enablePush == 0) return self.connError(.protocolError);
                return;
            },
            .unknown => {
                // Unknown extension frames are length-delimited and ignored
                // after parsing, per RFC 9113 Section 4.1.
            },
        }
    }

    fn applyPeerSettings(self: *Session, entries: []frameMod.SettingEntry) Error!void {
        // Settings are applied in the order they appear; a repeated
        // identifier replaces the previous value (RFC 9113 Section 6.5.3).
        for (entries) |e| {
            const sid: frameMod.SettingsId = @fromBackingInt(@intCast(e.id));
            if (frameMod.validateSetting(sid, e.value)) |code| {
                return self.connError(@fromBackingInt(@intCast(code)));
            }
            switch (sid) {
                .headerTableSize => {
                    self.peerSettings.headerTableSize = e.value;
                    self.henc.applySettingsSize(e.value);
                },
                .enablePush => {
                    // A server MUST NOT send ENABLE_PUSH; a client that
                    // receives it treats it as a connection error.
                    if (self.role == .client) return self.connError(.protocolError);
                    self.peerSettings.enablePush = e.value;
                },
                .maxConcurrentStreams => self.peerSettings.maxConcurrentStreams = e.value,
                .initialWindowSize => {
                    const delta = @as(i64, e.value) - @as(i64, self.peerSettings.initialWindowSize);
                    self.peerSettings.initialWindowSize = e.value;
                    if (delta != 0) {
                        var it = self.streams.valueIterator();
                        while (it.next()) |sp| {
                            sp.*.sendWindow += delta;
                            if (sp.*.sendWindow > frameMod.MAX_WINDOW) {
                                return self.connError(.flowControlError);
                            }
                        }
                    }
                },
                .maxFrameSize => self.peerSettings.maxFrameSize = e.value,
                .maxHeaderListSize => self.peerSettings.maxHeaderListSize = e.value,
                _ => {}, // unknown settings are ignored
            }
        }
    }

    /// Kind of header block being processed (RFC 9113 Section 8.3).
    const HeaderKind = enum { request, response, trailers };

    fn createStream(self: *Session, sid: u31) !*Stream {
        const s = try self.allocator.create(Stream);
        errdefer self.allocator.destroy(s);
        s.* = Stream.init(self.allocator, sid);
        // Flow-control windows come from the negotiated settings: the send
        // window follows the peer's INITIAL_WINDOW_SIZE, the receive window
        // follows ours (RFC 9113 Section 6.9.2).
        s.sendWindow = @intCast(self.peerSettings.initialWindowSize);
        s.recvWindow = @intCast(self.localSettings.initialWindowSize);
        try self.streams.put(sid, s);
        return s;
    }

    fn handleHeadersStart(self: *Session, sid: u31, block: []const u8, endHeaders: bool, endStream: bool, selfDependency: bool) Error!void {
        if (block.len > self.maxHeaderBlockBytes) return self.connError(.enhanceYourCalm);

        var st: *Stream = undefined;
        // A discarded block is still decoded: the HPACK context is
        // connection-wide, so skipping the decode would desynchronize it.
        var discard = false;
        var refuse: ?ErrorCode = null;

        if (self.streamPtr(sid)) |existing| {
            st = existing;
            if (existing.state == .closed) {
                discard = true;
                refuse = .streamClosed;
            }
        } else {
            switch (self.role) {
                .server => {
                    // Client-initiated streams use odd identifiers.
                    if (sid % 2 == 0) return self.connError(.protocolError);
                    if (sid <= self.largestPeerStream) {
                        // A lower identifier can only refer to a stream that
                        // already existed, so this is a stream error.
                        discard = true;
                        refuse = .streamClosed;
                    } else if (self.goawaySent or self.activePeerStreams >= self.localSettings.maxConcurrentStreams) {
                        // Refuse politely instead of killing the connection.
                        discard = true;
                        refuse = .refusedStream;
                    }
                    st = try self.createStream(sid);
                    self.largestPeerStream = @max(self.largestPeerStream, sid);
                    if (!discard) {
                        self.activePeerStreams += 1;
                        st.countedSlot = true;
                    }
                },
                .client => {
                    // Server-initiated streams require PUSH_PROMISE, which is
                    // not implemented (we advertise ENABLE_PUSH=0).
                    if (sid % 2 == 0) return self.connError(.protocolError);
                    if (self.streamPtr(sid) == null and sid > self.largestLocalStream) {
                        // A response for a stream this client never opened is
                        // a protocol error, not a stream error.
                        return self.connError(.protocolError);
                    }
                    discard = true;
                    refuse = .streamClosed;
                    st = try self.createStream(sid);
                },
            }
        }
        // A HEADERS priority section that depends on its own stream is a
        // stream error, but the block must still be decoded first: HPACK
        // state is connection-wide (RFC 9113 Section 4.3).
        if (selfDependency) {
            discard = true;
            if (refuse == null) refuse = .protocolError;
        }
        st.discardHeaders = discard;

        const kind: HeaderKind = if (st.headersRecv > 0) .trailers else switch (self.role) {
            .server => .request,
            .client => .response,
        };

        if (endHeaders) {
            try self.decodeAndDeliver(st, block, kind, endStream, !discard);
            if (discard) {
                if (refuse) |code| try self.resetStream(sid, code);
                self.removeStream(sid) catch {};
                return;
            }
            // The decode may have reset the stream (malformed header
            // list); re-resolve it before touching it.
            if (self.streamPtr(sid)) |after| {
                // A fully-received exchange (both sides ended) leaves no work.
                if (after.state == .closed) self.reapClosedStream(sid);
            }
        } else {
            // Header block continues in CONTINUATION frames.
            st.headerBlock = .empty;
            st.headerBlock.?.appendSlice(self.allocator, block) catch return Error.OutOfMemory;
            self.continuationSid = sid;
            self.continuationStream = st;
            self.continuationEndStream = endStream;
            self.continuationRefuse = refuse;
        }
    }

    fn handleContinuation(self: *Session, sid: u31, block: []const u8, endHeaders: bool) Error!void {
        const st = self.continuationStream orelse return self.connError(.protocolError);
        if (st.id != sid) return self.connError(.protocolError);
        const accumulated = st.headerBlock.?.items.len;
        if (block.len > self.maxHeaderBlockBytes -| accumulated) return self.connError(.enhanceYourCalm);
        st.headerBlock.?.appendSlice(self.allocator, block) catch return Error.OutOfMemory;
        if (!endHeaders) return;

        const endStream = self.continuationEndStream;
        const refuse = self.continuationRefuse;
        self.continuationSid = null;
        self.continuationStream = null;
        self.continuationRefuse = null;

        const kind: HeaderKind = if (st.headersRecv > 0) .trailers else switch (self.role) {
            .server => .request,
            .client => .response,
        };
        const discard = st.discardHeaders;

        try self.decodeAndDeliver(st, "", kind, endStream, !discard);
        if (discard) {
            if (refuse) |code| try self.resetStream(sid, code);
            self.removeStream(sid) catch {};
            return;
        }
        if (self.streamPtr(sid)) |after| {
            if (after.state == .closed) self.reapClosedStream(sid);
        }
    }

    fn decodeAndDeliver(self: *Session, st: *Stream, finalFrag: []const u8, kind: HeaderKind, endStream: bool, deliver: bool) Error!void {
        // Single-frame HEADERS have no chain buffer; multi-frame chains
        // accumulated their fragments already.
        var owned: ?[]u8 = null;
        defer if (owned) |b| self.allocator.free(b);
        var block: []const u8 = finalFrag;

        if (st.headerBlock != null) {
            if (finalFrag.len > 0) {
                st.headerBlock.?.appendSlice(self.allocator, finalFrag) catch return Error.OutOfMemory;
            }
            owned = st.headerBlock.?.toOwnedSlice(self.allocator) catch return Error.OutOfMemory;
            block = owned.?;
        }

        const res = self.hdec.decode(block) catch |e| switch (e) {
            error.HeaderTooLarge => return self.connError(.enhanceYourCalm),
            else => return self.connError(.compressionError),
        };
        defer {
            for (res.fields) |f| {
                self.allocator.free(f.name);
                self.allocator.free(f.value);
            }
            self.allocator.free(res.fields);
        }

        if (res.tooLarge) {
            // The block was fully decoded to keep the HPACK context in
            // sync; the oversized list is rejected as a stream error
            // (RFC 9113 Section 10.5.1).
            if (deliver) try self.resetStream(st.id, .enhanceYourCalm);
            return;
        }

        if (!deliver) return;

        // Malformed header lists are stream errors, not connection errors
        // (RFC 9113 Section 8.1.1).
        if (!validateHeaderList(res.fields, kind)) {
            try self.resetStream(st.id, .protocolError);
            return;
        }

        if (kind == .response and !st.finalResponse) {
            const status = parseStatus(res.fields) orelse {
                try self.resetStream(st.id, .protocolError);
                return;
            };
            if (status < 100 or status > 599 or status == 101) {
                try self.resetStream(st.id, .protocolError);
                return;
            }
            if (status < 200) {
                const cl = parseContentLength(res.fields) catch {
                    try self.resetStream(st.id, .protocolError);
                    return;
                };
                // Informational responses never carry content or END_STREAM;
                // multiple can precede the final response.
                if (endStream or cl != null) {
                    try self.resetStream(st.id, .protocolError);
                    return;
                }
                return;
            }
            const cl = parseContentLength(res.fields) catch {
                try self.resetStream(st.id, .protocolError);
                return;
            };
            if (status == 204 and cl != null) {
                try self.resetStream(st.id, .protocolError);
                return;
            }
            if (status == 205 and cl != null and cl.? != 0) {
                try self.resetStream(st.id, .protocolError);
                return;
            }
            st.finalResponse = true;
            st.responseStatus = status;
            st.contentLength = cl;
            st.bodyForbidden = st.requestIsHead or status == 204 or status == 304 or status == 205;
        } else if (kind == .request) {
            const method = fieldValue(res.fields, ":method") orelse {
                try self.resetStream(st.id, .protocolError);
                return;
            };
            if (fieldValue(res.fields, ":protocol") != null) {
                // We never enable SETTINGS_ENABLE_CONNECT_PROTOCOL.
                try self.resetStream(st.id, .protocolError);
                return;
            }
            st.requestIsHead = std.mem.eql(u8, method, "HEAD");
            st.requestIsConnect = std.mem.eql(u8, method, "CONNECT");
            st.contentLength = parseContentLength(res.fields) catch {
                try self.resetStream(st.id, .protocolError);
                return;
            };
        } else if (kind == .trailers) {
            if (!endStream or st.trailersRecv) {
                try self.resetStream(st.id, .protocolError);
                return;
            }
        }

        if (endStream and !bodyLengthSatisfied(st)) {
            try self.resetStream(st.id, .protocolError);
            return;
        }

        st.onRecvHeaders(endStream) catch |e| switch (e) {
            error.StreamClosed => {
                try self.resetStream(st.id, .streamClosed);
                return;
            },
            error.ProtocolError => {
                try self.resetStream(st.id, .protocolError);
                return;
            },
        };
        st.headersRecv += 1;
        if (kind == .trailers) st.trailersRecv = true;

        if (self.cbs.onHeaders) |cb| {
            cb(self.cbs.ctx, st.id, res.fields, endStream) catch {
                try self.resetStream(st.id, .internalError);
                return;
            };
        }
        if (endStream) {
            if (self.cbs.onStreamEnd) |cb| {
                cb(self.cbs.ctx, st.id) catch {
                    try self.resetStream(st.id, .internalError);
                    return;
                };
            }
        }
    }

    /// Sends RST_STREAM and tears the stream down locally. The connection
    /// stays usable (RFC 9113 Section 5.4.2).
    fn resetStream(self: *Session, sid: u31, code: ErrorCode) !void {
        if (self.streamPtr(sid)) |st| st.onSendRst();
        try frameMod.writeRstStream(&self.outbound, self.allocator, sid, @backingInt(code));
        self.reapClosedStream(sid);
    }

    /// RFC 9110 token characters, the only ones allowed in a field name.
    fn isTokenChar(c: u8) bool {
        return switch (c) {
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.' => true,
            '0'...'9' => true,
            'A'...'Z' => true,
            '^', '_', '`', '|', '~' => true,
            'a'...'z' => true,
            else => false,
        };
    }

    /// RFC 9110 field-value characters: visible ASCII, space, and HTAB.
    fn isFieldValueChar(c: u8) bool {
        return c == '\t' or (c >= 0x20 and c != 0x7F);
    }

    /// An HTTP method is a non-empty token (RFC 9110 Section 9.1).
    fn isTokenValue(value: []const u8) bool {
        if (value.len == 0) return false;
        for (value) |c| {
            if (!isTokenChar(c)) return false;
        }
        return true;
    }

    /// URI scheme syntax (RFC 3986 Section 3.1).
    fn isScheme(value: []const u8) bool {
        if (value.len == 0 or !std.ascii.isAlphabetic(value[0])) return false;
        for (value[1..]) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
        }
        return true;
    }

    /// Validates one decoded header list against the RFC 9113 rules for
    /// requests, responses, and trailers.
    pub fn validateHeaderList(fields: []const hpackMod.HeaderField, kind: HeaderKind) bool {
        var seenMethod = false;
        var seenPath = false;
        var seenScheme = false;
        var seenAuthority = false;
        var seenStatus = false;
        var seenProtocol = false;
        var seenRegular = false;
        var seenHost = false;
        var methodIsConnect = false;
        var pathValue: ?[]const u8 = null;
        var authorityValue: ?[]const u8 = null;
        var hostValue: ?[]const u8 = null;

        for (fields) |f| {
            if (f.name.len == 0) return false;

            // Field values may not contain NUL, CR, or LF (RFC 9113 8.2.3).
            for (f.value) |c| {
                if (!isFieldValueChar(c)) return false;
            }
            // Leading/trailing SP or HTAB is malformed in HTTP/2 field
            // values (RFC 9113 Section 8.2.1).
            if (f.value.len > 0 and
                (f.value[0] == ' ' or f.value[0] == '\t' or
                    f.value[f.value.len - 1] == ' ' or f.value[f.value.len - 1] == '\t'))
            {
                return false;
            }

            const isPseudo = f.name[0] == ':';
            if (isPseudo) {
                // Pseudo-headers MUST appear before regular header fields
                // and MUST be lowercase (RFC 9113 Section 8.3).
                if (seenRegular) return false;
                for (f.name[1..]) |c| {
                    if (std.ascii.isUpper(c)) return false;
                }
                if (kind == .trailers) return false; // trailers carry no pseudo-headers
                if (std.mem.eql(u8, f.name, ":method")) {
                    if (seenMethod or !isTokenValue(f.value)) return false;
                    seenMethod = true;
                    methodIsConnect = std.mem.eql(u8, f.value, "CONNECT");
                } else if (std.mem.eql(u8, f.name, ":path")) {
                    if (seenPath) return false;
                    seenPath = true;
                    pathValue = f.value;
                } else if (std.mem.eql(u8, f.name, ":scheme")) {
                    if (seenScheme or !isScheme(f.value)) return false;
                    seenScheme = true;
                } else if (std.mem.eql(u8, f.name, ":authority")) {
                    if (seenAuthority) return false;
                    seenAuthority = true;
                    // Userinfo is not part of :authority (RFC 9113 8.3.1).
                    if (std.mem.indexOfScalar(u8, f.value, '@') != null) return false;
                    authorityValue = f.value;
                } else if (std.mem.eql(u8, f.name, ":status")) {
                    if (seenStatus) return false;
                    seenStatus = true;
                } else if (std.mem.eql(u8, f.name, ":protocol")) {
                    if (seenProtocol) return false;
                    seenProtocol = true;
                } else {
                    return false; // unknown pseudo-header
                }
                if (f.value.len == 0) return false;
                if (std.mem.eql(u8, f.name, ":status")) {
                    if (f.value.len != 3) return false;
                    for (f.value) |c| {
                        if (!std.ascii.isDigit(c)) return false;
                    }
                }
            } else {
                // Regular field names: lowercase token characters only.
                for (f.name) |c| {
                    if (!isTokenChar(c)) return false;
                    if (std.ascii.isUpper(c)) return false;
                }
                // Connection-specific fields are forbidden (RFC 9113 8.2.2).
                if (std.mem.eql(u8, f.name, "connection") or
                    std.mem.eql(u8, f.name, "keep-alive") or
                    std.mem.eql(u8, f.name, "proxy-connection") or
                    std.mem.eql(u8, f.name, "transfer-encoding") or
                    std.mem.eql(u8, f.name, "upgrade"))
                {
                    return false;
                }
                if (std.mem.eql(u8, f.name, "te") and !std.ascii.eqlIgnoreCase(f.value, "trailers")) {
                    return false;
                }
                if (std.mem.eql(u8, f.name, "host")) {
                    if (seenHost) return false;
                    seenHost = true;
                    hostValue = f.value;
                }
                if (kind == .trailers and std.mem.eql(u8, f.name, "content-length")) return false;
                seenRegular = true;
            }
        }

        switch (kind) {
            .request => {
                if (!seenMethod) return false;
                if (seenStatus) return false;
                // :authority and Host must agree when both are present
                // (RFC 9113 Sections 8.3.1 and 8.3.2).
                if (authorityValue != null and hostValue != null and
                    !std.ascii.eqlIgnoreCase(authorityValue.?, hostValue.?))
                {
                    return false;
                }
                if (seenProtocol) {
                    // Extended CONNECT requires CONNECT and all four
                    // pseudo-headers (RFC 8441 Section 4).
                    if (!methodIsConnect) return false;
                    if (!seenScheme or !seenPath or !seenAuthority) return false;
                    const path = pathValue.?;
                    if (path.len == 0 or path[0] != '/') return false;
                } else if (methodIsConnect) {
                    // Plain CONNECT uses only :method and :authority.
                    if (!seenAuthority or seenScheme or seenPath) return false;
                } else {
                    if (!seenScheme or !seenPath) return false;
                    // Asterisk-form is the only path not starting with '/'
                    // (RFC 9113 Section 8.3.1).
                    const path = pathValue.?;
                    if (path.len == 0) return false;
                    if (path[0] != '/' and !std.mem.eql(u8, path, "*")) return false;
                }
            },
            .response => {
                if (!seenStatus) return false;
                if (seenMethod or seenPath or seenScheme or seenAuthority or seenProtocol) return false;
            },
            .trailers => {},
        }
        return true;
    }

    fn fieldValue(fields: []const hpackMod.HeaderField, name: []const u8) ?[]const u8 {
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, name)) return f.value;
        }
        return null;
    }

    const ContentLengthError = error{InvalidContentLength};

    fn parseContentLength(fields: []const hpackMod.HeaderField) ContentLengthError!?u64 {
        var result: ?u64 = null;
        for (fields) |f| {
            if (!std.mem.eql(u8, f.name, "content-length")) continue;
            if (f.value.len == 0) return error.InvalidContentLength;
            for (f.value) |c| {
                if (!std.ascii.isDigit(c)) return error.InvalidContentLength;
            }
            const n = std.fmt.parseInt(u64, f.value, 10) catch return error.InvalidContentLength;
            if (result) |previous| {
                if (previous != n) return error.InvalidContentLength;
            }
            result = n;
        }
        return result;
    }

    fn parseStatus(fields: []const hpackMod.HeaderField) ?u16 {
        const value = fieldValue(fields, ":status") orelse return null;
        return std.fmt.parseInt(u16, value, 10) catch null;
    }

    /// True when the received message body matches its declared framing.
    fn bodyLengthSatisfied(st: *const Stream) bool {
        if (st.contentLength) |cl| {
            if (st.bodyForbidden and (st.requestIsHead or st.responseStatus == 304)) {
                return st.bodyBytes == 0;
            }
            return st.bodyBytes == cl;
        }
        return !st.bodyForbidden or st.bodyBytes == 0;
    }

    /// True when the message body this endpoint sends matches its declared
    /// framing. HEAD and 304 responses may advertise a representation
    /// length without sending those bytes.
    fn outboundBodyLengthSatisfied(st: *const Stream) bool {
        if (st.sendContentLength) |cl| {
            if (st.sendBodyForbidden and (st.requestIsHead or st.responseStatus == 304)) {
                return st.bodyBytesSent == 0;
            }
            return st.bodyBytesSent == cl;
        }
        return !st.sendBodyForbidden or st.bodyBytesSent == 0;
    }

    /// True when the identifier belongs to a stream that existed at some
    /// point (so a frame for it is a stream error, not an idle-stream
    /// connection error).
    fn isKnownStreamId(self: *Session, sid: u31) bool {
        // Only identifiers that could have belonged to this endpoint's
        // peer are "known"; even identifiers were never opened because
        // server push is disabled (RFC 9113 Section 5.1.1).
        if (sid % 2 == 0) return false;
        return switch (self.role) {
            .server => sid <= self.largestPeerStream,
            .client => sid <= self.largestLocalStream,
        };
    }

    fn handleData(self: *Session, sid: u31, flowLen: usize, data: []const u8, endStream: bool) Error!void {
        // Connection-level flow control always applies and counts the whole
        // payload, including the Pad Length field and trailing padding
        // (RFC 9113 Sections 6.1 and 6.9.1).
        self.connRecvWindow -= @intCast(flowLen);
        self.connRecvPending += @intCast(flowLen);
        if (self.connRecvWindow < 0) {
            return self.connError(.flowControlError);
        }

        const st = self.streamPtr(sid) orelse {
            // DATA on an idle stream is a connection error; DATA on a
            // closed stream is a stream error (RFC 9113 Section 5.1).
            if (self.isKnownStreamId(sid)) {
                try self.resetStream(sid, .streamClosed);
            } else {
                return self.connError(.protocolError);
            }
            try self.maybeEmitWindowUpdates(sid);
            return;
        };
        if (!st.state.canRecvData()) {
            if (st.state == .idle) return self.connError(.protocolError);
            try self.resetStream(sid, .streamClosed);
            try self.maybeEmitWindowUpdates(sid);
            return;
        }
        if (!st.consumeRecv(@intCast(flowLen))) {
            try self.resetStream(sid, .flowControlError);
            try self.maybeEmitWindowUpdates(sid);
            return;
        }

        if (self.role == .client and !st.finalResponse) {
            try self.resetStream(sid, .protocolError);
            try self.maybeEmitWindowUpdates(sid);
            return;
        }
        if (st.bodyForbidden and data.len > 0) {
            try self.resetStream(sid, .protocolError);
            try self.maybeEmitWindowUpdates(sid);
            return;
        }
        st.bodyBytes = std.math.add(u64, st.bodyBytes, data.len) catch {
            try self.resetStream(sid, .protocolError);
            try self.maybeEmitWindowUpdates(sid);
            return;
        };
        if (st.contentLength) |cl| {
            if (st.bodyBytes > cl) {
                try self.resetStream(sid, .protocolError);
                try self.maybeEmitWindowUpdates(sid);
                return;
            }
        }
        if (endStream and !bodyLengthSatisfied(st)) {
            try self.resetStream(sid, .protocolError);
            try self.maybeEmitWindowUpdates(sid);
            return;
        }

        if (data.len > 0) {
            if (self.cbs.onData) |cb| {
                cb(self.cbs.ctx, sid, data) catch {
                    try self.resetStream(sid, .internalError);
                    try self.maybeEmitWindowUpdates(sid);
                    return;
                };
            }
        }
        st.onRecvData(endStream) catch |e| switch (e) {
            error.StreamClosed => {
                try self.resetStream(sid, .streamClosed);
                try self.maybeEmitWindowUpdates(sid);
                return;
            },
            error.ProtocolError => {
                try self.resetStream(sid, .protocolError);
                try self.maybeEmitWindowUpdates(sid);
                return;
            },
        };
        if (endStream) {
            if (self.cbs.onStreamEnd) |cb| {
                cb(self.cbs.ctx, sid) catch {
                    try self.resetStream(sid, .internalError);
                    try self.maybeEmitWindowUpdates(sid);
                    return;
                };
            }
        }
        // Fully-received streams (both sides ended) are reaped here, so
        // `maybeEmitWindowUpdates` below simply skips the missing entry.
        // `st` is dead after this point.
        if (st.state == .closed) self.reapClosedStream(sid);
        try self.maybeEmitWindowUpdates(sid);
    }

    /// Sends WINDOW_UPDATEs once >= half the window has been consumed.
    fn maybeEmitWindowUpdates(self: *Session, sid: u31) Error!void {
        const connHalf: i64 = @divTrunc(DEFAULT_CONNECTION_WINDOW, 2);
        if (self.connRecvPending >= connHalf) {
            const inc: u31 = @intCast(self.connRecvPending);
            try frameMod.writeWindowUpdate(&self.outbound, self.allocator, 0, inc);
            self.connRecvWindow += @intCast(inc);
            self.connRecvPending = 0;
        }
        if (self.streamPtr(sid)) |st| {
            const half: i64 = @divTrunc(@as(i64, self.localSettings.initialWindowSize), 2);
            if (st.recvPending > 0 and st.recvPending >= half and st.state != .closed) {
                const inc: u31 = @intCast(st.recvPending);
                try frameMod.writeWindowUpdate(&self.outbound, self.allocator, sid, inc);
                st.recvPending = 0;
                st.recvWindow += @intCast(inc);
            }
        }
    }

    fn handleWindowUpdate(self: *Session, sid: u31, inc: u31) Error!void {
        if (inc == 0) {
            // A zero increment is a connection error on stream 0 and a
            // stream error on any other stream (RFC 9113 Section 6.9).
            // Idle/closed streams cannot receive RST_STREAM.
            if (sid == 0) return self.connError(.protocolError);
            if (self.streamPtr(sid) != null) {
                try self.resetStream(sid, .protocolError);
            } else if (!self.isKnownStreamId(sid)) {
                return self.connError(.protocolError);
            }
            return;
        }
        const amount: i64 = @intCast(inc);
        if (sid == 0) {
            self.connSendWindow += amount;
            if (self.connSendWindow > frameMod.MAX_WINDOW) return self.connError(.flowControlError);
            return;
        }
        const st = self.streamPtr(sid) orelse {
            // WINDOW_UPDATE for an idle stream is a connection error; for a
            // closed stream it is ignored (RFC 9113 Section 5.1).
            if (self.isKnownStreamId(sid)) return;
            return self.connError(.protocolError);
        };
        if (st.state == .idle) {
            try self.resetStream(sid, .protocolError);
            return;
        }
        if (st.state == .closed) return;
        st.sendWindow += amount;
        if (st.sendWindow > frameMod.MAX_WINDOW) {
            // Stream-window overflow is a stream error; a connection
            // window overflow remains a connection error (RFC 9113
            // Section 6.9.1).
            try self.resetStream(sid, .flowControlError);
            return;
        }
    }

    /// Fields whose values must never be placed in the HPACK dynamic
    /// table: intermediaries and logs must not be able to replay them.
    const sensitiveNames = [_][]const u8{
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
    };

    fn isSensitive(name: []const u8) bool {
        for (sensitiveNames) |n| {
            if (std.ascii.eqlIgnoreCase(n, name)) return true;
        }
        return false;
    }

    /// Connection-specific fields that MUST NOT appear in an HTTP/2
    /// message (RFC 9113 Section 8.2.2).
    fn isHopByHop(name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(name, "connection") or
            std.ascii.eqlIgnoreCase(name, "keep-alive") or
            std.ascii.eqlIgnoreCase(name, "proxy-connection") or
            std.ascii.eqlIgnoreCase(name, "transfer-encoding") or
            std.ascii.eqlIgnoreCase(name, "upgrade");
    }

    /// Normalizes outgoing fields for HTTP/2: names are lowercased
    /// (RFC 9113 Section 8.2.1) and connection-specific fields are
    /// dropped instead of poisoning the connection.
    fn normalizeOutgoing(
        allocator: Allocator,
        fields: []const hpackMod.HeaderField,
        allowPseudo: bool,
    ) ![]hpackMod.HeaderField {
        var list = std.ArrayList(hpackMod.HeaderField).empty;
        errdefer {
            for (list.items) |f| allocator.free(f.name);
            list.deinit(allocator);
        }
        for (fields) |f| {
            if (f.name.len == 0) continue;
            if (f.name[0] == ':') {
                // Pseudo-headers are forbidden in trailers (RFC 9113
                // Section 8.1); silently dropping one would change the
                // sender's message.
                if (!allowPseudo) return Error.ProtocolViolation;
            } else if (isHopByHop(f.name)) {
                continue;
            } else if (std.ascii.eqlIgnoreCase(f.name, "te") and
                !std.ascii.eqlIgnoreCase(f.value, "trailers"))
            {
                continue;
            }
            const name = try allocator.dupe(u8, f.name);
            errdefer allocator.free(name);
            for (name) |*c| c.* = std.ascii.toLower(c.*);
            try list.append(allocator, .{ .name = name, .value = f.value });
        }
        return list.toOwnedSlice(allocator);
    }

    /// Encodes and sends HEADERS, splitting into CONTINUATIONs as needed.
    pub fn sendHeaders(self: *Session, sid: u31, fields: []const hpackMod.HeaderField, endStream: bool) !void {
        const st = self.streamPtr(sid);
        const is_new = st == null;

        if (is_new) {
            if (self.role != .client) return Error.StreamClosed;
            if (self.goawaySent or self.goawayReceived) return Error.ProtocolViolation;
            if (sid % 2 == 0) return Error.ProtocolViolation;
            if (sid <= self.largestLocalStream) return Error.ProtocolViolation;
            if (self.activeLocalStreams >= self.peerSettings.maxConcurrentStreams) {
                return Error.MaxConcurrentStreams;
            }
        }

        // The first HEADERS block on a stream carries the request or
        // response; later ones are trailers (RFC 9113 Section 8.1). A
        // server may emit several 1xx blocks before its final response.
        const trailers = if (st) |s|
            if (self.role == .server) s.finalResponseSent else s.headersSent > 0
        else
            false;
        const kind: HeaderKind = if (trailers)
            .trailers
        else if (self.role == .client)
            .request
        else
            .response;

        if (trailers and (!endStream or st.?.trailersSent)) {
            return Error.ProtocolViolation;
        }

        const normalized = try normalizeOutgoing(self.allocator, fields, !trailers);
        defer {
            for (normalized) |f| self.allocator.free(f.name);
            self.allocator.free(normalized);
        }

        // Validate before encoding: a malformed header list must never
        // reach the wire (RFC 9113 Section 8.1.1).
        if (!validateHeaderList(normalized, kind)) return Error.ProtocolViolation;

        // Header list size is bounded by the peer's SETTINGS_MAX_HEADER_LIST_SIZE.
        var list_size: usize = 0;
        for (normalized) |f| {
            list_size += hpackMod.ENTRY_OVERHEAD + f.name.len + f.value.len;
        }
        if (list_size > self.peerSettings.maxHeaderListSize) return Error.HeaderListTooLarge;

        var responseStatus: ?u16 = null;
        if (self.role == .server and !trailers) {
            const status = parseStatus(normalized) orelse return Error.ProtocolViolation;
            if (status < 100 or status > 599 or status == 101) return Error.ProtocolViolation;
            const cl = parseContentLength(normalized) catch return Error.ProtocolViolation;
            // Informational responses are interim, never end the stream,
            // and never carry Content-Length (RFC 9110 Section 8.6).
            if (status < 200) {
                if (endStream or cl != null) return Error.ProtocolViolation;
            } else if (st) |res| {
                if (status == 204 and cl != null) return Error.ProtocolViolation;
                if (status == 205 and cl != null and cl.? != 0) return Error.ProtocolViolation;
                const connectTunnel = res.requestIsConnect and status >= 200 and status < 300;
                if (connectTunnel and cl != null) return Error.ProtocolViolation;
                res.sendContentLength = cl;
                res.sendBodyForbidden = res.requestIsHead or status == 204 or
                    status == 304 or status == 205 or connectTunnel;
                res.responseStatus = status;
                if (endStream and !outboundBodyLengthSatisfied(res)) {
                    return Error.ProtocolViolation;
                }
            }
            responseStatus = status;
        }

        var requestContentLength: ?u64 = null;
        if (self.role == .client and !trailers) {
            requestContentLength = parseContentLength(normalized) catch return Error.ProtocolViolation;
            // A request that ends with HEADERS cannot claim a body.
            if (endStream and requestContentLength != null and requestContentLength.? != 0) {
                return Error.ProtocolViolation;
            }
        }

        var block = std.ArrayList(u8).empty;
        defer block.deinit(self.allocator);
        for (normalized) |f| {
            // Sensitive values are sent as "never indexed" literals so they
            // never enter the dynamic table (RFC 7541 Section 6.2.3).
            const indexing: hpackMod.Indexing = if (isSensitive(f.name)) .never else .incremental;
            try self.henc.encode(&block, f.name, f.value, indexing, false);
        }
        if (responseStatus) |status| {
            if (status >= 200) {
                if (self.streamPtr(sid)) |res| res.finalResponseSent = true;
            }
        }
        try self.sendHeaderBlockInternal(sid, block.items, endStream, trailers);
        if (!trailers and self.role == .client) {
            if (self.streamPtr(sid)) |req| {
                if (fieldValue(normalized, ":method")) |method| {
                    req.requestIsHead = std.mem.eql(u8, method, "HEAD");
                    req.requestIsConnect = std.mem.eql(u8, method, "CONNECT");
                }
                req.sendContentLength = requestContentLength;
            }
        }
    }

    pub fn sendHeaderBlock(self: *Session, sid: u31, block: []const u8, endStream: bool) !void {
        const trailers = if (self.streamPtr(sid)) |st|
            if (self.role == .server) st.finalResponseSent else st.headersSent > 0
        else
            false;
        try self.sendHeaderBlockInternal(sid, block, endStream, trailers);
    }

    fn sendHeaderBlockInternal(
        self: *Session,
        sid: u31,
        block: []const u8,
        endStream: bool,
        trailers: bool,
    ) !void {
        const max = @as(usize, self.peerSettings.maxFrameSize);
        if (self.streamPtr(sid) == null) {
            if (self.role != .client) return Error.StreamClosed;
            if (trailers) return Error.ProtocolViolation;
            if (self.goawaySent or self.goawayReceived) return Error.ProtocolViolation;
            if (sid % 2 == 0) return Error.ProtocolViolation;
            if (sid <= self.largestLocalStream) return Error.ProtocolViolation;
            if (self.activeLocalStreams >= self.peerSettings.maxConcurrentStreams) {
                return Error.MaxConcurrentStreams;
            }
            _ = try self.createStream(sid);
            self.activeLocalStreams += 1;
            self.streamPtr(sid).?.countedSlot = true;
            if (sid > self.largestLocalStream) self.largestLocalStream = sid;
            if (self.nextStreamId <= sid) self.nextStreamId = @as(u32, sid) + 2;
        }
        const st = self.streamPtr(sid).?;
        if (trailers and (!endStream or st.trailersSent)) {
            return Error.ProtocolViolation;
        }
        if (trailers and !outboundBodyLengthSatisfied(st)) {
            return Error.ProtocolViolation;
        }
        try st.onSendHeaders(endStream);
        st.headersSent += 1;
        // Response/trailer HEADERS with END_STREAM on an already
        // half-closed (remote) stream close it fully. The frame writes
        // below only use `sid` (never `st`), so reaping at the end is
        // borrow-safe.
        const sendClosed = st.state == .closed;

        var flags: u8 = 0;
        if (endStream) flags |= Flags.END_STREAM;

        if (block.len <= max) {
            flags |= Flags.END_HEADERS;
            try frameMod.writeHeader(&self.outbound, self.allocator, block.len, .headers, flags, sid);
            try self.outbound.appendSlice(self.allocator, block);
        } else {
            var off: usize = 0;
            var first = true;
            while (off < block.len) {
                const take = @min(max, block.len - off);
                const frag = block[off..][0..take];
                off += take;
                const last = off == block.len;
                // END_STREAM belongs to the HEADERS frame only; a
                // CONTINUATION frame must not carry it.
                var f2: u8 = if (first) flags else 0;
                if (last) f2 |= Flags.END_HEADERS;
                if (first) {
                    try frameMod.writeHeader(&self.outbound, self.allocator, frag.len, .headers, f2, sid);
                    first = false;
                } else {
                    try frameMod.writeHeader(&self.outbound, self.allocator, frag.len, .continuation, f2, sid);
                }
                try self.outbound.appendSlice(self.allocator, frag);
            }
        }
        if (trailers) st.trailersSent = true;
        if (sendClosed) self.reapClosedStream(sid);
    }

    /// Sends DATA respecting maxFrameSize and available windows.
    /// Returns bytes actually queued (rest needs WINDOW_UPDATE first).
    pub fn sendData(self: *Session, sid: u31, data: []const u8, endStream: bool) Error!usize {
        const st = self.streamPtr(sid) orelse return Error.StreamClosed;
        if (!st.state.canSendData() or st.endStreamSent) return Error.StreamClosed;
        if (st.sendBodyForbidden and data.len > 0) return Error.ProtocolViolation;
        if (st.sendContentLength) |cl| {
            const projected = std.math.add(u64, st.bodyBytesSent, data.len) catch
                return Error.ProtocolViolation;
            if (projected > cl) return Error.ProtocolViolation;
        }

        const max = @as(usize, self.peerSettings.maxFrameSize);

        // A zero-length DATA frame with END_STREAM closes the send side.
        if (data.len == 0) {
            if (!endStream) return 0;
            if (!outboundBodyLengthSatisfied(st)) return Error.ProtocolViolation;
            try frameMod.writeData(&self.outbound, self.allocator, sid, data, true);
            st.onSendData(true) catch return Error.StreamClosed;
            if (st.state == .closed) self.reapClosedStream(sid);
            return 0;
        }

        const budgetWin = @min(self.connSendWindow, st.sendWindow);
        if (budgetWin <= 0) return 0;

        const allowed: usize = @min(@as(usize, @intCast(budgetWin)), data.len);
        // Validate the final length before writing any bytes, but only
        // when this call can actually carry END_STREAM.
        if (endStream and allowed == data.len) {
            if (st.sendContentLength) |cl| {
                const total = std.math.add(u64, st.bodyBytesSent, data.len) catch
                    return Error.ProtocolViolation;
                if (total != cl) return Error.ProtocolViolation;
            }
        }
        var sent: usize = 0;

        while (sent < allowed) {
            const take = @min(max, allowed - sent);
            const chunk = data[sent..][0..take];
            const fin = endStream and sent + take == data.len;
            frameMod.writeData(&self.outbound, self.allocator, sid, chunk, fin) catch return Error.OutOfMemory;
            sent += take;
            st.bodyBytesSent += @intCast(take);
            _ = st.creditSend(@intCast(take));
            self.connSendWindow -= @intCast(take);
        }
        if (endStream and sent == data.len) {
            st.onSendData(true) catch {};
            // Fully-sent final DATA on a both-ended stream closes it;
            // `st` is dead after this (only `sid`/counts used below).
            if (st.state == .closed) self.reapClosedStream(sid);
        }
        return sent;
    }

    pub fn sendRstStream(self: *Session, sid: u31, code: ErrorCode) !void {
        if (self.streamPtr(sid)) |st| st.onSendRst();
        try frameMod.writeRstStream(&self.outbound, self.allocator, sid, @backingInt(code));
        self.reapClosedStream(sid);
    }

    pub fn sendWindowUpdate(self: *Session, sid: u31, inc: u31) !void {
        if (inc == 0) return Error.ProtocolViolation;
        if (inc > frameMod.MAX_WINDOW) return Error.FlowControlError;
        if (sid == 0) {
            // Connection-level credit: the window is the advertised one,
            // replenished as bytes are consumed.
            const next = self.connRecvWindow + @as(i64, inc);
            if (next > frameMod.MAX_WINDOW) return Error.FlowControlError;
            self.connRecvWindow = next;
            self.connRecvPending = @max(@as(i64, 0), self.connRecvPending - @as(i64, inc));
            try frameMod.writeWindowUpdate(&self.outbound, self.allocator, 0, inc);
            return;
        }
        if (self.streamPtr(sid)) |st| {
            const next = st.recvWindow + @as(i64, inc);
            if (next > frameMod.MAX_WINDOW) return Error.FlowControlError;
            st.recvWindow = next;
            // Credit already granted through this call must not be granted
            // again by the automatic half-window replenisher.
            st.recvPending = @max(@as(i64, 0), st.recvPending - @as(i64, inc));
        }
        try frameMod.writeWindowUpdate(&self.outbound, self.allocator, sid, inc);
    }

    pub fn sendPing(self: *Session, opaqueData: [8]u8) !void {
        try frameMod.writePing(&self.outbound, self.allocator, false, opaqueData);
    }

    /// Phase 1 of graceful shutdown: stop accepting new streams.
    pub fn beginGracefulShutdown(self: *Session) !void {
        if (self.goawaySent) return;
        try frameMod.writeGoaway(&self.outbound, self.allocator, 0x7FFFFFFF, 0, "");
        self.goawaySent = true;
        self.goawayLastSidSent = 0x7FFFFFFF;
    }

    /// Final GOAWAY with the real last-stream-id. The identifier must
    /// never increase across GOAWAY frames (RFC 9113 Section 6.8).
    pub fn finishGracefulShutdown(self: *Session) !void {
        // A client's GOAWAY refers to server-initiated (push) streams.
        // Push is disabled, so its final last-stream-id is zero.
        const candidate: u31 = if (self.role == .server)
            self.largestPeerStream
        else
            0;
        const lastSid: u31 = @min(candidate, self.goawayLastSidSent);
        try frameMod.writeGoaway(&self.outbound, self.allocator, lastSid, 0, "");
        self.goawaySent = true;
        self.goawayLastSidSent = lastSid;
    }

    pub fn sendConnectionClose(self: *Session, code: ErrorCode, debug: []const u8) !void {
        const candidate: u31 = if (self.role == .server) self.largestPeerStream else 0;
        const lastSid = @min(candidate, self.goawayLastSidSent);
        try frameMod.writeGoaway(&self.outbound, self.allocator, lastSid, @backingInt(code), debug);
        self.goawaySent = true;
        self.goawayLastSidSent = lastSid;
    }

    /// Queues a fatal GOAWAY then returns the mapped protocol error.
    fn connError(self: *Session, code: ErrorCode) Error {
        if (!self.closed) {
            self.closed = true;
            const candidate: u31 = if (self.role == .server) self.largestPeerStream else 0;
            // A fatal GOAWAY sent after a graceful GOAWAY must not
            // increase the advertised last-stream-id (RFC 9113 6.8).
            const lastSid = @min(candidate, self.goawayLastSidSent);
            frameMod.writeGoaway(
                &self.outbound,
                self.allocator,
                lastSid,
                @backingInt(code),
                @tagName(code),
            ) catch {};
        }
        return switch (code) {
            .compressionError => Error.CompressionError,
            .flowControlError => Error.FlowControlError,
            .frameSizeError => Error.FrameSizeExceeded,
            .streamClosed => Error.StreamClosed,
            else => Error.ProtocolViolation,
        };
    }

    fn removeStream(self: *Session, sid: u31) !void {
        if (self.streams.fetchRemove(sid)) |kv| {
            if (kv.value.countedSlot) {
                if (self.role == .server) {
                    if (self.activePeerStreams > 0) self.activePeerStreams -= 1;
                } else {
                    if (self.activeLocalStreams > 0) self.activeLocalStreams -= 1;
                }
            }
            kv.value.deinit();
            self.allocator.destroy(kv.value);
        }
    }

    /// Reaps a stream that reached the fully-closed state (both sides
    /// END_STREAM or reset). Completed streams must leave `streams` (and,
    /// server-side, the concurrency slot) or long-lived connections
    /// falsely hit `maxConcurrentStreams` and leak memory. Only call
    /// where no live `*Stream` borrow follows.
    fn reapClosedStream(self: *Session, sid: u31) void {
        const st = self.streamPtr(sid) orelse return;
        if (st.state == .closed) {
            self.removeStream(sid) catch {};
        }
    }

    /// Opens the next client-initiated stream id (clients only).
    pub fn nextClientStreamId(self: *Session) !u31 {
        if (self.role != .client) return Error.ProtocolViolation;
        const id = self.nextStreamId;
        // The 31-bit identifier space ends at 0x7FFFFFFF; asking for one
        // more must fail instead of wrapping around.
        if (id > 0x7FFFFFFF) return Error.ProtocolViolation;
        self.nextStreamId = id + 2;
        return @intCast(id);
    }
};

// Loopback integration test: full client<->server exchange

fn establishTestPair(client: *Session, server: *Session) !void {
    try client.startHandshake();
    try server.startHandshake();
    try server.feed(client.outbound.items);
    client.outbound.clearRetainingCapacity();
    try client.feed(server.outbound.items);
    server.outbound.clearRetainingCapacity();
}

fn hasRstStream(out: []const u8, sid: u31, code: u32) bool {
    var off: usize = 0;
    while (off + frameMod.FRAME_HEADER_SIZE <= out.len) {
        const hdr = FrameHeader.parse(out[off..][0..frameMod.FRAME_HEADER_SIZE]);
        off += frameMod.FRAME_HEADER_SIZE;
        if (off + hdr.length > out.len) return false;
        if (hdr.frameType == .rstStream and hdr.streamId == sid and hdr.length == 4) {
            if (std.mem.readInt(u32, out[off..][0..4], .big) == code) return true;
        }
        off += hdr.length;
    }
    return false;
}

test "session pair completes request/response exchange" {
    const a = std.testing.allocator;

    var client = try Session.init(a, .client, .{});
    defer client.deinit();
    var server = try Session.init(a, .server, .{});
    defer server.deinit();

    try client.startHandshake();
    try server.startHandshake(); // server SETTINGS

    // Wire the two sessions together.
    try server.feed(client.outbound.items);
    client.outbound.clearRetainingCapacity();
    try client.feed(server.outbound.items);
    server.outbound.clearRetainingCapacity();
    try client.feed(server.outbound.items); // SETTINGS ACK from server? (queued on settings)
    server.outbound.clearRetainingCapacity();

    // Client sends GET.
    const fields = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/hello" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":authority", .value = "x" },
    };
    try client.sendHeaders(1, fields[0..], true);

    // Server consumes request; capture headers via temporary callbacks.
    const Capture = struct {
        var methodBuf: [16]u8 = undefined;
        var pathBuf: [32]u8 = undefined;
        var methodLen: usize = 0;
        var pathLen: usize = 0;
        var done: bool = false;

        fn onHeaders(_: ?*anyopaque, _: u31, flds: []hpackMod.HeaderField, endStream: bool) anyerror!void {
            for (flds) |f| {
                if (std.mem.eql(u8, f.name, ":method")) {
                    @memcpy(methodBuf[0..f.value.len], f.value);
                    methodLen = f.value.len;
                }
                if (std.mem.eql(u8, f.name, ":path")) {
                    @memcpy(pathBuf[0..f.value.len], f.value);
                    pathLen = f.value.len;
                }
            }
            done = endStream;
        }
    };
    server.cbs = .{ .onHeaders = Capture.onHeaders };

    server.feed(client.outbound.items) catch |e| {
        return e;
    };
    try std.testing.expect(Capture.done);
    try std.testing.expectEqualStrings("GET", Capture.methodBuf[0..Capture.methodLen]);
    try std.testing.expectEqualStrings("/hello", Capture.pathBuf[0..Capture.pathLen]);
    client.outbound.clearRetainingCapacity();

    // Server responds: HEADERS + DATA(END_STREAM).
    const resp = [_]hpackMod.HeaderField{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-type", .value = "text/plain" },
    };
    try server.sendHeaders(1, resp[0..], false);
    const sent = try server.sendData(1, "hi", true);
    try std.testing.expectEqual(@as(usize, 2), sent);

    // Client consumes response.
    const CResp = struct {
        var status: u16 = 0;
        var body: [16]u8 = undefined;
        var blen: usize = 0;
        var ended: bool = false;

        fn onHeaders(_: ?*anyopaque, _: u31, flds: []hpackMod.HeaderField, _: bool) anyerror!void {
            for (flds) |f| {
                if (std.mem.eql(u8, f.name, ":status")) {
                    status = std.fmt.parseInt(u16, f.value, 10) catch 0;
                }
            }
        }
        fn onData(_: ?*anyopaque, _: u31, data: []const u8) anyerror!void {
            @memcpy(body[blen..][0..data.len], data);
            blen += data.len;
        }
        fn onEnd(_: ?*anyopaque, _: u31) anyerror!void {
            ended = true;
        }
    };
    client.cbs = .{
        .onHeaders = CResp.onHeaders,
        .onData = CResp.onData,
        .onStreamEnd = CResp.onEnd,
    };

    try client.feed(server.outbound.items);
    try std.testing.expectEqual(@as(u16, 200), CResp.status);
    try std.testing.expectEqualStrings("hi", CResp.body[0..CResp.blen]);
    try std.testing.expect(CResp.ended);

    // SETTINGS ACK flows back and closes the handshake cleanly.
    try server.feed(client.outbound.items);
}

test "informational responses are ignored until the final response" {
    const a = std.testing.allocator;
    var client = try Session.init(a, .client, .{});
    defer client.deinit();
    var server = try Session.init(a, .server, .{});
    defer server.deinit();
    try establishTestPair(&client, &server);

    const Capture = struct {
        var status: u16 = 0;
        var calls: usize = 0;
        var body: [8]u8 = undefined;
        var blen: usize = 0;
        var ended: bool = false;

        fn onHeaders(_: ?*anyopaque, _: u31, fields: []hpackMod.HeaderField, _: bool) anyerror!void {
            calls += 1;
            for (fields) |f| {
                if (std.mem.eql(u8, f.name, ":status")) {
                    status = std.fmt.parseInt(u16, f.value, 10) catch 0;
                }
            }
        }
        fn onData(_: ?*anyopaque, _: u31, data: []const u8) anyerror!void {
            @memcpy(body[blen..][0..data.len], data);
            blen += data.len;
        }
        fn onEnd(_: ?*anyopaque, _: u31) anyerror!void {
            ended = true;
        }
    };
    client.cbs = .{
        .onHeaders = Capture.onHeaders,
        .onData = Capture.onData,
        .onStreamEnd = Capture.onEnd,
    };

    const req = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":authority", .value = "x" },
    };
    try client.sendHeaders(1, req[0..], true);
    try server.feed(client.outbound.items);
    client.outbound.clearRetainingCapacity();

    const info = [_]hpackMod.HeaderField{.{ .name = ":status", .value = "103" }};
    try std.testing.expectError(Error.ProtocolViolation, server.sendHeaders(1, info[0..], true));
    const infoWithLength = [_]hpackMod.HeaderField{
        .{ .name = ":status", .value = "103" },
        .{ .name = "content-length", .value = "0" },
    };
    try std.testing.expectError(Error.ProtocolViolation, server.sendHeaders(1, infoWithLength[0..], false));
    try server.sendHeaders(1, info[0..], false);

    const resp = [_]hpackMod.HeaderField{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "2" },
    };
    try server.sendHeaders(1, resp[0..], false);
    _ = try server.sendData(1, "hi", true);
    try client.feed(server.outbound.items);
    server.outbound.clearRetainingCapacity();

    try std.testing.expectEqual(@as(usize, 1), Capture.calls);
    try std.testing.expectEqual(@as(u16, 200), Capture.status);
    try std.testing.expectEqualStrings("hi", Capture.body[0..Capture.blen]);
    try std.testing.expect(Capture.ended);
}

test "outbound trailers require END_STREAM and no pseudo-headers" {
    const a = std.testing.allocator;
    var client = try Session.init(a, .client, .{});
    defer client.deinit();
    var server = try Session.init(a, .server, .{});
    defer server.deinit();
    try establishTestPair(&client, &server);

    const req = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":authority", .value = "x" },
    };
    try client.sendHeaders(1, req[0..], true);
    try server.feed(client.outbound.items);
    client.outbound.clearRetainingCapacity();

    const resp = [_]hpackMod.HeaderField{.{ .name = ":status", .value = "200" }};
    try server.sendHeaders(1, resp[0..], false);

    const trailers = [_]hpackMod.HeaderField{.{ .name = "x-checksum", .value = "1" }};
    try std.testing.expectError(Error.ProtocolViolation, server.sendHeaders(1, trailers[0..], false));

    const pseudoTrailer = [_]hpackMod.HeaderField{.{ .name = ":status", .value = "200" }};
    try std.testing.expectError(Error.ProtocolViolation, server.sendHeaders(1, pseudoTrailer[0..], true));

    // The rejected blocks never consumed the one allowed trailer section.
    try server.sendHeaders(1, trailers[0..], true);
    try client.feed(server.outbound.items);
    server.outbound.clearRetainingCapacity();
    try std.testing.expect(!hasRstStream(client.outbound.items, 1, @backingInt(ErrorCode.protocolError)));
}

test "duplicate outbound trailers are rejected" {
    const a = std.testing.allocator;
    var client = try Session.init(a, .client, .{});
    defer client.deinit();
    var server = try Session.init(a, .server, .{});
    defer server.deinit();
    try establishTestPair(&client, &server);

    const req = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":authority", .value = "x" },
    };
    try client.sendHeaders(1, req[0..], false);
    const trailers = [_]hpackMod.HeaderField{.{ .name = "x-checksum", .value = "1" }};
    try client.sendHeaders(1, trailers[0..], true);
    try std.testing.expectError(Error.ProtocolViolation, client.sendHeaders(1, trailers[0..], true));
}

test "padding counts against the stream flow-control window" {
    const a = std.testing.allocator;
    var client = try Session.init(a, .client, .{});
    defer client.deinit();
    client.localSettings.initialWindowSize = 10;
    var server = try Session.init(a, .server, .{});
    defer server.deinit();
    try establishTestPair(&client, &server);

    const req = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":authority", .value = "x" },
    };
    try client.sendHeaders(1, req[0..], true);
    try server.feed(client.outbound.items);
    client.outbound.clearRetainingCapacity();

    const resp = [_]hpackMod.HeaderField{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "9" },
    };
    try server.sendHeaders(1, resp[0..], false);

    // Nine data bytes plus one pad-length byte and one padding byte: the
    // payload is 11 bytes, one over the advertised stream window.
    const payload = [_]u8{ 1, 'a', 'a', 'a', 'a', 'a', 'a', 'a', 'a', 'a', 0 };
    try frameMod.writeHeader(&server.outbound, a, payload.len, .data, Flags.PADDED | Flags.END_STREAM, 1);
    try server.outbound.appendSlice(a, &payload);

    try client.feed(server.outbound.items);
    server.outbound.clearRetainingCapacity();
    try std.testing.expect(hasRstStream(client.outbound.items, 1, @backingInt(ErrorCode.flowControlError)));
}

test "outbound content-length mismatches are rejected before sending" {
    const a = std.testing.allocator;
    var client = try Session.init(a, .client, .{});
    defer client.deinit();
    var server = try Session.init(a, .server, .{});
    defer server.deinit();
    try establishTestPair(&client, &server);

    const req = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":authority", .value = "x" },
    };
    try client.sendHeaders(1, req[0..], true);
    try server.feed(client.outbound.items);
    client.outbound.clearRetainingCapacity();

    const resp = [_]hpackMod.HeaderField{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "5" },
    };
    // A final HEADERS block cannot end the stream while promising a body.
    try std.testing.expectError(Error.ProtocolViolation, server.sendHeaders(1, resp[0..], true));
    try server.sendHeaders(1, resp[0..], false);
    try std.testing.expectError(Error.ProtocolViolation, server.sendData(1, "abc", true));
    try std.testing.expectError(Error.ProtocolViolation, server.sendData(1, "abcdef", false));

    // None of the rejected bytes were written, so the correct body fits.
    try std.testing.expectEqual(@as(usize, 5), try server.sendData(1, "abcde", true));
    try client.feed(server.outbound.items);
    server.outbound.clearRetainingCapacity();
    try std.testing.expect(!hasRstStream(client.outbound.items, 1, @backingInt(ErrorCode.protocolError)));
}

test "outbound requests validate content-length before sending" {
    const a = std.testing.allocator;
    var client = try Session.init(a, .client, .{});
    defer client.deinit();
    var server = try Session.init(a, .server, .{});
    defer server.deinit();
    try establishTestPair(&client, &server);

    const base = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":authority", .value = "x" },
    };
    const withBody = base ++ [_]hpackMod.HeaderField{.{ .name = "content-length", .value = "3" }};
    try std.testing.expectError(Error.ProtocolViolation, client.sendHeaders(1, &withBody, true));

    const invalid = base ++ [_]hpackMod.HeaderField{.{ .name = "content-length", .value = "3x" }};
    try std.testing.expectError(Error.ProtocolViolation, client.sendHeaders(1, &invalid, false));

    try client.sendHeaders(1, &withBody, false);
    try std.testing.expectError(Error.ProtocolViolation, client.sendData(1, "abcd", false));
    try std.testing.expectEqual(@as(usize, 3), try client.sendData(1, "abc", true));
    try server.feed(client.outbound.items);
    client.outbound.clearRetainingCapacity();
    try std.testing.expect(!hasRstStream(server.outbound.items, 1, @backingInt(ErrorCode.protocolError)));
}

test "a received content-length mismatch resets the stream" {
    const a = std.testing.allocator;
    var client = try Session.init(a, .client, .{});
    defer client.deinit();
    var server = try Session.init(a, .server, .{});
    defer server.deinit();
    try establishTestPair(&client, &server);

    const req = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":authority", .value = "x" },
    };
    try client.sendHeaders(1, req[0..], true);
    try server.feed(client.outbound.items);
    client.outbound.clearRetainingCapacity();

    const resp = [_]hpackMod.HeaderField{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "5" },
    };
    try server.sendHeaders(1, resp[0..], false);
    // Bypass sendData to exercise the receive-side length check.
    try frameMod.writeData(&server.outbound, a, 1, "abc", true);

    try client.feed(server.outbound.items);
    server.outbound.clearRetainingCapacity();
    try std.testing.expect(hasRstStream(client.outbound.items, 1, @backingInt(ErrorCode.protocolError)));
}

test "a received GOAWAY refuses only client streams above its last id" {
    const a = std.testing.allocator;
    var client = try Session.init(a, .client, .{});
    defer client.deinit();
    var server = try Session.init(a, .server, .{});
    defer server.deinit();
    try establishTestPair(&client, &server);

    const req = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":authority", .value = "x" },
    };
    try client.sendHeaders(1, req[0..], false);
    try client.sendHeaders(3, req[0..], false);
    try server.feed(client.outbound.items);
    client.outbound.clearRetainingCapacity();

    try frameMod.writeGoaway(&server.outbound, a, 1, 0, "");
    try client.feed(server.outbound.items);
    server.outbound.clearRetainingCapacity();

    try std.testing.expect(client.streamPtr(1) != null);
    try std.testing.expect(client.streamPtr(3) == null);
    try std.testing.expectError(Error.ProtocolViolation, client.sendHeaders(5, req[0..], true));
}

test "HEAD and 304 responses may declare a content-length without a body" {
    const a = std.testing.allocator;
    var client = try Session.init(a, .client, .{});
    defer client.deinit();
    var server = try Session.init(a, .server, .{});
    defer server.deinit();
    try establishTestPair(&client, &server);

    const headReq = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "HEAD" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":authority", .value = "x" },
    };
    try client.sendHeaders(1, headReq[0..], true);
    try server.feed(client.outbound.items);
    client.outbound.clearRetainingCapacity();

    const headResp = [_]hpackMod.HeaderField{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "10" },
    };
    try server.sendHeaders(1, headResp[0..], true);
    try client.feed(server.outbound.items);
    server.outbound.clearRetainingCapacity();
    try std.testing.expect(!hasRstStream(client.outbound.items, 1, @backingInt(ErrorCode.protocolError)));

    const getReq = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":authority", .value = "x" },
    };
    try client.sendHeaders(3, getReq[0..], true);
    try server.feed(client.outbound.items);
    client.outbound.clearRetainingCapacity();

    const notModified = [_]hpackMod.HeaderField{
        .{ .name = ":status", .value = "304" },
        .{ .name = "content-length", .value = "10" },
    };
    try server.sendHeaders(3, notModified[0..], true);
    try client.feed(server.outbound.items);
    server.outbound.clearRetainingCapacity();
    try std.testing.expect(!hasRstStream(client.outbound.items, 3, @backingInt(ErrorCode.protocolError)));
}

test "204 responses must not send content-length" {
    const a = std.testing.allocator;
    var client = try Session.init(a, .client, .{});
    defer client.deinit();
    var server = try Session.init(a, .server, .{});
    defer server.deinit();
    try establishTestPair(&client, &server);

    const req = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":authority", .value = "x" },
    };
    try client.sendHeaders(1, req[0..], true);
    try server.feed(client.outbound.items);
    client.outbound.clearRetainingCapacity();

    const withLength = [_]hpackMod.HeaderField{
        .{ .name = ":status", .value = "204" },
        .{ .name = "content-length", .value = "0" },
    };
    try std.testing.expectError(Error.ProtocolViolation, server.sendHeaders(1, withLength[0..], true));

    const resp = [_]hpackMod.HeaderField{.{ .name = ":status", .value = "204" }};
    try server.sendHeaders(1, resp[0..], true);
    try client.feed(server.outbound.items);
    server.outbound.clearRetainingCapacity();
    try std.testing.expect(!hasRstStream(client.outbound.items, 1, @backingInt(ErrorCode.protocolError)));
}

test "205 responses allow only a zero content-length" {
    const a = std.testing.allocator;
    var client = try Session.init(a, .client, .{});
    defer client.deinit();
    var server = try Session.init(a, .server, .{});
    defer server.deinit();
    try establishTestPair(&client, &server);

    const req = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":authority", .value = "x" },
    };
    try client.sendHeaders(1, req[0..], true);
    try server.feed(client.outbound.items);
    client.outbound.clearRetainingCapacity();

    const nonZero = [_]hpackMod.HeaderField{
        .{ .name = ":status", .value = "205" },
        .{ .name = "content-length", .value = "1" },
    };
    try std.testing.expectError(Error.ProtocolViolation, server.sendHeaders(1, nonZero[0..], true));

    const resp = [_]hpackMod.HeaderField{
        .{ .name = ":status", .value = "205" },
        .{ .name = "content-length", .value = "0" },
    };
    try server.sendHeaders(1, resp[0..], true);
    try client.feed(server.outbound.items);
    server.outbound.clearRetainingCapacity();
    try std.testing.expect(!hasRstStream(client.outbound.items, 1, @backingInt(ErrorCode.protocolError)));
}

test "header list validation tracks CONNECT pseudo-header rules" {
    const connect = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "CONNECT" },
        .{ .name = ":authority", .value = "example.com:443" },
    };
    try std.testing.expect(Session.validateHeaderList(&connect, .request));

    const connectWithPath = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "CONNECT" },
        .{ .name = ":authority", .value = "example.com:443" },
        .{ .name = ":path", .value = "/" },
    };
    try std.testing.expect(!Session.validateHeaderList(&connectWithPath, .request));

    const extended = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "CONNECT" },
        .{ .name = ":authority", .value = "example.com:443" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":protocol", .value = "websocket" },
    };
    try std.testing.expect(Session.validateHeaderList(&extended, .request));

    const relative = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "relative" },
    };
    try std.testing.expect(!Session.validateHeaderList(&relative, .request));

    const asterisk = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "OPTIONS" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "*" },
    };
    try std.testing.expect(Session.validateHeaderList(&asterisk, .request));
}

test "header list validation rejects uppercase, forbidden headers and mixed pseudo-headers" {
    // Uppercase header name -> rejected
    const badUpper = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "Content-Type", .value = "text/plain" },
    };
    try std.testing.expect(!Session.validateHeaderList(&badUpper, .request));

    // Forbidden 'connection' header -> rejected
    const badConn = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "connection", .value = "keep-alive" },
    };
    try std.testing.expect(!Session.validateHeaderList(&badConn, .request));

    // Forbidden 'te' header with value other than 'trailers' -> rejected
    const badTe = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "te", .value = "gzip" },
    };
    try std.testing.expect(!Session.validateHeaderList(&badTe, .request));

    // Valid 'te: trailers' -> accepted
    const goodTe = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "te", .value = "trailers" },
    };
    try std.testing.expect(Session.validateHeaderList(&goodTe, .request));

    // Mixed request and response pseudo-headers -> rejected
    const badMixed = [_]hpackMod.HeaderField{
        .{ .name = ":status", .value = "200" },
        .{ .name = ":method", .value = "GET" },
    };
    try std.testing.expect(!Session.validateHeaderList(&badMixed, .request));
    try std.testing.expect(!Session.validateHeaderList(&badMixed, .response));

    // A response must carry :status, a request must carry :method,
    // :scheme and :path.
    const respNoStatus = [_]hpackMod.HeaderField{.{ .name = "x", .value = "1" }};
    try std.testing.expect(!Session.validateHeaderList(&respNoStatus, .response));
    try std.testing.expect(!Session.validateHeaderList(&respNoStatus, .request));

    // Trailers carry no pseudo-headers at all.
    const trailerWithPseudo = [_]hpackMod.HeaderField{.{ .name = ":status", .value = "200" }};
    try std.testing.expect(!Session.validateHeaderList(&trailerWithPseudo, .trailers));
    const plainTrailer = [_]hpackMod.HeaderField{.{ .name = "x-checksum", .value = "1" }};
    try std.testing.expect(Session.validateHeaderList(&plainTrailer, .trailers));
}

test "header list validation rejects malformed method, scheme and authority" {
    const badMethod = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GE T" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
    };
    try std.testing.expect(!Session.validateHeaderList(&badMethod, .request));

    const badScheme = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "ht tp" },
        .{ .name = ":path", .value = "/" },
    };
    try std.testing.expect(!Session.validateHeaderList(&badScheme, .request));

    const userinfo = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":authority", .value = "user@example.com" },
    };
    try std.testing.expect(!Session.validateHeaderList(&userinfo, .request));
}

test "continued header blocks are rejected before exceeding configured budget" {
    var session = try Session.init(std.testing.allocator, .server, .{});
    defer session.deinit();
    session.maxHeaderBlockBytes = 5;

    try session.handleHeadersStart(1, "1234", false, false, false);
    try std.testing.expectError(Error.ProtocolViolation, session.handleContinuation(1, "56", true));
    try std.testing.expect(session.closed);
    try std.testing.expect(session.streamPtr(1).?.headerBlock.?.items.len <= 5);
}

// Protocol-level tests: framing rules, error escalation and flow control.

/// Serializes one frame into `buf` and returns the frame bytes.
fn buildFrame(buf: []u8, t: frameMod.FrameType, flags: u8, sid: u31, payload: []const u8) []const u8 {
    var h: frameMod.FrameHeader = .{
        .length = @intCast(payload.len),
        .frameType = t,
        .flags = flags,
        .streamId = sid,
    };
    var hb: [9]u8 = undefined;
    h.serialize(&hb);
    @memcpy(buf[0..9], &hb);
    @memcpy(buf[9..][0..payload.len], payload);
    return buf[0 .. 9 + payload.len];
}

/// Client SETTINGS payload (empty).
const empty_settings = [_]u8{};

/// Builds the client preface plus its SETTINGS frame.
fn clientHandshake(buf: []u8) []const u8 {
    @memcpy(buf[0..24], frameMod.CONNECTION_PREFACE);
    const settings = buildFrame(buf[24..], .settings, 0, 0, &empty_settings);
    return buf[0 .. 24 + settings.len];
}

/// HPACK block for a minimal GET request.
fn requestBlock(allocator: Allocator, path: []const u8) ![]u8 {
    var enc = hpackMod.Encoder.init(allocator);
    defer enc.deinit();
    var block = std.ArrayList(u8).empty;
    defer block.deinit(allocator);
    try enc.encode(&block, ":method", "GET", .incremental, false);
    try enc.encode(&block, ":scheme", "http", .incremental, false);
    try enc.encode(&block, ":path", path, .incremental, false);
    try enc.encode(&block, ":authority", "example.test", .incremental, false);
    return block.toOwnedSlice(allocator);
}

test "the first frame of a connection must be SETTINGS" {
    const a = std.testing.allocator;
    var client = try Session.init(a, .client, .{});
    defer client.deinit();
    try client.startHandshake();

    var buf: [64]u8 = undefined;
    const ping = buildFrame(&buf, .ping, 0, 0, &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    try std.testing.expectError(Error.ProtocolViolation, client.feed(ping));
    try std.testing.expect(client.closed);
    // A GOAWAY must be queued so the peer learns why.
    try std.testing.expect(client.outbound.items.len > 0);
}

test "a client rejects ENABLE_PUSH sent by the server" {
    const a = std.testing.allocator;
    var client = try Session.init(a, .client, .{});
    defer client.deinit();
    try client.startHandshake();

    var buf: [64]u8 = undefined;
    var payload: [6]u8 = undefined;
    frameMod.serializeSetting(&payload, @backingInt(frameMod.SettingsId.enablePush), 1);
    const settings = buildFrame(&buf, .settings, 0, 0, &payload);
    try std.testing.expectError(Error.ProtocolViolation, client.feed(settings));
    try std.testing.expect(client.closed);
}

test "a server does not advertise ENABLE_PUSH" {
    const a = std.testing.allocator;
    var server = try Session.init(a, .server, .{});
    defer server.deinit();
    try server.startHandshake();
    // The first frame must be SETTINGS; it must not carry ENABLE_PUSH.
    try std.testing.expect(server.outbound.items.len >= 9);
    try std.testing.expectEqual(frameMod.FrameType.settings, @field(FrameHeader.parse(server.outbound.items[0..9]), "frameType"));
    var i: usize = 0;
    while (i + 6 <= server.outbound.items.len - 9) : (i += 6) {
        const id = std.mem.readInt(u16, server.outbound.items[9 + i ..][0..2], .big);
        try std.testing.expect(id != @backingInt(frameMod.SettingsId.enablePush));
    }
}

test "settings are applied in order and adjust the stream windows" {
    const a = std.testing.allocator;
    var client = try Session.init(a, .client, .{});
    defer client.deinit();
    try client.startHandshake();

    // Open a stream so the window adjustment is observable.
    const fields = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":authority", .value = "example.test" },
    };
    try client.sendHeaders(1, &fields, true);
    const st = client.streamPtr(1).?;
    try std.testing.expectEqual(@as(i64, 65535), st.sendWindow);

    var buf: [64]u8 = undefined;
    var payload: [6]u8 = undefined;
    frameMod.serializeSetting(&payload, @backingInt(frameMod.SettingsId.initialWindowSize), 1000);
    const settings = buildFrame(&buf, .settings, 0, 0, &payload);
    try client.feed(settings);
    try std.testing.expectEqual(@as(i64, 1000), client.streamPtr(1).?.sendWindow);
}

test "a request over the concurrency limit is refused, not fatal" {
    const a = std.testing.allocator;
    var server = try Session.init(a, .server, .{});
    defer server.deinit();
    server.localSettings.maxConcurrentStreams = 1;
    try server.startHandshake();

    var buf: [256]u8 = undefined;
    const handshake = clientHandshake(&buf);
    try server.feed(handshake);
    server.outbound.clearRetainingCapacity();

    const block = try requestBlock(a, "/one");
    defer a.free(block);
    const first = buildFrame(buf[24..], .headers, 0x04, 1, block);
    try server.feed(first);
    server.outbound.clearRetainingCapacity();

    // The second concurrent request exceeds the advertised limit.
    const second = buildFrame(buf[24..], .headers, 0x04, 3, block);
    try server.feed(second);

    // The connection survives and an RST_STREAM (REFUSED_STREAM) is sent.
    try std.testing.expect(!server.closed);
    try std.testing.expect(server.outbound.items.len >= 9);
    const hdr = FrameHeader.parse(server.outbound.items[0..9]);
    try std.testing.expectEqual(FrameType.rstStream, hdr.frameType);
    try std.testing.expectEqual(@as(u31, 3), hdr.streamId);
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, server.outbound.items[9..13], .big));
}

test "data on a closed stream is a stream error" {
    const a = std.testing.allocator;
    var client = try Session.init(a, .client, .{});
    defer client.deinit();
    try client.startHandshake();
    // The peer SETTINGS frame must be the first inbound frame.
    {
        var sbuf: [64]u8 = undefined;
        const settings = buildFrame(&sbuf, .settings, 0, 0, &empty_settings);
        try client.feed(settings);
    }

    const fields = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":authority", .value = "example.test" },
    };
    try client.sendHeaders(1, &fields, true);
    // Reset the stream so a late DATA frame hits a closed stream.
    try client.sendRstStream(1, .cancel);
    client.outbound.clearRetainingCapacity();

    var buf: [64]u8 = undefined;
    const data = buildFrame(&buf, .data, 0, 1, "x");
    // The frame must not kill the connection.
    client.feed(data) catch |e| {
        try std.testing.expect(e == Error.ProtocolViolation);
    };
    try std.testing.expect(!client.closed);
}

test "a zero window update increment is a stream error" {
    const a = std.testing.allocator;
    var client = try Session.init(a, .client, .{});
    defer client.deinit();
    try client.startHandshake();
    {
        var sbuf: [64]u8 = undefined;
        const settings = buildFrame(&sbuf, .settings, 0, 0, &empty_settings);
        try client.feed(settings);
    }

    const fields = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":authority", .value = "example.test" },
    };
    try client.sendHeaders(1, &fields, true);
    client.outbound.clearRetainingCapacity();

    var buf: [64]u8 = undefined;
    const wu = buildFrame(&buf, .windowUpdate, 0, 1, &[_]u8{ 0, 0, 0, 0 });
    try client.feed(wu);
    try std.testing.expect(!client.closed);
    try std.testing.expect(client.outbound.items.len >= 9);
    const hdr = FrameHeader.parse(client.outbound.items[0..9]);
    try std.testing.expectEqual(FrameType.rstStream, hdr.frameType);
}

test "the sender never exceeds the peer's flow-control window" {
    const a = std.testing.allocator;
    var client = try Session.init(a, .client, .{});
    defer client.deinit();
    try client.startHandshake();

    const fields = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":authority", .value = "example.test" },
    };
    try client.sendHeaders(1, &fields, false);

    // The peer narrows the initial window to 100 bytes.
    client.peerSettings.initialWindowSize = 100;
    client.streamPtr(1).?.sendWindow = 100;

    const payload: [500]u8 = @splat(0);
    const sent = try client.sendData(1, &payload, false);
    try std.testing.expectEqual(@as(usize, 100), sent);
    try std.testing.expectEqual(@as(i64, 0), client.streamPtr(1).?.sendWindow);
    // The connection window is untouched by the stream window.
    try std.testing.expectEqual(@as(i64, 65535 - 100), client.connSendWindow);
}

test "the receiver grants credit with WINDOW_UPDATE once half the window is used" {
    const a = std.testing.allocator;
    var server = try Session.init(a, .server, .{});
    defer server.deinit();
    try server.startHandshake();

    var buf: [256]u8 = undefined;
    const handshake = clientHandshake(&buf);
    try server.feed(handshake);
    server.outbound.clearRetainingCapacity();

    const block = try requestBlock(a, "/data");
    defer a.free(block);
    const headers = buildFrame(buf[24..], .headers, 0x04, 1, block);
    try server.feed(headers);
    server.outbound.clearRetainingCapacity();

    // 40000 bytes pass the half-window threshold (32767). They are sent
    // in frames that respect SETTINGS_MAX_FRAME_SIZE.
    const payload = try a.alloc(u8, 40000);
    defer a.free(payload);
    @memset(payload, 'x');
    var frame_buf: [16384 + 9]u8 = undefined;
    var sent: usize = 0;
    while (sent < payload.len) {
        const take = @min(@as(usize, 16384), payload.len - sent);
        const data = buildFrame(&frame_buf, .data, 0, 1, payload[sent..][0..take]);
        try server.feed(data);
        sent += take;
    }

    // A connection-level WINDOW_UPDATE must have been queued.
    var sawConnUpdate = false;
    var off: usize = 0;
    while (off + 9 <= server.outbound.items.len) {
        const hdr = FrameHeader.parse(server.outbound.items[off..][0..9]);
        if (hdr.frameType == .windowUpdate and hdr.streamId == 0) sawConnUpdate = true;
        off += 9 + @as(usize, hdr.length);
    }
    try std.testing.expect(sawConnUpdate);
    try std.testing.expect(!server.closed);
}

test "an empty DATA frame with END_STREAM closes the send side" {
    const a = std.testing.allocator;
    var client = try Session.init(a, .client, .{});
    defer client.deinit();
    try client.startHandshake();

    const fields = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":authority", .value = "example.test" },
    };
    try client.sendHeaders(1, &fields, false);
    client.outbound.clearRetainingCapacity();

    const sent = try client.sendData(1, "", true);
    try std.testing.expectEqual(@as(usize, 0), sent);
    // A zero-length DATA frame with END_STREAM was written.
    try std.testing.expect(client.outbound.items.len >= 9);
    const hdr = FrameHeader.parse(client.outbound.items[0..9]);
    try std.testing.expectEqual(FrameType.data, hdr.frameType);
    try std.testing.expectEqual(@as(u24, 0), hdr.length);
    try std.testing.expect(hdr.flags & Flags.END_STREAM != 0);
}

test "client stream identifiers never wrap around" {
    const a = std.testing.allocator;
    var client = try Session.init(a, .client, .{});
    defer client.deinit();
    client.nextStreamId = 0x7FFFFFFF;
    try std.testing.expectEqual(@as(u31, 0x7FFFFFFF), try client.nextClientStreamId());
    try std.testing.expectError(Error.ProtocolViolation, client.nextClientStreamId());
}

test "the GOAWAY last-stream identifier never increases" {
    const a = std.testing.allocator;
    var server = try Session.init(a, .server, .{});
    defer server.deinit();
    try server.startHandshake();
    server.outbound.clearRetainingCapacity();

    try server.beginGracefulShutdown();
    // A second, lower identifier is allowed; a higher one is not.
    try server.finishGracefulShutdown();
    try std.testing.expect(server.outbound.items.len >= 34);
    const first = FrameHeader.parse(server.outbound.items[0..9]);
    try std.testing.expectEqual(FrameType.goaway, first.frameType);
    try std.testing.expectEqual(@as(u31, 0x7FFFFFFF), std.mem.readInt(u32, server.outbound.items[9..13], .big));
    // The second GOAWAY follows the first one (9-byte header + 8-byte body).
    const second = FrameHeader.parse(server.outbound.items[17..26]);
    try std.testing.expectEqual(FrameType.goaway, second.frameType);
    try std.testing.expectEqual(@as(u31, 0), std.mem.readInt(u32, server.outbound.items[26..30], .big));
}

test "sensitive headers are never placed in the dynamic table" {
    const a = std.testing.allocator;
    var client = try Session.init(a, .client, .{});
    defer client.deinit();
    try client.startHandshake();
    // Only the HEADERS frame must be in the outbound buffer.
    client.outbound.clearRetainingCapacity();

    const fields = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":authority", .value = "example.test" },
        .{ .name = "authorization", .value = "Bearer secret-token" },
    };
    try client.sendHeaders(1, &fields, true);

    // Decode the emitted block with a fresh decoder: the sensitive value
    // must not have been indexed.
    var dec = hpackMod.Decoder.init(a);
    defer dec.deinit();
    const res = try dec.decode(client.outbound.items[frameMod.FRAME_HEADER_SIZE..]);
    defer {
        for (res.fields) |f| {
            a.free(f.name);
            a.free(f.value);
        }
        a.free(res.fields);
    }
    try std.testing.expectEqual(@as(usize, 5), res.fields.len);
    try std.testing.expectEqualStrings("authorization", res.fields[4].name);
    try std.testing.expectEqualStrings("Bearer secret-token", res.fields[4].value);
    for (dec.dyn.entries.items) |e| {
        try std.testing.expect(!std.mem.eql(u8, e.name, "authorization"));
    }
}

test "outgoing header names are lowercased and hop-by-hop fields dropped" {
    const a = std.testing.allocator;
    var client = try Session.init(a, .client, .{});
    defer client.deinit();
    try client.startHandshake();
    client.outbound.clearRetainingCapacity();

    const fields = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":authority", .value = "example.test" },
        .{ .name = "User-Agent", .value = "httpx" },
        .{ .name = "Connection", .value = "close" },
    };
    try client.sendHeaders(1, &fields, true);

    var dec = hpackMod.Decoder.init(a);
    defer dec.deinit();
    const res = try dec.decode(client.outbound.items[frameMod.FRAME_HEADER_SIZE..]);
    defer {
        for (res.fields) |f| {
            a.free(f.name);
            a.free(f.value);
        }
        a.free(res.fields);
    }
    try std.testing.expectEqual(@as(usize, 5), res.fields.len);
    try std.testing.expectEqualStrings("user-agent", res.fields[4].name);
    for (res.fields) |f| {
        try std.testing.expect(!std.mem.eql(u8, f.name, "connection"));
    }
}

test "a malformed request header list is a stream error" {
    const a = std.testing.allocator;
    var server = try Session.init(a, .server, .{});
    defer server.deinit();
    try server.startHandshake();

    var buf: [256]u8 = undefined;
    const handshake = clientHandshake(&buf);
    try server.feed(handshake);
    server.outbound.clearRetainingCapacity();

    // A request without :method/:scheme/:path is malformed.
    var enc = hpackMod.Encoder.init(a);
    defer enc.deinit();
    var block = std.ArrayList(u8).empty;
    defer block.deinit(a);
    try enc.encode(&block, ":method", "GET", .incremental, false);
    try enc.encode(&block, "x-custom", "1", .incremental, false);

    const headers = buildFrame(buf[24..], .headers, 0x04, 1, block.items);
    try server.feed(headers);
    // The connection survives; the stream is reset.
    try std.testing.expect(!server.closed);
    try std.testing.expect(server.outbound.items.len >= 9);
    const hdr = FrameHeader.parse(server.outbound.items[0..9]);
    try std.testing.expectEqual(FrameType.rstStream, hdr.frameType);
}
