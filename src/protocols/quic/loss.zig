//! Loss detection and RTT estimation per RFC 9002.
//!
//! Constants follow ngtcp2/rcvry.h: kPacketThreshold=3, kTimeThreshold
//! =9/8, kGranularity=1ms, PTO backoff 2^pto_count, persistent-congestion
//! duration = (srtt + max(4*rttvar, granularity) + max_ack_delay) * 3.

const std = @import("std");

pub const GranularityMs: u64 = 1;
pub const PacketThreshold: u64 = 3;
/// Time threshold numerator/denominator: 9/8 of smoothed RTT.
const TT_NUM: u64 = 9;
const TT_DEN: u64 = 8;

pub const RttStats = struct {
    min_rtt_ms: u64 = std.math.maxInt(u64),
    latest_rtt_ms: u64 = 0,
    smoothed_rtt_ms: u64 = 0,
    rttvar_ms: u64 = 0,
    /// First RTT sample timestamp; ack-delay correction is skipped for it.
    first_sample_ts_ms: ?u64 = null,

    initial_rtt_ms: u64 = 333,

    pub fn onAckReceived(
        self: *RttStats,
        send_ts_ms: u64,
        ack_ts_ms: u64,
        peer_max_ack_delay_ms: u64,
    ) void {
        const raw = ack_ts_ms -| send_ts_ms;
        self.latest_rtt_ms = raw;

        if (self.first_sample_ts_ms == null) {
            self.first_sample_ts_ms = ack_ts_ms;
            self.min_rtt_ms = raw;
            self.smoothed_rtt_ms = raw;
            self.rttvar_ms = raw / 2;
            return;
        }

        // min_rtt from the uncorrected sample.
        self.min_rtt_ms = @min(self.min_rtt_ms, raw);

        // Ack-delay correction only when sample >= min_rtt + delay budget.
        var sample = raw;
        const budget = @min(peer_max_ack_delay_ms, raw -| self.min_rtt_ms);
        if (raw > self.min_rtt_ms) sample = raw - budget;

        const diff = if (self.smoothed_rtt_ms > sample)
            self.smoothed_rtt_ms - sample
        else
            sample - self.smoothed_rtt_ms;

        self.rttvar_ms = (3 * self.rttvar_ms + diff) / 4;
        self.smoothed_rtt_ms = (7 * self.smoothed_rtt_ms + sample) / 8;
    }

    /// PTO base without exponential backoff (ms).
    pub fn ptoBase(self: *const RttStats, include_max_ack_delay: bool, max_ack_delay_ms: u64) u64 {
        if (self.first_sample_ts_ms == null) {
            return self.initial_rtt_ms + @max(self.initial_rtt_ms / 2, GranularityMs);
        }
        var pto = self.smoothed_rtt_ms + @max(4 * self.rttvar_ms, GranularityMs);
        if (include_max_ack_delay) pto += max_ack_delay_ms;
        return pto;
    }
};

/// One tracked sent packet relevant to loss recovery.
pub const SentPacket = struct {
    pn: u64,
    ts_ms: u64,
    in_flight_bytes: usize,
    ack_eliciting: bool,
};

pub const RecoveryConfig = struct {
    max_ack_delay_ms: u64 = 25,
    include_ack_delay_in_pto: bool = true,
};

pub const Recovery = struct {
    rtt: RttStats = .{},
    cfg: RecoveryConfig = .{},

    largest_acked_pn: ?u64 = null,
    /// Earliest time a time-threshold loss check must run (null = none).
    loss_time_ms: ?u64 = null,
    pto_count: u32 = 0,

    // Persistent congestion tracking (application data space only).
    pc_start_ts_ms: ?u64 = null,
    pc_latest_ts_ms: ?u64 = null,

    pub fn init(cfg: RecoveryConfig) Recovery {
        return .{ .cfg = cfg };
    }

    /// Processes one ACK; returns newly-lost packet numbers via callback
    /// semantics: caller inspects `lost` slice filled here.
    pub fn detectLost(
        self: *Recovery,
        packets: []const SentPacket,
        now_ms: u64,
        lost_out: *std.ArrayList(SentPacket),
        gpa: std.mem.Allocator,
    ) !void {
        lost_out.clearRetainingCapacity();
        self.loss_time_ms = null;

        const largest = self.largest_acked_pn orelse return;
        const srtt: u64 = if (self.rtt.first_sample_ts_ms == null) self.rtt.initial_rtt_ms else self.rtt.smoothed_rtt_ms;
        const loss_delay = @max(srtt * TT_NUM / TT_DEN, GranularityMs);

        for (packets) |p| {
            if (p.pn >= largest) continue; // not yet beyond threshold

            // Packet threshold: lost when largest_newly_acked >= pn + K.
            const thresh_lost = largest >= p.pn + PacketThreshold;

            // Time threshold: lost when now >= ts + loss_delay.
            const expiry = p.ts_ms + loss_delay;
            const time_lost = now_ms >= expiry;

            if (thresh_lost or time_lost) {
                try lost_out.append(gpa, p);
                // Persistent-congestion window bookkeeping.
                self.noteLostForPc(p.ts_ms);
            } else {
                const t = expiry;
                if (self.loss_time_ms == null or t < self.loss_time_ms.?) {
                    self.loss_time_ms = t;
                }
            }
        }
    }

    fn noteLostForPc(self: *Recovery, ts_ms: u64) void {
        if (self.pc_start_ts_ms == null) {
            self.pc_start_ts_ms = ts_ms;
            self.pc_latest_ts_ms = ts_ms;
        } else {
            self.pc_latest_ts_ms = ts_ms;
        }
    }

    /// Declares persistent congestion when the contiguous lost span covers
    /// the full RFC 9002 duration.
    pub fn persistentCongestion(self: *const Recovery) bool {
        const start = self.pc_start_ts_ms orelse return false;
        const latest = self.pc_latest_ts_ms.?; // set together
        const duration =
            (self.rtt.smoothed_rtt_ms +
                @max(4 * self.rttvar_ms, GranularityMs) +
                self.cfg.max_ack_delay_ms) * 3;
        return (latest - start) >= duration;
    }

    pub fn clearPcWindow(self: *Recovery) void {
        self.pc_start_ts_ms = null;
        self.pc_latest_ts_ms = null;
    }

    /// Current PTO duration including backoff (ms).
    pub fn ptoDuration(self: *const Recovery, app_space: bool) u64 {
        const base = self.rtt.ptoBase(app_space and self.cfg.include_ack_delay_in_pto, self.cfg.max_ack_delay_ms);
        const backoff_shift: u5 = @intCast(@min(self.pto_count, 30));
        return base << backoff_shift;
    }

    pub fn onPtoExpired(self: *Recovery) void {
        self.pto_count += 1;
    }

    pub fn onAckOfInFlight(self: *Recovery) void {
        self.pto_count = 0;
    }

    pub fn resetPcAndLossTimerOnNewData(self: *Recovery) void {
        self.clearPcWindow();
    }
};

// Tests

test "first rtt sample initializes stats without correction" {
    var r = RttStats{};
    r.onAckReceived(100, 150, 25); // raw 50
    try std.testing.expectEqual(@as(u64, 50), r.min_rtt_ms);
    try std.testing.expectEqual(@as(u64, 50), r.smoothed_rtt_ms);
    try std.testing.expectEqual(@as(u64, 25), r.rttvar_ms);
}

test "ewma smoothing follows RFC 9002 factors" {
    var r = RttStats{};
    r.onAckReceived(0, 100, 0); // first: srtt=100 var=50
    // Second sample 60: diff=40 -> var=(3*50+40)/4=47 -> srtt=(7*100+60)/8=95
    r.onAckReceived(0, 60, 0);
    try std.testing.expectEqual(@as(u64, 60), r.latest_rtt_ms);
    try std.testing.expectEqual(@as(u64, 95), r.smoothed_rtt_ms);
    try std.testing.expectEqual(@as(u64, 47), r.rttvar_ms);
}

test "ack delay correction bounded by min_rtt gap" {
    var r = RttStats{};
    r.onAckReceived(0, 100, 0); // min=100 srtt=100
    // Sample 200 with ack delay 150: correction capped at raw-min=100.
    r.onAckReceived(0, 200, 150);
    // budget=min(150, 200-100)=100 -> sample=100
    try std.testing.expectEqual(@as(u64, 100), r.smoothed_rtt_ms);
}

test "packet threshold triggers before time threshold" {
    var rec = Recovery.init(.{});
    rec.largest_acked_pn = 10;

    var lost = std.ArrayList(SentPacket).empty;
    defer lost.deinit(std.testing.allocator);

    const pkts = [_]SentPacket{
        .{ .pn = 2, .ts_ms = 1000, .in_flight_bytes = 1200, .ack_eliciting = true },
        .{ .pn = 8, .ts_ms = 1990, .in_flight_bytes = 1200, .ack_eliciting = true }, // within 3? 10>=11 no
        .{ .pn = 7, .ts_ms = 1995, .in_flight_bytes = 1200, .ack_eliciting = true }, // 10 >= 7+3 -> lost
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
    rec.largest_acked_pn = 7;

    var lost = std.ArrayList(SentPacket).empty;
    defer lost.deinit(std.testing.allocator);

    // loss_delay = 900; packet sent at t=100 expires at 1000.
    const pkts = [_]SentPacket{
        .{ .pn = 5, .ts_ms = 100, .in_flight_bytes = 1200, .ack_eliciting = true },
    };
    try rec.detectLost(pkts[0..], 999, &lost, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), lost.items.len);
    try std.testing.expectEqual(@as(u64, 1000), rec.loss_time_ms.?);

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
