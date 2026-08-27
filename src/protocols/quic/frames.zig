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
//! CID lengths, out-of-range retire_prior_to, and non-monotonic ACK ranges
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
    reset_stream = 0x04,
    stop_sending = 0x05,
    crypto = 0x06,
    new_token = 0x07,
    stream_base = 0x08, // 0x08..0x0F with FIN/LEN/OFF bits
    max_data = 0x10,
    max_stream_data = 0x11,
    max_streams_bidi = 0x12,
    max_streams_uni = 0x13,
    data_blocked = 0x14,
    stream_data_blocked = 0x15,
    streams_blocked_bidi = 0x16,
    streams_blocked_uni = 0x17,
    new_connection_id = 0x18,
    retire_connection_id = 0x19,
    path_challenge = 0x1A,
    path_response = 0x1B,
    connection_close_transport = 0x1C,
    connection_close_application = 0x1D,
    handshake_done = 0x1E,
    _,

    pub fn streamFlags(t: u8) struct { fin: bool, len: bool, off: bool } {
        return .{ .fin = t & 0x01 != 0, .len = t & 0x02 != 0, .off = t & 0x04 != 0 };
    }
};

// ---------------------------------------------------------------------------
// Decoded frame view
// ---------------------------------------------------------------------------

pub const AckRange = struct { gap: u64, length: u64 };

pub const Frame = union(enum) {
    padding: u64, // count of consecutive pad bytes consumed
    ping,
    ack: Ack,
    reset_stream: struct {
        stream_id: u64,
        error_code: u64,
        final_size: u64,
    },
    stop_sending: struct { stream_id: u64, error_code: u64 },
    crypto: struct { offset: u64, data: []const u8 },
    new_token: struct { token: []const u8 },
    stream: struct {
        id: u64,
        offset: u64,
        data: []const u8,
        fin: bool,
    },
    max_data: struct { maximum: u64 },
    max_stream_data: struct { stream_id: u64, maximum: u64 },
    max_streams: struct { maximum: u64, bidi: bool },
    data_blocked: struct { limit: u64 },
    stream_data_blocked: struct { stream_id: u64, limit: u64 },
    streams_blocked: struct { limit: u64, bidi: bool },
    new_connection_id: struct {
        sequence: u64,
        retire_prior_to: u64,
        cid: []const u8,
        stateless_reset_token: [16]u8,
    },
    retire_connection_id: struct { sequence: u64 },
    path_challenge: struct { data: [8]u8 },
    path_response: struct { data: [8]u8 },
    connection_close: struct {
        error_code: u64,
        /// 0 for transport variant's frame type field; ignored either way.
        triggering_frame_type: u64,
        reason: []const u8,
        application: bool,
    },
    handshake_done,
};

pub const Ack = struct {
    largest_acknowledged: u64,
    ack_delay: u64,
    /// First range: number of CONTIGUOUS additional packets below largest.
    first_range: u64,
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
            const first_range = try dv(data, pos);
            // Validate: first range must not underflow below zero pn space.
            if (first_range > largest) return Error.InvalidFrame;

            const range_count_raw = try dv(data, pos);
            const range_count: usize = @intCast(range_count_raw);
            if (range_count > 64) return Error.InvalidFrame;

            var ranges_buf: [64]AckRange = undefined;
            var prev_low: u64 = largest - first_range;
            for (0..range_count) |i| {
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
            if (range_count > 0) {
                result_ranges = try allocRanges(ranges_buf[0..range_count]);
            }

            var f = Ack{
                .largest_acknowledged = largest,
                .ack_delay = delay,
                .first_range = first_range,
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
            return .{ .reset_stream = .{ .stream_id = sid, .error_code = code, .final_size = final } };
        },
        0x05 => {
            pos.* += 1;
            const sid = try dv(data, pos);
            const code = try dv(data, pos);
            return .{ .stop_sending = .{ .stream_id = sid, .error_code = code } };
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
            return .{ .new_token = .{ .token = tok } };
        },
        0x08...0x0F => {
            pos.* += 1;
            const flags = FrameType.streamFlags(raw);
            const sid = try dv(data, pos);
            const off = if (flags.off) try dv(data, pos) else 0;
            if (!flags.len) return Error.InvalidFrame; // we always require LEN
            const len = try dv(data, pos);
            const d = try take(data, pos, len);
            _ = std.math.add(u64, off, len) catch return Error.InvalidFrame;
            return .{ .stream = .{ .id = sid, .offset = off, .data = d, .fin = flags.fin } };
        },
        0x10 => {
            pos.* += 1;
            return .{ .max_data = .{ .maximum = try dv(data, pos) } };
        },
        0x11 => {
            pos.* += 1;
            const sid = try dv(data, pos);
            return .{ .max_stream_data = .{ .stream_id = sid, .maximum = try dv(data, pos) } };
        },
        0x12, 0x13 => {
            pos.* += 1;
            return .{ .max_streams = .{
                .maximum = try dv(data, pos),
                .bidi = raw == 0x12,
            } };
        },
        0x14 => {
            pos.* += 1;
            return .{ .data_blocked = .{ .limit = try dv(data, pos) } };
        },
        0x15 => {
            pos.* += 1;
            const sid = try dv(data, pos);
            return .{ .stream_data_blocked = .{ .stream_id = sid, .limit = try dv(data, pos) } };
        },
        0x16, 0x17 => {
            pos.* += 1;
            return .{ .streams_blocked = .{
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
            const cid_len: usize = data[pos.*];
            pos.* += 1;
            if (cid_len > 20) return Error.InvalidFrame;
            if (pos.* + cid_len > data.len) return Error.Truncated;
            const cid = data[pos.*..][0..cid_len];
            pos.* += cid_len;
            if (pos.* + 16 > data.len) return Error.Truncated;
            var token: [16]u8 = undefined;
            @memcpy(&token, data[pos.*..][0..16]);
            pos.* += 16;
            return .{ .new_connection_id = .{
                .sequence = seq,
                .retire_prior_to = rpt,
                .cid = cid,
                .stateless_reset_token = token,
            } };
        },
        0x19 => {
            pos.* += 1;
            return .{ .retire_connection_id = .{ .sequence = try dv(data, pos) } };
        },
        0x1A, 0x1B => {
            pos.* += 1;
            if (pos.* + 8 > data.len) return Error.Truncated;
            var d: [8]u8 = undefined;
            @memcpy(&d, data[pos.*..][0..8]);
            pos.* += 8;
            return if (raw == 0x1A)
                Frame{ .path_challenge = .{ .data = d } }
            else
                Frame{ .path_response = .{ .data = d } };
        },
        0x1C, 0x1D => {
            pos.* += 1;
            const code = try dv(data, pos);
            const trigger = if (raw == 0x1C) try dv(data, pos) else 0;
            const len = try dv(data, pos);
            const reason = try take(data, pos, len);
            return .{ .connection_close = .{
                .error_code = code,
                .triggering_frame_type = trigger,
                .reason = reason,
                .application = raw == 0x1D,
            } };
        },
        0x1E => {
            pos.* += 1;
            return .handshake_done;
        },
        else => return Error.InvalidFrame,
    }
}

fn allocRanges(src: []const AckRange) Error![]AckRange {
    const out = std.heap.page_allocator.alloc(AckRange, src.len) catch return Error.OutOfMemory;
    @memcpy(out, src);
    return out;
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

/// Encodes a frame into buf. Returns bytes written, or BufferTooSmall.
/// The `scratch` variants avoid allocation by writing ranges inline.
pub fn encode(out: *std.ArrayList(u8), gpa: Allocator, f: Frame) !void {
    switch (f) {
        .padding => |n| try out.appendNTimes(gpa, 0x00, @intCast(n)),
        .ping => try out.append(gpa, 0x01),
        .ack => return error.InvalidFrame, // use encodeAckFromBlocks
        .reset_stream => |r| {
            try out.append(gpa, 0x04);
            try putV(out, gpa, r.stream_id);
            try putV(out, gpa, r.error_code);
            try putV(out, gpa, r.final_size);
        },
        .stop_sending => |s| {
            try out.append(gpa, 0x05);
            try putV(out, gpa, s.stream_id);
            try putV(out, gpa, s.error_code);
        },
        .crypto => |c| {
            try out.append(gpa, 0x06);
            try putV(out, gpa, c.offset);
            try putV(out, gpa, c.data.len);
            try out.appendSlice(gpa, c.data);
        },
        .new_token => |t| {
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
        .max_data => |m| {
            try out.append(gpa, 0x10);
            try putV(out, gpa, m.maximum);
        },
        .max_stream_data => |m| {
            try out.append(gpa, 0x11);
            try putV(out, gpa, m.stream_id);
            try putV(out, gpa, m.maximum);
        },
        .max_streams => |m| {
            try out.append(gpa, if (m.bidi) 0x12 else 0x13);
            try putV(out, gpa, m.maximum);
        },
        .data_blocked => |d| {
            try out.append(gpa, 0x14);
            try putV(out, gpa, d.limit);
        },
        .stream_data_blocked => |d| {
            try out.append(gpa, 0x15);
            try putV(out, gpa, d.stream_id);
            try putV(out, gpa, d.limit);
        },
        .streams_blocked => |d| {
            try out.append(gpa, if (d.bidi) 0x16 else 0x17);
            try putV(out, gpa, d.limit);
        },
        .new_connection_id => |n| {
            try out.append(gpa, 0x18);
            try putV(out, gpa, n.sequence);
            try putV(out, gpa, n.retire_prior_to);
            try out.append(gpa, @intCast(n.cid.len));
            try out.appendSlice(gpa, n.cid);
            try out.appendSlice(gpa, n.stateless_reset_token[0..]);
        },
        .retire_connection_id => |r| {
            try out.append(gpa, 0x19);
            try putV(out, gpa, r.sequence);
        },
        .path_challenge => |p| {
            try out.append(gpa, 0x1A);
            try out.appendSlice(gpa, p.data[0..]);
        },
        .path_response => |p| {
            try out.append(gpa, 0x1B);
            try out.appendSlice(gpa, p.data[0..]);
        },
        .connection_close => |c| {
            try out.append(gpa, if (c.application) 0x1D else 0x1C);
            try putV(out, gpa, c.error_code);
            if (!c.application) try putV(out, gpa, c.triggering_frame_type);
            try putV(out, gpa, c.reason.len);
            try out.appendSlice(gpa, c.reason);
        },
        .handshake_done => try out.append(gpa, 0x1E),
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
    ack_delay: u64,
    blocks: []const AckBlock,
    ecn: ?struct { ect0: u64, ect1: u64, ce: u64 },
) !void {
    if (blocks.len == 0) return error.InvalidFrame;
    const top = blocks[0];
    const first_range = top.highest - (top.highest -| (top.len - 1));

    const type_byte: u8 = if (ecn != null) 0x03 else 0x02;
    try out.append(gpa, type_byte);
    try putV(out, gpa, largest);
    try putV(out, gpa, ack_delay);
    try putV(out, gpa, first_range);
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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
    try std.testing.expectEqual(@as(u64, 10), f.ack.largest_acknowledged);
    try std.testing.expectEqual(@as(u64, 0), f.ack.first_range); // single pkt
    try std.testing.expectEqual(@as(usize, 1), f.ack.ranges.len);
    try std.testing.expectEqual(@as(u64, 1), f.ack.ranges[0].gap); // pkts 9,8 missing
    try std.testing.expectEqual(@as(u64, 2), f.ack.ranges[0].length); // len-1 for 3 pkts
}

test "ack rejects malformed ranges" {
    // Craft ACK whose first_range exceeds largest.
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    try list.append(std.testing.allocator, 0x02);
    try putV(&list, std.testing.allocator, 5); // largest
    try putV(&list, std.testing.allocator, 0); // delay
    try putV(&list, std.testing.allocator, 10); // first_range > largest -> invalid
    try putV(&list, std.testing.allocator, 0); // range count

    var pos: usize = 0;
    try std.testing.expectError(Error.InvalidFrame, decode(list.items, &pos));
}

test "new_connection_id roundtrip and retire_prior_to validation" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    var token: [16]u8 = undefined;
    for (&token, 0..) |*b, i| b.* = @intCast(i);
    try encode(&list, std.testing.allocator, .{ .new_connection_id = .{
        .sequence = 3,
        .retire_prior_to = 1,
        .cid = &.{ 0xAA, 0xBB, 0xCC },
        .stateless_reset_token = token,
    } });

    var pos: usize = 0;
    const f = try decode(list.items, &pos);
    try std.testing.expectEqual(@as(u64, 3), f.new_connection_id.sequence);
    try std.testing.expectEqual(@as(u64, 1), f.new_connection_id.retire_prior_to);
    try std.testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB, 0xCC }, f.new_connection_id.cid);

    // retire_prior_to > sequence rejected.
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
    try encode(&list, std.testing.allocator, .{ .path_challenge = .{ .data = .{ 1, 2, 3, 4, 5, 6, 7, 8 } } });
    var pos: usize = 0;
    const f = try decode(list.items, &pos);
    try std.testing.expectEqualSlices(u8, &[8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }, f.path_challenge.data[0..]);

    try encode(&list, std.testing.allocator, .{ .path_response = .{ .data = .{ 8, 7, 6, 5, 4, 3, 2, 1 } } });
    const f2 = try decode(list.items, &pos);
    try std.testing.expectEqualSlices(u8, &[8]u8{ 8, 7, 6, 5, 4, 3, 2, 1 }, f2.path_response.data[0..]);
}

test "connection close both variants" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    try encode(&list, std.testing.allocator, .{ .connection_close = .{
        .error_code = 0x01,
        .triggering_frame_type = 0x06,
        .reason = "",
        .application = false,
    } });
    var pos: usize = 0;
    const f = try decode(list.items, &pos);
    try std.testing.expect(!f.connection_close.application);

    try encode(&list, std.testing.allocator, .{ .connection_close = .{
        .error_code = 0x0100,
        .triggering_frame_type = 0,
        .reason = "done",
        .application = true,
    } });
    const f2 = try decode(list.items, &pos);
    try std.testing.expect(f2.connection_close.application);
    try std.testing.expectEqualStrings("done", f2.connection_close.reason);
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
