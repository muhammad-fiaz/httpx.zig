//! QUIC stream data handling: ordered delivery via a gap-based reorder
//! buffer, flow-control accounting (stream + connection credit), and
//! FIN/RESET semantics (RFC 9000 sections 2 and 4).
//!
//! Design mirrors ngtcp2_strm's fast path: in-order data is delivered
//! immediately; out-of-order chunks are buffered until the hole fills.
//! A cap on buffered gaps guards against hostile senders.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    FlowControlViolation,
    FinalSizeViolation,
    OutOfMemory,
    StreamReset,
};

pub const MAX_BUFFERED_GAPS = 4096;
pub const ENTRY_OVERHEAD: u64 = 1; // per-byte FC accounting (no HPACK-style overhead)

pub const Stream = struct {
    allocator: Allocator,
    id: u64,
    bidi: bool,
    initiator: bool,

    // receive side
    /// Next byte offset the application expects.
    recv_offset: u64 = 0,
    /// Largest offset we are willing to receive (our advertised window top).
    recv_max_offset: u64 = 65_535,
    /// Highest offset ever received (for final-size checks).
    max_seen_offset: u64 = 0,
    fin_offset: ?u64 = null,
    reset_error: ?u64 = null,

    /// Buffered out-of-order chunks awaiting earlier bytes. Sorted by
    /// offset ascending; non-overlapping.
    pending: std.ArrayList(Chunk) = .empty,

    // send side
    send_max_offset: u64 = 0, // peer-granted limit
    sent_offset: u64 = 0,
    fin_queued: bool = false,

    pub const Chunk = struct { offset: u64, data: []u8 };

    pub fn init(allocator: Allocator, id: u64, bidi: bool, initiator: bool) Stream {
        return .{ .allocator = allocator, .id = id, .bidi = bidi, .initiator = initiator };
    }

    pub fn deinit(self: *Stream) void {
        for (self.pending.items) |c| self.allocator.free(c.data);
        self.pending.deinit(self.allocator);
    }

    /// Receive-side flow-control check for an incoming frame span.
    pub fn fcAllows(self: *const Stream, offset: u64, len: u64) bool {
        return offset +| len <= self.recv_max_offset;
    }

    /// Feeds received stream bytes at `offset`. Delivers contiguous bytes
    /// through `sink` (called repeatedly). Returns total newly-delivered
    /// length (may be 0 when buffering out-of-order input).
    pub fn receive(
        self: *Stream,
        offset: u64,
        data: []const u8,
        fin: bool,
        sink: anytype,
    ) Error!usize {
        if (self.reset_error != null) return Error.StreamReset;
        if (!self.fcAllows(offset, data.len)) return Error.FlowControlViolation;

        const end = std.math.add(u64, offset, data.len) catch return Error.FlowControlViolation;

        // Once FIN has established the stream's final size, every later
        // frame must lie entirely at or below that size (RFC 9000 Section
        // 4.5), regardless of whether the duplicate frame repeats FIN.
        if (self.fin_offset) |final_size| {
            if (end > final_size) return Error.FinalSizeViolation;
        }

        // Final-size consistency (RFC 9000 section 4.5).
        if (fin) {
            if (self.fin_offset) |prev| {
                if (prev != end) return Error.FinalSizeViolation;
            } else if (end < self.max_seen_offset) {
                return Error.FinalSizeViolation;
            }
            self.fin_offset = end;
        }
        self.max_seen_offset = @max(self.max_seen_offset, end);

        var delivered: usize = 0;

        if (offset == self.recv_offset) {
            // Fast path / head of the hole.
            sink.call(data[0..]) catch return Error.OutOfMemory;
            delivered += data.len;
            self.recv_offset = end;
            try self.drainContiguous(sink, &delivered);
        } else if (offset > self.recv_offset) {
            // Out of order: buffer it.
            const copy = try self.allocator.dupe(u8, data);
            errdefer self.allocator.free(copy);
            try self.pending.append(self.allocator, .{ .offset = offset, .data = copy });
            std.mem.sort(Chunk, self.pending.items, {}, chunkLess);
            self.rejectOverlaps() catch return Error.OutOfMemory;
            if (self.pending.items.len > MAX_BUFFERED_GAPS) return Error.OutOfMemory;
        } else {
            // Partial overlap of already-delivered prefix: trim left.
            const skip = self.recv_offset - offset;
            if (skip < data.len) {
                const tail = data[@intCast(skip)..];
                sink.call(tail) catch return Error.OutOfMemory;
                delivered += tail.len;
                self.recv_offset = end;
                try self.drainContiguous(sink, &delivered);
            }
        }
        return delivered;
    }

    fn chunkLess(_: void, a: Chunk, b: Chunk) bool {
        return a.offset < b.offset;
    }

    fn rejectOverlaps(self: *Stream) !void {
        var i: usize = 1;
        while (i < self.pending.items.len) {
            const prev_end = self.pending.items[i - 1].offset + self.pending.items[i - 1].data.len;
            const cur_start = self.pending.items[i].offset;
            if (cur_start < prev_end) {
                // Fully covered -> drop; partially -> trim front.
                const cur = self.pending.items[i];
                if (cur.offset + cur.data.len <= prev_end) {
                    self.allocator.free(cur.data);
                    _ = self.pending.orderedRemove(i);
                    continue;
                }
                const keep = cur.data[(prev_end - cur.offset)..];
                const moved = try self.allocator.dupe(u8, keep);
                self.allocator.free(cur.data);
                self.pending.items[i] = .{ .offset = prev_end, .data = moved };
            }
            i += 1;
        }
    }

    fn drainContiguous(self: *Stream, sink: anytype, delivered: *usize) Error!void {
        while (self.pending.items.len > 0 and
            self.pending.items[0].offset <= self.recv_offset)
        {
            const c = self.pending.items[0];
            if (c.offset + c.data.len <= self.recv_offset) {
                // Fully redundant.
                self.allocator.free(c.data);
                _ = self.pending.orderedRemove(0);
                continue;
            }
            const skip: usize = @intCast(self.recv_offset - c.offset);
            const tail = c.data[skip..];
            sink.call(tail) catch return Error.OutOfMemory;
            delivered.* += tail.len;
            self.recv_offset += tail.len;
            self.allocator.free(c.data);
            _ = self.pending.orderedRemove(0);
        }
    }

    /// Advertises more receive capacity by `delta` (MAX_STREAM_DATA value
    /// becomes recv_max_offset + delta).
    pub fn extendRecvWindow(self: *Stream, delta: u64) void {
        self.recv_max_offset += delta;
    }

    pub fn canReceiveMore(self: *const Stream) bool {
        // Simple half-window policy: grant more once consumed >= 50%.
        return self.max_seen_offset >= self.recv_max_offset / 2;
    }

    pub fn onReset(self: *Stream, code: u64) void {
        self.reset_error = code;
        for (self.pending.items) |c| self.allocator.free(c.data);
        self.pending.clearRetainingCapacity();
    }

    /// Sender side: returns how many bytes may be sent now.
    pub fn sendAllowance(self: *const Stream, conn_allowance: u64) u64 {
        const granted = self.send_max_offset -| self.sent_offset;
        return @min(granted, conn_allowance);
    }

    pub fn recordSent(self: *Stream, n: u64, fin: bool) void {
        self.sent_offset += n;
        if (fin) self.fin_queued = true;
    }
};

/// Simple callback sink collecting delivered bytes into an ArrayList.
pub const CollectSink = struct {
    list: *std.ArrayList(u8),
    gpa: Allocator,

    pub fn call(self: *CollectSink, data: []const u8) !void {
        try self.list.appendSlice(self.gpa, data);
    }
};

// Tests

fn collect(gpa: Allocator) struct { s: Stream, out: std.ArrayList(u8), cs: *CollectSink } {
    _ = gpa;
    unreachable;
}

test "in-order delivery passes straight through" {
    const a = std.testing.allocator;
    var st = Stream.init(a, 4, true, true);
    defer st.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);
    var sink = CollectSink{ .list = &out, .gpa = a };

    _ = try st.receive(0, "hello ", false, &sink);
    _ = try st.receive(6, "world", true, &sink);
    try std.testing.expectEqualStrings("hello world", out.items);
    try std.testing.expectEqual(@as(u64, 11), st.recv_offset);
}

test "out-of-order chunks buffer then flush" {
    const a = std.testing.allocator;
    var st = Stream.init(a, 0, true, true);
    defer st.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);
    var sink = CollectSink{ .list = &out, .gpa = a };

    _ = try st.receive(5, "WORLD", false, &sink); // buffered
    try std.testing.expectEqualStrings("", out.items);
    _ = try st.receive(0, "HELLO", false, &sink); // releases both
    try std.testing.expectEqualStrings("HELLOWORLD", out.items);

    // Duplicate overlap of delivered prefix is trimmed, not duplicated.
    _ = try st.receive(3, "LOWO", false, &sink);
    try std.testing.expectEqualStrings("HELLOWORLD", out.items);
}

test "flow control violation detected" {
    const a = std.testing.allocator;
    var st = Stream.init(a, 0, true, true);
    defer st.deinit();
    st.recv_max_offset = 10;
    try std.testing.expect(!st.fcAllows(5, 6));
    try std.testing.expect(st.fcAllows(5, 5));

    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);
    var sink = CollectSink{ .list = &out, .gpa = a };
    try std.testing.expectError(Error.FlowControlViolation, st.receive(5, "123456", false, &sink));
    try std.testing.expectError(Error.FlowControlViolation, st.receive(std.math.maxInt(u64), "x", false, &sink));
}

test "final size mismatch rejected" {
    const a = std.testing.allocator;
    var st = Stream.init(a, 0, true, true);
    defer st.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);
    var sink = CollectSink{ .list = &out, .gpa = a };

    _ = try st.receive(0, "abc", true, &sink); // fin@3
    try std.testing.expectError(Error.FinalSizeViolation, st.receive(2, "xyz", true, &sink)); // end=5
    try std.testing.expectError(Error.FinalSizeViolation, st.receive(3, "x", false, &sink)); // extends past fin@3

    // FIN below already-seen data also rejected.
    var st2 = Stream.init(a, 1, true, true);
    defer st2.deinit();
    var sink2 = CollectSink{ .list = &out, .gpa = a };
    _ = try st2.receive(0, "abcdef", false, &sink2);
    try std.testing.expectError(Error.FinalSizeViolation, st2.receive(0, "ab", true, &sink2));
}

test "reset discards buffered data" {
    const a = std.testing.allocator;
    var st = Stream.init(a, 0, true, true);
    defer st.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);
    var sink = CollectSink{ .list = &out, .gpa = a };

    _ = try st.receive(5, "later", false, &sink); // buffered
    st.onReset(0x08);
    try std.testing.expectEqual(@as(usize, 0), st.pending.items.len);
    try std.testing.expectError(Error.StreamReset, st.receive(5, "x", false, &sink));
}

test "send allowance respects peer grants and connection budget" {
    const a = std.testing.allocator;
    var st = Stream.init(a, 0, true, true);
    defer st.deinit();
    st.send_max_offset = 100;
    st.recordSent(30, false);
    try std.testing.expectEqual(@as(u64, 70), st.sendAllowance(1000));
    try std.testing.expectEqual(@as(u64, 20), st.sendAllowance(20));
}
