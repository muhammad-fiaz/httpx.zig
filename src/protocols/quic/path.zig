//! Path validation (RFC 9000 section 8.2): PATH_CHALLENGE/PATH_RESPONSE
//! exchange used for address validation, connection migration, and NAT
//! rebinding confirmation. Timing model follows ngtcp2_pv: probe timeout
//! = 3 * PTO base, two probes per round, bounded rounds.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const MAX_PROBES_PER_ROUND = 2;
pub const MAX_ROUNDS = 10;
pub const CHALLENGE_LEN = 8;

pub const State = enum {
    idle,
    validating,
    validated,
    failed,
};

/// One direction of validation for a single remote path.
pub const PathValidator = struct {
    state: State = .idle,
    /// Probe queue for the current round: [head..len) are issued-but-
    /// unanswered; [answer_head..len) still need to go on the wire.
    queue: [MAX_PROBES_PER_ROUND]struct { data: [CHALLENGE_LEN]u8, ts_ms: u64 } = undefined,
    answer_head: usize = 0,
    len: usize = 0,
    round: u32 = 0,
    started_ts_ms: u64 = 0,

    pto_base_ms: u64,

    pub fn init(pto_base_ms: u64) PathValidator {
        return .{ .pto_base_ms = @max(pto_base_ms, 1) };
    }

    /// Begins (or re-begins) validation toward the current path.
    pub fn start(self: *PathValidator, now_ms: u64, rng: std.Random) void {
        if (self.state == .validated or self.state == .failed) return;
        self.state = .validating;
        if (self.started_ts_ms == 0) self.started_ts_ms = now_ms;
        if (self.len == 0) self.refill(now_ms, rng);
    }

    fn refill(self: *PathValidator, now_ms: u64, rng: std.Random) void {
        self.answer_head = 0;
        self.len = 0;
        while (self.len < MAX_PROBES_PER_ROUND) {
            var c: [CHALLENGE_LEN]u8 = undefined;
            rng.bytes(&c);
            self.queue[self.len] = .{ .data = c, .ts_ms = now_ms };
            self.len += 1;
        }
    }

    /// Next pending PATH_CHALLENGE payload to put on the wire.
    pub fn nextChallenge(self: *PathValidator) ?[CHALLENGE_LEN]u8 {
        if (self.answer_head >= self.len) return null;
        return self.queue[self.answer_head].data;
    }

    /// Marks one challenge as handed to the packetizer.
    pub fn markSent(self: *PathValidator) void {
        if (self.answer_head < self.len) self.answer_head += 1;
    }

    /// Checks a received PATH_RESPONSE. Returns true when it matches an
    /// outstanding (issued, unanswered) challenge.
    pub fn onResponse(self: *PathValidator, data: *const [CHALLENGE_LEN]u8) bool {
        if (self.state != .validating) return false;
        for (self.queue[0..self.len]) |q| {
            if (std.mem.eql(u8, q.data[0..], data[0..])) {
                self.state = .validated;
                self.len = 0;
                self.answer_head = 0;
                return true;
            }
        }
        return false;
    }

    /// Timer expiry handling. Returns true when validation finished
    /// (success or failure).
    pub fn onTimeout(self: *PathValidator, now_ms: u64, rng: std.Random) bool {
        if (self.state != .validating) return false;

        const timeout = self.probeTimeoutMs();
        var expired = false;
        for (self.queue[0..self.len]) |q| {
            if (now_ms >= q.ts_ms + timeout) {
                expired = true;
                break;
            }
        }
        if (!expired) return false;

        self.round += 1;
        if (self.round > MAX_ROUNDS or
            now_ms >= self.started_ts_ms +| self.totalTimeoutMs())
        {
            self.state = .failed;
            self.len = 0;
            self.answer_head = 0;
            return true;
        }
        self.refill(now_ms, rng);
        return false;
    }

    fn probeTimeoutMs(self: *const PathValidator) u64 {
        return 3 * self.pto_base_ms;
    }

    pub fn totalTimeoutMs(self: *const PathValidator) u64 {
        return 3 * self.probeTimeoutMs();
    }

    pub fn isValidated(self: *const PathValidator) bool {
        return self.state == .validated;
    }

    pub fn reset(self: *PathValidator) void {
        self.* = .{ .pto_base_ms = self.pto_base_ms };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "challenge-response roundtrip validates path" {
    var prng = std.Random.DefaultPrng.init(0xC1D);
    const rng = prng.random();

    var pv = PathValidator.init(50);
    pv.start(1000, rng);

    const challenge = pv.nextChallenge().?;
    pv.markSent();

    // Wrong echo does not validate.
    var wrong: [8]u8 = challenge;
    wrong[0] ^= 0xFF;
    try std.testing.expect(!pv.onResponse(&wrong));
    try std.testing.expect(!pv.isValidated());

    // Correct echo confirms.
    try std.testing.expect(pv.onResponse(&challenge));
    try std.testing.expect(pv.isValidated());
}

test "timeout triggers fresh rounds then failure" {
    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();

    var pv = PathValidator.init(10); // probe timeout 30ms
    pv.start(0, rng);

    // Simulate repeated expiry far past total budget.
    var t: u64 = 100;
    while (t < 5000) : (t += 100) {
        if (pv.onTimeout(t, rng)) break;
    }
    try std.testing.expect(pv.state == .failed);
}

test "reset clears validated state for migration" {
    var prng = std.Random.DefaultPrng.init(7);
    const rng = prng.random();
    var pv = PathValidator.init(20);
    pv.start(0, rng);
    const c = pv.nextChallenge().?;
    pv.markSent();
    _ = pv.onResponse(&c);
    try std.testing.expect(pv.isValidated());

    // Peer moved networks: re-validate from scratch.
    pv.reset();
    try std.testing.expect(!pv.isValidated());
    pv.start(9999, rng);
    try std.testing.expect(pv.nextChallenge() != null);
}
