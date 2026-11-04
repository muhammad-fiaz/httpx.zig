//! Path validation (RFC 9000 section 8.2): PATH_CHALLENGE/PATH_RESPONSE
//! exchange used for address validation, connection migration, and NAT
//! rebinding confirmation. Probe timeout is 3 * PTO base, with two probes
//! per round and a bounded number of rounds.

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
    /// Probe queue for the current round; entries below `sentLen` have
    /// been issued and are eligible to validate a response.
    queue: [MAX_PROBES_PER_ROUND]struct { data: [CHALLENGE_LEN]u8, tsMs: u64 } = undefined,
    /// Number of challenge values actually handed to the packetizer.
    sentLen: usize = 0,
    answerHead: usize = 0,
    len: usize = 0,
    round: u32 = 0,
    startedTsMs: u64 = 0,

    ptoBaseMs: u64,

    pub fn init(ptoBaseMs: u64) PathValidator {
        return .{ .ptoBaseMs = @max(ptoBaseMs, 1) };
    }

    /// Begins (or re-begins) validation toward the current path.
    pub fn start(self: *PathValidator, nowMs: u64, rng: std.Random) void {
        if (self.state == .validated or self.state == .failed) return;
        self.state = .validating;
        if (self.startedTsMs == 0) self.startedTsMs = nowMs;
        if (self.len == 0) self.refill(nowMs, rng);
    }

    /// Starts validation with fresh operating-system entropy. Network paths
    /// must use this method so an off-path peer cannot guess a challenge.
    pub fn startSecure(self: *PathValidator, nowMs: u64, io: std.Io) error{EntropyUnavailable}!void {
        if (self.state == .validated or self.state == .failed) return;
        self.state = .validating;
        if (self.startedTsMs == 0) self.startedTsMs = nowMs;
        if (self.len == 0) self.refillSecure(nowMs, io) catch |err| {
            self.state = .failed;
            return err;
        };
    }

    fn refill(self: *PathValidator, nowMs: u64, rng: std.Random) void {
        self.answerHead = 0;
        self.sentLen = 0;
        self.len = 0;
        while (self.len < MAX_PROBES_PER_ROUND) {
            var c: [CHALLENGE_LEN]u8 = undefined;
            rng.bytes(&c);
            self.queue[self.len] = .{ .data = c, .tsMs = nowMs };
            self.len += 1;
        }
    }

    fn refillSecure(self: *PathValidator, nowMs: u64, io: std.Io) error{EntropyUnavailable}!void {
        self.answerHead = 0;
        self.sentLen = 0;
        self.len = 0;
        while (self.len < MAX_PROBES_PER_ROUND) {
            var challenge: [CHALLENGE_LEN]u8 = undefined;
            io.randomSecure(&challenge) catch return error.EntropyUnavailable;
            self.queue[self.len] = .{ .data = challenge, .tsMs = nowMs };
            self.len += 1;
        }
    }

    /// Next pending PATH_CHALLENGE payload to put on the wire.
    pub fn nextChallenge(self: *PathValidator) ?[CHALLENGE_LEN]u8 {
        if (self.answerHead >= self.len) return null;
        return self.queue[self.answerHead].data;
    }

    /// Marks one challenge as handed to the packetizer.
    pub fn markSent(self: *PathValidator) void {
        if (self.answerHead < self.len) {
            self.answerHead += 1;
            self.sentLen = @max(self.sentLen, self.answerHead);
        }
    }

    /// Checks a received PATH_RESPONSE. Returns true when it matches an
    /// outstanding (issued, unanswered) challenge.
    pub fn onResponse(self: *PathValidator, data: *const [CHALLENGE_LEN]u8) bool {
        if (self.state != .validating) return false;
        for (self.queue[0..self.sentLen]) |q| {
            if (std.mem.eql(u8, q.data[0..], data[0..])) {
                self.state = .validated;
                self.len = 0;
                self.sentLen = 0;
                self.answerHead = 0;
                return true;
            }
        }
        return false;
    }

    /// Timer expiry handling. Returns true when validation finished
    /// (success or failure).
    pub fn onTimeout(self: *PathValidator, nowMs: u64, rng: std.Random) bool {
        if (self.state != .validating) return false;

        const timeout = self.probeTimeoutMs();
        var expired = false;
        for (self.queue[0..self.sentLen]) |q| {
            if (nowMs >= q.tsMs + timeout) {
                expired = true;
                break;
            }
        }
        if (!expired) return false;

        self.round += 1;
        if (self.round > MAX_ROUNDS or
            nowMs >= self.startedTsMs +| self.totalTimeoutMs())
        {
            self.state = .failed;
            self.len = 0;
            self.sentLen = 0;
            self.answerHead = 0;
            return true;
        }
        self.refill(nowMs, rng);
        return false;
    }

    /// Secure counterpart used by live connections. Returns `null` when no
    /// probe expired, `false` after queuing a new round, or `true` on failure.
    pub fn onTimeoutSecure(self: *PathValidator, nowMs: u64, io: std.Io) error{EntropyUnavailable}!?bool {
        if (self.state != .validating or self.sentLen == 0) return null;

        const timeout = self.probeTimeoutMs();
        var expired = false;
        for (self.queue[0..self.sentLen]) |challenge| {
            if (nowMs >= challenge.tsMs + timeout) {
                expired = true;
                break;
            }
        }
        if (!expired) return null;

        self.round += 1;
        if (self.round > MAX_ROUNDS or
            nowMs >= self.startedTsMs +| self.totalTimeoutMs())
        {
            self.state = .failed;
            self.len = 0;
            self.sentLen = 0;
            self.answerHead = 0;
            return true;
        }
        self.refillSecure(nowMs, io) catch |err| {
            self.state = .failed;
            return err;
        };
        return false;
    }

    fn probeTimeoutMs(self: *const PathValidator) u64 {
        return 3 * self.ptoBaseMs;
    }

    pub fn totalTimeoutMs(self: *const PathValidator) u64 {
        return 3 * self.probeTimeoutMs();
    }

    pub fn isValidated(self: *const PathValidator) bool {
        return self.state == .validated;
    }

    pub fn reset(self: *PathValidator) void {
        self.* = .{ .ptoBaseMs = self.ptoBaseMs };
    }
};

// Tests

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

test "unsent challenge cannot validate and secure validation issues entropy" {
    var prng = std.Random.DefaultPrng.init(1234);
    const rng = prng.random();
    var pv = PathValidator.init(50);
    pv.start(1000, rng);
    const unsent = pv.queue[1].data;
    try std.testing.expect(!pv.onResponse(&unsent));
    try std.testing.expectEqual(State.validating, pv.state);

    const io = std.Io.Threaded.global_single_threaded.io();
    pv.reset();
    try pv.startSecure(2000, io);
    const issued = pv.nextChallenge().?;
    pv.markSent();
    try std.testing.expect(pv.onResponse(&issued));
    try std.testing.expectEqual(State.validated, pv.state);
}

test "timeout triggers fresh rounds then failure" {
    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();

    var pv = PathValidator.init(10); // probe timeout 30ms
    pv.start(0, rng);

    // Simulate repeated expiry far past total budget.
    var t: u64 = 100;
    while (t < 5000) : (t += 100) {
        while (pv.nextChallenge() != null) pv.markSent();
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
