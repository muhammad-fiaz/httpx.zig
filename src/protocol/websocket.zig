//! WebSocket Protocol Implementation for httpx.zig
//!
//! Implements RFC 6455: The WebSocket Protocol
//!
//! WebSocket provides full-duplex communication over a single TCP connection.
//! The protocol begins with an HTTP/1.1 upgrade handshake, then switches to a
//! binary framing protocol for bidirectional messaging.
//!
//! ## Clean flat API -- no double-namespace
//!
//! ```zig
//! const httpx = @import("httpx");
//!
//! // Server upgrade check
//! if (httpx.isWebSocketUpgrade(&request)) {
//!     const key = httpx.wsExtractKey(&request).?;
//!     const accept = try httpx.wsAcceptKey(key, allocator);
//!     defer allocator.free(accept);
//! }
//!
//! // Encode a text frame (server -> client, no mask)
//! const frame = try httpx.wsEncodeFrame(allocator, .text, "hello", true, false, .{0,0,0,0});
//! defer allocator.free(frame);
//!
//! // Decode a received frame
//! const result = try httpx.wsDecodeFrame(allocator, raw_bytes);
//! var f = result.frame;
//! defer f.deinit();
//! ```

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Request = @import("../core/request.zig").Request;

// Constants

/// WebSocket magic GUID from RFC 6455 1.3.
pub const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// Types

/// WebSocket frame opcode.
pub const WsOpcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,

    /// Returns true for control opcodes (close, ping, pong).
    pub fn isControl(self: WsOpcode) bool {
        return @intFromEnum(self) >= 0x8;
    }

    /// Returns true for data opcodes (text, binary, continuation).
    pub fn isData(self: WsOpcode) bool {
        return @intFromEnum(self) < 0x8;
    }
};

/// A decoded WebSocket frame. Call `deinit()` when done.
pub const WsFrame = struct {
    /// Whether this is the final fragment of a message.
    fin: bool,
    opcode: WsOpcode,
    /// Whether the payload was masked (required for client->server).
    masked: bool,
    /// Decoded (unmasked) payload bytes.
    payload: []u8,
    allocator: Allocator,

    pub fn deinit(self: *WsFrame) void {
        self.allocator.free(self.payload);
    }
};

/// WebSocket close status codes per RFC 6455 7.4.
pub const WsCloseCode = enum(u16) {
    normal = 1000,
    going_away = 1001,
    protocol_error = 1002,
    unsupported_data = 1003,
    no_status = 1005,
    abnormal = 1006,
    invalid_payload = 1007,
    policy_violation = 1008,
    message_too_big = 1009,
    missing_extension = 1010,
    internal_error = 1011,
    _,
};

/// Result of `wsDecodeFrame`.
pub const WsDecodeResult = struct {
    frame: WsFrame,
    /// Number of bytes consumed from the input slice.
    consumed: usize,
};

// Handshake helpers

/// Returns true when `req` is a valid WebSocket upgrade request.
///
/// Checks `Upgrade: websocket`, `Connection: Upgrade`, and `Sec-WebSocket-Key`.
pub fn isWebSocketUpgrade(req: *const Request) bool {
    const upgrade = req.headers.get("Upgrade") orelse return false;
    const connection = req.headers.get("Connection") orelse return false;
    const key = req.headers.get("Sec-WebSocket-Key") orelse return false;
    return std.ascii.eqlIgnoreCase(upgrade, "websocket") and
        std.ascii.findIgnoreCase(connection, "upgrade") != null and
        key.len > 0;
}

/// Returns the `Sec-WebSocket-Key` value, or null if absent.
pub fn wsExtractKey(req: *const Request) ?[]const u8 {
    return req.headers.get("Sec-WebSocket-Key");
}

/// Computes `Sec-WebSocket-Accept` from the client's key (RFC 6455 1.3).
///
/// Caller owns the returned slice; free with the same allocator.
pub fn wsAcceptKey(client_key: []const u8, allocator: Allocator) ![]u8 {
    const concat = try std.fmt.allocPrint(allocator, "{s}{s}", .{ client_key, WS_GUID });
    defer allocator.free(concat);

    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(concat);
    var digest: [20]u8 = undefined;
    sha1.final(&digest);

    const encoded_len = std.base64.standard.Encoder.calcSize(digest.len);
    const result = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(result, &digest);
    return result;
}

/// Builds a `101 Switching Protocols` response header map for a WebSocket upgrade.
///
/// Returns the computed `Sec-WebSocket-Accept` value; caller must free it.
/// Set these on your 101 response:
///   `Upgrade: websocket`
///   `Connection: Upgrade`
///   `Sec-WebSocket-Accept: <returned value>`
pub fn wsUpgradeHeaders(client_key: []const u8, allocator: Allocator) ![]u8 {
    return wsAcceptKey(client_key, allocator);
}

// Frame encoding

/// Encodes a WebSocket frame.
///
/// - `opcode`: frame type (text, binary, ping, pong, close, continuation)
/// - `payload`: raw bytes to send
/// - `fin`: true for the final (or only) fragment
/// - `masked`: true for client->server frames (RFC 6455 requires masking)
/// - `mask_key`: 4-byte key; only used when `masked` is true
///
/// Caller owns the returned slice.
pub fn wsEncodeFrame(
    allocator: Allocator,
    opcode: WsOpcode,
    payload: []const u8,
    fin: bool,
    masked: bool,
    mask_key: [4]u8,
) ![]u8 {
    const ext_len_bytes: usize =
        if (payload.len < 126) 0 else if (payload.len < 65536) 2 else 8;
    const mask_bytes: usize = if (masked) 4 else 0;
    const header_size: usize = 2 + ext_len_bytes + mask_bytes;

    const frame = try allocator.alloc(u8, header_size + payload.len);
    errdefer allocator.free(frame);

    frame[0] = (@as(u8, if (fin) 0x80 else 0x00)) | @as(u8, @intFromEnum(opcode));

    var offset: usize = 2;
    if (payload.len < 126) {
        frame[1] = @as(u8, @intCast(payload.len)) | (if (masked) @as(u8, 0x80) else 0);
    } else if (payload.len < 65536) {
        frame[1] = 126 | (if (masked) @as(u8, 0x80) else 0);
        frame[2] = @intCast((payload.len >> 8) & 0xFF);
        frame[3] = @intCast(payload.len & 0xFF);
        offset = 4;
    } else {
        frame[1] = 127 | (if (masked) @as(u8, 0x80) else 0);
        const l: u64 = payload.len;
        frame[2] = @intCast((l >> 56) & 0xFF);
        frame[3] = @intCast((l >> 48) & 0xFF);
        frame[4] = @intCast((l >> 40) & 0xFF);
        frame[5] = @intCast((l >> 32) & 0xFF);
        frame[6] = @intCast((l >> 24) & 0xFF);
        frame[7] = @intCast((l >> 16) & 0xFF);
        frame[8] = @intCast((l >> 8) & 0xFF);
        frame[9] = @intCast(l & 0xFF);
        offset = 10;
    }

    if (masked) {
        frame[offset..][0..4].* = mask_key;
        offset += 4;
        for (payload, 0..) |b, i| {
            frame[offset + i] = b ^ mask_key[i & 3];
        }
    } else {
        @memcpy(frame[offset..][0..payload.len], payload);
    }

    return frame;
}

/// Encodes a text frame for sending from a server (unmasked, fin=true).
/// Convenience wrapper around `wsEncodeFrame`.
pub fn wsTextFrame(allocator: Allocator, text: []const u8) ![]u8 {
    return wsEncodeFrame(allocator, .text, text, true, false, .{ 0, 0, 0, 0 });
}

/// Encodes a binary frame for sending from a server (unmasked, fin=true).
pub fn wsBinaryFrame(allocator: Allocator, data: []const u8) ![]u8 {
    return wsEncodeFrame(allocator, .binary, data, true, false, .{ 0, 0, 0, 0 });
}

/// Encodes a ping frame.
pub fn wsPingFrame(allocator: Allocator, data: []const u8) ![]u8 {
    return wsEncodeFrame(allocator, .ping, data, true, false, .{ 0, 0, 0, 0 });
}

/// Encodes a pong frame.
pub fn wsPongFrame(allocator: Allocator, data: []const u8) ![]u8 {
    return wsEncodeFrame(allocator, .pong, data, true, false, .{ 0, 0, 0, 0 });
}

/// Encodes a close frame with optional code and reason.
pub fn wsCloseFrame(allocator: Allocator, code: WsCloseCode, reason: []const u8) ![]u8 {
    const code_u16: u16 = @intFromEnum(code);
    var payload_buf: [125]u8 = undefined;
    payload_buf[0] = @intCast((code_u16 >> 8) & 0xFF);
    payload_buf[1] = @intCast(code_u16 & 0xFF);
    const reason_len = @min(reason.len, 123);
    @memcpy(payload_buf[2..][0..reason_len], reason[0..reason_len]);
    return wsEncodeFrame(allocator, .close, payload_buf[0 .. 2 + reason_len], true, false, .{ 0, 0, 0, 0 });
}

// Frame decoding

/// Decodes one WebSocket frame from `data`.
///
/// Returns `error.NeedMoreData` if `data` is incomplete.
/// The returned `WsFrame.payload` is allocated; call `frame.deinit()` when done.
pub fn wsDecodeFrame(allocator: Allocator, data: []const u8) !WsDecodeResult {
    if (data.len < 2) return error.NeedMoreData;

    const fin = (data[0] & 0x80) != 0;
    const opcode: WsOpcode = @as(WsOpcode, @enumFromInt(@as(u4, @intCast(data[0] & 0x0F))));
    const masked = (data[1] & 0x80) != 0;
    var len: u64 = data[1] & 0x7F;
    var offset: usize = 2;

    if (len == 126) {
        if (data.len < 4) return error.NeedMoreData;
        len = (@as(u64, data[2]) << 8) | data[3];
        offset = 4;
    } else if (len == 127) {
        if (data.len < 10) return error.NeedMoreData;
        len = (@as(u64, data[2]) << 56) | (@as(u64, data[3]) << 48) |
            (@as(u64, data[4]) << 40) | (@as(u64, data[5]) << 32) |
            (@as(u64, data[6]) << 24) | (@as(u64, data[7]) << 16) |
            (@as(u64, data[8]) << 8) | data[9];
        offset = 10;
    }

    var mask: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        if (data.len < offset + 4) return error.NeedMoreData;
        mask = data[offset..][0..4].*;
        offset += 4;
    }

    const payload_len: usize = @intCast(len);
    if (data.len < offset + payload_len) return error.NeedMoreData;

    const payload = try allocator.alloc(u8, payload_len);
    @memcpy(payload, data[offset..][0..payload_len]);

    if (masked) {
        for (payload, 0..) |*b, i| b.* ^= mask[i & 3];
    }

    return .{
        .frame = .{
            .fin = fin,
            .opcode = opcode,
            .masked = masked,
            .payload = payload,
            .allocator = allocator,
        },
        .consumed = offset + payload_len,
    };
}

// Message reassembly

/// Errors that can occur during WebSocket message reassembly.
pub const MessageError = error{
    /// Received a continuation frame without a preceding initial opcode.
    UnexpectedContinuation,
    /// Received an unexpected data opcode while a fragmented message is in progress.
    UnexpectedOpcode,
    /// The assembled message exceeds the configured size limit.
    MessageTooLarge,
    /// Invalid opcode encountered during reassembly.
    InvalidOpcode,
};

/// Configuration for WebSocket message assembly.
pub const MessageAssemblerConfig = struct {
    /// Maximum allowed message size in bytes. 0 means no limit.
    max_message_size: usize = 0,
};

/// Tracks continuation frames across multiple WebSocket frames and
/// reassembles them into complete messages.
///
/// Handles the fragmentation protocol defined in RFC 6455 5.4:
///   - A fragmented message starts with a data frame with FIN=0 and a non-continuation opcode.
///   - Continuation frames (opcode 0x0) carry the remaining fragments.
///   - The final fragment has FIN=1.
///   - Control frames (ping, pong, close) may be interleaved between fragments.
pub const MessageAssembler = struct {
    allocator: Allocator,
    config: MessageAssemblerConfig,

    /// The accumulated payload data for the in-progress fragmented message.
    buffer: std.ArrayList(u8) = .empty,
    /// The opcode of the initial frame in the fragmented sequence.
    initial_opcode: ?WsOpcode = null,
    /// Whether we are currently assembling a fragmented message.
    in_progress: bool = false,

    const Self = @This();

    pub fn init(allocator: Allocator, config: MessageAssemblerConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit(self.allocator);
    }

    /// Processes a single decoded frame and returns the complete message
    /// when the final fragment (FIN=1) is received.
    ///
    /// For control frames (ping, pong, close), returns them immediately
    /// without affecting the fragmentation state.
    ///
    /// Returns `null` if the frame is an intermediate fragment (more data expected).
    /// Returns the complete reassembled message when FIN is set.
    pub fn feed(self: *Self, frame: WsFrame) MessageError!?WsCompleteMessage {
        if (frame.opcode.isControl()) {
            return .{
                .opcode = frame.opcode,
                .payload = try self.allocator.dupe(u8, frame.payload),
                .allocator = self.allocator,
            };
        }

        if (!self.in_progress) {
            if (frame.opcode == .continuation) {
                return error.UnexpectedContinuation;
            }

            if (frame.fin) {
                return .{
                    .opcode = frame.opcode,
                    .payload = try self.allocator.dupe(u8, frame.payload),
                    .allocator = self.allocator,
                };
            }

            self.in_progress = true;
            self.initial_opcode = frame.opcode;
            try self.appendPayload(frame.payload);
            return null;
        }

        if (frame.opcode != .continuation) {
            return error.UnexpectedOpcode;
        }

        try self.appendPayload(frame.payload);

        if (frame.fin) {
            const msg = WsCompleteMessage{
                .opcode = self.initial_opcode.?,
                .payload = try self.buffer.toOwnedSlice(self.allocator),
                .allocator = self.allocator,
            };
            self.buffer = .empty;
            self.in_progress = false;
            self.initial_opcode = null;
            return msg;
        }

        return null;
    }

    fn appendPayload(self: *Self, payload: []const u8) MessageError!void {
        if (self.config.max_message_size > 0) {
            if (self.buffer.items.len + payload.len > self.config.max_message_size) {
                self.buffer.clearRetainingCapacity();
                self.in_progress = false;
                self.initial_opcode = null;
                return error.MessageTooLarge;
            }
        }
        try self.buffer.appendSlice(self.allocator, payload);
    }

    /// Resets the assembler state, discarding any in-progress message.
    pub fn reset(self: *Self) void {
        self.buffer.clearRetainingCapacity();
        self.in_progress = false;
        self.initial_opcode = null;
    }
};

/// A complete reassembled WebSocket message.
pub const WsCompleteMessage = struct {
    opcode: WsOpcode,
    payload: []u8,
    allocator: Allocator,

    pub fn deinit(self: *WsCompleteMessage) void {
        self.allocator.free(self.payload);
    }
};

/// Decodes a stream of WebSocket frames into complete messages.
///
/// Processes each frame from the `data` slice, tracking continuation frames
/// and reassembling fragmented messages. Control frames are yielded immediately.
///
/// Caller owns the returned messages; each message's payload and the
/// messages array must be freed by the caller.
pub fn decodeMessage(
    allocator: Allocator,
    data: []const u8,
    config: MessageAssemblerConfig,
) MessageError![]WsCompleteMessage {
    var assembler = MessageAssembler.init(allocator, config);
    defer assembler.deinit();

    var messages = std.ArrayList(WsCompleteMessage).empty;
    defer {
        for (messages.items) |*msg| {
            msg.deinit();
        }
        messages.deinit(allocator);
    }

    var offset: usize = 0;
    while (offset < data.len) {
        const result = wsDecodeFrame(allocator, data[offset..]) catch |err| switch (err) {
            error.NeedMoreData => break,
            else => return error.InvalidOpcode,
        };
        offset += result.consumed;

        if (try assembler.feed(result.frame)) |msg| {
            try messages.append(allocator, msg);
        }
    }

    return try messages.toOwnedSlice(allocator);
}

// Tests

test "wsAcceptKey -- RFC 6455 test vector" {
    const allocator = std.testing.allocator;
    const result = try wsAcceptKey("dGhlIHNhbXBsZSBub25jZQ==", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", result);
}

test "wsEncodeFrame / wsDecodeFrame roundtrip -- text" {
    const allocator = std.testing.allocator;
    const payload = "Hello, WebSocket!";
    const enc = try wsEncodeFrame(allocator, .text, payload, true, false, .{ 0, 0, 0, 0 });
    defer allocator.free(enc);
    var r = try wsDecodeFrame(allocator, enc);
    defer r.frame.deinit();
    try std.testing.expectEqual(WsOpcode.text, r.frame.opcode);
    try std.testing.expect(r.frame.fin);
    try std.testing.expectEqualStrings(payload, r.frame.payload);
}

test "wsEncodeFrame / wsDecodeFrame -- masked" {
    const allocator = std.testing.allocator;
    const enc = try wsEncodeFrame(allocator, .text, "Hi", true, true, .{ 0x37, 0xfa, 0x21, 0x3d });
    defer allocator.free(enc);
    var r = try wsDecodeFrame(allocator, enc);
    defer r.frame.deinit();
    try std.testing.expectEqualStrings("Hi", r.frame.payload);
}

test "wsEncodeFrame -- extended 16-bit length" {
    const allocator = std.testing.allocator;
    var big: [200]u8 = undefined;
    @memset(&big, 0xAB);
    const enc = try wsEncodeFrame(allocator, .binary, &big, true, false, .{ 0, 0, 0, 0 });
    defer allocator.free(enc);
    var r = try wsDecodeFrame(allocator, enc);
    defer r.frame.deinit();
    try std.testing.expectEqual(@as(usize, 200), r.frame.payload.len);
}

test "wsTextFrame / wsBinaryFrame convenience" {
    const allocator = std.testing.allocator;
    const tf = try wsTextFrame(allocator, "ping!");
    defer allocator.free(tf);
    const bf = try wsBinaryFrame(allocator, &.{ 1, 2, 3 });
    defer allocator.free(bf);
    try std.testing.expect(tf.len > 0);
    try std.testing.expect(bf.len > 0);
}

test "wsCloseFrame" {
    const allocator = std.testing.allocator;
    const cf = try wsCloseFrame(allocator, .normal, "bye");
    defer allocator.free(cf);
    // Decode and verify close opcode
    var r = try wsDecodeFrame(allocator, cf);
    defer r.frame.deinit();
    try std.testing.expectEqual(WsOpcode.close, r.frame.opcode);
}

test "isWebSocketUpgrade -- valid" {
    const allocator = std.testing.allocator;
    var req = try @import("../core/request.zig").Request.init(allocator, .GET, "/ws");
    defer req.deinit();
    try req.headers.set("Upgrade", "websocket");
    try req.headers.set("Connection", "Upgrade");
    try req.headers.set("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==");
    try std.testing.expect(isWebSocketUpgrade(&req));
}

test "isWebSocketUpgrade -- invalid (missing key)" {
    const allocator = std.testing.allocator;
    var req = try @import("../core/request.zig").Request.init(allocator, .GET, "/ws");
    defer req.deinit();
    try req.headers.set("Upgrade", "websocket");
    try req.headers.set("Connection", "Upgrade");
    try std.testing.expect(!isWebSocketUpgrade(&req));
}

test "WsOpcode classification" {
    try std.testing.expect(WsOpcode.text.isData());
    try std.testing.expect(WsOpcode.binary.isData());
    try std.testing.expect(!WsOpcode.ping.isData());
    try std.testing.expect(WsOpcode.ping.isControl());
    try std.testing.expect(WsOpcode.close.isControl());
}

test "MessageAssembler -- single unfragmented text frame" {
    const allocator = std.testing.allocator;
    var assembler = MessageAssembler.init(allocator, .{});
    defer assembler.deinit();

    const enc = try wsEncodeFrame(allocator, .text, "hello", true, false, .{ 0, 0, 0, 0 });
    defer allocator.free(enc);
    const result = try wsDecodeFrame(allocator, enc);
    defer result.frame.deinit();

    const msg = try assembler.feed(result.frame);
    try std.testing.expect(msg != null);
    try std.testing.expectEqual(WsOpcode.text, msg.?.opcode);
    try std.testing.expectEqualStrings("hello", msg.?.payload);
    msg.?.deinit();
}

test "MessageAssembler -- fragmented text across 3 frames" {
    const allocator = std.testing.allocator;
    var assembler = MessageAssembler.init(allocator, .{});
    defer assembler.deinit();

    const enc1 = try wsEncodeFrame(allocator, .text, "hel", false, false, .{ 0, 0, 0, 0 });
    defer allocator.free(enc1);
    const enc2 = try wsEncodeFrame(allocator, .continuation, "lo ", false, false, .{ 0, 0, 0, 0 });
    defer allocator.free(enc2);
    const enc3 = try wsEncodeFrame(allocator, .continuation, "world", true, false, .{ 0, 0, 0, 0 });
    defer allocator.free(enc3);

    const r1 = try wsDecodeFrame(allocator, enc1);
    const r2 = try wsDecodeFrame(allocator, enc2);
    const r3 = try wsDecodeFrame(allocator, enc3);

    try std.testing.expect((try assembler.feed(r1.frame)) == null);
    try std.testing.expect((try assembler.feed(r2.frame)) == null);

    const msg = try assembler.feed(r3.frame);
    try std.testing.expect(msg != null);
    try std.testing.expectEqual(WsOpcode.text, msg.?.opcode);
    try std.testing.expectEqualStrings("hello world", msg.?.payload);
    msg.?.deinit();
}

test "MessageAssembler -- control frame interleaved with fragments" {
    const allocator = std.testing.allocator;
    var assembler = MessageAssembler.init(allocator, .{});
    defer assembler.deinit();

    const enc1 = try wsEncodeFrame(allocator, .binary, "part1", false, false, .{ 0, 0, 0, 0 });
    defer allocator.free(enc1);
    const ping = try wsEncodeFrame(allocator, .ping, "ping!", true, false, .{ 0, 0, 0, 0 });
    defer allocator.free(ping);
    const enc2 = try wsEncodeFrame(allocator, .continuation, "part2", true, false, .{ 0, 0, 0, 0 });
    defer allocator.free(enc2);

    const r1 = try wsDecodeFrame(allocator, enc1);
    const rp = try wsDecodeFrame(allocator, ping);
    const r2 = try wsDecodeFrame(allocator, enc2);

    try std.testing.expect((try assembler.feed(r1.frame)) == null);

    const control_msg = try assembler.feed(rp.frame);
    try std.testing.expect(control_msg != null);
    try std.testing.expectEqual(WsOpcode.ping, control_msg.?.opcode);
    control_msg.?.deinit();

    const msg = try assembler.feed(r2.frame);
    try std.testing.expect(msg != null);
    try std.testing.expectEqual(WsOpcode.binary, msg.?.opcode);
    try std.testing.expectEqualStrings("part1part2", msg.?.payload);
    msg.?.deinit();
}

test "MessageAssembler -- unexpected continuation without initial opcode" {
    const allocator = std.testing.allocator;
    var assembler = MessageAssembler.init(allocator, .{});
    defer assembler.deinit();

    const enc = try wsEncodeFrame(allocator, .continuation, "data", true, false, .{ 0, 0, 0, 0 });
    defer allocator.free(enc);
    const r = try wsDecodeFrame(allocator, enc);

    try std.testing.expectError(error.UnexpectedContinuation, assembler.feed(r.frame));
}

test "MessageAssembler -- unexpected opcode during fragmentation" {
    const allocator = std.testing.allocator;
    var assembler = MessageAssembler.init(allocator, .{});
    defer assembler.deinit();

    const enc1 = try wsEncodeFrame(allocator, .text, "part", false, false, .{ 0, 0, 0, 0 });
    defer allocator.free(enc1);
    const enc2 = try wsEncodeFrame(allocator, .binary, "other", false, false, .{ 0, 0, 0, 0 });
    defer allocator.free(enc2);

    const r1 = try wsDecodeFrame(allocator, enc1);
    const r2 = try wsDecodeFrame(allocator, enc2);

    try std.testing.expect((try assembler.feed(r1.frame)) == null);
    try std.testing.expectError(error.UnexpectedOpcode, assembler.feed(r2.frame));
}

test "MessageAssembler -- message too large" {
    const allocator = std.testing.allocator;
    var assembler = MessageAssembler.init(allocator, .{ .max_message_size = 10 });
    defer assembler.deinit();

    const enc1 = try wsEncodeFrame(allocator, .text, "hello", false, false, .{ 0, 0, 0, 0 });
    defer allocator.free(enc1);
    const enc2 = try wsEncodeFrame(allocator, .continuation, "world this is too long", true, false, .{ 0, 0, 0, 0 });
    defer allocator.free(enc2);

    const r1 = try wsDecodeFrame(allocator, enc1);
    const r2 = try wsDecodeFrame(allocator, enc2);

    try std.testing.expect((try assembler.feed(r1.frame)) == null);
    try std.testing.expectError(error.MessageTooLarge, assembler.feed(r2.frame));
}

test "MessageAssembler -- reset clears state" {
    const allocator = std.testing.allocator;
    var assembler = MessageAssembler.init(allocator, .{});
    defer assembler.deinit();

    const enc = try wsEncodeFrame(allocator, .text, "partial", false, false, .{ 0, 0, 0, 0 });
    defer allocator.free(enc);
    const r = try wsDecodeFrame(allocator, enc);

    try std.testing.expect((try assembler.feed(r.frame)) == null);
    try std.testing.expect(assembler.in_progress);

    assembler.reset();
    try std.testing.expect(!assembler.in_progress);
    try std.testing.expect(assembler.initial_opcode == null);
}

const Socket = @import("../net/socket.zig").Socket;
const Address = @import("../net/address.zig");
const tls_mod = @import("../tls/tls.zig");
const common = @import("../data/common.zig");
const io_util = @import("../io/any_io.zig");
const list_writer = @import("../io/list_writer.zig");

/// WebSocket client configuration.
pub const WsClientConfig = struct {
    /// Maximum frame size in bytes. 0 means no limit.
    max_frame_size: usize = 0,
    /// Maximum message size in bytes. 0 means no limit.
    max_message_size: usize = 0,
    /// Connect timeout in milliseconds. 0 means no timeout.
    connect_timeout_ms: u64 = 10_000,
    /// Read timeout in milliseconds. 0 means no timeout.
    read_timeout_ms: u64 = 30_000,
    /// Write timeout in milliseconds. 0 means no timeout.
    write_timeout_ms: u64 = 30_000,
    /// TLS certificate verification. Never set to false in production.
    verify_ssl: bool = true,
    /// Optional subprotocols to request.
    subprotocols: ?[]const []const u8 = null,
    /// Optional additional headers.
    headers: ?[]const [2][]const u8 = null,
};

/// Result of a WebSocket receive operation.
pub const WsMessage = struct {
    opcode: WsOpcode,
    payload: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WsMessage) void {
        self.allocator.free(self.payload);
    }

    pub fn isText(self: *const WsMessage) bool {
        return self.opcode == .text;
    }

    pub fn isBinary(self: *const WsMessage) bool {
        return self.opcode == .binary;
    }
};

/// High-level WebSocket client. Manages connection, handshake, and messaging.
pub const WsClient = struct {
    allocator: std.mem.Allocator,
    config: WsClientConfig,
    socket: Socket,
    connected: bool = false,
    close_sent: bool = false,
    close_received: bool = false,
    assembler: MessageAssembler,

    const Self = @This();

    /// Creates a new WebSocket client. Call `connect` to establish a connection.
    pub fn init(allocator: std.mem.Allocator, config: WsClientConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .socket = undefined,
            .assembler = MessageAssembler.init(allocator, .{
                .max_message_size = config.max_message_size,
            }),
        };
    }

    /// Releases all resources.
    pub fn deinit(self: *Self) void {
        self.assembler.deinit();
        if (self.connected) {
            self.socket.close();
            self.connected = false;
        }
    }

    /// Connects to a WebSocket server at the given URL (ws:// or wss://).
    pub fn connect(self: *Self, url: []const u8) !void {
        const parsed = try parseWsUrl(url);
        const host = parsed.host orelse return error.InvalidUri;
        const port = parsed.port orelse if (parsed.tls) 443 else 80;
        const path = if (parsed.path) |p| p else "/";

        const addr = try Address.resolve(self.allocator, host, port);
        self.socket = try Socket.createForAddress(addr);

        if (self.config.connect_timeout_ms > 0) {
            try self.socket.connectWithTimeout(addr, self.config.connect_timeout_ms);
        } else {
            try self.socket.connect(addr);
        }

        if (self.config.read_timeout_ms > 0) {
            try self.socket.setRecvTimeout(self.config.read_timeout_ms);
        }
        if (self.config.write_timeout_ms > 0) {
            try self.socket.setSendTimeout(self.config.write_timeout_ms);
        }

        self.connected = true;

        if (parsed.tls) {
            return self.doTlsHandshake(host, port);
        }

        try self.doUpgrade(host, port, path);
    }

    fn doTlsHandshake(self: *Self, host: []const u8, port: u16) !void {
        const cfg = tls_mod.TlsConfig{
            .host = host,
            .port = port,
            .verify = self.config.verify_ssl,
        };
        var session = tls_mod.TlsSession.init(.{
            .socket = &self.socket,
            .config = cfg,
        });
        _ = try session.handshake();
        // After TLS, do the HTTP upgrade over the encrypted channel
        try self.doUpgrade(host, port, "/");
    }

    fn doUpgrade(self: *Self, host: []const u8, port: u16, path: []const u8) !void {
        // Generate Sec-WebSocket-Key
        var key_bytes: [16]u8 = undefined;
        io_util.defaultIo().random(&key_bytes);
        const key = std.base64.standard.Encoder.encode(&key_bytes);

        // Build upgrade request
        var request = std.ArrayList(u8).empty;
        const writer = list_writer.init(self.allocator, &request);
        defer request.deinit(self.allocator);

        try writer.print("GET {s} HTTP/1.1\r\n", .{path});
        try writer.print("Host: {s}:{d}\r\n", .{ host, port });
        try writer.print("Upgrade: websocket\r\n", .{});
        try writer.print("Connection: Upgrade\r\n", .{});
        try writer.print("Sec-WebSocket-Key: {s}\r\n", .{key});
        try writer.print("Sec-WebSocket-Version: 13\r\n", .{});

        // Subprotocols
        if (self.config.subprotocols) |protos| {
            var first = true;
            for (protos) |proto| {
                if (first) {
                    try writer.print("Sec-WebSocket-Protocol: {s}", .{proto});
                    first = false;
                } else {
                    try writer.print(", {s}", .{proto});
                }
            }
            try writer.print("\r\n", .{});
        }

        // Custom headers
        if (self.config.headers) |hdrs| {
            for (hdrs) |h| {
                try writer.print("{s}: {s}\r\n", .{ h[0], h[1] });
            }
        }

        try writer.print("\r\n", .{});

        const req_bytes = try request.toOwnedSlice(self.allocator);
        defer self.allocator.free(req_bytes);

        try self.socket.sendAll(req_bytes);

        // Read response
        var response_buf = std.ArrayList(u8).empty;
        defer response_buf.deinit(self.allocator);

        var buf: [4096]u8 = undefined;
        var found_end = false;
        while (!found_end) {
            const n = self.socket.recv(&buf, 0) catch |err| return err;
            if (n == 0) return error.ConnectionClosed;
            try response_buf.appendSlice(self.allocator, buf[0..n]);
            if (mem.indexOf(u8, response_buf.items, "\r\n\r\n") != null) {
                found_end = true;
            }
        }

        const response = response_buf.items;
        // Validate 101 response
        if (!mem.startsWith(u8, response, "HTTP/1.1 101")) {
            return error.HandshakeFailed;
        }
        if (mem.indexOf(u8, response, "Upgrade: websocket") == null and
            mem.indexOf(u8, response, "upgrade: websocket") == null)
        {
            return error.HandshakeFailed;
        }
        if (mem.indexOf(u8, response, "Connection: Upgrade") == null and
            mem.indexOf(u8, response, "connection: upgrade") == null)
        {
            return error.HandshakeFailed;
        }

        // Verify Sec-WebSocket-Accept
        const accept = wsAcceptKey(key, self.allocator) catch return error.HandshakeFailed;
        defer self.allocator.free(accept);
        if (mem.indexOf(u8, response, accept) == null) {
            return error.InvalidAcceptKey;
        }
    }

    /// Sends a text message.
    pub fn sendText(self: *Self, text: []const u8) !void {
        return self.sendMessage(.text, text);
    }

    /// Sends a binary message.
    pub fn sendBinary(self: *Self, data: []const u8) !void {
        return self.sendMessage(.binary, data);
    }

    /// Sends a message with the given opcode.
    pub fn sendMessage(self: *Self, opcode: WsOpcode, payload: []const u8) !void {
        if (self.close_sent) return error.ConnectionClosing;
        var mask_key: [4]u8 = undefined;
        io_util.defaultIo().random(&mask_key);
        const frame = try wsEncodeFrame(self.allocator, opcode, payload, true, true, mask_key);
        defer self.allocator.free(frame);
        try self.socket.sendAll(frame);
    }

    /// Sends a ping frame with optional payload.
    pub fn ping(self: *Self, payload: []const u8) !void {
        if (self.close_sent) return error.ConnectionClosing;
        var mask_key: [4]u8 = undefined;
        io_util.defaultIo().random(&mask_key);
        const frame = try wsEncodeFrame(self.allocator, .ping, payload, true, true, mask_key);
        defer self.allocator.free(frame);
        try self.socket.sendAll(frame);
    }

    /// Sends a pong frame with optional payload.
    pub fn pong(self: *Self, payload: []const u8) !void {
        if (self.close_sent) return error.ConnectionClosing;
        var mask_key: [4]u8 = undefined;
        io_util.defaultIo().random(&mask_key);
        const frame = try wsEncodeFrame(self.allocator, .pong, payload, true, true, mask_key);
        defer self.allocator.free(frame);
        try self.socket.sendAll(frame);
    }

    /// Initiates the close handshake with a normal close code.
    pub fn close(self: *Self) !void {
        return self.closeWithCode(.normal, "");
    }

    /// Initiates the close handshake with a specific code.
    pub fn closeWithCode(self: *Self, code: WsCloseCode, reason: []const u8) !void {
        if (self.close_sent) return;
        self.close_sent = true;
        const frame = try wsCloseFrame(self.allocator, code, reason);
        defer self.allocator.free(frame);
        self.socket.sendAll(frame) catch {};
    }

    /// Receives the next complete message. Caller must free with `msg.deinit()`.
    pub fn receive(self: *Self) !WsMessage {
        while (true) {
            if (self.close_received) return error.ConnectionClosed;

            // Read a frame
            var frame_buf = std.ArrayList(u8).empty;
            defer frame_buf.deinit(self.allocator);

            var first_read = true;
            var consumed: usize = 0;
            while (true) {
                var tmp: [4096]u8 = undefined;
                const n = self.socket.recv(&tmp, 0) catch |err| return err;
                if (n == 0) return error.ConnectionClosed;
                try frame_buf.appendSlice(self.allocator, tmp[0..n]);

                // Try to decode what we have so far
                if (frame_buf.items.len >= 2) {
                    const decode_result = wsDecodeFrame(self.allocator, frame_buf.items) catch |err| switch (err) {
                        error.NeedMoreData => {
                            first_read = false;
                            continue;
                        },
                        else => return err,
                    };
                    consumed = decode_result.consumed;
                    const frame = decode_result.frame;

                    // Handle control frames inline
                    if (frame.opcode == .ping) {
                        // Auto-respond with pong
                        self.pong(frame.payload) catch {};
                        self.allocator.free(frame.payload);
                        // Remove consumed bytes and continue
                        const remaining = frame_buf.items.len - consumed;
                        if (remaining > 0) {
                            mem.copyForwards(u8, frame_buf.items[0..remaining], frame_buf.items[consumed..]);
                        }
                        frame_buf.items.len = remaining;
                        first_read = true;
                        continue;
                    } else if (frame.opcode == .pong) {
                        // Unsolicited pong, ignore
                        self.allocator.free(frame.payload);
                        const remaining = frame_buf.items.len - consumed;
                        if (remaining > 0) {
                            mem.copyForwards(u8, frame_buf.items[0..remaining], frame_buf.items[consumed..]);
                        }
                        frame_buf.items.len = remaining;
                        first_read = true;
                        continue;
                    } else if (frame.opcode == .close) {
                        self.close_received = true;
                        // Send close back if we haven't already
                        if (!self.close_sent) {
                            self.closeWithCode(.normal, "") catch {};
                        }
                        self.allocator.free(frame.payload);
                        return error.ConnectionClosed;
                    }

                    // Data frame — feed to assembler
                    const msg = self.assembler.feed(frame) catch |err| {
                        self.allocator.free(frame.payload);
                        return err;
                    };
                    self.allocator.free(frame.payload);

                    if (msg) |complete_msg| {
                        return WsMessage{
                            .opcode = complete_msg.opcode,
                            .payload = complete_msg.payload,
                            .allocator = self.allocator,
                        };
                    }

                    // Remove consumed bytes and continue
                    const remaining = frame_buf.items.len - consumed;
                    if (remaining > 0) {
                        mem.copyForwards(u8, frame_buf.items[0..remaining], frame_buf.items[consumed..]);
                    }
                    frame_buf.items.len = remaining;
                    first_read = true;
                }
            }
        }
    }
};

const Response = @import("../core/response.zig").Response;

/// WebSocket server configuration.
pub const WsServerConfig = struct {
    /// Maximum frame size in bytes. 0 means no limit.
    max_frame_size: usize = 0,
    /// Maximum message size in bytes. 0 means no limit.
    max_message_size: usize = 0,
    /// Allowed origins. null means allow all.
    allowed_origins: ?[]const []const u8 = null,
    /// Supported subprotocols.
    subprotocols: ?[]const []const u8 = null,
};

/// Validates a WebSocket upgrade request.
/// Returns the extracted key, or null if the request is invalid.
pub fn validateUpgrade(req: *const Request) ?[]const u8 {
    if (!isWebSocketUpgrade(req)) return null;
    return wsExtractKey(req);
}

/// Validates the Origin header against a list of allowed origins.
/// Returns true if the origin is allowed, or if no restrictions are configured.
pub fn validateOrigin(req: *const Request, allowed_origins: ?[]const []const u8) bool {
    const origins = allowed_origins orelse return true;
    const origin = req.headers.get("Origin") orelse return false;
    for (origins) |allowed| {
        if (mem.eql(u8, allowed, "*") or mem.eql(u8, allowed, origin)) {
            return true;
        }
    }
    return false;
}

/// Negotiates a subprotocol from the client's request.
/// Returns the selected protocol, or null if none match.
pub fn negotiateSubprotocol(
    req: *const Request,
    supported: []const []const u8,
) ?[]const u8 {
    const header = req.headers.get("Sec-WebSocket-Protocol") orelse return null;
    var iter = mem.splitScalar(u8, header, ',');
    while (iter.next()) |requested| {
        const trimmed = mem.trim(u8, requested, " \t");
        for (supported) |proto| {
            if (mem.eql(u8, proto, trimmed)) {
                return proto;
            }
        }
    }
    return null;
}

/// Builds a 101 Switching Protocols response for a WebSocket upgrade.
/// Sets the required headers on the response. Returns the Sec-WebSocket-Accept value.
pub fn buildUpgradeResponse(
    allocator: std.mem.Allocator,
    resp: *Response,
    client_key: []const u8,
    subprotocol: ?[]const u8,
) ![]u8 {
    const accept = try wsAcceptKey(client_key, allocator);
    errdefer allocator.free(accept);

    resp.status = .{ .code = 101, .reason = "Switching Protocols" };
    try resp.headers.set("Upgrade", "websocket");
    try resp.headers.set("Connection", "Upgrade");
    try resp.headers.set("Sec-WebSocket-Accept", accept);

    if (subprotocol) |proto| {
        try resp.headers.set("Sec-WebSocket-Protocol", proto);
    }

    return accept;
}

/// Callbacks for WebSocket server event handling.
pub const WsCallbacks = struct {
    on_open: ?*const fn (ctx: *anyopaque) void = null,
    on_message: ?*const fn (ctx: *anyopaque, msg: WsMessage) void = null,
    on_close: ?*const fn (ctx: *anyopaque, code: u16, reason: []const u8) void = null,
    on_error: ?*const fn (ctx: *anyopaque, err: anyerror) void = null,
    on_ping: ?*const fn (ctx: *anyopaque, payload: []const u8) void = null,
    on_pong: ?*const fn (ctx: *anyopaque, payload: []const u8) void = null,
};

/// Server-side WebSocket connection handler. Manages a single upgraded connection.
pub const WsConnection = struct {
    allocator: std.mem.Allocator,
    socket: *Socket,
    assembler: MessageAssembler,
    callbacks: WsCallbacks,
    context: *anyopaque,
    close_sent: bool = false,
    close_received: bool = false,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        socket: *Socket,
        config: WsServerConfig,
        callbacks: WsCallbacks,
        context: *anyopaque,
    ) Self {
        return .{
            .allocator = allocator,
            .socket = socket,
            .assembler = MessageAssembler.init(allocator, .{
                .max_message_size = config.max_message_size,
            }),
            .callbacks = callbacks,
            .context = context,
        };
    }

    pub fn deinit(self: *Self) void {
        self.assembler.deinit();
    }

    /// Sends a text message.
    pub fn sendText(self: *Self, text: []const u8) !void {
        return self.sendMessage(.text, text);
    }

    /// Sends a binary message.
    pub fn sendBinary(self: *Self, data: []const u8) !void {
        return self.sendMessage(.binary, data);
    }

    /// Sends a message with the given opcode. Server frames are not masked.
    pub fn sendMessage(self: *Self, opcode: WsOpcode, payload: []const u8) !void {
        if (self.close_sent) return error.ConnectionClosing;
        const frame = try wsEncodeFrame(self.allocator, opcode, payload, true, false, .{ 0, 0, 0, 0 });
        defer self.allocator.free(frame);
        try self.socket.sendAll(frame);
    }

    /// Sends a ping frame.
    pub fn ping(self: *Self, payload: []const u8) !void {
        if (self.close_sent) return error.ConnectionClosing;
        const frame = try wsEncodeFrame(self.allocator, .ping, payload, true, false, .{ 0, 0, 0, 0 });
        defer self.allocator.free(frame);
        try self.socket.sendAll(frame);
    }

    /// Sends a pong frame.
    pub fn pong(self: *Self, payload: []const u8) !void {
        if (self.close_sent) return error.ConnectionClosing;
        const frame = try wsEncodeFrame(self.allocator, .pong, payload, true, false, .{ 0, 0, 0, 0 });
        defer self.allocator.free(frame);
        try self.socket.sendAll(frame);
    }

    /// Sends a close frame.
    pub fn close(self: *Self) !void {
        return self.closeWithCode(.normal, "");
    }

    /// Sends a close frame with a specific code and reason.
    pub fn closeWithCode(self: *Self, code: WsCloseCode, reason: []const u8) !void {
        if (self.close_sent) return;
        self.close_sent = true;
        const frame = try wsCloseFrame(self.allocator, code, reason);
        defer self.allocator.free(frame);
        self.socket.sendAll(frame) catch {};
    }

    /// Reads and processes messages in a loop. Blocks until the connection closes.
    pub fn readLoop(self: *Self) !void {
        while (true) {
            if (self.close_received) return;

            var frame_buf = std.ArrayList(u8).empty;
            defer frame_buf.deinit(self.allocator);

            var consumed: usize = 0;
            while (true) {
                var tmp: [4096]u8 = undefined;
                const n = self.socket.recv(&tmp, 0) catch |err| {
                    if (self.callbacks.on_error) |cb| cb(self.context, err);
                    return err;
                };
                if (n == 0) {
                    if (self.callbacks.on_close) |cb| cb(self.context, 1006, "abnormal close");
                    return;
                }
                try frame_buf.appendSlice(self.allocator, tmp[0..n]);

                if (frame_buf.items.len >= 2) {
                    const decode_result = wsDecodeFrame(self.allocator, frame_buf.items) catch |err| switch (err) {
                        error.NeedMoreData => continue,
                        else => {
                            if (self.callbacks.on_error) |cb| cb(self.context, err);
                            return err;
                        },
                    };
                    consumed = decode_result.consumed;
                    const frame = decode_result.frame;

                    if (frame.opcode == .ping) {
                        if (self.callbacks.on_ping) |cb| cb(self.context, frame.payload);
                        self.pong(frame.payload) catch {};
                        self.allocator.free(frame.payload);
                    } else if (frame.opcode == .pong) {
                        if (self.callbacks.on_pong) |cb| cb(self.context, frame.payload);
                        self.allocator.free(frame.payload);
                    } else if (frame.opcode == .close) {
                        self.close_received = true;
                        var close_code: u16 = 1005;
                        var close_reason: []const u8 = "";
                        if (frame.payload.len >= 2) {
                            close_code = (@as(u16, frame.payload[0]) << 8) | frame.payload[1];
                            close_reason = frame.payload[2..];
                        }
                        if (self.callbacks.on_close) |cb| cb(self.context, close_code, close_reason);
                        if (!self.close_sent) {
                            self.closeWithCode(.normal, "") catch {};
                        }
                        self.allocator.free(frame.payload);
                        return;
                    } else {
                        // Data frame — feed to assembler
                        const msg = self.assembler.feed(frame) catch |err| {
                            self.allocator.free(frame.payload);
                            if (self.callbacks.on_error) |cb| cb(self.context, err);
                            return err;
                        };
                        self.allocator.free(frame.payload);

                        if (msg) |complete_msg| {
                            const ws_msg = WsMessage{
                                .opcode = complete_msg.opcode,
                                .payload = complete_msg.payload,
                                .allocator = self.allocator,
                            };
                            if (self.callbacks.on_message) |cb| cb(self.context, ws_msg);
                            complete_msg.deinit();
                        }
                    }

                    // Remove consumed bytes
                    const remaining = frame_buf.items.len - consumed;
                    if (remaining > 0) {
                        mem.copyForwards(u8, frame_buf.items[0..remaining], frame_buf.items[consumed..]);
                    }
                    frame_buf.items.len = remaining;
                }
            }
        }
    }
};

const ParsedWsUrl = struct {
    tls: bool,
    host: ?[]const u8,
    port: ?u16,
    path: ?[]const u8,
};

fn parseWsUrl(url: []const u8) !ParsedWsUrl {
    var remaining = url;
    var tls = false;

    if (mem.startsWith(u8, remaining, "wss://")) {
        tls = true;
        remaining = remaining["wss://".len..];
    } else if (mem.startsWith(u8, remaining, "ws://")) {
        remaining = remaining["ws://".len..];
    } else {
        return error.InvalidUri;
    }

    // Find path
    var path: ?[]const u8 = null;
    if (mem.indexOf(u8, remaining, "/")) |pos| {
        path = remaining[pos..];
        remaining = remaining[0..pos];
    }

    // Parse host:port
    var host: ?[]const u8 = null;
    var port: ?u16 = null;
    if (mem.indexOf(u8, remaining, ":")) |pos| {
        host = remaining[0..pos];
        port = std.fmt.parseInt(u16, remaining[pos + 1 ..], 10) catch return error.InvalidUri;
    } else {
        host = remaining;
    }

    return .{
        .tls = tls,
        .host = host,
        .port = port,
        .path = path,
    };
}

test "WsClient init/deinit" {
    const allocator = std.testing.allocator;
    var client = WsClient.init(allocator, .{});
    defer client.deinit();
    try std.testing.expect(!client.connected);
    try std.testing.expect(!client.close_sent);
}

test "parseWsUrl -- ws:// with path" {
    const result = try parseWsUrl("ws://example.com/ws?token=abc");
    try std.testing.expect(!result.tls);
    try std.testing.expectEqualStrings("example.com", result.host.?);
    try std.testing.expect(result.port == null);
    try std.testing.expectEqualStrings("/ws?token=abc", result.path.?);
}

test "parseWsUrl -- wss:// with port" {
    const result = try parseWsUrl("wss://example.com:8443/chat");
    try std.testing.expect(result.tls);
    try std.testing.expectEqualStrings("example.com", result.host.?);
    try std.testing.expectEqual(@as(?u16, 8443), result.port);
    try std.testing.expectEqualStrings("/chat", result.path.?);
}

test "parseWsUrl -- invalid scheme" {
    try std.testing.expectError(error.InvalidUri, parseWsUrl("http://example.com"));
}

test "validateOrigin -- null allows all" {
    const allocator = std.testing.allocator;
    var req = try Request.init(allocator, .GET, "/ws");
    defer req.deinit();
    try req.headers.set("Origin", "http://evil.com");
    try std.testing.expect(validateOrigin(&req, null));
}

test "validateOrigin -- matching origin" {
    const allocator = std.testing.allocator;
    var req = try Request.init(allocator, .GET, "/ws");
    defer req.deinit();
    try req.headers.set("Origin", "http://localhost:8080");
    const allowed = [_][]const u8{ "http://localhost:8080", "https://example.com" };
    try std.testing.expect(validateOrigin(&req, &allowed));
}

test "validateOrigin -- non-matching origin" {
    const allocator = std.testing.allocator;
    var req = try Request.init(allocator, .GET, "/ws");
    defer req.deinit();
    try req.headers.set("Origin", "http://evil.com");
    const allowed = [_][]const u8{"http://localhost:8080"};
    try std.testing.expect(!validateOrigin(&req, &allowed));
}

test "validateOrigin -- wildcard" {
    const allocator = std.testing.allocator;
    var req = try Request.init(allocator, .GET, "/ws");
    defer req.deinit();
    try req.headers.set("Origin", "http://anything.com");
    const allowed = [_][]const u8{"*"};
    try std.testing.expect(validateOrigin(&req, &allowed));
}

test "negotiateSubprotocol -- matching" {
    const allocator = std.testing.allocator;
    var req = try Request.init(allocator, .GET, "/ws");
    defer req.deinit();
    try req.headers.set("Sec-WebSocket-Protocol", "chat, binary");
    const supported = [_][]const u8{ "binary", "graphql-ws" };
    const result = negotiateSubprotocol(&req, &supported);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("binary", result.?);
}

test "negotiateSubprotocol -- no match" {
    const allocator = std.testing.allocator;
    var req = try Request.init(allocator, .GET, "/ws");
    defer req.deinit();
    try req.headers.set("Sec-WebSocket-Protocol", "chat");
    const supported = [_][]const u8{ "binary", "graphql-ws" };
    try std.testing.expect(negotiateSubprotocol(&req, &supported) == null);
}

test "negotiateSubprotocol -- no header" {
    const allocator = std.testing.allocator;
    var req = try Request.init(allocator, .GET, "/ws");
    defer req.deinit();
    const supported = [_][]const u8{"chat"};
    try std.testing.expect(negotiateSubprotocol(&req, &supported) == null);
}

test "buildUpgradeResponse -- sets headers" {
    const allocator = std.testing.allocator;
    var resp = Response.init(allocator, 200);
    defer resp.deinit();

    const accept = try buildUpgradeResponse(allocator, &resp, "dGhlIHNhbXBsZSBub25jZQ==", null);
    defer allocator.free(accept);

    try std.testing.expectEqual(@as(u16, 101), resp.status.code);
    const upgrade = resp.headers.get("Upgrade");
    try std.testing.expect(upgrade != null);
    try std.testing.expectEqualStrings("websocket", upgrade.?);
    const conn = resp.headers.get("Connection");
    try std.testing.expect(conn != null);
    try std.testing.expectEqualStrings("Upgrade", conn.?);
    const accept_hdr = resp.headers.get("Sec-WebSocket-Accept");
    try std.testing.expect(accept_hdr != null);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept_hdr.?);
}

test "buildUpgradeResponse -- with subprotocol" {
    const allocator = std.testing.allocator;
    var resp = Response.init(allocator, 200);
    defer resp.deinit();

    _ = try buildUpgradeResponse(allocator, &resp, "dGhlIHNhbXBsZSBub25jZQ==", "chat");
    const proto = resp.headers.get("Sec-WebSocket-Protocol");
    try std.testing.expect(proto != null);
    try std.testing.expectEqualStrings("chat", proto.?);
}

test "WsConnection init/deinit" {
    const allocator = std.testing.allocator;
    var sock = Socket{ .handle = 0 };
    var ctx: u32 = 0;
    var conn = WsConnection.init(allocator, &sock, .{}, .{}, &ctx);
    defer conn.deinit();
    try std.testing.expect(!conn.close_sent);
}

test "validateUpgrade -- valid" {
    const allocator = std.testing.allocator;
    var req = try Request.init(allocator, .GET, "/ws");
    defer req.deinit();
    try req.headers.set("Upgrade", "websocket");
    try req.headers.set("Connection", "Upgrade");
    try req.headers.set("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==");
    const key = validateUpgrade(&req);
    try std.testing.expect(key != null);
    try std.testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", key.?);
}

test "validateUpgrade -- missing key" {
    const allocator = std.testing.allocator;
    var req = try Request.init(allocator, .GET, "/ws");
    defer req.deinit();
    try req.headers.set("Upgrade", "websocket");
    try req.headers.set("Connection", "Upgrade");
    try std.testing.expect(validateUpgrade(&req) == null);
}

test "MessageAssembler -- fragmented binary across 3 frames" {
    const allocator = std.testing.allocator;
    var assembler = MessageAssembler.init(allocator, .{});
    defer assembler.deinit();

    const enc1 = try wsEncodeFrame(allocator, .binary, "AA", false, false, .{ 0, 0, 0, 0 });
    defer allocator.free(enc1);
    const enc2 = try wsEncodeFrame(allocator, .continuation, "BB", false, false, .{ 0, 0, 0, 0 });
    defer allocator.free(enc2);
    const enc3 = try wsEncodeFrame(allocator, .continuation, "CC", true, false, .{ 0, 0, 0, 0 });
    defer allocator.free(enc3);

    const r1 = try wsDecodeFrame(allocator, enc1);
    const r2 = try wsDecodeFrame(allocator, enc2);
    const r3 = try wsDecodeFrame(allocator, enc3);

    try std.testing.expect((try assembler.feed(r1.frame)) == null);
    try std.testing.expect((try assembler.feed(r2.frame)) == null);

    const msg = try assembler.feed(r3.frame);
    try std.testing.expect(msg != null);
    try std.testing.expectEqual(WsOpcode.binary, msg.?.opcode);
    try std.testing.expectEqualStrings("AABBCC", msg.?.payload);
    msg.?.deinit();
}

test "wsDecodeFrame -- empty payload" {
    const allocator = std.testing.allocator;
    const enc = try wsEncodeFrame(allocator, .ping, "", true, false, .{ 0, 0, 0, 0 });
    defer allocator.free(enc);
    var r = try wsDecodeFrame(allocator, enc);
    defer r.frame.deinit();
    try std.testing.expectEqual(WsOpcode.ping, r.frame.opcode);
    try std.testing.expect(r.frame.fin);
    try std.testing.expectEqual(@as(usize, 0), r.frame.payload.len);
}

test "wsEncodeFrame -- 64-bit payload length" {
    const allocator = std.testing.allocator;
    // 70000 bytes requires 64-bit extended length
    var big: [70000]u8 = undefined;
    @memset(&big, 0xCD);
    const enc = try wsEncodeFrame(allocator, .binary, &big, true, false, .{ 0, 0, 0, 0 });
    defer allocator.free(enc);
    // Header: 2 + 8 = 10 bytes
    try std.testing.expect(enc.len > 10);
    var r = try wsDecodeFrame(allocator, enc);
    defer r.frame.deinit();
    try std.testing.expectEqual(@as(usize, 70000), r.frame.payload.len);
}

test "WsCloseCode -- values" {
    try std.testing.expectEqual(@as(u16, 1000), @intFromEnum(WsCloseCode.normal));
    try std.testing.expectEqual(@as(u16, 1001), @intFromEnum(WsCloseCode.going_away));
    try std.testing.expectEqual(@as(u16, 1002), @intFromEnum(WsCloseCode.protocol_error));
    try std.testing.expectEqual(@as(u16, 1006), @intFromEnum(WsCloseCode.abnormal));
    try std.testing.expectEqual(@as(u16, 1009), @intFromEnum(WsCloseCode.message_too_big));
}
