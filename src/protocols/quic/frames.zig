//! QUIC transport frame encoding/decoding (RFC 9000 section 12.4).
//!
//! All frame types implemented: PADDING, PING, ACK(+ECN), RESET_STREAM,
//! STOP_SENDING, CRYPTO, NEW_TOKEN, STREAM(0x08-0x0F), MAX_DATA,
//! MAX_STREAM_DATA, MAX_STREAMS(bi/uni), DATA_BLOCKED,
//! STREAM_DATA_BLOCKED, STREAMS_BLOCKED(bi/uni), NEW_CONNECTION_ID,
//! RETIRE_CONNECTION_ID, PATH_CHALLENGE, PATH_RESPONSE,
//! CONNECTION_CLOSE(transport/application), HANDSHAKE_DONE.
//!
//! Decode validates structure strictly: truncated varints/fields, invalid
//! CID lengths, out-of-range retirePriorTo, and non-monotonic ACK ranges
//! are hard errors (hostile-input safe).

const std = @import("std");
const Allocator = std.mem.Allocator;
const varint = @import("varint.zig");

pub const Error = error{
    Truncated,
    InvalidFrame,
    OutOfMemory,
    BufferTooSmall,
};

pub const FrameType = enum(u64) {
    padding = 0x00,
    ping = 0x01,
    ack = 0x02,
    ack_ecn = 0x03,
    resetStream = 0x04,
    stopSending = 0x05,
    crypto = 0x06,
    newToken = 0x07,
    stream_base = 0x08, // 0x08..0x0F with FIN/LEN/OFF bits
    maxData = 0x10,
    maxStreamData = 0x11,
    max_streams_bidi = 0x12,
    max_streams_uni = 0x13,
    dataBlocked = 0x14,
    streamDataBlocked = 0x15,
    streams_blocked_bidi = 0x16,
    streams_blocked_uni = 0x17,
    newConnectionId = 0x18,
    retireConnectionId = 0x19,
    pathChallenge = 0x1A,
    pathResponse = 0x1B,
    connection_close_transport = 0x1C,
    connection_close_application = 0x1D,
    handshakeDone = 0x1E,
    _,

    pub fn streamFlags(t: u8) struct { fin: bool, len: bool, off: bool } {
        return .{ .fin = t & 0x01 != 0, .len = t & 0x02 != 0, .off = t & 0x04 != 0 };
    }
};

// Decoded frame view

pub const AckRange = struct { gap: u64, length: u64 };

pub const Frame = union(enum) {
    padding: u64, // count of consecutive pad bytes consumed
    ping,
    ack: Ack,
    resetStream: struct {
        streamId: u64,
        errorCode: u64,
        finalSize: u64,
    },
    stopSending: struct { streamId: u64, errorCode: u64 },
    crypto: struct { offset: u64, data: []const u8 },
    newToken: struct { token: []const u8 },
    stream: struct {
        id: u64,
        offset: u64,
        data: []const u8,
        fin: bool,
    },
    maxData: struct { maximum: u64 },
    maxStreamData: struct { streamId: u64, maximum: u64 },
    maxStreams: struct { maximum: u64, bidi: bool },
    dataBlocked: struct { limit: u64 },
    streamDataBlocked: struct { streamId: u64, limit: u64 },
    streamsBlocked: struct { limit: u64, bidi: bool },
    newConnectionId: struct {
        sequence: u64,
        retirePriorTo: u64,
        cid: []const u8,
        statelessResetToken: [16]u8,
    },
    retireConnectionId: struct { sequence: u64 },
    pathChallenge: struct { data: [8]u8 },
    pathResponse: struct { data: [8]u8 },
    connectionClose: struct {
        errorCode: u64,
        /// 0 for transport variant's frame type field; ignored either way.
        triggeringFrameType: u64,
        reason: []const u8,
        application: bool,
    },
    handshakeDone,
};

pub const Ack = struct {
    largestAcknowledged: u64,
    ackDelay: u64,
    /// First range: number of CONTIGUOUS additional packets below largest.
    firstRange: u64,
    /// Alternating gap/range pairs below the first range (ascending gaps).
    ranges: []AckRange,
    ecn: ?struct { ect0: u64, ect1: u64, ce: u64 } = null,
};

/// Decodes one frame starting at `data[pos.*]`. Advances pos past it.
/// Slices reference the input buffer.
/// varint decode mapped into this module's error set.
inline fn dv(data: []const u8, pos: *usize) Error!u64 {
    return varint.decode(data, pos) catch |e| switch (e) {
        error.BufferTooSmall => Error.Truncated,
        error.TooLarge => Error.InvalidFrame,
        error.Truncated => Error.Truncated,
    };
}

/// Returns a bounded slice and advances the cursor without overflow-prone
/// `offset + length` arithmetic on attacker-controlled frame fields.
fn take(data: []const u8, pos: *usize, length: u64) Error![]const u8 {
    const len: usize = std.math.cast(usize, length) orelse return Error.InvalidFrame;
    if (pos.* > data.len or len > data.len - pos.*) return Error.Truncated;
    const result = data[pos.*..][0..len];
    pos.* += len;
    return result;
}

pub fn decode(data: []const u8, pos: *usize) Error!Frame {
    if (pos.* >= data.len) return Error.Truncated;
    const raw = data[pos.*];
    switch (raw) {
        0x00 => { // PADDING run
            const start = pos.*;
            pos.* += 1;
            while (pos.* < data.len and data[pos.*] == 0x00) pos.* += 1;
            return .{ .padding = pos.* - start };
        },
        0x01 => {
            pos.* += 1;
            return .ping;
        },
        0x02, 0x03 => {
            pos.* += 1;
            const largest = try dv(data, pos);
            const delay = try dv(data, pos);
            const firstRange = try dv(data, pos);
            // Validate: first range must not underflow below zero pn space.
            if (firstRange > largest) return Error.InvalidFrame;

            const range_count_raw = try dv(data, pos);
            const rangeCount: usize = @intCast(range_count_raw);
            if (rangeCount > 64) return Error.InvalidFrame;

            var ranges_buf: [64]AckRange = undefined;
            var prev_low: u64 = largest - firstRange;
            for (0..rangeCount) |i| {
                const gap = try dv(data, pos);
                const len = try dv(data, pos);
                // gap counts missing packets between prev low edge and this
                // block's high edge: cur_high = prev_low - gap - 2
                if (gap + 2 > prev_low) return Error.InvalidFrame;
                const cur_high = prev_low - gap - 2;
                if (len > cur_high + 1) return Error.InvalidFrame;
                ranges_buf[i] = .{ .gap = gap, .length = len };
                prev_low = cur_high + 1 - len;
            }

            var result_ranges: []AckRange = &.{};
            if (rangeCount > 0) {
                result_ranges = try allocRanges(ranges_buf[0..rangeCount]);
            }

            var f = Ack{
                .largestAcknowledged = largest,
                .ackDelay = delay,
                .firstRange = firstRange,
                .ranges = result_ranges,
            };

            if (raw == 0x03) {
                const ect0 = try dv(data, pos);
                const ect1 = try dv(data, pos);
                const ce = try dv(data, pos);
                f.ecn = .{ .ect0 = ect0, .ect1 = ect1, .ce = ce };
            }
            return .{ .ack = f };
        },
        0x04 => {
            pos.* += 1;
            const sid = try dv(data, pos);
            const code = try dv(data, pos);
            const final = try dv(data, pos);
            return .{ .resetStream = .{ .streamId = sid, .errorCode = code, .finalSize = final } };
        },
        0x05 => {
            pos.* += 1;
            const sid = try dv(data, pos);
            const code = try dv(data, pos);
            return .{ .stopSending = .{ .streamId = sid, .errorCode = code } };
        },
        0x06 => {
            pos.* += 1;
            const off = try dv(data, pos);
            const len = try dv(data, pos);
            const d = try take(data, pos, len);
            _ = std.math.add(u64, off, len) catch return Error.InvalidFrame;
            return .{ .crypto = .{ .offset = off, .data = d } };
        },
        0x07 => {
            pos.* += 1;
            const len = try dv(data, pos);
            const tok = try take(data, pos, len);
            return .{ .newToken = .{ .token = tok } };
        },
        0x08...0x0F => {
            pos.* += 1;
            const flags = FrameType.streamFlags(raw);
            const sid = try dv(data, pos);
            const off = if (flags.off) try dv(data, pos) else 0;
            const len: u64 = if (flags.len) try dv(data, pos) else @intCast(data.len - pos.*);
            const d = try take(data, pos, len);
            _ = std.math.add(u64, off, len) catch return Error.InvalidFrame;
            return .{ .stream = .{ .id = sid, .offset = off, .data = d, .fin = flags.fin } };
        },
        0x10 => {
            pos.* += 1;
            return .{ .maxData = .{ .maximum = try dv(data, pos) } };
        },
        0x11 => {
            pos.* += 1;
            const sid = try dv(data, pos);
            return .{ .maxStreamData = .{ .streamId = sid, .maximum = try dv(data, pos) } };
        },
        0x12, 0x13 => {
            pos.* += 1;
            return .{ .maxStreams = .{
                .maximum = try dv(data, pos),
                .bidi = raw == 0x12,
            } };
        },
        0x14 => {
            pos.* += 1;
            return .{ .dataBlocked = .{ .limit = try dv(data, pos) } };
        },
        0x15 => {
            pos.* += 1;
            const sid = try dv(data, pos);
            return .{ .streamDataBlocked = .{ .streamId = sid, .limit = try dv(data, pos) } };
        },
        0x16, 0x17 => {
            pos.* += 1;
            return .{ .streamsBlocked = .{
                .limit = try dv(data, pos),
                .bidi = raw == 0x16,
            } };
        },
        0x18 => {
            pos.* += 1;
            const seq = try dv(data, pos);
            const rpt = try dv(data, pos);
            if (rpt > seq) return Error.InvalidFrame;
            if (pos.* >= data.len) return Error.Truncated;
            const cidLen: usize = data[pos.*];
            pos.* += 1;
            if (cidLen > 20) return Error.InvalidFrame;
            if (pos.* + cidLen > data.len) return Error.Truncated;
            const cid = data[pos.*..][0..cidLen];
            pos.* += cidLen;
            if (pos.* + 16 > data.len) return Error.Truncated;
            var token: [16]u8 = undefined;
            @memcpy(&token, data[pos.*..][0..16]);
            pos.* += 16;
            return .{ .newConnectionId = .{
                .sequence = seq,
                .retirePriorTo = rpt,
                .cid = cid,
                .statelessResetToken = token,
            } };
        },
        0x19 => {
            pos.* += 1;
            return .{ .retireConnectionId = .{ .sequence = try dv(data, pos) } };
        },
        0x1A, 0x1B => {
            pos.* += 1;
            if (pos.* + 8 > data.len) return Error.Truncated;
            var d: [8]u8 = undefined;
            @memcpy(&d, data[pos.*..][0..8]);
            pos.* += 8;
            return if (raw == 0x1A)
                Frame{ .pathChallenge = .{ .data = d } }
            else
                Frame{ .pathResponse = .{ .data = d } };
        },
        0x1C, 0x1D => {
            pos.* += 1;
            const code = try dv(data, pos);
            const trigger = if (raw == 0x1C) try dv(data, pos) else 0;
            const len = try dv(data, pos);
            const reason = try take(data, pos, len);
            return .{ .connectionClose = .{
                .errorCode = code,
                .triggeringFrameType = trigger,
                .reason = reason,
                .application = raw == 0x1D,
            } };
        },
        0x1E => {
            pos.* += 1;
            return .handshakeDone;
        },
        else => return Error.InvalidFrame,
    }
}

fn allocRanges(src: []const AckRange) Error![]AckRange {
    const out = std.heap.page_allocator.alloc(AckRange, src.len) catch return Error.OutOfMemory;
    @memcpy(out, src);
    return out;
}

// Encoding

/// Encodes a frame into buf. Returns bytes written, or BufferTooSmall.
/// The `scratch` variants avoid allocation by writing ranges inline.
pub fn encode(out: *std.ArrayList(u8), gpa: Allocator, f: Frame) !void {
    switch (f) {
        .padding => |n| try out.appendNTimes(gpa, 0x00, @intCast(n)),
        .ping => try out.append(gpa, 0x01),
        .ack => return error.InvalidFrame, // use encodeAckFromBlocks
        .resetStream => |r| {
            try out.append(gpa, 0x04);
            try putV(out, gpa, r.streamId);
            try putV(out, gpa, r.errorCode);
            try putV(out, gpa, r.finalSize);
        },
        .stopSending => |s| {
            try out.append(gpa, 0x05);
            try putV(out, gpa, s.streamId);
            try putV(out, gpa, s.errorCode);
        },
        .crypto => |c| {
            try out.append(gpa, 0x06);
            try putV(out, gpa, c.offset);
            try putV(out, gpa, c.data.len);
            try out.appendSlice(gpa, c.data);
        },
        .newToken => |t| {
            try out.append(gpa, 0x07);
            try putV(out, gpa, t.token.len);
            try out.appendSlice(gpa, t.token);
        },
        .stream => |s| {
            var t: u8 = 0x08 | 0x02; // LEN always set
            if (s.fin) t |= 0x01;
            if (s.offset != 0) t |= 0x04;
            try out.append(gpa, t);
            try putV(out, gpa, s.id);
            if (s.offset != 0) try putV(out, gpa, s.offset);
            try putV(out, gpa, s.data.len);
            try out.appendSlice(gpa, s.data);
        },
        .maxData => |m| {
            try out.append(gpa, 0x10);
            try putV(out, gpa, m.maximum);
        },
        .maxStreamData => |m| {
            try out.append(gpa, 0x11);
            try putV(out, gpa, m.streamId);
            try putV(out, gpa, m.maximum);
        },
        .maxStreams => |m| {
            try out.append(gpa, if (m.bidi) 0x12 else 0x13);
            try putV(out, gpa, m.maximum);
        },
        .dataBlocked => |d| {
            try out.append(gpa, 0x14);
            try putV(out, gpa, d.limit);
        },
        .streamDataBlocked => |d| {
            try out.append(gpa, 0x15);
            try putV(out, gpa, d.streamId);
            try putV(out, gpa, d.limit);
        },
        .streamsBlocked => |d| {
            try out.append(gpa, if (d.bidi) 0x16 else 0x17);
            try putV(out, gpa, d.limit);
        },
        .newConnectionId => |n| {
            try out.append(gpa, 0x18);
            try putV(out, gpa, n.sequence);
            try putV(out, gpa, n.retirePriorTo);
            try out.append(gpa, @intCast(n.cid.len));
            try out.appendSlice(gpa, n.cid);
            try out.appendSlice(gpa, n.statelessResetToken[0..]);
        },
        .retireConnectionId => |r| {
            try out.append(gpa, 0x19);
            try putV(out, gpa, r.sequence);
        },
        .pathChallenge => |p| {
            try out.append(gpa, 0x1A);
            try out.appendSlice(gpa, p.data[0..]);
        },
        .pathResponse => |p| {
            try out.append(gpa, 0x1B);
            try out.appendSlice(gpa, p.data[0..]);
        },
        .connectionClose => |c| {
            try out.append(gpa, if (c.application) 0x1D else 0x1C);
            try putV(out, gpa, c.errorCode);
            if (!c.application) try putV(out, gpa, c.triggeringFrameType);
            try putV(out, gpa, c.reason.len);
            try out.appendSlice(gpa, c.reason);
        },
        .handshakeDone => try out.append(gpa, 0x1E),
    }
}

fn putV(out: *std.ArrayList(u8), gpa: Allocator, v: u64) !void {
    var tmp: [8]u8 = undefined;
    const n = varint.encode(tmp[0..], v) catch return error.BufferTooSmall;
    try out.appendSlice(gpa, tmp[0..n]);
}

/// Encodes an ACK frame from explicit range blocks (highest-first).
/// `blocks` are {highest,len} descending; caller guarantees ordering.
/// One contiguous acknowledged block, highest packet number first.
pub const AckBlock = struct { highest: u64, len: u64 };

pub fn encodeAckFromBlocks(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    largest: u64,
    ackDelay: u64,
    blocks: []const AckBlock,
    ecn: ?struct { ect0: u64, ect1: u64, ce: u64 },
) !void {
    if (blocks.len == 0) return error.InvalidFrame;
    const top = blocks[0];
    const firstRange = top.highest - (top.highest -| (top.len - 1));

    const type_byte: u8 = if (ecn != null) 0x03 else 0x02;
    try out.append(gpa, type_byte);
    try putV(out, gpa, largest);
    try putV(out, gpa, ackDelay);
    try putV(out, gpa, firstRange);
    try putV(out, gpa, blocks.len - 1);

    var prev_low: u64 = top.highest - top.len + 1;
    for (blocks[1..]) |b| {
        if (b.highest >= prev_low) return error.InvalidFrame;
        const gap = prev_low - b.highest - 2;
        try putV(out, gpa, gap);
        try putV(out, gpa, b.len - 1);
        prev_low = b.highest - b.len + 1;
    }

    if (ecn) |e| {
        try putV(out, gpa, e.ect0);
        try putV(out, gpa, e.ect1);
        try putV(out, gpa, e.ce);
    }
}

// Tests

test "crypto frame roundtrip" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    try encode(&list, std.testing.allocator, .{ .crypto = .{ .offset = 300, .data = "hello quic" } });

    var pos: usize = 0;
    const f = try decode(list.items, &pos);
    try std.testing.expectEqual(@as(u64, 300), f.crypto.offset);
    try std.testing.expectEqualStrings("hello quic", f.crypto.data);
    try std.testing.expectEqual(list.items.len, pos);
}

test "stream frame roundtrip with offset and fin" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    try encode(&list, std.testing.allocator, .{ .stream = .{
        .id = 8,
        .offset = 1024,
        .data = "body!",
        .fin = true,
    } });
    try std.testing.expectEqual(@as(u8, 0x0F), list.items[0]); // FIN|LEN|OFF

    var pos: usize = 0;
    const f = try decode(list.items, &pos);
    try std.testing.expect(f.stream.fin);
    try std.testing.expectEqual(@as(u64, 8), f.stream.id);
    try std.testing.expectEqual(@as(u64, 1024), f.stream.offset);
    try std.testing.expectEqualStrings("body!", f.stream.data);
}

test "ack frame roundtrip two blocks with gap" {
    // Acked packets: {10}, {7,6,5}. Missing: 9, 8 -> gap 1 between 5..7 and 10.
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    const blocks = [_]AckBlock{
        .{ .highest = 10, .len = 1 },
        .{ .highest = 7, .len = 3 },
    };
    try encodeAckFromBlocks(&list, std.testing.allocator, 10, 100, blocks[0..], null);

    var pos: usize = 0;
    const f = try decode(list.items, &pos);
    try std.testing.expectEqual(@as(u64, 10), f.ack.largestAcknowledged);
    try std.testing.expectEqual(@as(u64, 0), f.ack.firstRange); // single pkt
    try std.testing.expectEqual(@as(usize, 1), f.ack.ranges.len);
    try std.testing.expectEqual(@as(u64, 1), f.ack.ranges[0].gap); // pkts 9,8 missing
    try std.testing.expectEqual(@as(u64, 2), f.ack.ranges[0].length); // len-1 for 3 pkts
}

test "ack rejects malformed ranges" {
    // Craft ACK whose firstRange exceeds largest.
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    try list.append(std.testing.allocator, 0x02);
    try putV(&list, std.testing.allocator, 5); // largest
    try putV(&list, std.testing.allocator, 0); // delay
    try putV(&list, std.testing.allocator, 10); // firstRange > largest -> invalid
    try putV(&list, std.testing.allocator, 0); // range count

    var pos: usize = 0;
    try std.testing.expectError(Error.InvalidFrame, decode(list.items, &pos));
}

test "newConnectionId roundtrip and retirePriorTo validation" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    var token: [16]u8 = undefined;
    for (&token, 0..) |*b, i| b.* = @intCast(i);
    try encode(&list, std.testing.allocator, .{ .newConnectionId = .{
        .sequence = 3,
        .retirePriorTo = 1,
        .cid = &.{ 0xAA, 0xBB, 0xCC },
        .statelessResetToken = token,
    } });

    var pos: usize = 0;
    const f = try decode(list.items, &pos);
    try std.testing.expectEqual(@as(u64, 3), f.newConnectionId.sequence);
    try std.testing.expectEqual(@as(u64, 1), f.newConnectionId.retirePriorTo);
    try std.testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB, 0xCC }, f.newConnectionId.cid);

    // retirePriorTo > sequence rejected.
    var bad = std.ArrayList(u8).empty;
    defer bad.deinit(std.testing.allocator);
    try bad.append(std.testing.allocator, 0x18);
    try putV(&bad, std.testing.allocator, 2);
    try putV(&bad, std.testing.allocator, 5); // > sequence
    try bad.append(std.testing.allocator, 4);
    try bad.appendSlice(std.testing.allocator, &.{ 1, 2, 3, 4 });
    try bad.appendSlice(std.testing.allocator, token[0..]);
    var pos2: usize = 0;
    try std.testing.expectError(Error.InvalidFrame, decode(bad.items, &pos2));
}

test "path challenge/response fixed 8-byte payload" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    try encode(&list, std.testing.allocator, .{ .pathChallenge = .{ .data = .{ 1, 2, 3, 4, 5, 6, 7, 8 } } });
    var pos: usize = 0;
    const f = try decode(list.items, &pos);
    try std.testing.expectEqualSlices(u8, &[8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }, f.pathChallenge.data[0..]);

    try encode(&list, std.testing.allocator, .{ .pathResponse = .{ .data = .{ 8, 7, 6, 5, 4, 3, 2, 1 } } });
    const f2 = try decode(list.items, &pos);
    try std.testing.expectEqualSlices(u8, &[8]u8{ 8, 7, 6, 5, 4, 3, 2, 1 }, f2.pathResponse.data[0..]);
}

test "connection close both variants" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    try encode(&list, std.testing.allocator, .{ .connectionClose = .{
        .errorCode = 0x01,
        .triggeringFrameType = 0x06,
        .reason = "",
        .application = false,
    } });
    var pos: usize = 0;
    const f = try decode(list.items, &pos);
    try std.testing.expect(!f.connectionClose.application);

    try encode(&list, std.testing.allocator, .{ .connectionClose = .{
        .errorCode = 0x0100,
        .triggeringFrameType = 0,
        .reason = "done",
        .application = true,
    } });
    const f2 = try decode(list.items, &pos);
    try std.testing.expect(f2.connectionClose.application);
    try std.testing.expectEqualStrings("done", f2.connectionClose.reason);
}

test "padding run decodes as one frame" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    try list.appendNTimes(std.testing.allocator, 0x00, 7);
    try list.append(std.testing.allocator, 0x01); // ping terminator
    var pos: usize = 0;
    const f = try decode(list.items, &pos);
    try std.testing.expectEqual(@as(u64, 7), f.padding);
    const f2 = try decode(list.items, &pos);
    try std.testing.expect(f2 == .ping);
}
