//! HTTP/2 connection engine (RFC 9113), modeled on nghttp2's session
//! semantics: preface validation, SETTINGS exchange with ACK tracking,
//! CONTINUATION assembly, complete flow-control accounting, GOAWAY
//! graceful shutdown, PING keepalive, and strict error escalation.
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
    OutOfMemory,
};

pub const DEFAULT_HEADER_TABLE_SIZE: u32 = 4096;
pub const DEFAULT_MAX_CONCURRENT: u32 = 100;
pub const DEFAULT_INITIAL_WINDOW: u32 = 65535;
pub const DEFAULT_MAX_HEADER_LIST: u32 = 0xFFFFFFFF;

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
    prefaceMatched: usize = 0,
    /// When set, ONLY CONTINUATION frames for this stream are legal next.
    continuationSid: ?u31 = null,
    continuationStream: ?*Stream = null,

    // HPACK contexts (connection-wide).
    hdec: hpackMod.Decoder,
    henc: hpackMod.Encoder,

    streams: std.AutoHashMap(u31, *Stream),
    activePeerStreams: usize = 0,

    localSettings: Settings = .{},
    peerSettings: Settings = .{},
    settingsAcked: bool = false,

    nextStreamId: u31 = 1,
    largestPeerStream: u31 = 0,

    connSendWindow: i64 = 65535,
    connRecvPending: i64 = 0,

    goawaySent: bool = false,
    goawayLastSidSent: u31 = 0x7FFFFFFF,
    goawayReceived: bool = false,
    closed: bool = false,
    awaitingSettingsAck: bool = false,

    /// END_STREAM flag carried by an in-progress HEADERS/CONTINUATION chain.
    continuationEndStream: bool = false,
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

    // -- lifecycle ------------------------------------------------------------

    /// Client: emit magic + initial SETTINGS. Server: initial SETTINGS.
    pub fn startHandshake(self: *Session) !void {
        if (self.role == .client) {
            try self.outbound.appendSlice(self.allocator, frameMod.CONNECTION_PREFACE);
        }
        try self.sendInitialSettings();
    }

    fn sendInitialSettings(self: *Session) !void {
        const es = self.localSettings.entries();
        try frameMod.writeSettings(&self.outbound, self.allocator, &es);
        self.awaitingSettingsAck = true;
    }

    // -- inbound ---------------------------------------------------------------

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

            // Stream-id legality up front.
            switch (hdr.frameType) {
                .data, .headers, .rstStream, .continuation, .pushPromise => {
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
                error.FrameTooLarge => return self.connError(.frameSizeError),
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
            .headers => |h| try self.handleHeadersStart(hdr.streamId, h.block, h.endHeaders, h.endStream),
            .continuation => |c| try self.handleContinuation(hdr.streamId, c.block, c.endHeaders),
            .data => |d| try self.handleData(hdr.streamId, d.data, d.endStream),
            .rstStream => |r| {
                if (self.role == .server and hdr.streamId <= self.largestPeerStream) {}
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
                } else if (hdr.streamId > self.largestPeerStream) {
                    // RST_STREAM cannot create a stream. On an idle stream it
                    // is a connection-level PROTOCOL_ERROR (RFC 9113 5.4.1).
                    return self.connError(.protocolError);
                }
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
        var windowDelta: i64 = 0;
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
                .enablePush => self.peerSettings.enablePush = e.value,
                .maxConcurrentStreams => self.peerSettings.maxConcurrentStreams = e.value,
                .initialWindowSize => {
                    windowDelta = @as(i64, e.value) - self.peerSettings.initialWindowSize;
                    self.peerSettings.initialWindowSize = e.value;
                },
                .maxFrameSize => self.peerSettings.maxFrameSize = e.value,
                .maxHeaderListSize => self.peerSettings.maxHeaderListSize = e.value,
                _ => {}, // unknown ignored
            }
        }
        if (windowDelta != 0) {
            var it = self.streams.valueIterator();
            while (it.next()) |sp| {
                sp.*.sendWindow += windowDelta;
                if (sp.*.sendWindow > frameMod.MAX_WINDOW) {
                    return self.connError(.flowControlError);
                }
            }
        }
    }

    fn handleHeadersStart(self: *Session, sid: u31, block: []const u8, endHeaders: bool, endStream: bool) Error!void {
        var st: *Stream = blk: {
            if (self.streamPtr(sid)) |existing| break :blk existing;
            if (self.goawayLastStream) |last| {
                if (sid > last) return Error.StreamClosed;
            }
            // New peer-initiated request stream. Concurrency is enforced
            // against OUR advertised limit (localSettings), not the peer's.
            if (self.role == .server) {
                if (sid <= self.largestPeerStream) return self.connError(.protocolError);
                if (sid % 2 == 0) return self.connError(.protocolError);
                if (self.goawaySent) return Error.StreamClosed;
                if (self.activePeerStreams >= self.localSettings.maxConcurrentStreams) {
                    return self.connError(.protocolError);
                }
            }
            const s = try self.allocator.create(Stream);
            s.* = Stream.init(self.allocator, sid);
            s.state = .idle;
            try self.streams.put(sid, s);
            if (self.role == .server and sid % 2 == 1) {
                self.activePeerStreams += 1;
            }
            if (sid > self.largestPeerStream) self.largestPeerStream = sid;
            break :blk s;
        };

        if (endHeaders) {
            st.onRecvHeaders(endStream) catch |e| switch (e) {
                error.StreamClosed => return self.connError(.streamClosed),
                error.ProtocolError => return self.connError(.protocolError),
            };
            try self.decodeAndDeliver(st, block);
            // A fully-received request/response (both sides ended) leaves
            // no further work: reap now (`st` is dead after this).
            if (st.state == .closed) self.reapClosedStream(sid);
        } else {
            // Open the stream state now; END_STREAM applies at chain end.
            st.headerBlock = .empty;
            st.headerBlock.?.appendSlice(self.allocator, block) catch return Error.OutOfMemory;
            self.continuationSid = sid;
            self.continuationStream = st;
            self.continuationEndStream = endStream;
        }
    }

    fn handleContinuation(self: *Session, sid: u31, block: []const u8, endHeaders: bool) Error!void {
        const st = self.continuationStream orelse return self.connError(.protocolError);
        if (st.id != sid) return self.connError(.protocolError);
        st.headerBlock.?.appendSlice(self.allocator, block) catch return Error.OutOfMemory;
        if (!endHeaders) return;

        const endStream = self.continuationEndStream;
        self.continuationSid = null;
        self.continuationStream = null;

        st.onRecvHeaders(endStream) catch |e| switch (e) {
            error.StreamClosed => return self.connError(.streamClosed),
            error.ProtocolError => return self.connError(.protocolError),
        };
        try self.decodeAndDeliver(st, "");
        if (st.state == .closed) self.reapClosedStream(sid);
    }

    fn decodeAndDeliver(self: *Session, st: *Stream, finalFrag: []const u8) Error!void {
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

        // Pseudo-header validation (RFC 9113 Section 8.3)
        if (res.fields.len > 0 and !validatePseudoHeaders(res.fields)) {
            return self.connError(.protocolError);
        }

        const endStream = st.endStreamRecv;
        if (self.cbs.onHeaders) |cb| {
            cb(self.cbs.ctx, st.id, res.fields, endStream) catch return Error.ProtocolViolation;
        }
        if (endStream) {
            if (self.cbs.onStreamEnd) |cb| {
                cb(self.cbs.ctx, st.id) catch return Error.ProtocolViolation;
            }
        }
    }

    fn validatePseudoHeaders(fields: []hpackMod.HeaderField) bool {
        var seenMethod = false;
        var seenPath = false;
        var seenScheme = false;
        var seenAuthority = false;
        var seenStatus = false;
        var seenRegular = false;
        for (fields) |f| {
            // RFC 9113 Section 8.2.1: Header field names MUST be lowercase ASCII.
            for (f.name) |c| {
                if (std.ascii.isUpper(c)) return false;
            }

            // RFC 9113 Section 8.2.2: Connection-specific header fields MUST NOT be sent.
            if (std.mem.eql(u8, f.name, "connection") or
                std.mem.eql(u8, f.name, "keep-alive") or
                std.mem.eql(u8, f.name, "proxy-connection") or
                std.mem.eql(u8, f.name, "transfer-encoding") or
                std.mem.eql(u8, f.name, "upgrade"))
            {
                return false;
            }
            if (std.mem.eql(u8, f.name, "te") and !std.mem.eql(u8, f.value, "trailers")) {
                return false;
            }

            const isPseudo = f.name.len > 0 and f.name[0] == ':';
            if (isPseudo) {
                // Pseudo-headers MUST appear before regular header fields.
                if (seenRegular) return false;
                if (std.mem.eql(u8, f.name, ":method")) {
                    if (seenMethod or seenStatus) return false;
                    seenMethod = true;
                } else if (std.mem.eql(u8, f.name, ":path")) {
                    if (seenPath or seenStatus) return false;
                    seenPath = true;
                } else if (std.mem.eql(u8, f.name, ":scheme")) {
                    if (seenScheme or seenStatus) return false;
                    seenScheme = true;
                } else if (std.mem.eql(u8, f.name, ":authority")) {
                    if (seenAuthority) return false;
                    seenAuthority = true;
                } else if (std.mem.eql(u8, f.name, ":status")) {
                    if (seenStatus or seenMethod or seenPath or seenScheme) return false;
                    seenStatus = true;
                } else {
                    return false;
                }
                // :path, :method, :scheme, :status cannot be empty.
                if (std.mem.eql(u8, f.name, ":path") or
                    std.mem.eql(u8, f.name, ":method") or
                    std.mem.eql(u8, f.name, ":scheme") or
                    std.mem.eql(u8, f.name, ":status"))
                {
                    if (f.value.len == 0) return false;
                }
            } else {
                seenRegular = true;
            }
        }
        return true;
    }

    fn handleData(self: *Session, sid: u31, data: []const u8, endStream: bool) Error!void {
        // Connection-level flow control always applies.
        self.connRecvPending += @intCast(data.len);
        if (self.connRecvPending > self.localSettings.initialWindowSize) {
            return self.connError(.flowControlError);
        }

        const st = self.streamPtr(sid) orelse return self.connError(.protocolError);
        if (!st.state.canRecvData()) {
            if (st.state == .idle) return self.connError(.protocolError);
            return self.connError(.streamClosed);
        }
        if (!st.consumeRecv(@intCast(data.len))) {
            return self.connError(.flowControlError);
        }

        if (data.len > 0) {
            if (self.cbs.onData) |cb| cb(self.cbs.ctx, sid, data) catch return Error.ProtocolViolation;
        }
        st.onRecvData(endStream) catch |e| switch (e) {
            error.StreamClosed => return self.connError(.streamClosed),
            error.ProtocolError => return self.connError(.protocolError),
        };
        if (endStream) {
            if (self.cbs.onStreamEnd) |cb| cb(self.cbs.ctx, sid) catch return Error.ProtocolViolation;
        }
        // Fully-received streams (both sides ended) are reaped here, so
        // `maybeEmitWindowUpdates` below simply skips the missing entry.
        // `st` is dead after this point.
        if (st.state == .closed) self.reapClosedStream(sid);
        try self.maybeEmitWindowUpdates(sid);
    }

    /// Sends WINDOW_UPDATEs once >= half the window has been consumed.
    fn maybeEmitWindowUpdates(self: *Session, sid: u31) Error!void {
        const half: i64 = @divTrunc(@as(i64, self.localSettings.initialWindowSize), 2);
        if (self.connRecvPending >= half) {
            const inc: u31 = @intCast(self.connRecvPending);
            try frameMod.writeWindowUpdate(&self.outbound, self.allocator, 0, inc);
            self.connRecvPending = 0;
        }
        if (self.streamPtr(sid)) |st| {
            if (st.recvPending >= half and st.state != .closed) {
                const inc: u31 = @intCast(st.recvPending);
                try frameMod.writeWindowUpdate(&self.outbound, self.allocator, sid, inc);
                st.recvPending = 0;
                st.recvWindow += inc;
            }
        }
    }

    fn handleWindowUpdate(self: *Session, sid: u31, inc: u31) Error!void {
        if (inc == 0) return self.connError(.protocolError);
        const amount: i64 = @intCast(inc);
        if (sid == 0) {
            self.connSendWindow += amount;
            if (self.connSendWindow > frameMod.MAX_WINDOW) return self.connError(.flowControlError);
            return;
        }
        const st = self.streamPtr(sid) orelse return;
        if (st.state == .idle) return self.connError(.protocolError);
        if (st.state == .closed) return;
        st.sendWindow += amount;
        if (st.sendWindow > frameMod.MAX_WINDOW) return self.connError(.flowControlError);
    }

    // -- outbound ----------------------------------------------------------------

    /// Encodes and sends HEADERS, splitting into CONTINUATIONs as needed.
    pub fn sendHeaders(self: *Session, sid: u31, fields: []const hpackMod.HeaderField, endStream: bool) !void {
        var block = std.ArrayList(u8).empty;
        defer block.deinit(self.allocator);
        for (fields) |f| {
            try self.henc.encode(&block, f.name, f.value, .incremental, false);
        }
        try self.sendHeaderBlock(sid, block.items, endStream);
    }

    pub fn sendHeaderBlock(self: *Session, sid: u31, block: []const u8, endStream: bool) !void {
        const max = @min(@as(usize, self.peerSettings.maxFrameSize), 16384);
        if (self.streamPtr(sid) == null) {
            const s = try self.allocator.create(Stream);
            s.* = Stream.init(self.allocator, sid);
            s.state = .idle;
            try self.streams.put(sid, s);
        }
        const st = self.streamPtr(sid).?;
        try st.onSendHeaders(endStream);
        // Response/trailer HEADERS with END_STREAM on an already
        // half-closed (remote) stream close it fully. The frame writes
        // below only use `sid` (never `st`), so reaping at the end is
        // borrow-safe.
        const sendClosed = st.state == .closed;

        var flags: u8 = 0;
        if (endStream) flags |= Flags.END_STREAM;

        if (block.len <= max) {
            if (flags == 0) flags |= Flags.END_HEADERS else flags |= Flags.END_HEADERS;
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
                var f2: u8 = flags & Flags.END_STREAM;
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
        if (sendClosed) self.reapClosedStream(sid);
    }

    /// Sends DATA respecting maxFrameSize and available windows.
    /// Returns bytes actually queued (rest needs WINDOW_UPDATE first).
    pub fn sendData(self: *Session, sid: u31, data: []const u8, endStream: bool) Error!usize {
        const st = self.streamPtr(sid) orelse return Error.StreamClosed;
        if (!st.state.canSendData() or st.endStreamSent) return Error.StreamClosed;

        const budgetWin = @min(self.connSendWindow, st.sendWindow);
        if (budgetWin <= 0) return 0;

        const max = @min(@as(usize, self.peerSettings.maxFrameSize), 16384);
        const allowed: usize = @min(@as(usize, @intCast(budgetWin)), data.len);
        var sent: usize = 0;

        while (sent < allowed) {
            const take = @min(max, allowed - sent);
            const chunk = data[sent..][0..take];
            const fin = endStream and sent + take == data.len;
            frameMod.writeData(&self.outbound, self.allocator, sid, chunk, fin) catch return Error.OutOfMemory;
            sent += take;
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
        if (sid == 0) {
            // The connection receive window is represented by pending
            // consumed bytes; the emitted update replenishes that credit.
            if (self.connRecvPending < 0 or inc > frameMod.MAX_WINDOW) return Error.FlowControlError;
            self.connRecvPending = @max(@as(i64, 0), self.connRecvPending - @as(i64, inc));
            try frameMod.writeWindowUpdate(&self.outbound, self.allocator, 0, inc);
            return;
        }
        if (self.streamPtr(sid)) |st| {
            const next = st.recvWindow + @as(i64, inc);
            if (next > frameMod.MAX_WINDOW) return Error.FlowControlError;
            st.recvWindow = next;
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

    /// Final GOAWAY with the real last-stream-id.
    pub fn finishGracefulShutdown(self: *Session) !void {
        const lastSid: u31 = if (self.role == .server)
            self.largestPeerStream
        else
            self.nextStreamId -| 2;
        try frameMod.writeGoaway(&self.outbound, self.allocator, lastSid, 0, "");
    }

    pub fn sendConnectionClose(self: *Session, code: ErrorCode, debug: []const u8) !void {
        try frameMod.writeGoaway(&self.outbound, self.allocator, 0x7FFFFFFF, @backingInt(code), debug);
    }

    /// Queues a fatal GOAWAY then returns the mapped protocol error.
    fn connError(self: *Session, code: ErrorCode) Error {
        if (!self.closed) {
            self.closed = true;
            const lastSid: u31 = if (self.role == .server) self.largestPeerStream else 0x7FFFFFFF;
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
            if (self.role == .server and sid % 2 == 1 and self.activePeerStreams > 0) {
                self.activePeerStreams -= 1;
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
        if (id > 0x7FFFFFFF) return Error.ProtocolViolation;
        self.nextStreamId += 2;
        return id;
    }
};

// Loopback integration test: full client<->server exchange

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

test "validatePseudoHeaders rejects uppercase, forbidden headers and mixed pseudo-headers" {
    // Uppercase header name -> rejected
    var badUpper = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = "Content-Type", .value = "text/plain" },
    };
    try std.testing.expect(!Session.validatePseudoHeaders(&badUpper));

    // Forbidden 'connection' header -> rejected
    var badConn = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = "connection", .value = "keep-alive" },
    };
    try std.testing.expect(!Session.validatePseudoHeaders(&badConn));

    // Forbidden 'te' header with value other than 'trailers' -> rejected
    var badTe = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = "te", .value = "gzip" },
    };
    try std.testing.expect(!Session.validatePseudoHeaders(&badTe));

    // Valid 'te: trailers' -> accepted
    var goodTe = [_]hpackMod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = "te", .value = "trailers" },
    };
    try std.testing.expect(Session.validatePseudoHeaders(&goodTe));

    // Mixed request and response pseudo-headers -> rejected
    var badMixed = [_]hpackMod.HeaderField{
        .{ .name = ":status", .value = "200" },
        .{ .name = ":method", .value = "GET" },
    };
    try std.testing.expect(!Session.validatePseudoHeaders(&badMixed));
}
