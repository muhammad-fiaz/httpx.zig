//! Connection ID registry for the local-endpoint view (RFC 9000 section
//! 5.1): tracks CIDs advertised by the PEER via NEW_CONNECTION_ID,
//! enforces uniqueness and retire_prior_to semantics, rotates the active
//! destination CID, and emits RETIRE_CONNECTION_ID exactly once per
//! retired sequence.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    ProtocolViolation,
    CidLimitExceeded,
    OutOfMemory,
    NotFound,
};

pub const MAX_CID_LEN = 20;

pub const Entry = struct {
    sequence: u64,
    cid: [MAX_CID_LEN]u8,
    cid_len: u8,
    stateless_reset_token: [16]u8,
    retired: bool = false,
    /// RETIRE_CONNECTION_ID already queued for this sequence.
    retire_sent: bool = false,

    pub fn cidSlice(self: *const Entry) []const u8 {
        return self.cid[0..self.cid_len];
    }
};

/// Outcome of processing one NEW_CONNECTION_ID frame.
pub const NewCidResult = struct {
    /// Sequence numbers needing RETIRE_CONNECTION_ID frames.
    newly_retired_buf: [8]u64 = undefined,
    newly_retired_len: usize = 0,
    /// True when the ACTIVE destination CID was rotated.
    rotated: bool = false,

    pub fn newlyRetired(self: *const NewCidResult) []const u64 {
        return self.newly_retired_buf[0..self.newly_retired_len];
    }
};

pub const Registry = struct {
    allocator: Allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// Sequence of our currently preferred destination CID.
    active_seq: u64 = 0,
    have_active: bool = false,
    /// Peer's advertised limit (active_connection_id_limit).
    peer_cid_limit: u64 = 2,

    pub fn init(allocator: Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.entries.deinit(self.allocator);
    }

    fn findBySeq(self: *Registry, seq: u64) ?*Entry {
        for (self.entries.items) |*e| {
            if (e.sequence == seq) return e;
        }
        return null;
    }

    /// Handles a NEW_CONNECTION_ID frame. Returns retirement actions.
    pub fn onNewConnectionId(
        self: *Registry,
        sequence: u64,
        retire_prior_to: u64,
        cid: []const u8,
        token: *const [16]u8,
    ) Error!NewCidResult {
        var res: NewCidResult = .{};

        // RFC 9000 19.15: retire_prior_to must not exceed sequence.
        if (retire_prior_to > sequence) return Error.ProtocolViolation;
        if (cid.len == 0 or cid.len > MAX_CID_LEN) return Error.ProtocolViolation;

        if (self.findBySeq(sequence)) |existing| {
            // Re-transmission: MUST match exactly.
            if (!std.mem.eql(u8, existing.cidSlice(), cid) or
                !std.mem.eql(u8, existing.stateless_reset_token[0..], token))
            {
                return Error.ProtocolViolation;
            }
            existing.retired = false;
        } else {
            // Distinct sequences must carry distinct CIDs.
            for (self.entries.items) |*e| {
                if (std.mem.eql(u8, e.cidSlice(), cid)) return Error.ProtocolViolation;
            }

            // Bound outstanding un-retired CIDs by the peer's limit + slack.
            var live: u64 = 0;
            for (self.entries.items) |*e| {
                if (!e.retired) live += 1;
            }
            if (live >= @max(self.peer_cid_limit, 2)) {
                // Retire the oldest non-active entry to make room.
                var oldest_idx: ?usize = null;
                for (self.entries.items, 0..) |*e, i| {
                    if (!e.retired and e.sequence != self.active_seq) {
                        if (oldest_idx == null or e.sequence < self.entries.items[oldest_idx.?].sequence) {
                            oldest_idx = i;
                        }
                    }
                }
                if (oldest_idx) |oi| {
                    self.entries.items[oi].retired = true;
                } else {
                    return Error.CidLimitExceeded;
                }
            }

            try self.entries.append(self.allocator, .{
                .sequence = sequence,
                .cid = blk: {
                    var c: [MAX_CID_LEN]u8 = undefined;
                    @memcpy(c[0..cid.len], cid);
                    break :blk c;
                },
                .cid_len = @intCast(cid.len),
                .stateless_reset_token = token.*,
            });
        }

        // Process retire_prior_to: mark all lower sequences retired and
        // queue RETIRE frames for them (once).
        for (self.entries.items) |*e| {
            if (e.sequence < retire_prior_to and !e.retire_sent) {
                e.retired = true;
                e.retire_sent = true;
                if (res.newly_retired_len < res.newly_retired_buf.len) {
                    res.newly_retired_buf[res.newly_retired_len] = e.sequence;
                    res.newly_retired_len += 1;
                }
            } else if (e.sequence >= retire_prior_to) {
                e.retired = false;
            }
        }

        // Rotate away from an actively-retired CID.
        if (self.have_active and self.active_seq < retire_prior_to) {
            if (self.pickReplacement(retire_prior_to)) |new_seq| {
                self.active_seq = new_seq;
                res.rotated = true;
            } else {
                return Error.CidLimitExceeded;
            }
        } else if (!self.have_active and sequence >= retire_prior_to) {
            self.active_seq = sequence;
            self.have_active = true;
        }

        return res;
    }

    fn pickReplacement(self: *Registry, above: u64) ?u64 {
        var best: ?u64 = null;
        for (self.entries.items) |*e| {
            if (!e.retired and e.sequence >= above) {
                if (best == null or e.sequence < best.?) best = e.sequence;
            }
        }
        return best;
    }

    pub fn activeCid(self: *const Registry) ?[]const u8 {
        if (!self.have_active) return null;
        const e = self.findBySeqConst(self.active_seq) orelse return null;
        if (e.retired) return null;
        return e.cidSlice();
    }

    pub fn activeToken(self: *const Registry) ?[16]u8 {
        if (!self.have_active) return null;
        const e = self.findBySeqConst(self.active_seq) orelse return null;
        return e.stateless_reset_token;
    }

    fn findBySeqConst(self: *const Registry, seq: u64) ?*const Entry {
        for (self.entries.items) |*e| {
            if (e.sequence == seq) return e;
        }
        return null;
    }
};

// Tests

test "initial NEW_CONNECTION_ID becomes active" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    var tok: [16]u8 = .{0xAA} ** 16;

    const res = try r.onNewConnectionId(0, 0, &.{ 1, 2, 3, 4 }, &tok);
    try std.testing.expectEqual(@as(usize, 0), res.newlyRetired().len);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, r.activeCid().?);
}

test "retransmission must match exactly" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    var tok: [16]u8 = .{0} ** 16;
    _ = try r.onNewConnectionId(1, 0, &.{ 9, 9 }, &tok);

    // Same seq + same cid: OK.
    _ = try r.onNewConnectionId(1, 0, &.{ 9, 9 }, &tok);
    // Same seq + different cid: violation.
    try std.testing.expectError(Error.ProtocolViolation, r.onNewConnectionId(1, 0, &.{ 8, 8 }, &tok));
}

test "distinct sequences cannot share a CID" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    var tok: [16]u8 = .{7} ** 16;
    _ = try r.onNewConnectionId(1, 0, &.{ 5, 5 }, &tok);
    try std.testing.expectError(Error.ProtocolViolation, r.onNewConnectionId(2, 0, &.{ 5, 5 }, &tok));
}

test "retire_prior_to rotates active and queues retirements" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    var tok: [16]u8 = .{1} ** 16;

    _ = try r.onNewConnectionId(0, 0, &.{ 0xA0, 0xA0 }, &tok); // active
    _ = try r.onNewConnectionId(1, 0, &.{ 0xA1, 0xA1 }, &tok);
    _ = try r.onNewConnectionId(2, 0, &.{ 0xA2, 0xA2 }, &tok);

    // Peer demands retiring everything below seq 2 -> active (0) must move.
    const res = try r.onNewConnectionId(3, 2, &.{ 0xA3, 0xA3 }, &tok);
    try std.testing.expect(res.rotated);
    try std.testing.expectEqual(@as(u64, 2), r.active_seq);
    try std.testing.expectEqualSlices(u8, &.{ 0xA2, 0xA2 }, r.activeCid().?);

    // Sequences 0 and 1 queued for RETIRE_CONNECTION_ID exactly once each.
    const retired = res.newlyRetired();
    try std.testing.expectEqual(@as(usize, 2), retired.len);

    // A repeat of the same frame must NOT re-queue retirements.
    const res2 = try r.onNewConnectionId(3, 2, &.{ 0xA3, 0xA3 }, &tok);
    try std.testing.expectEqual(@as(usize, 0), res2.newlyRetired().len);
}

test "invalid retire_prior_to rejected" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    var tok: [16]u8 = .{0} ** 16;
    try std.testing.expectError(
        Error.ProtocolViolation,
        r.onNewConnectionId(1, 5, &.{ 1, 1 }, &tok), // rpt > sequence
    );
    try std.testing.expectError(
        Error.ProtocolViolation,
        r.onNewConnectionId(1, 0, &.{}, &tok), // zero-length CID
    );
}
