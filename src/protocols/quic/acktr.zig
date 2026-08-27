//! ACK range tracking and ACK frame generation (RFC 9000 section 19.3,
//! structure modeled on ngtcp2_acktr: descending contiguous ranges).
//!
//! add(pn) merges adjacent/overlapping blocks; generation walks blocks
//! producing Largest Acknowledged / First Range / Gap+Range pairs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const frames = @import("frames.zig");

pub const Error = error{
    DuplicatePacket,
    OutOfMemory,
};

/// Maximum retained ranges beyond the top block (ngtcp2 uses 32+1).
pub const MAX_RANGES = 33;

pub const Block = frames.AckBlock;

pub const AckTracker = struct {
    allocator: Allocator,
    /// Sorted strictly descending by highest; non-overlapping.
    blocks: std.ArrayList(Block) = .empty,
    largest_seen: ?u64 = null,

    pub fn init(allocator: Allocator) AckTracker {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AckTracker) void {
        self.blocks.deinit(self.allocator);
    }

    pub fn contains(self: *const AckTracker, pn: u64) bool {
        for (self.blocks.items) |b| {
            if (pn <= b.highest and pn >= b.highest - b.len + 1) return true;
            if (b.highest < pn) break;
        }
        return false;
    }

    /// Records receipt of one packet number. Returns error.DuplicatePacket
    /// if already tracked.
    pub fn add(self: *AckTracker, pn: u64) Error!void {
        if (self.contains(pn)) return Error.DuplicatePacket;

        // Insertion index: first block whose highest <= pn (descending list).
        var idx: usize = 0;
        while (idx < self.blocks.items.len and self.blocks.items[idx].highest > pn) idx += 1;
        try self.insertAndCoalesce(.{ .highest = pn, .len = 1 }, idx);
        self.largest_seen = @max(self.largest_seen orelse 0, pn);
    }

    fn insertAndCoalesce(self: *AckTracker, block_in: Block, at: usize) Error!void {
        var block = block_in;
        try self.blocks.insert(self.allocator, at, block);

        // Coalesce with the immediately-lower block(s).
        while (at + 1 < self.blocks.items.len) {
            const below = self.blocks.items[at + 1];
            if (below.highest + 1 >= (block.highest - block.len + 1)) {
                const lo = @min((block.highest - block.len + 1), (below.highest - below.len + 1));
                block = .{ .highest = @max(block.highest, below.highest), .len = 0 };
                block.len = block.highest - lo + 1;
                self.blocks.items[at] = block;
                _ = self.blocks.orderedRemove(at + 1);
            } else break;
        }
        self.blocks.items[at] = block;

        // Coalesce upward (earlier indices hold higher packets).
        var i = at;
        while (i > 0) {
            const above = self.blocks.items[i - 1];
            if (block.highest + 1 >= (above.highest - above.len + 1)) {
                const lo = @min((above.highest - above.len + 1), (block.highest - block.len + 1));
                const hi = @max(above.highest, block.highest);
                self.blocks.items[i - 1] = .{ .highest = hi, .len = hi - lo + 1 };
                _ = self.blocks.orderedRemove(i);
                i -= 1;
                block = self.blocks.items[i];
            } else break;
        }

        // Cap stored ranges: drop the smallest-PN block when overflowing.
        while (self.blocks.items.len > MAX_RANGES) {
            _ = self.blocks.pop();
        }
    }

    /// Produces ACK blocks ready for frames.encodeAckFromBlocks. The
    /// returned slice is owned by the caller's ArrayList.
    pub fn generateBlocks(
        self: *const AckTracker,
        out: *std.ArrayList(Block),
        gpa: Allocator,
        max_blocks: usize,
    ) !void {
        out.clearRetainingCapacity();
        const limit = @min(max_blocks, self.blocks.items.len);
        for (self.blocks.items[0..limit]) |b| {
            try out.append(gpa, b);
        }
    }
};

test "single packet add" {
    var t = AckTracker.init(std.testing.allocator);
    defer t.deinit();
    try t.add(5);
    try std.testing.expect(t.contains(5));
    try std.testing.expect(!t.contains(4));
    try std.testing.expectError(Error.DuplicatePacket, t.add(5));
}

test "in-order and out-of-order adds coalesce" {
    var t = AckTracker.init(std.testing.allocator);
    defer t.deinit();

    // Out-of-order arrival: 10, then 5-7 contiguous.
    try t.add(10);
    try t.add(7);
    try t.add(6); // merges with 7
    try t.add(5); // merges into [5..7]
    try std.testing.expectEqual(@as(usize, 2), t.blocks.items.len);

    // 8 extends the lower block but 9 is still missing: two ranges remain.
    try t.add(8);
    try std.testing.expectEqual(@as(usize, 2), t.blocks.items.len);
    try std.testing.expectEqual(@as(u64, 8), t.blocks.items[1].highest);
    try std.testing.expectEqual(@as(u64, 4), t.blocks.items[1].len);

    // 9 fills the final gap: everything merges into one range.
    try t.add(9);
    try std.testing.expectEqual(@as(usize, 1), t.blocks.items.len);
    try std.testing.expectEqual(@as(u64, 10), t.blocks.items[0].highest);
    try std.testing.expectEqual(@as(u64, 6), t.blocks.items[0].len);

    // 11 extends the top upward.
    try t.add(11);
    try std.testing.expectEqual(@as(u64, 11), t.blocks.items[0].highest);
    try std.testing.expectEqual(@as(u64, 7), t.blocks.items[0].len);
}

test "ack frame generation matches wire expectations" {
    var t = AckTracker.init(std.testing.allocator);
    defer t.deinit();
    try t.add(10);
    try t.add(7);
    try t.add(6);
    try t.add(5);

    var blocks = std.ArrayList(Block).empty;
    defer blocks.deinit(std.testing.allocator);
    try t.generateBlocks(&blocks, std.testing.allocator, 64);

    try std.testing.expectEqual(@as(usize, 2), blocks.items.len);
    try std.testing.expectEqual(@as(u64, 10), blocks.items[0].highest);
    try std.testing.expectEqual(@as(u64, 1), blocks.items[0].len);
    try std.testing.expectEqual(@as(u64, 7), blocks.items[1].highest);
    try std.testing.expectEqual(@as(u64, 3), blocks.items[1].len);

    // Encode through the frame layer and decode back.
    var wire = std.ArrayList(u8).empty;
    defer wire.deinit(std.testing.allocator);
    try frames.encodeAckFromBlocks(&wire, std.testing.allocator, 10, 50, blocks.items, null);

    var pos: usize = 0;
    const f = try frames.decode(wire.items, &pos);
    try std.testing.expectEqual(@as(u64, 10), f.ack.largest_acknowledged);
    try std.testing.expectEqual(@as(u64, 0), f.ack.first_range);
    try std.testing.expectEqual(@as(usize, 1), f.ack.ranges.len);
    try std.testing.expectEqual(@as(u64, 1), f.ack.ranges[0].gap); // 9,8 missing
    try std.testing.expectEqual(@as(u64, 2), f.ack.ranges[0].length); // covers len-1
}
