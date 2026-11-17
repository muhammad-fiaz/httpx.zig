//! QUIC stream data handling: ordered delivery via a gap-based reorder
//! buffer, flow-control accounting (stream + connection credit), and
//! FIN/RESET semantics (RFC 9000 sections 2 and 4).
//!
//! In-order data is delivered immediately; out-of-order chunks are
//! buffered until the hole fills. A cap on buffered gaps guards against
//! hostile senders.

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
    recvOffset: u64 = 0,
    /// Largest offset we are willing to receive (our advertised window top).
    recvMaxOffset: u64 = 65_535,
    /// Highest offset ever received (for final-size checks).
    maxSeenOffset: u64 = 0,
    finOffset: ?u64 = null,
    finNotified: bool = false,
    resetError: ?u64 = null,

    /// Buffered out-of-order chunks awaiting earlier bytes. Sorted by
    /// offset ascending; non-overlapping. Consumed chunks are retired at
    /// `pending_head`, so draining never shifts the array.
    pending: std.ArrayList(Chunk) = .empty,
    /// Index of the first live chunk in `pending`.
    pending_head: usize = 0,

    // send side
    sendMaxOffset: u64 = 0, // peer-granted limit
    sentOffset: u64 = 0,
    finQueued: bool = false,

    pub const Chunk = struct {
        /// Stream offset of the first live byte.
        offset: u64,
        /// Index of the first live byte inside `data`.
        start: usize,
        /// The received bytes; only `data[start..]` is live.
        data: []u8,

        /// The bytes that have not been delivered yet.
        fn live(c: Chunk) []const u8 {
            return c.data[c.start..];
        }
    };

    /// Next contiguous byte offset delivered to the application.
    pub fn currentRecvOffset(self: *const Stream) u64 {
        return self.recvOffset;
    }

    /// Number of chunks buffered while waiting for an earlier hole.
    pub fn pendingCount(self: *const Stream) usize {
        return self.pending.items.len - self.pending_head;
    }

    pub fn init(allocator: Allocator, id: u64, bidi: bool, initiator: bool) Stream {
        return .{ .allocator = allocator, .id = id, .bidi = bidi, .initiator = initiator };
    }

    pub fn deinit(self: *Stream) void {
        for (self.pending.items[self.pending_head..]) |c| self.allocator.free(c.data);
        self.pending.deinit(self.allocator);
    }

    /// Receive-side flow-control check for an incoming frame span.
    pub fn fcAllows(self: *const Stream, offset: u64, len: u64) bool {
        return offset +| len <= self.recvMaxOffset;
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
        if (self.resetError != null) return Error.StreamReset;
        if (!self.fcAllows(offset, data.len)) return Error.FlowControlViolation;

        const end = std.math.add(u64, offset, data.len) catch return Error.FlowControlViolation;

        // Once FIN has established the stream's final size, every later
        // frame must lie entirely at or below that size (RFC 9000 Section
        // 4.5), regardless of whether the duplicate frame repeats FIN.
        if (self.finOffset) |finalSize| {
            if (end > finalSize) return Error.FinalSizeViolation;
        }

        // Final-size consistency (RFC 9000 section 4.5).
        if (fin) {
            if (self.finOffset) |prev| {
                if (prev != end) return Error.FinalSizeViolation;
            } else if (end < self.maxSeenOffset) {
                return Error.FinalSizeViolation;
            }
            self.finOffset = end;
        }
        self.maxSeenOffset = @max(self.maxSeenOffset, end);

        var delivered: usize = 0;

        if (offset == self.recvOffset) {
            // Fast path / head of the hole.
            sink.call(data[0..]) catch return Error.OutOfMemory;
            delivered += data.len;
            self.recvOffset = end;
            try self.drainContiguous(sink, &delivered);
        } else if (offset > self.recvOffset) {
            // Out of order: buffer it.
            const copy = try self.allocator.dupe(u8, data);
            // The list stays sorted, so a binary search replaces a full
            // re-sort for every buffered chunk.
            const at = self.insertPosition(offset);
            self.pending.insert(self.allocator, at, .{
                .offset = offset,
                .start = 0,
                .data = copy,
            }) catch |err| {
                self.allocator.free(copy);
                return err;
            };
            try self.rejectOverlaps();
            if (self.pendingCount() > MAX_BUFFERED_GAPS) return Error.OutOfMemory;
        } else {
            // Partial overlap of already-delivered prefix: trim left.
            const skip = self.recvOffset - offset;
            if (skip < data.len) {
                const tail = data[@intCast(skip)..];
                sink.call(tail) catch return Error.OutOfMemory;
                delivered += tail.len;
                self.recvOffset = end;
                try self.drainContiguous(sink, &delivered);
            }
        }
        return delivered;
    }

    /// Position (in the whole list) for a chunk starting at `offset`.
    /// The live chunks are sorted by offset, so a binary search finds
    /// the slot without re-sorting the list.
    fn insertPosition(self: *const Stream, offset: u64) usize {
        const live = self.pending.items[self.pending_head..];
        const rel = std.sort.upperBound(Chunk, live, offset, struct {
            fn compare(ctx: u64, c: Chunk) std.math.Order {
                return std.math.order(ctx, c.offset);
            }
        }.compare);
        return self.pending_head + rel;
    }

    /// Drops the consumed prefix of the pending list. The shift only
    /// runs once the dead prefix is at least half the array, so every
    /// chunk is moved at most once per compaction.
    fn compactPending(self: *Stream) void {
        if (self.pending_head == 0) return;
        if (self.pending_head == self.pending.items.len) {
            self.pending.clearRetainingCapacity();
            self.pending_head = 0;
            return;
        }
        if (self.pending_head < 32 and self.pending_head * 2 < self.pending.items.len) return;
        const remaining = self.pending.items.len - self.pending_head;
        @memmove(self.pending.items[0..remaining], self.pending.items[self.pending_head..]);
        self.pending.items.len = remaining;
        self.pending_head = 0;
    }

    /// Removes or trims chunks that overlap an earlier chunk. The list
    /// stays sorted and the chunks stay non-overlapping.
    fn rejectOverlaps(self: *Stream) !void {
        var i: usize = self.pending_head + 1;
        while (i < self.pending.items.len) {
            const prev = self.pending.items[i - 1];
            const prevEnd = prev.offset + prev.live().len;
            const cur = self.pending.items[i];
            if (cur.offset < prevEnd) {
                // Fully covered -> drop; partially -> trim front.
                if (cur.offset + cur.live().len <= prevEnd) {
                    self.allocator.free(cur.data);
                    _ = self.pending.orderedRemove(i);
                    continue;
                }
                // Trimming only moves the live window: the buffer itself
                // stays allocated, so no copy is needed.
                const trimFront: usize = @intCast(prevEnd - cur.offset);
                self.pending.items[i].start += trimFront;
                self.pending.items[i].offset = prevEnd;
            }
            i += 1;
        }
    }

    fn drainContiguous(self: *Stream, sink: anytype, delivered: *usize) Error!void {
        while (self.pendingCount() > 0 and
            self.pending.items[self.pending_head].offset <= self.recvOffset)
        {
            const c = self.pending.items[self.pending_head];
            const bytes = c.live();
            if (c.offset + bytes.len <= self.recvOffset) {
                // Fully redundant.
                self.allocator.free(c.data);
                self.pending_head += 1;
                continue;
            }
            const skip: usize = @intCast(self.recvOffset - c.offset);
            const tail = bytes[skip..];
            sink.call(tail) catch return Error.OutOfMemory;
            delivered.* += tail.len;
            self.recvOffset += tail.len;
            self.allocator.free(c.data);
            self.pending_head += 1;
        }
        self.compactPending();
    }

    /// Advertises more receive capacity by `delta` (MAX_STREAM_DATA value
    /// becomes recvMaxOffset + delta).
    pub fn extendRecvWindow(self: *Stream, delta: u64) void {
        self.recvMaxOffset += delta;
    }

    pub fn canReceiveMore(self: *const Stream) bool {
        // Simple half-window policy: grant more once consumed >= 50%.
        return self.maxSeenOffset >= self.recvMaxOffset / 2;
    }

    pub fn onReset(self: *Stream, code: u64) void {
        self.resetError = code;
        for (self.pending.items[self.pending_head..]) |c| self.allocator.free(c.data);
        self.pending.clearRetainingCapacity();
        self.pending_head = 0;
    }

    /// Sender side: returns how many bytes may be sent now.
    pub fn sendAllowance(self: *const Stream, connAllowance: u64) u64 {
        const granted = self.sendMaxOffset -| self.sentOffset;
        return @min(granted, connAllowance);
    }

    pub fn recordSent(self: *Stream, n: u64, fin: bool) void {
        self.sentOffset += n;
        if (fin) self.finQueued = true;
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
    try std.testing.expectEqual(@as(u64, 11), st.recvOffset);
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

test "overlapping buffered chunks are trimmed or dropped" {
    const a = std.testing.allocator;
    var st = Stream.init(a, 0, true, true);
    defer st.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);
    var sink = CollectSink{ .list = &out, .gpa = a };

    // "5678" at offset 5 is buffered.
    _ = try st.receive(5, "5678", false, &sink);
    // A retransmission overlapping the buffered chunk is trimmed to the
    // bytes the buffer does not already carry.
    _ = try st.receive(6, "6789", false, &sink);
    try std.testing.expectEqual(@as(usize, 2), st.pendingCount());

    // Delivering the head releases the trimmed bytes in order.
    _ = try st.receive(0, "01234", false, &sink);
    try std.testing.expectEqualStrings("0123456789", out.items);
    try std.testing.expectEqual(@as(u64, 10), st.recvOffset);
    try std.testing.expectEqual(@as(usize, 0), st.pendingCount());
}

test "a fully covered buffered chunk is dropped" {
    const a = std.testing.allocator;
    var st = Stream.init(a, 0, true, true);
    defer st.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);
    var sink = CollectSink{ .list = &out, .gpa = a };

    _ = try st.receive(5, "5678", false, &sink);
    // Entirely inside the buffered chunk: nothing new to keep.
    _ = try st.receive(6, "67", false, &sink);
    try std.testing.expectEqual(@as(usize, 1), st.pendingCount());

    _ = try st.receive(0, "01234", false, &sink);
    try std.testing.expectEqualStrings("012345678", out.items);
}

test "gap limit error leaves buffered chunk owned by stream" {
    const a = std.testing.allocator;
    var st = Stream.init(a, 0, true, true);
    defer st.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);
    var sink = CollectSink{ .list = &out, .gpa = a };

    for (0..MAX_BUFFERED_GAPS + 1) |i| {
        const offset: u64 = @intCast(i * 2 + 1);
        if (i == MAX_BUFFERED_GAPS) {
            try std.testing.expectError(Error.OutOfMemory, st.receive(offset, "x", false, &sink));
        } else {
            _ = try st.receive(offset, "x", false, &sink);
        }
    }
    // Deinit must free every still-buffered chunk exactly once, including
    // the chunk whose insertion crossed the configured gap limit.
    try std.testing.expectEqual(@as(usize, MAX_BUFFERED_GAPS + 1), st.pendingCount());
}

test "flow control violation detected" {
    const a = std.testing.allocator;
    var st = Stream.init(a, 0, true, true);
    defer st.deinit();
    st.recvMaxOffset = 10;
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
    try std.testing.expectEqual(@as(usize, 0), st.pendingCount());
    try std.testing.expectError(Error.StreamReset, st.receive(5, "x", false, &sink));
}

test "send allowance respects peer grants and connection budget" {
    const a = std.testing.allocator;
    var st = Stream.init(a, 0, true, true);
    defer st.deinit();
    st.sendMaxOffset = 100;
    st.recordSent(30, false);
    try std.testing.expectEqual(@as(u64, 70), st.sendAllowance(1000));
    try std.testing.expectEqual(@as(u64, 20), st.sendAllowance(20));
}

test "offsetless stream data starts at zero and duplicates are ignored" {
    const a = std.testing.allocator;
    var st = Stream.init(a, 0, true, false);
    defer st.deinit();

    const Sink = struct {
        bytes: usize = 0,
        pub fn call(sinkSelf: *@This(), data: []const u8) !void {
            sinkSelf.bytes += data.len;
        }
    };
    var sink = Sink{};

    // First chunk at offset 0.
    _ = try st.receive(0, "abc", false, &sink);
    try std.testing.expectEqual(@as(u64, 3), st.recvOffset);

    // A frame without OFF starts at zero, so this repeated prefix is ignored.
    _ = try st.receive(0, "abc", false, &sink);
    try std.testing.expectEqual(@as(u64, 3), st.recvOffset);
    try std.testing.expectEqual(@as(usize, 3), sink.bytes);
}

test "a late duplicate without an offset remains at offset zero" {
    const a = std.testing.allocator;
    var st = Stream.init(a, 0, true, false);
    defer st.deinit();

    const Sink = struct {
        bytes: usize = 0,
        pub fn call(sinkSelf: *@This(), data: []const u8) !void {
            sinkSelf.bytes += data.len;
        }
    };
    var sink = Sink{};

    _ = try st.receive(0, "0123456789", true, &sink);
    try std.testing.expectEqual(@as(u64, 10), st.recvOffset);
    try std.testing.expectEqual(@as(usize, 10), sink.bytes);

    // An absent OFF field always means offset zero, so the retransmitted
    // prefix is recognized as already delivered and does not advance the
    // stream or violate its final size.
    const delivered = try st.receive(0, "0123456789", true, &sink);
    try std.testing.expectEqual(@as(usize, 0), delivered);
    try std.testing.expectEqual(@as(usize, 10), sink.bytes);
}
