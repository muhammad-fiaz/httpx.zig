//! TLS 1.3 session resumption and 0-RTT early data (RFC 8446 Sections 4.6.1, 4.2.10, 4.2.11).
//!
//! Two halves with opposite ownership:
//!
//! * `ClientSession`: an opaque ticket plus the derived PSK, owned by the
//!   TLS *client* (typically parked in the high-level client's
//!   origin-keyed cache). Duped/freed explicitly; expiry is wall-clock.
//!   Tracks `maxEarlyData` and ALPN binding for 0-RTT.
//! * `TicketKeys`: the *server's* ticket-encryption keys. Tickets are
//!   stateless (AEAD-sealed PSK + metadata), so the server keeps no
//!   per-client state. `previous` enables rotation without invalidating
//!   outstanding tickets.
//! * `ReplayCache`: bounded, thread-safe server-side anti-replay tracking
//!   to defend against 0-RTT replay attacks within the freshness window.
//!
//! References:
//!   - RFC 8446 Section 4.6.1 — New Session Ticket Message
//!   - RFC 8446 Section 4.2.10 — Early Data Indication
//!   - RFC 8446 Section 4.2.11 — Pre-Shared Key Extension
//!   - RFC 8446 Section 7.1 — Key Schedule (resumption master secret)
//!   - RFC 8446 Section 8.2 — Replay Detection in 0-RTT

const std = @import("std");
const Allocator = std.mem.Allocator;
const tls = std.crypto.tls;
const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const clockMod = @import("../../common/clock.zig");
const syncMod = @import("../../common/sync.zig");
const handshakeMod = @import("handshake.zig");

/// Shared Io for tests. `Threaded.global_single_threaded` is documented as
/// debug-only, but in tests it is the simplest real implementation and it
/// still routes randomSecure to the OS CSPRNG.
pub const testIo = struct {
    pub fn get() std.Io {
        return std.Io.Threaded.global_single_threaded.io();
    }
};

/// Origin-keyed client session cache for TLS 1.3 resumption. Bounded
/// (default 32 entries, oldest evicted); internally synchronized for
/// sharing across threads. Stored sessions are duped on the way in and
/// out, so callers keep single ownership of their copies.
pub const SessionCache = struct {
    allocator: Allocator,
    mu: syncMod.Spinlock = .{},
    entries: std.ArrayList(CachedEntry) = .empty,
    maxEntries: u32 = 32,

    const CachedEntry = struct {
        host: [64]u8,
        hostLen: u8,
        port: u16,
        session: ClientSession,
    };

    pub fn init(allocator: Allocator) SessionCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SessionCache) void {
        for (self.entries.items) |*e| {
            self.allocator.free(e.session.ticket);
            self.allocator.free(e.session.host);
            std.crypto.secureZero(u8, &e.session.psk);
        }
        self.entries.deinit(self.allocator);
    }

    /// Returns an owned duplicate of the usable session for this origin,
    /// or null. Caller owns the result (`deinit` with an allocator).
    pub fn get(self: *SessionCache, host: []const u8, port: u16, nowMs: u64) ?ClientSession {
        return self.getWithAlpn(host, port, nowMs, null);
    }

    /// Returns an owned duplicate of the usable session matching origin and ALPN (if requested).
    pub fn getWithAlpn(self: *SessionCache, host: []const u8, port: u16, nowMs: u64, targetAlpn: ?[]const u8) ?ClientSession {
        if (host.len == 0 or host.len > 64) return null;
        self.mu.lock();
        defer self.mu.unlock();
        for (self.entries.items) |*e| {
            if (e.port == port and e.hostLen == host.len and
                std.mem.eql(u8, e.host[0..e.hostLen], host))
            {
                if (!e.session.isUsableWithAlpn(host, nowMs, targetAlpn)) return null;
                return e.session.dupe(self.allocator) catch null;
            }
        }
        return null;
    }

    /// Stores an owned copy. Evicts the oldest entry when full. The
    /// caller's `session` is NOT consumed.
    pub fn put(self: *SessionCache, host: []const u8, port: u16, session: *const ClientSession) void {
        if (host.len == 0 or host.len > 64) return;
        self.mu.lock();
        defer self.mu.unlock();
        // Replace any existing entry for this origin outright.
        for (self.entries.items) |*e| {
            if (e.port == port and e.hostLen == host.len and
                std.mem.eql(u8, e.host[0..e.hostLen], host))
            {
                const fresh = session.dupe(self.allocator) catch return;
                self.allocator.free(e.session.ticket);
                self.allocator.free(e.session.host);
                e.session = fresh;
                return;
            }
        }
        while (self.entries.items.len >= self.maxEntries) {
            var oldest: usize = 0;
            for (self.entries.items, 0..) |*e, i| {
                if (e.session.createdMs < self.entries.items[oldest].session.createdMs) oldest = i;
            }
            var evicted = self.entries.swapRemove(oldest);
            evicted.session.deinit(self.allocator);
        }
        const fresh = session.dupe(self.allocator) catch return;
        errdefer {
            self.allocator.free(fresh.ticket);
            self.allocator.free(fresh.host);
        }
        var entry = CachedEntry{
            .host = [_]u8{0} ** 64,
            .hostLen = @intCast(host.len),
            .port = port,
            .session = fresh,
        };
        @memcpy(entry.host[0..host.len], host);
        self.entries.append(self.allocator, entry) catch return;
    }
};

/// Bounded anti-replay defense mechanism for TLS 1.3 0-RTT early data (RFC 8446 Section 8.2).
/// Tracks unique hash of (ticket || binder) within the ticket validity and clock-skew window.
/// Enforces bounded capacity and fails closed (rejects early data) on saturation or replay.
pub const ReplayCache = struct {
    allocator: Allocator,
    mu: syncMod.Spinlock = .{},
    entries: std.ArrayList(Entry) = .empty,
    maxEntries: u32 = 1024,
    windowMs: u64 = 10_000,

    const Entry = struct {
        idHash: [32]u8,
        seenAtMs: u64,
    };

    pub fn init(allocator: Allocator, maxEntries: u32) ReplayCache {
        return .{
            .allocator = allocator,
            .maxEntries = if (maxEntries == 0) 1024 else maxEntries,
        };
    }

    pub fn deinit(self: *ReplayCache) void {
        self.entries.deinit(self.allocator);
    }

    /// Returns true if the token is fresh and recorded; returns false if replay is detected
    /// or if the cache is full (fail closed).
    pub fn checkAndRecord(self: *ReplayCache, id: []const u8, nowMs: u64) bool {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(id);
        const digest = h.finalResult();

        self.mu.lock();
        defer self.mu.unlock();

        // 1. Evict entries older than windowMs
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const age = nowMs -| self.entries.items[i].seenAtMs;
            if (age > self.windowMs) {
                _ = self.entries.swapRemove(i);
            } else {
                i += 1;
            }
        }

        // 2. Check duplicate
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, &e.idHash, &digest)) {
                return false; // Replay detected!
            }
        }

        // 3. Bound check: fail closed
        if (self.entries.items.len >= self.maxEntries) {
            return false;
        }

        // 4. Record entry
        self.entries.append(self.allocator, .{
            .idHash = digest,
            .seenAtMs = nowMs,
        }) catch return false;

        return true;
    }
};

/// True for cipher suites a SHA-256-only key schedule can resume with.
pub fn suiteSupportsResumption(suite: tls.CipherSuite) bool {
    return suite == .AES_128_GCM_SHA256 or suite == .CHACHA20_POLY1305_SHA256;
}

/// HKDF-Expand-Label (RFC 8446 Section 7.1).
fn expandLabel(prk: [32]u8, comptime label: []const u8, context: []const u8, out: []u8) void {
    const fullLabel = "tls13 " ++ label;
    var info: [2 + 1 + 64 + 1 + 32]u8 = undefined;
    var w: usize = 0;
    info[w] = @intCast(out.len >> 8);
    info[w + 1] = @intCast(out.len & 0xFF);
    w += 2;
    info[w] = @intCast(fullLabel.len);
    w += 1;
    @memcpy(info[w..][0..fullLabel.len], fullLabel);
    w += fullLabel.len;
    info[w] = @intCast(context.len);
    w += 1;
    if (context.len > 0) {
        @memcpy(info[w..][0..context.len], context);
        w += context.len;
    }
    HkdfSha256.expand(out, info[0..w], prk);
}

/// Builds an owned `ClientSession` from a decoded NewSessionTicket and
/// the connection's resumption master secret.
pub fn clientSessionFromTicket(
    allocator: Allocator,
    nst: handshakeMod.NewSessionTicket,
    resumptionMaster: [32]u8,
    suite: tls.CipherSuite,
    host: []const u8,
    nowMs: u64,
) !ClientSession {
    return clientSessionFromTicketWithAlpn(allocator, nst, resumptionMaster, suite, host, null, nowMs);
}

/// Builds an owned `ClientSession` with explicit ALPN binding.
pub fn clientSessionFromTicketWithAlpn(
    allocator: Allocator,
    nst: handshakeMod.NewSessionTicket,
    resumptionMaster: [32]u8,
    suite: tls.CipherSuite,
    host: []const u8,
    alpn: ?[]const u8,
    nowMs: u64,
) !ClientSession {
    if (!suiteSupportsResumption(suite)) return error.UnsupportedSuite;
    var psk: [32]u8 = undefined;
    expandLabel(resumptionMaster, "resumption", nst.nonce, &psk);
    errdefer std.crypto.secureZero(u8, &psk);
    var alpnBuf: [16]u8 = [_]u8{0} ** 16;
    var alpnLen: u8 = 0;
    if (alpn) |a| {
        alpnLen = @intCast(@min(a.len, 16));
        @memcpy(alpnBuf[0..alpnLen], a[0..alpnLen]);
    }
    return .{
        .ticket = try allocator.dupe(u8, nst.ticket),
        .psk = psk,
        .ageAdd = nst.ageAdd,
        .createdMs = nowMs,
        .lifetimeSecs = nst.lifetimeSecs,
        .suite = suite,
        .host = try allocator.dupe(u8, host),
        .maxEarlyData = nst.maxEarlyData orelse 0,
        .alpn = alpnBuf,
        .alpnLen = alpnLen,
    };
}

/// Maximum ticket age the server will honor beyond nominal lifetime
/// (clock-skew tolerance, RFC 8446 Section 4.2.11.2 guidance).
pub const ticketSkewMs: i64 = 10_000;

/// Ticket plaintext layout:
/// V2: magic[4] || suite u16 || createdMs u64 || lifetimeSecs u32 || ageAdd u32 || maxEarlyData u32 || alpnLen u8 || alpn[16] || psk[32] = 75 bytes
/// V1: magic[4] || suite u16 || createdMs u64 || lifetimeSecs u32 || ageAdd u32 || psk[32] = 54 bytes
pub const ticketMagic: [4]u8 = .{ 'H', 'X', 'P', '2' };
pub const ticketMagicV1: [4]u8 = .{ 'H', 'X', 'P', 'S' };
pub const ticketPlainLen: usize = 4 + 2 + 8 + 4 + 4 + 4 + 1 + 16 + 32;
pub const ticketPlainLenV1: usize = 4 + 2 + 8 + 4 + 4 + 32;
pub const ticketNonceLen: usize = 12;
pub const ticketBlobLen: usize = ticketNonceLen + ticketPlainLen + ChaCha20Poly1305.tag_length;
pub const ticketBlobLenV1: usize = ticketNonceLen + ticketPlainLenV1 + ChaCha20Poly1305.tag_length;

/// A resumption PSK held by the client, bound to the origin host it was
/// issued for.
pub const ClientSession = struct {
    ticket: []u8,
    psk: [32]u8,
    ageAdd: u32,
    createdMs: u64,
    lifetimeSecs: u32,
    suite: tls.CipherSuite,
    host: []u8,
    maxEarlyData: u32 = 0,
    alpn: [16]u8 = [_]u8{0} ** 16,
    alpnLen: u8 = 0,

    pub fn deinit(self: *ClientSession, allocator: Allocator) void {
        allocator.free(self.ticket);
        allocator.free(self.host);
        std.crypto.secureZero(u8, &self.psk);
        self.* = undefined;
    }

    pub fn dupe(self: *const ClientSession, allocator: Allocator) !ClientSession {
        return .{
            .ticket = try allocator.dupe(u8, self.ticket),
            .psk = self.psk,
            .ageAdd = self.ageAdd,
            .createdMs = self.createdMs,
            .lifetimeSecs = self.lifetimeSecs,
            .suite = self.suite,
            .host = try allocator.dupe(u8, self.host),
            .maxEarlyData = self.maxEarlyData,
            .alpn = self.alpn,
            .alpnLen = self.alpnLen,
        };
    }

    /// True when the ticket is still usable for `host` right now.
    pub fn isUsable(self: *const ClientSession, host: []const u8, nowMs: u64) bool {
        return self.isUsableWithAlpn(host, nowMs, null);
    }

    /// True when the ticket matches host, freshness, and optional ALPN protocol.
    pub fn isUsableWithAlpn(self: *const ClientSession, host: []const u8, nowMs: u64, targetAlpn: ?[]const u8) bool {
        if (!std.mem.eql(u8, self.host, host)) return false;
        if (self.ticket.len == 0) return false;
        if (targetAlpn) |a| {
            if (self.alpnLen > 0 and !std.mem.eql(u8, self.alpn[0..self.alpnLen], a)) return false;
        }
        const ageMs = @as(i64, @intCast(nowMs)) - @as(i64, @intCast(self.createdMs));
        if (ageMs < 0) return false;
        return ageMs < @as(i64, @intCast(self.lifetimeSecs)) * 1000 + ticketSkewMs;
    }

    /// Obfuscated ticket age for the ClientHello offer (RFC 8446 4.2.11.2).
    pub fn obfuscatedAge(self: *const ClientSession, nowMs: u64) u32 {
        const ageMs: u64 = nowMs -| self.createdMs;
        const age: u32 = @truncate(ageMs);
        return age +% self.ageAdd;
    }
};

/// Server-side ticket protection keys. Stateless tickets: seal on issue,
/// open on offer. Keep `previous` across rotations so tickets sealed just
/// before a rotation still verify.
pub const TicketKeys = struct {
    current: [32]u8,
    previous: ?[32]u8 = null,

    /// Generates a fresh sealing key from OS entropy. Fails rather than
    /// falling back to a software PRNG: a predictable key would let
    /// anyone mint a valid session ticket.
    pub fn generate(io: std.Io) !TicketKeys {
        var k: TicketKeys = .{ .current = undefined };
        try io.randomSecure(&k.current);
        return k;
    }

    pub fn rotate(self: *TicketKeys, next: [32]u8) void {
        self.previous = self.current;
        self.current = next;
    }

    /// Seals a ticket with optional maxEarlyData and ALPN binding.
    /// The ticket nonce comes from OS entropy, so this can fail.
    pub fn seal(
        self: *const TicketKeys,
        io: std.Io,
        psk: [32]u8,
        suite: tls.CipherSuite,
        createdMs: u64,
        lifetimeSecs: u32,
        ageAdd: u32,
        maxEarlyData: u32,
        alpn: []const u8,
    ) ![ticketBlobLen]u8 {
        var plain: [ticketPlainLen]u8 = undefined;
        @memcpy(plain[0..4], &ticketMagic);
        std.mem.writeInt(u16, plain[4..6], @intFromEnum(suite), .big);
        std.mem.writeInt(u64, plain[6..14], createdMs, .big);
        std.mem.writeInt(u32, plain[14..18], lifetimeSecs, .big);
        std.mem.writeInt(u32, plain[18..22], ageAdd, .big);
        std.mem.writeInt(u32, plain[22..26], maxEarlyData, .big);
        const aLen: u8 = @intCast(@min(alpn.len, 16));
        plain[26] = aLen;
        @memset(plain[27..43], 0);
        if (aLen > 0) @memcpy(plain[27..][0..aLen], alpn[0..aLen]);
        @memcpy(plain[43..75], &psk);

        var out: [ticketBlobLen]u8 = undefined;
        try io.randomSecure(out[0..ticketNonceLen]);
        var tag: [ChaCha20Poly1305.tag_length]u8 = undefined;
        ChaCha20Poly1305.encrypt(
            out[ticketNonceLen..][0..ticketPlainLen],
            &tag,
            &plain,
            &.{},
            out[0..ticketNonceLen].*,
            self.current,
        );
        @memcpy(out[ticketNonceLen + ticketPlainLen ..], &tag);
        std.crypto.secureZero(u8, &plain);
        return out;
    }

    /// Opens a ticket sealed by current or previous keys. Verifies magic,
    /// suite sanity, and lifetime against `nowMs`. Returns the PSK plus
    /// metadata; the caller decides acceptance (binder still required).
    pub fn open(self: *const TicketKeys, blob: []const u8, nowMs: u64) !struct {
        psk: [32]u8,
        suite: tls.CipherSuite,
        createdMs: u64,
        lifetimeSecs: u32,
        ageAdd: u32,
        maxEarlyData: u32,
        alpn: [16]u8,
        alpnLen: u8,
    } {
        if (blob.len != ticketBlobLen and blob.len != ticketBlobLenV1) {
            return error.InvalidTicket;
        }
        const isV2 = (blob.len == ticketBlobLen);
        const plainLen = if (isV2) ticketPlainLen else ticketPlainLenV1;
        const nonce = blob[0..ticketNonceLen].*;
        const ct = blob[ticketNonceLen..][0..plainLen];
        const tag = blob[ticketNonceLen + plainLen ..][0..ChaCha20Poly1305.tag_length].*;
        var plain: [ticketPlainLen]u8 = undefined;
        var ok = false;
        const keys: [2]?[32]u8 = .{ self.current, self.previous };
        for (keys) |kopt| {
            const k = kopt orelse continue;
            ChaCha20Poly1305.decrypt(plain[0..plainLen], ct, tag, &.{}, nonce, k) catch continue;
            ok = true;
            break;
        }
        if (!ok) return error.InvalidTicket;
        defer std.crypto.secureZero(u8, &plain);

        const magic = if (isV2) ticketMagic else ticketMagicV1;
        if (!std.mem.eql(u8, plain[0..4], &magic)) return error.InvalidTicket;
        const suite: tls.CipherSuite = @enumFromInt(std.mem.readInt(u16, plain[4..6], .big));
        const created = std.mem.readInt(u64, plain[6..14], .big);
        const lifetime = std.mem.readInt(u32, plain[14..18], .big);
        const ageAdd = std.mem.readInt(u32, plain[18..22], .big);
        if (lifetime == 0) return error.InvalidTicket;
        const ageMs = @as(i64, @intCast(nowMs)) - @as(i64, @intCast(created));
        if (ageMs < 0 or ageMs > @as(i64, @intCast(lifetime)) * 1000 + ticketSkewMs) {
            return error.TicketExpired;
        }

        var maxEarlyData: u32 = 0;
        var alpn: [16]u8 = [_]u8{0} ** 16;
        var alpnLen: u8 = 0;
        var psk: [32]u8 = undefined;
        if (isV2) {
            maxEarlyData = std.mem.readInt(u32, plain[22..26], .big);
            alpnLen = plain[26];
            if (alpnLen > 16) return error.InvalidTicket;
            @memcpy(&alpn, plain[27..43]);
            @memcpy(&psk, plain[43..75]);
        } else {
            @memcpy(&psk, plain[22..54]);
        }
        return .{
            .psk = psk,
            .suite = suite,
            .createdMs = created,
            .lifetimeSecs = lifetime,
            .ageAdd = ageAdd,
            .maxEarlyData = maxEarlyData,
            .alpn = alpn,
            .alpnLen = alpnLen,
        };
    }
};

test "ticket seal/open round trip with expiry and rotation" {
    var keys = TicketKeys{ .current = [_]u8{0x11} ** 32 };
    const psk = [_]u8{0x42} ** 32;
    const blob = try keys.seal(testIo.get(), psk, .AES_128_GCM_SHA256, 1_000_000, 3600, 0xA11CE, 0xFFFFFFFF, "h3");
    const opened = try keys.open(&blob, 1_000_000 + 1000);
    try std.testing.expectEqualSlices(u8, &psk, &opened.psk);
    try std.testing.expectEqual(tls.CipherSuite.AES_128_GCM_SHA256, opened.suite);
    try std.testing.expectEqual(@as(u64, 1_000_000), opened.createdMs);
    try std.testing.expectEqual(@as(u32, 3600), opened.lifetimeSecs);
    try std.testing.expectEqual(@as(u32, 0xA11CE), opened.ageAdd);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), opened.maxEarlyData);
    try std.testing.expectEqual(@as(u8, 2), opened.alpnLen);
    try std.testing.expectEqualStrings("h3", opened.alpn[0..opened.alpnLen]);

    // Expired tickets fail closed.
    try std.testing.expectError(error.TicketExpired, keys.open(&blob, 1_000_000 + 3600 * 1000 + ticketSkewMs + 1));
    // Corrupted blobs fail closed.
    var bad = blob;
    bad[20] ^= 0xFF;
    try std.testing.expectError(error.InvalidTicket, keys.open(&bad, 1_000_000 + 1000));

    // Rotation: old tickets still verify via `previous`, then die.
    keys.rotate([_]u8{0x22} ** 32);
    const reopened = try keys.open(&blob, 1_000_000 + 1000);
    try std.testing.expectEqualSlices(u8, &psk, &reopened.psk);
    keys.rotate([_]u8{0x33} ** 32);
    try std.testing.expectError(error.InvalidTicket, keys.open(&blob, 1_000_000 + 1000));
}

test "replay cache records and detects duplicates within window" {
    const a = std.testing.allocator;
    var rc = ReplayCache.init(a, 4);
    defer rc.deinit();

    // First attempt succeeds
    try std.testing.expect(rc.checkAndRecord("ticket_alpha_binder", 1000));
    // Immediate duplicate fails
    try std.testing.expect(!rc.checkAndRecord("ticket_alpha_binder", 1001));

    // Another distinct ticket succeeds
    try std.testing.expect(rc.checkAndRecord("ticket_beta_binder", 1002));
    try std.testing.expect(!rc.checkAndRecord("ticket_beta_binder", 1003));

    // After expiration window (10s), expired entry is purged
    try std.testing.expect(rc.checkAndRecord("ticket_gamma", 20000));
}

test "client session usability is host-bound and time-bound" {
    const a = std.testing.allocator;
    var s = ClientSession{
        .ticket = try a.dupe(u8, "tok"),
        .psk = [_]u8{0} ** 32,
        .ageAdd = 7,
        .createdMs = 5_000,
        .lifetimeSecs = 10,
        .suite = .AES_128_GCM_SHA256,
        .host = try a.dupe(u8, "example.com"),
    };
    defer s.deinit(a);
    try std.testing.expect(s.isUsable("example.com", 8_000));
    try std.testing.expect(!s.isUsable("other.com", 8_000));
    try std.testing.expect(!s.isUsable("example.com", 5_000 + 10 * 1000 + ticketSkewMs));
    // Obfuscation round-trips through wrapping arithmetic.
    const obf = s.obfuscatedAge(9_000);
    try std.testing.expectEqual(@as(u32, 4000) +% 7, obf);
}
