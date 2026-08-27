//! HTTP/2 connection engine (RFC 9113), modeled on nghttp2's session
//! semantics: preface validation, SETTINGS exchange with ACK tracking,
//! CONTINUATION assembly, complete flow-control accounting, GOAWAY
//! graceful shutdown, PING keepalive, and strict error escalation.
//!
//! I/O model: feed() accepts arbitrary network chunks; outbound frames
//! accumulate in `outbound` which the owner flushes to the wire. Protocol
//! violations queue a terminating GOAWAY and surface as a returned error.

const std = @import("std");
const Allocator = std.mem.Allocator;
const frame_mod = @import("frame.zig");
const hpack_mod = @import("hpack.zig");
const stream_mod = @import("stream.zig");

const FrameHeader = frame_mod.FrameHeader;
const FrameType = frame_mod.FrameType;
const Flags = frame_mod.Flags;
const Stream = stream_mod.Stream;
const ErrorCode = stream_mod.ErrorCode;

pub const Error = frame_mod.Error || hpack_mod.Error || stream_mod.Stream.RecvError || error{
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
    header_table_size: u32 = DEFAULT_HEADER_TABLE_SIZE,
    enable_push: u32 = 1,
    max_concurrent_streams: u32 = DEFAULT_MAX_CONCURRENT,
    initial_window_size: u32 = DEFAULT_INITIAL_WINDOW,
    max_frame_size: u32 = frame_mod.DEFAULT_MAX_FRAME_SIZE,
    max_header_list_size: u32 = DEFAULT_MAX_HEADER_LIST,

    pub fn entries(self: *const Settings) [6]frame_mod.SettingEntry {
        return .{
            .{ .id = @intFromEnum(frame_mod.SettingsId.header_table_size), .value = self.header_table_size },
            .{ .id = @intFromEnum(frame_mod.SettingsId.enable_push), .value = self.enable_push },
            .{ .id = @intFromEnum(frame_mod.SettingsId.max_concurrent_streams), .value = self.max_concurrent_streams },
            .{ .id = @intFromEnum(frame_mod.SettingsId.initial_window_size), .value = self.initial_window_size },
            .{ .id = @intFromEnum(frame_mod.SettingsId.max_frame_size), .value = self.max_frame_size },
            .{ .id = @intFromEnum(frame_mod.SettingsId.max_header_list_size), .value = self.max_header_list_size },
        };
    }
};

// Callbacks

pub const Callbacks = struct {
    ctx: ?*anyopaque = null,
    /// Complete header list decoded for `sid`.
    onHeaders: ?*const fn (ctx: ?*anyopaque, sid: u31, fields: []hpack_mod.HeaderField, end_stream: bool) anyerror!void = null,
    /// DATA payload chunk (already de-padded).
    onData: ?*const fn (ctx: ?*anyopaque, sid: u31, data: []const u8) anyerror!void = null,
    /// Stream fully consumed our side (END_STREAM received).
    onStreamEnd: ?*const fn (ctx: ?*anyopaque, sid: u31) anyerror!void = null,
    onReset: ?*const fn (ctx: ?*anyopaque, sid: u31, code: u32) void = null,
    onPingAck: ?*const fn (ctx: ?*anyopaque, opaque_data: [8]u8) void = null,
    onGoaway: ?*const fn (ctx: ?*anyopaque, last_sid: u31, code: u32, debug: []const u8) void = null,
};

// Session

pub const Role = enum { client, server };

pub const Session = struct {
    allocator: Allocator,
    role: Role,
    cbs: Callbacks = .{},

    // Inbound reassembly.
    inbuf: std.ArrayList(u8) = .empty,
    preface_done: bool = false,
    preface_matched: usize = 0,
    /// When set, ONLY CONTINUATION frames for this stream are legal next.
    continuation_sid: ?u31 = null,
    continuation_stream: ?*Stream = null,

    // HPACK contexts (connection-wide).
    hdec: hpack_mod.Decoder,
    henc: hpack_mod.Encoder,

    streams: std.AutoHashMap(u31, *Stream),
    active_peer_streams: usize = 0,

    local_settings: Settings = .{},
    peer_settings: Settings = .{},
    settings_acked: bool = false,

    next_stream_id: u31 = 1,
    largest_peer_stream: u31 = 0,

    conn_send_window: i64 = 65535,
    conn_recv_pending: i64 = 0,

    goaway_sent: bool = false,
    goaway_last_sid_sent: u31 = 0x7FFFFFFF,
    goaway_received: bool = false,
    closed: bool = false,
    awaiting_settings_ack: bool = false,

    /// END_STREAM flag carried by an in-progress HEADERS/CONTINUATION chain.
    continuation_end_stream: bool = false,
    /// Last stream ID accepted by the peer's most recent GOAWAY.
    goaway_last_stream: ?u31 = null,

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
        s.hdec = hpack_mod.Decoder.init(allocator);
        s.henc = hpack_mod.Encoder.init(allocator);
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
            try self.outbound.appendSlice(self.allocator, frame_mod.CONNECTION_PREFACE);
        }
        try self.sendInitialSettings();
    }

    fn sendInitialSettings(self: *Session) !void {
        const es = self.local_settings.entries();
        try frame_mod.writeSettings(&self.outbound, self.allocator, &es);
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

        if (!self.preface_done) {
            if (self.role == .server) {
                try self.consumePreface();
                if (!self.preface_done) return;
            } else {
                // Clients sent the magic themselves; peer sends SETTINGS.
                self.preface_done = true;
            }
        }

        while (true) {
            if (self.inbuf.items.len < frame_mod.FRAME_HEADER_SIZE) return;
            var hdr_bytes: [9]u8 = undefined;
            @memcpy(&hdr_bytes, self.inbuf.items[0..9]);
            const hdr = FrameHeader.parse(&hdr_bytes);

            if (@as(usize, hdr.length) > self.peer_settings.max_frame_size) {
                return self.connError(.frame_size_error);
            }

            const total = 9 + @as(usize, hdr.length);
            if (self.inbuf.items.len < total) return;

            const payload = self.inbuf.items[9..total];

            // Stream-id legality up front.
            switch (hdr.frame_type) {
                .data, .headers, .rst_stream, .continuation, .push_promise => {
                    if (hdr.stream_id == 0) return self.connError(.protocol_error);
                },
                .settings, .ping, .goaway => {
                    if (hdr.stream_id != 0) return self.connError(.protocol_error);
                },
                else => {},
            }

            // CONTINUATION exclusivity rule.
            if (self.continuation_sid != null) {
                if (hdr.frame_type != .continuation or hdr.stream_id != self.continuation_sid.?) {
                    return self.connError(.protocol_error);
                }
            } else if (hdr.frame_type == .continuation) {
                return self.connError(.protocol_error);
            }

            const parsed = frame_mod.Frame.parse(hdr, payload, self.allocator) catch |e| switch (e) {
                error.OutOfMemory => return Error.OutOfMemory,
                error.ProtocolError => return self.connError(.protocol_error),
                else => return self.connError(.frame_size_error),
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
        const want = frame_mod.CONNECTION_PREFACE.len;
        const buf = self.inbuf.items;
        const cmp_len = @min(buf.len, want);
        if (!std.mem.eql(u8, buf[0..cmp_len], frame_mod.CONNECTION_PREFACE[0..cmp_len])) {
            return Error.ProtocolViolation;
        }
        if (buf.len < want) return;
        // Consume the preface bytes so frame parsing starts at offset 0.
        std.mem.copyForwards(u8, buf[0 .. buf.len - want], buf[want..]);
        self.inbuf.shrinkRetainingCapacity(buf.len - want);
        self.preface_done = true;
    }

    fn handleFrame(self: *Session, hdr: FrameHeader, f: frame_mod.Frame) Error!void {
        switch (f) {
            .settings => |entries| {
                if (hdr.hasAck()) {
                    if (!self.awaiting_settings_ack) return self.connError(.protocol_error);
                    self.awaiting_settings_ack = false;
                    self.settings_acked = true;
                    return;
                }
                try self.applyPeerSettings(entries);
                try frame_mod.writeSettingsAck(&self.outbound, self.allocator);
            },
            .headers => |h| try self.handleHeadersStart(hdr.stream_id, h.block, h.end_headers, h.end_stream),
            .continuation => |c| try self.handleContinuation(hdr.stream_id, c.block, c.end_headers),
            .data => |d| try self.handleData(hdr.stream_id, d.data, d.end_stream),
            .rst_stream => |r| {
                if (self.role == .server and hdr.stream_id <= self.largest_peer_stream) {}
                if (self.streamPtr(hdr.stream_id)) |st| {
                    st.onRecvRst();
                    if (self.cbs.onReset) |cb| cb(self.cbs.ctx, hdr.stream_id, r.error_code);
                    try self.removeStream(hdr.stream_id);
                } else if (hdr.stream_id > self.largest_peer_stream) {
                    // RST_STREAM cannot create a stream. On an idle stream it
                    // is a connection-level PROTOCOL_ERROR (RFC 9113 5.4.1).
                    return self.connError(.protocol_error);
                }
            },
            .window_update => |w| try self.handleWindowUpdate(hdr.stream_id, w.increment),
            .ping => |p| {
                if (!hdr.hasAck()) {
                    try frame_mod.writePing(&self.outbound, self.allocator, true, p.opaque_data);
                } else if (self.cbs.onPingAck) |cb| {
                    cb(self.cbs.ctx, p.opaque_data);
                }
            },
            .goaway => |g| {
                self.goaway_received = true;
                if (self.goaway_last_stream) |previous| {
                    self.goaway_last_stream = @min(previous, g.last_stream_id);
                } else {
                    self.goaway_last_stream = g.last_stream_id;
                }
                if (self.cbs.onGoaway) |cb| cb(self.cbs.ctx, g.last_stream_id, g.error_code, g.debug_data);
            },
            .priority, .push_promise => {
                // Priority tolerated-and-ignored (RFC 9113 Â§5.3 deprecation);
                // PUSH_PROMISE ignored by default (push disabled).
            },
            .unknown => {
                // Unknown extension frames are length-delimited and ignored
                // after parsing, per RFC 9113 Section 4.1.
            },
        }
    }

    fn applyPeerSettings(self: *Session, entries: []frame_mod.SettingEntry) Error!void {
        var window_delta: i64 = 0;
        for (entries) |e| {
            const sid: frame_mod.SettingsId = @enumFromInt(e.id);
            if (frame_mod.validateSetting(sid, e.value)) |code| {
                return self.connError(@enumFromInt(code));
            }
            switch (sid) {
                .header_table_size => {
                    self.peer_settings.header_table_size = e.value;
                    self.henc.applySettingsSize(e.value);
                },
                .enable_push => self.peer_settings.enable_push = e.value,
                .max_concurrent_streams => self.peer_settings.max_concurrent_streams = e.value,
                .initial_window_size => {
                    window_delta = @as(i64, e.value) - self.peer_settings.initial_window_size;
                    self.peer_settings.initial_window_size = e.value;
                },
                .max_frame_size => self.peer_settings.max_frame_size = e.value,
                .max_header_list_size => self.peer_settings.max_header_list_size = e.value,
                _ => {}, // unknown ignored
            }
        }
        if (window_delta != 0) {
            var it = self.streams.valueIterator();
            while (it.next()) |sp| {
                sp.*.send_window += window_delta;
                if (sp.*.send_window > frame_mod.MAX_WINDOW) {
                    return self.connError(.flow_control_error);
                }
            }
        }
        self.awaiting_settings_ack = true;
    }

    fn handleHeadersStart(self: *Session, sid: u31, block: []const u8, end_headers: bool, end_stream: bool) Error!void {
        var st: *Stream = blk: {
            if (self.streamPtr(sid)) |existing| break :blk existing;
            if (self.goaway_last_stream) |last| {
                if (sid > last) return Error.StreamClosed;
            }
            // New peer-initiated request stream.
            if (self.role == .server) {
                if (sid <= self.largest_peer_stream) return self.connError(.protocol_error);
                if (sid % 2 == 0) return self.connError(.protocol_error);
                if (self.goaway_sent) return Error.StreamClosed;
                if (self.active_peer_streams >= self.peer_settings.max_concurrent_streams) {
                    return self.connError(.protocol_error);
                }
            }
            const s = try self.allocator.create(Stream);
            s.* = Stream.init(self.allocator, sid);
            s.state = .idle;
            try self.streams.put(sid, s);
            if (sid > self.largest_peer_stream) self.largest_peer_stream = sid;
            break :blk s;
        };

        if (end_headers) {
            st.onRecvHeaders(end_stream) catch |e| switch (e) {
                error.StreamClosed => return self.connError(.stream_closed),
                error.ProtocolError => return self.connError(.protocol_error),
            };
            try self.decodeAndDeliver(st, block);
        } else {
            // Open the stream state now; END_STREAM applies at chain end.
            st.header_block = .empty;
            st.header_block.?.appendSlice(self.allocator, block) catch return Error.OutOfMemory;
            self.continuation_sid = sid;
            self.continuation_stream = st;
            self.continuation_end_stream = end_stream;
        }
    }

    fn handleContinuation(self: *Session, sid: u31, block: []const u8, end_headers: bool) Error!void {
        const st = self.continuation_stream orelse return self.connError(.protocol_error);
        if (st.id != sid) return self.connError(.protocol_error);
        st.header_block.?.appendSlice(self.allocator, block) catch return Error.OutOfMemory;
        if (!end_headers) return;

        const end_stream = self.continuation_end_stream;
        self.continuation_sid = null;
        self.continuation_stream = null;

        st.onRecvHeaders(end_stream) catch |e| switch (e) {
            error.StreamClosed => return self.connError(.stream_closed),
            error.ProtocolError => return self.connError(.protocol_error),
        };
        try self.decodeAndDeliver(st, "");
    }

    fn decodeAndDeliver(self: *Session, st: *Stream, final_frag: []const u8) Error!void {
        // Single-frame HEADERS have no chain buffer; multi-frame chains
        // accumulated their fragments already.
        var owned: ?[]u8 = null;
        defer if (owned) |b| self.allocator.free(b);
        var block: []const u8 = final_frag;

        if (st.header_block != null) {
            if (final_frag.len > 0) {
                st.header_block.?.appendSlice(self.allocator, final_frag) catch return Error.OutOfMemory;
            }
            owned = st.header_block.?.toOwnedSlice(self.allocator) catch return Error.OutOfMemory;
            block = owned.?;
        }

        const res = self.hdec.decode(block) catch |e| switch (e) {
            error.HeaderTooLarge => return self.connError(.enhance_your_calm),
            else => return self.connError(.compression_error),
        };
        defer {
            for (res.fields) |f| {
                self.allocator.free(f.name);
                self.allocator.free(f.value);
            }
            self.allocator.free(res.fields);
        }

        const end_stream = st.end_stream_recv;
        if (self.cbs.onHeaders) |cb| {
            cb(self.cbs.ctx, st.id, res.fields, end_stream) catch return Error.ProtocolViolation;
        }
        if (end_stream) {
            if (self.cbs.onStreamEnd) |cb| {
                cb(self.cbs.ctx, st.id) catch return Error.ProtocolViolation;
            }
        }
    }

    fn handleData(self: *Session, sid: u31, data: []const u8, end_stream: bool) Error!void {
        // Connection-level flow control always applies.
        self.conn_recv_pending += @intCast(data.len);
        if (self.conn_recv_pending > self.local_settings.initial_window_size) {
            return self.connError(.flow_control_error);
        }

        const st = self.streamPtr(sid) orelse return;
        if (!st.state.canRecvData()) {
            if (st.state == .idle) return self.connError(.protocol_error);
            return self.connError(.stream_closed);
        }
        if (!st.consumeRecv(@intCast(data.len))) {
            return self.connError(.flow_control_error);
        }

        if (data.len > 0) {
            if (self.cbs.onData) |cb| cb(self.cbs.ctx, sid, data) catch return Error.ProtocolViolation;
        }
        st.onRecvData(end_stream) catch |e| switch (e) {
            error.StreamClosed => return self.connError(.stream_closed),
            error.ProtocolError => return self.connError(.protocol_error),
        };
        if (end_stream) {
            if (self.cbs.onStreamEnd) |cb| cb(self.cbs.ctx, sid) catch return Error.ProtocolViolation;
        }
        self.maybeEmitWindowUpdates(sid);
    }

    /// Sends WINDOW_UPDATEs once >= half the window has been consumed.
    fn maybeEmitWindowUpdates(self: *Session, sid: u31) void {
        const half: i64 = @divTrunc(@as(i64, self.local_settings.initial_window_size), 2);
        if (self.conn_recv_pending >= half) {
            const inc: u31 = @intCast(self.conn_recv_pending);
            self.conn_recv_pending = 0;
            frame_mod.writeWindowUpdate(&self.outbound, self.allocator, 0, inc) catch {};
        }
        if (self.streamPtr(sid)) |st| {
            if (st.recv_pending >= half and st.state != .closed) {
                const inc: u31 = @intCast(st.recv_pending);
                st.recv_pending = 0;
                st.recv_window += inc;
                frame_mod.writeWindowUpdate(&self.outbound, self.allocator, sid, inc) catch {};
            }
        }
    }

    fn handleWindowUpdate(self: *Session, sid: u31, inc: u31) Error!void {
        if (inc == 0) return self.connError(.protocol_error);
        const amount: i64 = @intCast(inc);
        if (sid == 0) {
            self.conn_send_window += amount;
            if (self.conn_send_window > frame_mod.MAX_WINDOW) return self.connError(.flow_control_error);
            return;
        }
        const st = self.streamPtr(sid) orelse return;
        // WINDOW_UPDATE on idle/closed streams is a connection error
        // (closed-stream updates are tolerated per RFC 9113 6.9 note).
        if (st.state == .idle or st.state == .closed) return self.connError(.protocol_error);
        st.send_window += amount;
        if (st.send_window > frame_mod.MAX_WINDOW) return self.connError(.flow_control_error);
    }

    // -- outbound ----------------------------------------------------------------

    /// Encodes and sends HEADERS, splitting into CONTINUATIONs as needed.
    pub fn sendHeaders(self: *Session, sid: u31, fields: []const hpack_mod.HeaderField, end_stream: bool) !void {
        var block = std.ArrayList(u8).empty;
        defer block.deinit(self.allocator);
        for (fields) |f| {
            try self.henc.encode(&block, f.name, f.value, .incremental, false);
        }
        try self.sendHeaderBlock(sid, block.items, end_stream);
    }

    pub fn sendHeaderBlock(self: *Session, sid: u31, block: []const u8, end_stream: bool) !void {
        const max = @min(@as(usize, self.local_settings.max_frame_size), 16384);
        if (self.streamPtr(sid) == null) {
            const s = try self.allocator.create(Stream);
            s.* = Stream.init(self.allocator, sid);
            s.state = .idle;
            try self.streams.put(sid, s);
        }
        const st = self.streamPtr(sid).?;
        try st.onSendHeaders(end_stream);

        var flags: u8 = 0;
        if (end_stream) flags |= Flags.END_STREAM;

        if (block.len <= max) {
            if (flags == 0) flags |= Flags.END_HEADERS else flags |= Flags.END_HEADERS;
            try frame_mod.writeHeader(&self.outbound, self.allocator, block.len, .headers, flags, sid);
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
                    try frame_mod.writeHeader(&self.outbound, self.allocator, frag.len, .headers, f2, sid);
                    first = false;
                } else {
                    try frame_mod.writeHeader(&self.outbound, self.allocator, frag.len, .continuation, f2, sid);
                }
                try self.outbound.appendSlice(self.allocator, frag);
            }
        }
    }

    /// Sends DATA respecting max_frame_size and available windows.
    /// Returns bytes actually queued (rest needs WINDOW_UPDATE first).
    pub fn sendData(self: *Session, sid: u31, data: []const u8, end_stream: bool) Error!usize {
        const st = self.streamPtr(sid) orelse return Error.StreamClosed;
        if (!st.state.canSendData() or st.end_stream_sent) return Error.StreamClosed;

        const budget_win = @min(self.conn_send_window, st.send_window);
        if (budget_win <= 0) return 0;

        const max = @min(@as(usize, self.local_settings.max_frame_size), 16384);
        const allowed: usize = @min(@as(usize, @intCast(budget_win)), data.len);
        var sent: usize = 0;

        while (sent < allowed) {
            const take = @min(max, allowed - sent);
            const chunk = data[sent..][0..take];
            const fin = end_stream and sent + take == data.len;
            frame_mod.writeData(&self.outbound, self.allocator, sid, chunk, fin) catch return Error.OutOfMemory;
            sent += take;
            _ = st.creditSend(@intCast(take));
            self.conn_send_window -= @intCast(take);
        }
        if (end_stream and sent == data.len) {
            st.onSendData(true) catch {};
        }
        return sent;
    }

    pub fn sendRstStream(self: *Session, sid: u31, code: ErrorCode) !void {
        if (self.streamPtr(sid)) |st| st.onSendRst();
        try frame_mod.writeRstStream(&self.outbound, self.allocator, sid, @intFromEnum(code));
    }

    pub fn sendWindowUpdate(self: *Session, sid: u31, inc: u31) !void {
        if (sid == 0) {
            self.conn_send_window += @as(i64, inc);
            return;
        }
        if (self.streamPtr(sid)) |st| st.send_window += @as(i64, inc);
        try frame_mod.writeWindowUpdate(&self.outbound, self.allocator, sid, inc);
    }

    pub fn sendPing(self: *Session, opaque_data: [8]u8) !void {
        try frame_mod.writePing(&self.outbound, self.allocator, false, opaque_data);
    }

    /// Phase 1 of graceful shutdown: stop accepting new streams.
    pub fn beginGracefulShutdown(self: *Session) !void {
        if (self.goaway_sent) return;
        try frame_mod.writeGoaway(&self.outbound, self.allocator, 0x7FFFFFFF, 0, "");
        self.goaway_sent = true;
        self.goaway_last_sid_sent = 0x7FFFFFFF;
    }

    /// Final GOAWAY with the real last-stream-id.
    pub fn finishGracefulShutdown(self: *Session) !void {
        const last_sid: u31 = if (self.role == .server)
            self.largest_peer_stream
        else
            self.next_stream_id -| 2;
        try frame_mod.writeGoaway(&self.outbound, self.allocator, last_sid, 0, "");
    }

    pub fn sendConnectionClose(self: *Session, code: ErrorCode, debug: []const u8) !void {
        try frame_mod.writeGoaway(&self.outbound, self.allocator, 0x7FFFFFFF, @intFromEnum(code), debug);
    }

    /// Queues a fatal GOAWAY then returns the mapped protocol error.
    fn connError(self: *Session, code: ErrorCode) Error {
        if (!self.closed) {
            self.closed = true;
            const last_sid: u31 = if (self.role == .server) self.largest_peer_stream else 0x7FFFFFFF;
            frame_mod.writeGoaway(
                &self.outbound,
                self.allocator,
                last_sid,
                @intFromEnum(code),
                @tagName(code),
            ) catch {};
        }
        return switch (code) {
            .compression_error => Error.CompressionError,
            .flow_control_error => Error.FlowControlError,
            .frame_size_error => Error.FrameSizeExceeded,
            .stream_closed => Error.StreamClosed,
            else => Error.ProtocolViolation,
        };
    }

    fn removeStream(self: *Session, sid: u31) !void {
        if (self.streams.fetchRemove(sid)) |kv| {
            if (self.role == .server and sid % 2 == 1 and self.active_peer_streams > 0) {
                self.active_peer_streams -= 1;
            }
            kv.value.deinit();
            self.allocator.destroy(kv.value);
        }
    }

    /// Opens the next client-initiated stream id (clients only).
    pub fn nextClientStreamId(self: *Session) !u31 {
        if (self.role != .client) return Error.ProtocolViolation;
        const id = self.next_stream_id;
        if (id > 0x7FFFFFFF) return Error.ProtocolViolation;
        self.next_stream_id += 2;
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
    const fields = [_]hpack_mod.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/hello" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":authority", .value = "x" },
    };
    try client.sendHeaders(1, fields[0..], true);

    // Server consumes request; capture headers via temporary callbacks.
    const Capture = struct {
        var method_buf: [16]u8 = undefined;
        var path_buf: [32]u8 = undefined;
        var method_len: usize = 0;
        var path_len: usize = 0;
        var done: bool = false;

        fn onHeaders(_: ?*anyopaque, _: u31, flds: []hpack_mod.HeaderField, end_stream: bool) anyerror!void {
            for (flds) |f| {
                if (std.mem.eql(u8, f.name, ":method")) {
                    @memcpy(method_buf[0..f.value.len], f.value);
                    method_len = f.value.len;
                }
                if (std.mem.eql(u8, f.name, ":path")) {
                    @memcpy(path_buf[0..f.value.len], f.value);
                    path_len = f.value.len;
                }
            }
            done = end_stream;
        }
    };
    server.cbs = .{ .onHeaders = Capture.onHeaders };

    server.feed(client.outbound.items) catch |e| {
        std.debug.print("server.feed err={any} closed={} outbound_len={d}\n", .{ e, server.closed, server.outbound.items.len });
        return e;
    };
    try std.testing.expect(Capture.done);
    try std.testing.expectEqualStrings("GET", Capture.method_buf[0..Capture.method_len]);
    try std.testing.expectEqualStrings("/hello", Capture.path_buf[0..Capture.path_len]);
    client.outbound.clearRetainingCapacity();

    // Server responds: HEADERS + DATA(END_STREAM).
    const resp = [_]hpack_mod.HeaderField{
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

        fn onHeaders(_: ?*anyopaque, _: u31, flds: []hpack_mod.HeaderField, _: bool) anyerror!void {
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
