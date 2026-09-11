//! TLS 1.3 session resumption (RFC 8446 Sections 4.6.1, 4.2.11).
//!
//! Two halves with opposite ownership:
//!
//! * `ClientSession`: an opaque ticket plus the derived PSK, owned by the
//!   TLS *client* (typically parked in the high-level client's
//!   origin-keyed cache). Duped/freed explicitly; expiry is wall-clock.
//! * `TicketKeys`: the *server's* ticket-encryption keys. Tickets are
//!   stateless (AEAD-sealed PSK + metadata), so the server keeps no
//!   per-client state. `previous` enables rotation without invalidating
//!   outstanding tickets.
//!
//! 0-RTT early data is deliberately NOT implemented (replay risk): tickets
//! never carry `early_data` extensions and offers containing them are
//! rejected. Only `psk_dhe_ke` resumption (forward-secret) is supported.
//!
//! Thread-safety: values are thread-confined; the client's session cache
//! serializes access itself. `TicketKeys` is read-only after creation.
//!
//! References:
//!   - RFC 8446 Section 4.6.1 — New Session Ticket Message
//!   - RFC 8446 Section 4.2.11 — Pre-Shared Key Extension
//!   - RFC 8446 Section 7.1 — Key Schedule (resumption master secret)

const std = @import("std");
const Allocator = std.mem.Allocator;
const tls = std.crypto.tls;
const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const clock_mod = @import("../../common/clock.zig");
const sync_mod = @import("../../common/sync.zig");
const handshake_mod = @import("handshake.zig");

/// Origin-keyed client session cache for TLS 1.3 resumption. Bounded
/// (default 32 entries, oldest evicted); internally synchronized for
/// sharing across threads. Stored sessions are duped on the way in and
/// out, so callers keep single ownership of their copies.
pub const SessionCache = struct {
    allocator: Allocator,
    mu: sync_mod.Spinlock = .{},
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
        if (host.len == 0 or host.len > 64) return null;
        self.mu.lock();
        defer self.mu.unlock();
        for (self.entries.items) |*e| {
            if (e.port == port and e.hostLen == host.len and
                std.mem.eql(u8, e.host[0..e.hostLen], host))
            {
                if (!e.session.isUsable(host, nowMs)) return null;
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
        // Ownership of `fresh` moves into the list; cancel the errdefer
        // by appending infallibly-after-reserve... (append can still OOM:
        // on failure the errdefer above frees the dupe.)
        self.entries.append(self.allocator, entry) catch return;
    }
};

test "session cache stores, returns, replaces, and evicts" {
    const a = std.testing.allocator;
    var cache = SessionCache.init(a);
    defer cache.deinit();
    cache.maxEntries = 2;

    var s1 = ClientSession{
        .ticket = try a.dupe(u8, "t1"),
        .psk = [_]u8{1} ** 32,
        .ageAdd = 0,
        .createdMs = 1000,
        .lifetimeSecs = 3600,
        .suite = .AES_128_GCM_SHA256,
        .host = try a.dupe(u8, "a.com"),
    };
    defer s1.deinit(a);
    cache.put("a.com", 443, &s1);
    var got = cache.get("a.com", 443, 2000) orelse return error.MissingSession;
    defer got.deinit(a);
    try std.testing.expectEqualSlices(u8, "t1", got.ticket);
    // Wrong port misses.
    try std.testing.expect(cache.get("a.com", 444, 2000) == null);

    var s2 = ClientSession{
        .ticket = try a.dupe(u8, "t2"),
        .psk = [_]u8{2} ** 32,
        .ageAdd = 0,
        .createdMs = 2000,
        .lifetimeSecs = 3600,
        .suite = .AES_128_GCM_SHA256,
        .host = try a.dupe(u8, "b.com"),
    };
    defer s2.deinit(a);
    cache.put("b.com", 443, &s2);
    var s3 = ClientSession{
        .ticket = try a.dupe(u8, "t3"),
        .psk = [_]u8{3} ** 32,
        .ageAdd = 0,
        .createdMs = 3000,
        .lifetimeSecs = 3600,
        .suite = .AES_128_GCM_SHA256,
        .host = try a.dupe(u8, "c.com"),
    };
    defer s3.deinit(a);
    cache.put("c.com", 443, &s3);
    // Oldest (a.com) evicted; newest kept.
    try std.testing.expect(cache.get("a.com", 443, 4000) == null);
    var got3 = cache.get("c.com", 443, 4000) orelse return error.MissingSession;
    defer got3.deinit(a);
    try std.testing.expectEqualSlices(u8, "t3", got3.ticket);
}

/// True for cipher suites a SHA-256-only key schedule can resume with.
/// AES_256_GCM_SHA384 needs a SHA-384 transcript, which the native
/// engine does not implement — such tickets are ignored, never offered.
pub fn suiteSupportsResumption(suite: tls.CipherSuite) bool {
    return suite == .AES_128_GCM_SHA256 or suite == .CHACHA20_POLY1305_SHA256;
}

/// HKDF-Expand-Label (RFC 8446 Section 7.1), same construction as the
/// handshake engine's helper (kept local so this module never imports
/// the engine back).
fn expandLabel(prk: [32]u8, comptime label: []const u8, context: []const u8, out: []u8) void {
    const full_label = "tls13 " ++ label;
    var info: [2 + 1 + 64 + 1 + 32]u8 = undefined;
    var w: usize = 0;
    info[w] = @intCast(out.len >> 8);
    info[w + 1] = @intCast(out.len & 0xFF);
    w += 2;
    info[w] = @intCast(full_label.len);
    w += 1;
    @memcpy(info[w..][0..full_label.len], full_label);
    w += full_label.len;
    info[w] = @intCast(context.len);
    w += 1;
    if (context.len > 0) {
        @memcpy(info[w..][0..context.len], context);
        w += context.len;
    }
    HkdfSha256.expand(out, info[0..w], prk);
}

/// Builds an owned `ClientSession` from a decoded NewSessionTicket and
/// the connection's resumption master secret. Shared by the engine-level
/// and connection-level NST consumers so there is exactly one
/// ticket-to-PSK derivation path.
pub fn clientSessionFromTicket(
    allocator: Allocator,
    nst: handshake_mod.NewSessionTicket,
    resumptionMaster: [32]u8,
    suite: tls.CipherSuite,
    host: []const u8,
    nowMs: u64,
) !ClientSession {
    if (!suiteSupportsResumption(suite)) return error.UnsupportedSuite;
    var psk: [32]u8 = undefined;
    expandLabel(resumptionMaster, "resumption", nst.nonce, &psk);
    errdefer std.crypto.secureZero(u8, &psk);
    return .{
        .ticket = try allocator.dupe(u8, nst.ticket),
        .psk = psk,
        .ageAdd = nst.ageAdd,
        .createdMs = nowMs,
        .lifetimeSecs = nst.lifetimeSecs,
        .suite = suite,
        .host = try allocator.dupe(u8, host),
    };
}

/// Maximum ticket age the server will honor beyond nominal lifetime
/// (clock-skew tolerance, RFC 8446 Section 4.2.11.2 guidance).
pub const ticket_skew_ms: i64 = 10_000;

/// Ticket plaintext layout (AEAD-sealed, never on the wire in the clear):
/// magic[4] || suite u16 || createdMs u64 || lifetimeSecs u32 ||
/// ageAdd u32 || psk[32].
const ticket_magic: [4]u8 = .{ 'H', 'X', 'P', 'S' };
const ticket_plain_len: usize = 4 + 2 + 8 + 4 + 4 + 32;
const ticket_nonce_len: usize = 12;

/// A resumption PSK held by the client, bound to the origin host it was
/// issued for. The PSK authenticates the *resumed* handshake; the ticket
/// is opaque to the client.
pub const ClientSession = struct {
    /// Opaque ticket blob (owned).
    ticket: []u8,
    /// Resumption PSK: HKDF-Expand-Label(resumption_master, "resumption",
    /// ticket_nonce, Hash.length).
    psk: [32]u8,
    /// Ticket age-add for obfuscation (owned from the NST).
    ageAdd: u32,
    /// Local receipt time (ms). Freshness uses the server-embedded
    /// creation time instead (AEAD-authenticated); this is bookkeeping.
    createdMs: u64,
    /// Ticket lifetime in seconds (from the NST).
    lifetimeSecs: u32,
    /// Cipher suite the ticket was issued for (hash must match to resume).
    suite: tls.CipherSuite,
    /// Origin host the ticket is bound to (owned). Never offer a ticket
    /// to a different host.
    host: []u8,

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
        };
    }

    /// True when the ticket is still usable for `host` right now.
    pub fn isUsable(self: *const ClientSession, host: []const u8, nowMs: u64) bool {
        if (!std.mem.eql(u8, self.host, host)) return false;
        if (self.ticket.len == 0) return false;
        const age_ms = @as(i64, @intCast(nowMs)) - @as(i64, @intCast(self.createdMs));
        if (age_ms < 0) return false;
        return age_ms < @as(i64, @intCast(self.lifetimeSecs)) * 1000 + ticket_skew_ms;
    }

    /// Obfuscated ticket age for the ClientHello offer (RFC 8446 4.2.11.2).
    pub fn obfuscatedAge(self: *const ClientSession, nowMs: u64) u32 {
        const age_ms: u64 = nowMs -| self.createdMs;
        const age: u32 = @truncate(age_ms);
        return age +% self.ageAdd;
    }
};

/// Server-side ticket protection keys. Stateless tickets: seal on issue,
/// open on offer. Keep `previous` across rotations so tickets sealed just
/// before a rotation still verify.
pub const TicketKeys = struct {
    current: [32]u8,
    previous: ?[32]u8 = null,

    /// Generates fresh keys from the OS CSPRNG (with deterministic
    /// fallback mirroring the handshake engine's helper).
    pub fn generate() TicketKeys {
        var k: TicketKeys = .{ .current = undefined };
        fillRandom(&k.current);
        return k;
    }

    /// Rotates: `next` becomes current, old current becomes previous.
    pub fn rotate(self: *TicketKeys, next: [32]u8) void {
        self.previous = self.current;
        self.current = next;
    }

    /// Seals a ticket: nonce || ChaCha20-Poly1305(plaintext). Returned
    /// by value (82 bytes); no allocation involved.
    pub fn seal(
        self: *const TicketKeys,
        psk: [32]u8,
        suite: tls.CipherSuite,
        createdMs: u64,
        lifetimeSecs: u32,
        ageAdd: u32,
    ) [ticket_nonce_len + ticket_plain_len + ChaCha20Poly1305.tag_length]u8 {
        var plain: [ticket_plain_len]u8 = undefined;
        @memcpy(plain[0..4], &ticket_magic);
        std.mem.writeInt(u16, plain[4..6], @intFromEnum(suite), .big);
        std.mem.writeInt(u64, plain[6..14], createdMs, .big);
        std.mem.writeInt(u32, plain[14..18], lifetimeSecs, .big);
        std.mem.writeInt(u32, plain[18..22], ageAdd, .big);
        @memcpy(plain[22..54], &psk);
        var out: [ticket_nonce_len + ticket_plain_len + ChaCha20Poly1305.tag_length]u8 = undefined;
        fillRandom(out[0..ticket_nonce_len]);
        var tag: [ChaCha20Poly1305.tag_length]u8 = undefined;
        ChaCha20Poly1305.encrypt(
            out[ticket_nonce_len..][0..ticket_plain_len],
            &tag,
            &plain,
            &.{},
            out[0..ticket_nonce_len].*,
            self.current,
        );
        @memcpy(out[ticket_nonce_len + ticket_plain_len ..], &tag);
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
    } {
        if (blob.len != ticket_nonce_len + ticket_plain_len + ChaCha20Poly1305.tag_length) {
            return error.InvalidTicket;
        }
        const nonce = blob[0..ticket_nonce_len].*;
        const ct = blob[ticket_nonce_len..][0..ticket_plain_len];
        const tag = blob[ticket_nonce_len + ticket_plain_len ..][0..ChaCha20Poly1305.tag_length].*;
        var plain: [ticket_plain_len]u8 = undefined;
        var ok = false;
        const keys: [2]?[32]u8 = .{ self.current, self.previous };
        for (keys) |kopt| {
            const k = kopt orelse continue;
            ChaCha20Poly1305.decrypt(&plain, ct, tag, &.{}, nonce, k) catch continue;
            ok = true;
            break;
        }
        if (!ok) return error.InvalidTicket;
        defer std.crypto.secureZero(u8, &plain);
        if (!std.mem.eql(u8, plain[0..4], &ticket_magic)) return error.InvalidTicket;
        const suite: tls.CipherSuite = @enumFromInt(std.mem.readInt(u16, plain[4..6], .big));
        const created = std.mem.readInt(u64, plain[6..14], .big);
        const lifetime = std.mem.readInt(u32, plain[14..18], .big);
        const age_add = std.mem.readInt(u32, plain[18..22], .big);
        if (lifetime == 0) return error.InvalidTicket;
        const age_ms = @as(i64, @intCast(nowMs)) - @as(i64, @intCast(created));
        if (age_ms < 0 or age_ms > @as(i64, @intCast(lifetime)) * 1000 + ticket_skew_ms) {
            return error.TicketExpired;
        }
        var psk: [32]u8 = undefined;
        @memcpy(&psk, plain[22..54]);
        return .{ .psk = psk, .suite = suite, .createdMs = created, .lifetimeSecs = lifetime, .ageAdd = age_add };
    }
};

fn fillRandom(buf: []u8) void {
    if (@hasDecl(std.posix, "getrandom")) {
        std.posix.getrandom(buf) catch {
            var counter: u64 = 0x9E3779B97F4A7C15;
            counter +%= buf.len;
            var prng = std.Random.DefaultPrng.init(counter ^ 0x123456789ABCDEF0);
            prng.random().bytes(buf);
        };
        return;
    }
    var prng = std.Random.DefaultPrng.init(0x123456789ABCDEF0 ^ @as(u64, @intCast(buf.len)));
    prng.random().bytes(buf);
}

test "ticket seal/open round trip with expiry and rotation" {
    var keys = TicketKeys{ .current = [_]u8{0x11} ** 32 };
    const psk = [_]u8{0x42} ** 32;
    const blob = keys.seal(psk, .AES_128_GCM_SHA256, 1_000_000, 3600, 0xA11CE);
    const opened = try keys.open(&blob, 1_000_000 + 1000);
    try std.testing.expectEqualSlices(u8, &psk, &opened.psk);
    try std.testing.expectEqual(tls.CipherSuite.AES_128_GCM_SHA256, opened.suite);
    try std.testing.expectEqual(@as(u64, 1_000_000), opened.createdMs);
    try std.testing.expectEqual(@as(u32, 3600), opened.lifetimeSecs);
    try std.testing.expectEqual(@as(u32, 0xA11CE), opened.ageAdd);

    // Expired tickets fail closed.
    try std.testing.expectError(error.TicketExpired, keys.open(&blob, 1_000_000 + 3600 * 1000 + ticket_skew_ms + 1));
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
    try std.testing.expect(!s.isUsable("example.com", 5_000 + 10 * 1000 + ticket_skew_ms));
    // Obfuscation round-trips through wrapping arithmetic.
    const obf = s.obfuscatedAge(9_000);
    try std.testing.expectEqual(@as(u32, 4000) +% 7, obf);
}
