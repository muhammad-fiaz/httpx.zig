//! RFC 6455 WebSocket session over a type-erased byte stream.
//!
//! The session owns its receive buffer and any in-flight fragmentation state.
//! It never owns the underlying transport: plain sockets, TLS server
//! connections and TLS client connections are all supplied as a borrowing
//! `common.Stream`. `deinit` releases session memory only.
//!
//! Concurrency: one reader and one writer may run concurrently. Multiple
//! writers must serialize their calls; `sendText`/`sendBinary`/`ping`/`pong`/
//! `close` are not internally locked.
//!
//! References:
//!   - RFC 6455 Section 5 — Data Framing
//!   - RFC 6455 Section 7 — Closing the Connection
//!   - RFC 7692 — Compression Extensions for WebSocket

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zigantic");
const frameMod = @import("websocketFrame.zig");
const deflateMod = @import("websocketDeflate.zig");
const Stream = @import("../../common/stream.zig").Stream;

const Frame = frameMod.FrameHeader;
pub const Opcode = frameMod.Opcode;

pub const Error = error{
    NotOpen,
    ConnectionClosed,
    IoError,
    ProtocolError,
    MessageTooLarge,
    FrameTooLarge,
    InvalidUtf8,
    InvalidCloseCode,
    OutOfMemory,
};

pub const ConfigSchema = z.objectOf(.{
    .maxMsgBytes = z.withDefault(z.positiveInt(usize, .{}), 16 * 1024 * 1024),
    .maxFrame = z.withDefault(z.positiveInt(usize, .{}), 16 * 1024 * 1024),
    .readBuf = z.withDefault(z.positiveInt(usize, .{}), 8 * 1024),
    .readMs = z.withDefault(z.integer(u32, .{}), 30_000),
    .writeMs = z.withDefault(z.integer(u32, .{}), 30_000),
    .closeMs = z.withDefault(z.integer(u32, .{}), 5_000),
    .autoPong = z.withDefault(z.boolean(.{}), true),
    .maxInflate = z.withDefault(z.positiveInt(usize, .{}), 16 * 1024 * 1024),
}, .{});
pub const Config = ConfigSchema.Value;

pub const Role = enum { client, server };

/// Optional transport owner invoked by `Session.deinit`. Server sessions leave
/// this null because the HTTP worker owns the connection; client sessions set
/// it so socket/TLS cleanup is automatic.
pub const Owner = struct {
    context: *anyopaque,
    destroyFn: *const fn (context: *anyopaque) void,

    fn destroy(self: Owner) void {
        self.destroyFn(self.context);
    }
};

pub const Options = struct {
    role: Role,
    /// Bytes already read past the opening handshake.
    initial: []const u8 = "",
    /// True when permessage-deflate was negotiated.
    compression: bool = false,
};

pub const MessageKind = enum { text, binary };

/// Owned inbound data message.
pub const Message = struct {
    allocator: Allocator,
    kind: MessageKind,
    data: []u8,

    pub fn deinit(self: *Message) void {
        self.allocator.free(self.data);
        self.* = undefined;
    }
};

pub const CloseInfo = struct {
    code: u16,
    reason: []u8,

    pub fn deinit(self: *CloseInfo, allocator: Allocator) void {
        allocator.free(self.reason);
        self.* = undefined;
    }
};

/// One decoded frame-level event. Payloads are owned by the caller.
pub const Event = union(enum) {
    text: []u8,
    binary: []u8,
    ping: []u8,
    pong: []u8,
    close: CloseInfo,

    pub fn deinit(self: *Event, allocator: Allocator) void {
        switch (self.*) {
            .text => |data| allocator.free(data),
            .binary => |data| allocator.free(data),
            .ping => |data| allocator.free(data),
            .pong => |data| allocator.free(data),
            .close => |info| allocator.free(info.reason),
        }
        self.* = undefined;
    }
};

pub const Session = struct {
    allocator: Allocator,
    io: std.Io,
    stream: Stream,
    config: Config,
    role: Role,
    compression: bool,

    readBuf: []u8,
    readStart: usize = 0,
    readEnd: usize = 0,

    fragData: std.ArrayList(u8) = .empty,
    fragKind: ?MessageKind = null,
    fragCompressed: bool = false,

    closed: bool = false,
    closeSent: bool = false,
    closeReceived: bool = false,
    owner: ?Owner = null,

    /// Initializes a session. `stream` is borrowed and must outlive the
    /// session. `initial` is copied into the receive buffer.
    pub fn init(allocator: Allocator, io: std.Io, stream: Stream, config: Config, options: Options) Error!Session {
        if (config.readBuf == 0 or config.maxFrame == 0 or config.maxMsgBytes == 0) {
            return error.ProtocolError;
        }
        const bufLen = @max(config.readBuf, options.initial.len);
        const readBuf = allocator.alloc(u8, bufLen) catch return error.OutOfMemory;
        @memcpy(readBuf[0..options.initial.len], options.initial);

        if (config.readMs > 0) stream.setReadTimeoutMs(config.readMs);
        if (config.writeMs > 0) stream.setWriteTimeoutMs(config.writeMs);

        return .{
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .config = config,
            .role = options.role,
            .compression = options.compression,
            .readBuf = readBuf,
            .readEnd = options.initial.len,
        };
    }

    /// Releases session memory and, for client sessions, the owned transport.
    /// The transport stays open and owned by the caller when `owner` is null;
    /// call `close` first for a graceful WebSocket shutdown.
    pub fn deinit(self: *Session) void {
        self.allocator.free(self.readBuf);
        self.fragData.deinit(self.allocator);
        if (self.owner) |owner| owner.destroy();
        self.* = undefined;
    }

    pub fn isOpen(self: *const Session) bool {
        return !self.closed;
    }

    /// Sends a text message.
    pub fn sendText(self: *Session, text: []const u8) Error!void {
        return self.sendData(.text, text);
    }

    /// Sends a binary message.
    pub fn sendBinary(self: *Session, data: []const u8) Error!void {
        return self.sendData(.binary, data);
    }

    fn sendData(self: *Session, kind: MessageKind, data: []const u8) Error!void {
        if (self.closed or self.closeSent) return error.NotOpen;
        var payload = data;
        var compressed: ?[]u8 = null;
        defer if (compressed) |buf| self.allocator.free(buf);
        var rsv1 = false;
        if (self.compression and data.len > 0) {
            compressed = deflateMod.compressMessage(self.allocator, data) catch return error.IoError;
            payload = compressed.?;
            rsv1 = true;
        }
        const opcode: Opcode = if (kind == .text) .text else .binary;
        try self.writeFrame(opcode, payload, true, rsv1);
    }

    /// Sends a ping with an optional payload (at most 125 bytes).
    pub fn ping(self: *Session, payload: []const u8) Error!void {
        if (payload.len > 125) return error.ProtocolError;
        if (self.closed or self.closeSent) return error.NotOpen;
        try self.writeFrame(.ping, payload, true, false);
    }

    /// Sends an unsolicited pong.
    pub fn pong(self: *Session, payload: []const u8) Error!void {
        if (payload.len > 125) return error.ProtocolError;
        if (self.closed or self.closeSent) return error.NotOpen;
        try self.writeFrame(.pong, payload, true, false);
    }

    /// Reads the next frame-level event. Control frames are returned to the
    /// caller; with `config.autoPong` a ping is answered before returning.
    pub fn receiveEvent(self: *Session) Error!Event {
        if (self.closed) return error.NotOpen;
        const event = try self.nextEvent();
        switch (event) {
            .ping => |payload| {
                if (self.config.autoPong and !self.closeSent) {
                    self.writeFrame(.pong, payload, true, false) catch {};
                }
            },
            .close => {
                self.closed = true;
            },
            else => {},
        }
        return event;
    }

    /// Reads the next data message, transparently answering ping frames and
    /// discarding pongs. Returns null after a completed close handshake.
    pub fn receive(self: *Session) Error!?Message {
        while (true) {
            const event = try self.receiveEvent();
            switch (event) {
                .text => |data| return .{ .allocator = self.allocator, .kind = .text, .data = data },
                .binary => |data| return .{ .allocator = self.allocator, .kind = .binary, .data = data },
                .ping => |data| self.allocator.free(data),
                .pong => |data| self.allocator.free(data),
                .close => |info| {
                    self.allocator.free(info.reason);
                    return null;
                },
            }
        }
    }

    /// Convenience wrapper over `receive`: returns null on close and fails with
    /// `error.InvalidUtf8` for a binary message.
    pub fn receiveText(self: *Session) Error!?[]u8 {
        var message = (try self.receive()) orelse return null;
        if (message.kind != .text) {
            message.deinit();
            return error.InvalidUtf8;
        }
        return message.data;
    }

    /// Convenience wrapper over `receive`: returns null on close and fails with
    /// `error.ProtocolError` for a text message.
    pub fn receiveBinary(self: *Session) Error!?[]u8 {
        var message = (try self.receive()) orelse return null;
        if (message.kind != .binary) {
            message.deinit();
            return error.ProtocolError;
        }
        return message.data;
    }

    /// Sends a close frame and waits (bounded by `config.closeMs`) for
    /// the peer's close. Idempotent; safe to call more than once.
    pub fn close(self: *Session, code: u16, reason: []const u8) Error!void {
        if (!self.closeSent) {
            try self.sendClose(code, reason);
            self.closeSent = true;
        }
        if (self.closeReceived or self.closed) {
            self.closed = true;
            return;
        }
        if (self.config.closeMs > 0) self.stream.setReadTimeoutMs(self.config.closeMs);
        while (!self.closeReceived and !self.closed) {
            const event = self.receiveEvent() catch break;
            switch (event) {
                .text => |data| self.allocator.free(data),
                .binary => |data| self.allocator.free(data),
                .ping => |data| self.allocator.free(data),
                .pong => |data| self.allocator.free(data),
                .close => |info| self.allocator.free(info.reason),
            }
        }
        self.closed = true;
    }

    fn sendClose(self: *Session, code: u16, reason: []const u8) Error!void {
        if (!validCloseCode(code)) return error.InvalidCloseCode;
        const maxReason = 123;
        var buf: [maxReason + 2]u8 = undefined;
        if (code == 0 and reason.len == 0) {
            try self.writeFrame(.close, &.{}, true, false);
            return;
        }
        std.mem.writeInt(u16, buf[0..2], code, .big);
        const take = @min(reason.len, maxReason);
        @memcpy(buf[2..][0..take], reason[0..take]);
        try self.writeFrame(.close, buf[0 .. 2 + take], true, false);
    }

    // Frame input

    const HeaderInfo = struct {
        header: Frame,
        consumed: usize,
    };

    fn nextEvent(self: *Session) Error!Event {
        while (true) {
            const frameInfo = try self.readFrameHeader();
            const header = frameInfo.header;

            if (header.payloadLen > self.config.maxFrame) {
                return self.fail(1009, "frame too large", error.FrameTooLarge);
            }
            if (self.role == .client and header.masked) {
                return self.fail(1002, "server frames must not be masked", error.ProtocolError);
            }
            if (self.role == .server and !header.masked) {
                return self.fail(1002, "client frames must be masked", error.ProtocolError);
            }
            if (header.rsv1 and !self.compression) {
                return self.fail(1002, "unexpected reserved bit", error.ProtocolError);
            }

            const payloadLen: usize = @intCast(header.payloadLen);
            const payload = self.allocator.alloc(u8, payloadLen) catch return error.OutOfMemory;
            var payloadOwned = true;
            defer if (payloadOwned) self.allocator.free(payload);
            try self.readExact(payload);
            if (header.masked) frameMod.applyMask(payload, header.maskKey.?);

            switch (header.opcode) {
                .ping => {
                    payloadOwned = false;
                    return Event{ .ping = payload };
                },
                .pong => {
                    payloadOwned = false;
                    return Event{ .pong = payload };
                },
                .close => {
                    const info = try self.parseClose(payload);
                    if (!self.closeSent) {
                        if (info.code == 1005) {
                            self.writeFrame(.close, &.{}, true, false) catch {};
                        } else {
                            self.sendClose(info.code, info.reason) catch {};
                        }
                        self.closeSent = true;
                    }
                    self.closeReceived = true;
                    return Event{ .close = info };
                },
                .text, .binary => {
                    if (self.fragKind != null) {
                        return self.fail(1002, "new data frame during fragmentation", error.ProtocolError);
                    }
                    const kind: MessageKind = if (header.opcode == .text) .text else .binary;
                    if (header.fin) {
                        return try self.finishMessage(kind, payload, header.rsv1);
                    }
                    self.fragKind = kind;
                    self.fragCompressed = header.rsv1;
                    self.fragData.clearRetainingCapacity();
                    self.fragData.appendSlice(self.allocator, payload) catch return error.OutOfMemory;
                    if (self.fragData.items.len > self.config.maxMsgBytes) {
                        return self.fail(1009, "message too large", error.MessageTooLarge);
                    }
                },
                .continuation => {
                    const kind = self.fragKind orelse {
                        return self.fail(1002, "unexpected continuation", error.ProtocolError);
                    };
                    if (header.rsv1) {
                        return self.fail(1002, "reserved bit on continuation", error.ProtocolError);
                    }
                    const nextLen = std.math.add(usize, self.fragData.items.len, payload.len) catch {
                        return self.fail(1009, "message too large", error.MessageTooLarge);
                    };
                    if (nextLen > self.config.maxMsgBytes) {
                        return self.fail(1009, "message too large", error.MessageTooLarge);
                    }
                    self.fragData.appendSlice(self.allocator, payload) catch return error.OutOfMemory;
                    if (header.fin) {
                        const message = try self.finishMessage(kind, self.fragData.items, self.fragCompressed);
                        self.fragKind = null;
                        self.fragCompressed = false;
                        return message;
                    }
                },
                else => return self.fail(1002, "unknown opcode", error.ProtocolError),
            }
        }
    }

    fn finishMessage(self: *Session, kind: MessageKind, payload: []const u8, compressed: bool) Error!Event {
        var data: []u8 = undefined;
        if (compressed) {
            data = deflateMod.decompressMessage(self.allocator, payload, self.config.maxInflate) catch |err| switch (err) {
                error.DecompressedTooLarge => return self.fail(1009, "decompressed message too large", error.MessageTooLarge),
                error.OutOfMemory => return error.OutOfMemory,
                else => return self.fail(1002, "invalid compressed message", error.ProtocolError),
            };
        } else {
            if (payload.len > self.config.maxMsgBytes) {
                return self.fail(1009, "message too large", error.MessageTooLarge);
            }
            data = self.allocator.dupe(u8, payload) catch return error.OutOfMemory;
        }
        if (kind == .text and !std.unicode.utf8ValidateSlice(data)) {
            self.allocator.free(data);
            return self.fail(1007, "invalid UTF-8", error.InvalidUtf8);
        }
        return switch (kind) {
            .text => Event{ .text = data },
            .binary => Event{ .binary = data },
        };
    }

    fn parseClose(self: *Session, payload: []u8) Error!CloseInfo {
        if (payload.len == 1) return self.fail(1002, "invalid close payload", error.ProtocolError);
        if (payload.len < 2) {
            return .{ .code = 1005, .reason = self.allocator.alloc(u8, 0) catch return error.OutOfMemory };
        }
        const code = std.mem.readInt(u16, payload[0..2], .big);
        if (!validCloseCode(code)) return self.fail(1002, "invalid close code", error.InvalidCloseCode);
        const reason = self.allocator.dupe(u8, payload[2..]) catch return error.OutOfMemory;
        if (!std.unicode.utf8ValidateSlice(reason)) {
            self.allocator.free(reason);
            return self.fail(1007, "invalid close reason", error.InvalidUtf8);
        }
        return .{ .code = code, .reason = reason };
    }

    fn fail(self: *Session, code: u16, reason: []const u8, err: Error) Error {
        if (!self.closeSent) {
            self.sendClose(code, reason) catch {};
            self.closeSent = true;
        }
        self.closed = true;
        return err;
    }

    // Frame output

    fn writeFrame(self: *Session, opcode: Opcode, payload: []const u8, fin: bool, rsv1: bool) Error!void {
        var header: [14]u8 = undefined;
        var maskKey: ?[4]u8 = null;
        if (self.role == .client) {
            var key: [4]u8 = undefined;
            self.io.random(&key);
            maskKey = key;
        }
        const n = frameMod.buildFrameHeaderWithRsv(&header, fin, rsv1, opcode, payload.len, maskKey);
        try self.writeRaw(header[0..n]);
        if (maskKey) |key| {
            var scratch: [4096]u8 = undefined;
            var offset: usize = 0;
            while (offset < payload.len) {
                const take = @min(scratch.len, payload.len - offset);
                for (payload[offset..][0..take], 0..) |byte, i| {
                    scratch[i] = byte ^ key[(offset + i) % 4];
                }
                try self.writeRaw(scratch[0..take]);
                offset += take;
            }
        } else {
            try self.writeRaw(payload);
        }
    }

    fn writeRaw(self: *Session, bytes: []const u8) Error!void {
        self.stream.writeAll(bytes) catch return error.IoError;
    }

    fn readFrameHeader(self: *Session) Error!HeaderInfo {
        var headerBytes: [14]u8 = undefined;
        try self.readExact(headerBytes[0..2]);
        const b1 = headerBytes[1];
        var extra: usize = 0;
        const len7 = b1 & 0x7F;
        if (len7 == 126) extra += 2 else if (len7 == 127) extra += 8;
        if (b1 & 0x80 != 0) extra += 4;
        if (extra > 0) try self.readExact(headerBytes[2..][0..extra]);

        const parsed = frameMod.parseFrameHeader(headerBytes[0 .. 2 + extra]) catch |err| switch (err) {
            error.InvalidFrame => return self.fail(1002, "invalid frame", error.ProtocolError),
            error.ProtocolViolation => return self.fail(1002, "protocol violation", error.ProtocolError),
        };
        return .{ .header = parsed.hdr, .consumed = parsed.consumed };
    }

    fn readExact(self: *Session, out: []u8) Error!void {
        var pos: usize = 0;
        while (pos < out.len) {
            if (self.readStart == self.readEnd) try self.fill();
            const available = self.readEnd - self.readStart;
            const take = @min(available, out.len - pos);
            @memcpy(out[pos..][0..take], self.readBuf[self.readStart..][0..take]);
            self.readStart += take;
            pos += take;
        }
    }

    fn fill(self: *Session) Error!void {
        if (self.readStart > 0) {
            const remaining = self.readEnd - self.readStart;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.readBuf[0..remaining], self.readBuf[self.readStart..self.readEnd]);
            }
            self.readStart = 0;
            self.readEnd = remaining;
        }
        const n = self.stream.read(self.readBuf[self.readEnd..]) catch return error.IoError;
        if (n == 0) return error.ConnectionClosed;
        self.readEnd += n;
    }
};

/// Valid application close codes (RFC 6455 Section 7.4).
pub fn validCloseCode(code: u16) bool {
    return switch (code) {
        1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014 => true,
        3000...4999 => true,
        else => false,
    };
}
