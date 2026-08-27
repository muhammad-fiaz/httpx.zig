//! NewReno congestion control (RFC 9002 section 7) with constants from
//! ngtcp2_cc: initial window = min(10*MSS, max(2*MSS, 14720)), minimum
//! window = 2*MSS, halving on congestion event, additive growth per RTT
//! in congestion avoidance.

const std = @import("std");

pub const NewReno = struct {
    mss: usize,
    cwnd: usize,
    ssthresh: usize = std.math.maxInt(usize),
    /// Start of the most recent congestion recovery epoch.
    recovery_start_ts_ms: ?u64 = null,
    /// Congestion-avoidance fractional credit (bytes toward one MSS).
    ca_pending: usize = 0,

    const max_cwnd_cap: usize = 1 << 30;

    pub fn init(mss: usize) NewReno {
        return .{
            .mss = mss,
            .cwnd = @min(10 * mss, @max(2 * mss, 14720)),
        };
    }

    pub fn bytesInFlightLimit(self: *const NewReno) usize {
        return self.cwnd;
    }

    pub fn inRecovery(self: *const NewReno, sent_ts_ms: u64) bool {
        const start = self.recovery_start_ts_ms orelse return false;
        return sent_ts_ms <= start;
    }

    /// Slow start grows +MSS per ACKed MSS; congestion avoidance adds
    /// roughly one MSS per round trip using fractional credit.
    pub fn onPacketAcked(self: *NewReno, acked_bytes: usize, sent_ts_ms: u64) void {
        if (self.inRecovery(sent_ts_ms)) return;

        if (self.cwnd < self.ssthresh) {
            const grow = @min(acked_bytes, self.mss);
            self.cwnd += grow;
        } else if (acked_bytes > 0) {
            self.ca_pending += acked_bytes;
            if (self.ca_pending >= self.cwnd) {
                self.ca_pending -= self.cwnd;
                self.cwnd += self.mss;
            }
        }
        self.cwnd = @min(self.cwnd, max_cwnd_cap);
    }

    /// Congestion event (new loss or ECN-CE): halve, enter recovery.
    pub fn onCongestionEvent(self: *NewReno, now_ms: u64) void {
        self.recovery_start_ts_ms = now_ms;
        self.ssthresh = @max(self.cwnd / 2, 2 * self.mss);
        self.cwnd = @max(self.cwnd / 2, 2 * self.mss);
        self.ca_pending = 0;
    }

    /// Persistent congestion: collapse to minimum window.
    pub fn onPersistentCongestion(self: *NewReno) void {
        self.ssthresh = @max(self.cwnd / 2, 2 * self.mss);
        self.cwnd = 2 * self.mss;
        self.recovery_start_ts_ms = null;
        self.ca_pending = 0;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "initial window formula" {
    // min(10*MSS, max(2*MSS, 14720))
    const cc = NewReno.init(1200);
    try std.testing.expectEqual(@as(usize, 12000), cc.cwnd); // 10*1200 < 14720
    const big = NewReno.init(1500);
    try std.testing.expectEqual(@as(usize, 14720), big.cwnd); // capped by constant
}

test "slow start grows per ack until ssthresh" {
    var cc = NewReno.init(1000);
    cc.ssthresh = 50_000; // above initial window -> slow start active
    const before = cc.cwnd;
    cc.onPacketAcked(1000, 10);
    try std.testing.expectEqual(before + 1000, cc.cwnd);
}

test "congestion event halves cwnd and blocks same-epoch growth" {
    var cc = NewReno.init(1000);
    cc.cwnd = 20000;
    cc.onCongestionEvent(100);
    try std.testing.expectEqual(@as(usize, 10000), cc.cwnd);
    try std.testing.expectEqual(cc.cwnd, cc.ssthresh);

    // ACK of a packet sent DURING the recovery epoch must not grow cwnd.
    const pre = cc.cwnd;
    cc.onPacketAcked(1000, 100);
    try std.testing.expectEqual(pre, cc.cwnd);

    // ACK of a later packet in CA accumulates credit without immediate growth.
    cc.onPacketAcked(1000, 200);
    try std.testing.expect(cc.ca_pending > 0 or cc.cwnd > pre);
}

test "persistent congestion collapses to minimum window" {
    var cc = NewReno.init(1000);
    cc.cwnd = 60000;
    cc.onPersistentCongestion();
    try std.testing.expectEqual(@as(usize, 2000), cc.cwnd);
}
