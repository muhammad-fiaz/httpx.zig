//! Loss detection and RTT estimation per RFC 9002.
//!
//! Constants follow ngtcp2/rcvry.h: kPacketThreshold=3, kTimeThreshold
//! =9/8, kGranularity=1ms, PTO backoff 2^ptoCount, persistent-congestion
//! duration = (srtt + max(4*rttvar, granularity) + max_ack_delay) * 3.

const std = @import("std");

pub const GranularityMs: u64 = 1;
pub const PacketThreshold: u64 = 3;
/// Time threshold numerator/denominator: 9/8 of smoothed RTT.
const TT_NUM: u64 = 9;
const TT_DEN: u64 = 8;

pub const RttStats = struct {
    minRttMs: u64 = std.math.maxInt(u64),
    latestRttMs: u64 = 0,
    smoothedRttMs: u64 = 0,
    rttvarMs: u64 = 0,
    /// First RTT sample timestamp; ack-delay correction is skipped for it.
    firstSampleTsMs: ?u64 = null,

    initialRttMs: u64 = 333,

    pub fn onAckReceived(
        self: *RttStats,
        sendTsMs: u64,
        ackTsMs: u64,
        peerMaxAckDelayMs: u64,
    ) void {
        const raw = ackTsMs -| sendTsMs;
        self.latestRttMs = raw;

        if (self.firstSampleTsMs == null) {
            self.firstSampleTsMs = ackTsMs;
            self.minRttMs = raw;
            self.smoothedRttMs = raw;
            self.rttvarMs = raw / 2;
            return;
        }

        // min_rtt from the uncorrected sample.
        self.minRttMs = @min(self.minRttMs, raw);

        // Ack-delay correction only when sample >= min_rtt + delay budget.
        var sample = raw;
        const budget = @min(peerMaxAckDelayMs, raw -| self.minRttMs);
        if (raw > self.minRttMs) sample = raw - budget;

        const diff = if (self.smoothedRttMs > sample)
            self.smoothedRttMs - sample
        else
            sample - self.smoothedRttMs;

        self.rttvarMs = (3 *| self.rttvarMs +| diff) / 4;
        self.smoothedRttMs = (7 *| self.smoothedRttMs +| sample) / 8;
    }

    /// PTO base without exponential backoff (ms).
    pub fn ptoBase(self: *const RttStats, includeMaxAckDelay: bool, maxAckDelayMs: u64) u64 {
        if (self.firstSampleTsMs == null) {
            return self.initialRttMs +| @max(self.initialRttMs / 2, GranularityMs);
        }
        var pto = self.smoothedRttMs +| @max(4 *| self.rttvarMs, GranularityMs);
        if (includeMaxAckDelay) pto +|= maxAckDelayMs;
        return pto;
    }
};

/// One tracked sent packet relevant to loss recovery.
pub const SentPacket = struct {
    pn: u64,
    tsMs: u64,
    inFlightBytes: usize,
    ackEliciting: bool,
};

pub const RecoveryConfig = struct {
    maxAckDelayMs: u64 = 25,
    includeAckDelayInPto: bool = true,
};

pub const Recovery = struct {
    rtt: RttStats = .{},
    cfg: RecoveryConfig = .{},

    largestAckedPn: ?u64 = null,
    /// Earliest time a time-threshold loss check must run (null = none).
    lossTimeMs: ?u64 = null,
    ptoCount: u32 = 0,

    // Persistent congestion tracking (application data space only).
    pcStartTsMs: ?u64 = null,
    pcLatestTsMs: ?u64 = null,

    pub fn init(cfg: RecoveryConfig) Recovery {
        return .{ .cfg = cfg };
    }

    /// Processes one ACK; returns newly-lost packet numbers via callback
    /// semantics: caller inspects `lost` slice filled here.
    pub fn detectLost(
        self: *Recovery,
        packets: []const SentPacket,
        nowMs: u64,
        lostOut: *std.ArrayList(SentPacket),
        gpa: std.mem.Allocator,
    ) !void {
        lostOut.clearRetainingCapacity();
        self.lossTimeMs = null;

        const largest = self.largestAckedPn orelse return;
        const srtt: u64 = if (self.rtt.firstSampleTsMs == null) self.rtt.initialRttMs else self.rtt.smoothedRttMs;
        const loss_delay = @max(srtt * TT_NUM / TT_DEN, GranularityMs);

        for (packets) |p| {
            if (p.pn >= largest) continue; // not yet beyond threshold

            // Packet threshold: lost when largest_newly_acked >= pn + K.
            const thresh_lost = largest - p.pn >= PacketThreshold;

            // Time threshold: lost when now >= ts + loss_delay.
            const expiry = p.tsMs +| loss_delay;
            const time_lost = nowMs >= expiry;

            if (thresh_lost or time_lost) {
                try lostOut.append(gpa, p);
                // Persistent-congestion window bookkeeping.
                self.noteLostForPc(p.tsMs);
            } else {
                const t = expiry;
                if (self.lossTimeMs == null or t < self.lossTimeMs.?) {
                    self.lossTimeMs = t;
                }
            }
        }
    }

    fn noteLostForPc(self: *Recovery, tsMs: u64) void {
        if (self.pcStartTsMs == null) {
            self.pcStartTsMs = tsMs;
            self.pcLatestTsMs = tsMs;
        } else {
            self.pcLatestTsMs = tsMs;
        }
    }

    /// Declares persistent congestion when the contiguous lost span covers
    /// the full RFC 9002 duration.
    pub fn persistentCongestion(self: *const Recovery) bool {
        const start = self.pcStartTsMs orelse return false;
        const latest = self.pcLatestTsMs.?; // set together
        const duration = (self.rtt.smoothedRttMs +|
            @max(4 * self.rtt.rttvarMs, GranularityMs) +|
            self.cfg.maxAckDelayMs) *| 3;
        return (latest - start) >= duration;
    }

    pub fn clearPcWindow(self: *Recovery) void {
        self.pcStartTsMs = null;
        self.pcLatestTsMs = null;
    }

    /// Current PTO duration including backoff (ms).
    pub fn ptoDuration(self: *const Recovery, appSpace: bool) u64 {
        const base = self.rtt.ptoBase(appSpace and self.cfg.includeAckDelayInPto, self.cfg.maxAckDelayMs);
        const backoff_shift: u5 = @intCast(@min(self.ptoCount, 30));
        return base <<| backoff_shift;
    }

    pub fn onPtoExpired(self: *Recovery) void {
        self.ptoCount += 1;
    }

    pub fn onAckOfInFlight(self: *Recovery) void {
        self.ptoCount = 0;
    }

    pub fn resetPcAndLossTimerOnNewData(self: *Recovery) void {
        self.clearPcWindow();
    }
};

// Tests

test "first rtt sample initializes stats without correction" {
    var r = RttStats{};
    r.onAckReceived(100, 150, 25); // raw 50
    try std.testing.expectEqual(@as(u64, 50), r.minRttMs);
    try std.testing.expectEqual(@as(u64, 50), r.smoothedRttMs);
    try std.testing.expectEqual(@as(u64, 25), r.rttvarMs);
}

test "ewma smoothing follows RFC 9002 factors" {
    var r = RttStats{};
    r.onAckReceived(0, 100, 0); // first: srtt=100 var=50
    // Second sample 60: diff=40 -> var=(3*50+40)/4=47 -> srtt=(7*100+60)/8=95
    r.onAckReceived(0, 60, 0);
    try std.testing.expectEqual(@as(u64, 60), r.latestRttMs);
    try std.testing.expectEqual(@as(u64, 95), r.smoothedRttMs);
    try std.testing.expectEqual(@as(u64, 47), r.rttvarMs);
}

test "ack delay correction bounded by min_rtt gap" {
    var r = RttStats{};
    r.onAckReceived(0, 100, 0); // min=100 srtt=100
    // Sample 200 with ack delay 150: correction capped at raw-min=100.
    r.onAckReceived(0, 200, 150);
    // budget=min(150, 200-100)=100 -> sample=100
    try std.testing.expectEqual(@as(u64, 100), r.smoothedRttMs);
}

test "packet threshold triggers before time threshold" {
    var rec = Recovery.init(.{});
    rec.largestAckedPn = 10;

    var lost = std.ArrayList(SentPacket).empty;
    defer lost.deinit(std.testing.allocator);

    const pkts = [_]SentPacket{
        .{ .pn = 2, .tsMs = 1000, .inFlightBytes = 1200, .ackEliciting = true },
        .{ .pn = 8, .tsMs = 1990, .inFlightBytes = 1200, .ackEliciting = true }, // within 3? 10>=11 no
        .{ .pn = 7, .tsMs = 1995, .inFlightBytes = 1200, .ackEliciting = true }, // 10 >= 7+3 -> lost
    };
    try rec.detectLost(pkts[0..], 2000, &lost, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), lost.items.len);
    try std.testing.expectEqual(@as(u64, 2), lost.items[0].pn);
    try std.testing.expectEqual(@as(u64, 7), lost.items[1].pn);
}

test "time threshold fires at 9/8 srtt" {
    var rec = Recovery.init(.{});
    rec.rtt.onAckReceived(0, 800, 0); // srtt=800
    // largest=7 keeps pn=5 outside the PACKET threshold (5+3=8 > 7),
    // isolating the TIME threshold behavior.
    rec.largestAckedPn = 7;

    var lost = std.ArrayList(SentPacket).empty;
    defer lost.deinit(std.testing.allocator);

    // loss_delay = 900; packet sent at t=100 expires at 1000.
    const pkts = [_]SentPacket{
        .{ .pn = 5, .tsMs = 100, .inFlightBytes = 1200, .ackEliciting = true },
    };
    try rec.detectLost(pkts[0..], 999, &lost, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), lost.items.len);
    try std.testing.expectEqual(@as(u64, 1000), rec.lossTimeMs.?);

    try rec.detectLost(pkts[0..], 1000, &lost, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), lost.items.len);
}

test "pto doubles with count" {
    var rec = Recovery.init(.{});
    const d0 = rec.ptoDuration(false);
    rec.onPtoExpired();
    const d1 = rec.ptoDuration(false);
    try std.testing.expectEqual(d0 * 2, d1);
    rec.onAckOfInFlight();
    try std.testing.expectEqual(rec.rtt.ptoBase(false, 25), rec.ptoDuration(false));
}
