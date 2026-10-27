//! NewReno congestion control (RFC 9002 section 7): initial window =
//! min(10*MSS, max(2*MSS, 14720)), minimum window = 2*MSS, halving on a
//! congestion event, and additive growth per RTT in congestion avoidance.

const std = @import("std");

pub const NewReno = struct {
    mss: usize,
    cwnd: usize,
    ssthresh: usize = std.math.maxInt(usize),
    /// Start of the most recent congestion recovery epoch.
    recoveryStartTsMs: ?u64 = null,
    /// Congestion-avoidance fractional credit (bytes toward one MSS).
    caPending: usize = 0,

    const maxCwndCap: usize = 1 << 30;

    pub fn init(mss: usize) NewReno {
        return .{
            .mss = mss,
            .cwnd = @min(10 * mss, @max(2 * mss, 14720)),
        };
    }

    pub fn bytesInFlightLimit(self: *const NewReno) usize {
        return self.cwnd;
    }

    pub fn inRecovery(self: *const NewReno, sentTsMs: u64) bool {
        const start = self.recoveryStartTsMs orelse return false;
        return sentTsMs <= start;
    }

    /// Slow start grows +MSS per ACKed MSS; congestion avoidance adds
    /// roughly one MSS per round trip using fractional credit.
    pub fn onPacketAcked(self: *NewReno, ackedBytes: usize, sentTsMs: u64) void {
        if (self.inRecovery(sentTsMs)) return;

        if (self.cwnd < self.ssthresh) {
            const grow = @min(ackedBytes, self.mss);
            self.cwnd += grow;
        } else if (ackedBytes > 0) {
            self.caPending += ackedBytes;
            if (self.caPending >= self.cwnd) {
                self.caPending -= self.cwnd;
                self.cwnd += self.mss;
            }
        }
        self.cwnd = @min(self.cwnd, maxCwndCap);
    }

    /// Congestion event (new loss or ECN-CE): halve, enter recovery.
    pub fn onCongestionEvent(self: *NewReno, nowMs: u64) void {
        self.recoveryStartTsMs = nowMs;
        self.ssthresh = @max(self.cwnd / 2, 2 * self.mss);
        self.cwnd = @max(self.cwnd / 2, 2 * self.mss);
        self.caPending = 0;
    }

    /// Persistent congestion: collapse to minimum window.
    pub fn onPersistentCongestion(self: *NewReno) void {
        self.ssthresh = @max(self.cwnd / 2, 2 * self.mss);
        self.cwnd = 2 * self.mss;
        self.recoveryStartTsMs = null;
        self.caPending = 0;
    }
};

/// RFC 8312: CUBIC Congestion Control for Fast Long-Distance Networks.
pub const Cubic = struct {
    mss: usize,
    cwnd: usize,
    ssthresh: usize = std.math.maxInt(usize),
    wMax: usize = 0,
    kSec: f64 = 0.0,
    epochStartTsMs: u64 = 0,
    recoveryStartTsMs: ?u64 = null,
    caPending: usize = 0,

    const maxCwndCap: usize = 1 << 30;
    const beta: f64 = 0.7; // RFC 8312 Section 4.5
    const c: f64 = 0.4; // RFC 8312 Section 4.1

    pub fn init(mss: usize) Cubic {
        return .{
            .mss = mss,
            .cwnd = @min(10 * mss, @max(2 * mss, 14720)),
        };
    }

    pub fn bytesInFlightLimit(self: *const Cubic) usize {
        return self.cwnd;
    }

    pub fn inRecovery(self: *const Cubic, sentTsMs: u64) bool {
        const start = self.recoveryStartTsMs orelse return false;
        return sentTsMs <= start;
    }

    pub fn onPacketAcked(self: *Cubic, ackedBytes: usize, sentTsMs: u64, nowMs: u64, rttMs: u64) void {
        if (self.inRecovery(sentTsMs)) return;

        if (self.cwnd < self.ssthresh) {
            // Slow start
            const grow = @min(ackedBytes, self.mss);
            self.cwnd += grow;
        } else if (ackedBytes > 0) {
            // Congestion avoidance using CUBIC growth function (RFC 8312)
            const tSec = if (nowMs >= self.epochStartTsMs)
                @as(f64, @floatFromInt(nowMs - self.epochStartTsMs)) / 1000.0
            else
                0.0;
            const delta = tSec - self.kSec;
            const wMaxPkt = @as(f64, @floatFromInt(self.wMax)) / @as(f64, @floatFromInt(self.mss));
            const wCubicPkt = c * delta * delta * delta + wMaxPkt;
            const wCubic = @max(@as(usize, @intFromFloat(@max(0.0, wCubicPkt) * @as(f64, @floatFromInt(self.mss)))), 2 * self.mss);

            // TCP-friendly region
            const rttSec = @max(0.001, @as(f64, @floatFromInt(rttMs)) / 1000.0);
            const wTcpPkt = wMaxPkt * beta + ((3.0 * (1.0 - beta)) / (1.0 + beta)) * (tSec / rttSec);
            const wTcp = @max(@as(usize, @intFromFloat(@max(0.0, wTcpPkt) * @as(f64, @floatFromInt(self.mss)))), 2 * self.mss);

            const targetCwnd = @max(wCubic, wTcp);

            if (targetCwnd > self.cwnd) {
                self.caPending += ackedBytes;
                if (self.caPending >= self.cwnd) {
                    self.caPending -= self.cwnd;
                    self.cwnd += self.mss;
                }
            }
        }
        self.cwnd = @min(self.cwnd, maxCwndCap);
    }

    pub fn onCongestionEvent(self: *Cubic, nowMs: u64) void {
        self.recoveryStartTsMs = nowMs;
        self.epochStartTsMs = nowMs;
        self.wMax = self.cwnd;
        self.ssthresh = @max(@as(usize, @intFromFloat(@as(f64, @floatFromInt(self.cwnd)) * beta)), 2 * self.mss);
        self.cwnd = self.ssthresh;
        self.caPending = 0;

        const wMaxPkt = @as(f64, @floatFromInt(self.wMax)) / @as(f64, @floatFromInt(self.mss));
        self.kSec = std.math.cbrt((wMaxPkt * (1.0 - beta)) / c);
    }

    pub fn onPersistentCongestion(self: *Cubic) void {
        self.ssthresh = @max(self.cwnd / 2, 2 * self.mss);
        self.cwnd = 2 * self.mss;
        self.recoveryStartTsMs = null;
        self.epochStartTsMs = 0;
        self.kSec = 0.0;
        self.wMax = self.cwnd;
        self.caPending = 0;
    }
};

pub const Algorithm = enum {
    newReno,
    cubic,
};

pub const CongestionController = union(Algorithm) {
    newReno: NewReno,
    cubic: Cubic,

    pub fn init(algo: Algorithm, mss: usize) CongestionController {
        return switch (algo) {
            .newReno => .{ .newReno = NewReno.init(mss) },
            .cubic => .{ .cubic = Cubic.init(mss) },
        };
    }

    pub fn bytesInFlightLimit(self: *const CongestionController) usize {
        return switch (self.*) {
            .newReno => |*c_inst| c_inst.bytesInFlightLimit(),
            .cubic => |*c_inst| c_inst.bytesInFlightLimit(),
        };
    }

    pub fn onPacketAcked(self: *CongestionController, ackedBytes: usize, sentTsMs: u64, nowMs: u64, rttMs: u64) void {
        switch (self.*) {
            .newReno => |*c_inst| c_inst.onPacketAcked(ackedBytes, sentTsMs),
            .cubic => |*c_inst| c_inst.onPacketAcked(ackedBytes, sentTsMs, nowMs, rttMs),
        }
    }

    pub fn onCongestionEvent(self: *CongestionController, nowMs: u64) void {
        switch (self.*) {
            .newReno => |*c_inst| c_inst.onCongestionEvent(nowMs),
            .cubic => |*c_inst| c_inst.onCongestionEvent(nowMs),
        }
    }

    pub fn onPersistentCongestion(self: *CongestionController) void {
        switch (self.*) {
            .newReno => |*c_inst| c_inst.onPersistentCongestion(),
            .cubic => |*c_inst| c_inst.onPersistentCongestion(),
        }
    }
};

// Tests

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
    try std.testing.expect(cc.caPending > 0 or cc.cwnd > pre);
}

test "persistent congestion collapses to minimum window" {
    var cc = NewReno.init(1000);
    cc.cwnd = 60000;
    cc.onPersistentCongestion();
    try std.testing.expectEqual(@as(usize, 2000), cc.cwnd);
}

test "cubic initial window, multiplicative decrease and recovery" {
    var cc = Cubic.init(1200);
    try std.testing.expectEqual(@as(usize, 12000), cc.cwnd);

    // Enter congestion event at cwnd = 20000
    cc.cwnd = 20000;
    cc.onCongestionEvent(1000);

    // RFC 8312: beta = 0.7, so cwnd = 14000
    try std.testing.expectEqual(@as(usize, 14000), cc.cwnd);
    try std.testing.expectEqual(@as(usize, 20000), cc.wMax);
    try std.testing.expect(cc.kSec > 0.0);

    // ACK sent during recovery should not grow window
    cc.onPacketAcked(1200, 1000, 1050, 50);
    try std.testing.expectEqual(@as(usize, 14000), cc.cwnd);

    // ACK sent after recovery in CA
    cc.onPacketAcked(1200, 1050, 2000, 50);
    try std.testing.expect(cc.cwnd >= 14000);

    // Persistent congestion drops to 2*MSS
    cc.onPersistentCongestion();
    try std.testing.expectEqual(@as(usize, 2400), cc.cwnd);
}

test "congestion controller polymorphism" {
    var cc = CongestionController.init(.cubic, 1000);
    try std.testing.expectEqual(@as(usize, 10000), cc.bytesInFlightLimit());
    cc.onCongestionEvent(500);
    try std.testing.expectEqual(@as(usize, 7000), cc.bytesInFlightLimit());
}
