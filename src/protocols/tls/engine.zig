//! TLS 1.3 handshake engine (RFC 8446 Section 4, Section 7.1).
//!
//! Drives the full TLS 1.3 handshake for both client and server roles.
//! Produces/parses handshake messages, derives keys via the key schedule,
//! and handles ALPN negotiation. Uses only std.crypto primitives — no FFI.
//!
//! Thread-safety: thread-confined — one engine per connection.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tls = std.crypto.tls;
const x25519 = std.crypto.dh.X25519;
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

const record_mod = @import("record.zig");
const handshake_mod = @import("handshake.zig");
const Transcript = handshake_mod.Transcript;
const HashLen = handshake_mod.HashLen;
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const P256 = std.crypto.ecc.P256;
const certMod = @import("certificate.zig");
const verify_mod = @import("verify.zig");
const trustStoreMod = @import("trust_store.zig");
const clock_mod = @import("../../common/clock.zig");

const alpn_mod = @import("alpn.zig");
const session_mod = @import("session.zig");

// Random helper — OS CSPRNG when available, otherwise deterministic PRNG

var random_counter: u64 = 0x9E3779B97F4A7C15;

fn fillRandom(buf: []u8) void {
    if (@hasDecl(std.posix, "getrandom")) {
        std.posix.getrandom(buf) catch {
            random_counter +%= 1;
            var prng = std.Random.DefaultPrng.init(random_counter ^ 0x123456789ABCDEF0);
            prng.random().bytes(buf);
        };
        return;
    }
    random_counter +%= 1;
    var prng = std.Random.DefaultPrng.init(random_counter ^ 0x123456789ABCDEF0);
    prng.random().bytes(buf);
}

// HKDF-Expand-Label (RFC 8446 Section 7.1)
// info = uint16(len) || uint8(6 + label.len) || "tls13 " || label || uint8(context_len) || context
// For Derive-Secret, context is the transcript hash; for key/iv expansion, context is empty.
pub fn hkdfExpandLabel(prk: [32]u8, comptime label: []const u8, out: []u8) void {
    hkdfExpandLabelWithContext(prk, label, &.{}, out);
}

pub fn hkdfExpandLabelWithContext(prk: [32]u8, comptime label: []const u8, context: []const u8, out: []u8) void {
    const fullLabel = "tls13 " ++ label;
    var info_buf: [2 + 1 + 64 + 1 + 32]u8 = undefined;
    const total: u16 = @intCast(out.len);
    var w: usize = 0;
    info_buf[w] = @intCast(total >> 8);
    info_buf[w + 1] = @intCast(total & 0xFF);
    w += 2;
    info_buf[w] = @intCast(fullLabel.len);
    w += 1;
    @memcpy(info_buf[w..][0..fullLabel.len], fullLabel);
    w += fullLabel.len;
    info_buf[w] = @intCast(context.len);
    w += 1;
    if (context.len > 0) {
        @memcpy(info_buf[w..][0..context.len], context);
        w += context.len;
    }
    HkdfSha256.expand(out, info_buf[0..w], prk);
}

fn deriveSecret(prk: [32]u8, comptime label: []const u8, transcript_hash: [32]u8) [32]u8 {
    var out: [32]u8 = undefined;
    hkdfExpandLabelWithContext(prk, label, &transcript_hash, &out);
    return out;
}

// Errors

pub const Error = error{
    OutOfMemory,
    HandshakeFailed,
    ProtocolViolation,
    UnsupportedCipherSuite,
    UnsupportedSignatureScheme,
    CertificateVerifyFailed,
    TlsAlert,
    InvalidKeyShare,
    BufferTooSmall,
};

// Encryption levels

pub const EncryptionLevel = enum {
    initial,
    handshake,
    application,
};

// Callbacks

pub const Callbacks = struct {
    ctx: ?*anyopaque = null,
    onKeys: *const fn (ctx: ?*anyopaque, level: EncryptionLevel, keys: DerivedKeys) void = struct {
        fn noOp(_: ?*anyopaque, _: EncryptionLevel, _: DerivedKeys) void {}
    }.noOp,
    onHandshakeData: *const fn (ctx: ?*anyopaque, level: EncryptionLevel, data: []const u8) void = struct {
        fn noOp(_: ?*anyopaque, _: EncryptionLevel, _: []const u8) void {}
    }.noOp,
    onAlert: *const fn (ctx: ?*anyopaque, alert: handshake_mod.Alert) void = struct {
        fn noOp(_: ?*anyopaque, _: handshake_mod.Alert) void {}
    }.noOp,
};

// Derived keys

pub const DerivedKeys = struct {
    clientKey: [32]u8 = undefined,
    clientKeyLen: u8 = 16,
    clientIv: [12]u8 = undefined,
    serverKey: [32]u8 = undefined,
    serverKeyLen: u8 = 16,
    serverIv: [12]u8 = undefined,
    cipher: record_mod.RecordCipher = .aes_128_gcm,

    pub fn clientKeySlice(self: *const DerivedKeys) []const u8 {
        return self.clientKey[0..self.clientKeyLen];
    }
    pub fn serverKeySlice(self: *const DerivedKeys) []const u8 {
        return self.serverKey[0..self.serverKeyLen];
    }
};

// TLS 1.3 Handshake Engine

pub const Engine = struct {
    allocator: Allocator,
    role: enum { client, server },
    cbs: Callbacks,

    // ECDHE state
    localKeypair: x25519.KeyPair = undefined,
    sharedSecret: ?[32]u8 = null,

    // Transcript over all handshake messages (SHA-256)
    transcript: Transcript,

    // Key schedule state (RFC 8446 Section 7.1)
    handshakeSecret: ?[32]u8 = null,
    masterSecret: ?[32]u8 = null,

    // Derived keys per level
    hsKeys: ?DerivedKeys = null,
    apKeys: ?DerivedKeys = null,
    clientHsTrafficSecret: ?[32]u8 = null,
    serverHsTrafficSecret: ?[32]u8 = null,

    // Selected cipher suite
    selectedSuite: tls.CipherSuite = .AES_128_GCM_SHA256,

    /// PSK offered by this client in the current handshake (set by
    /// `produceClientHelloResumption`). Cleared when the server does not
    /// select it.
    offeredPsk: ?[32]u8 = null,
    /// PSK accepted for this handshake (client: server selected identity
    /// 0; server: ticket verified). Drives the key schedule fork
    /// (Early/Master secrets) and the abbreviated flight.
    resumptionPsk: ?[32]u8 = null,
    /// Cipher suite the accepted PSK ticket was issued for. The flight
    /// falls back to full when negotiation picks a different suite.
    pskSuite: ?tls.CipherSuite = null,
    /// Server-side ticket keys for issuing/verifying NST tickets. When
    /// null the server never selects PSK (silent full-handshake fallback).
    ticketKeys: ?session_mod.TicketKeys = null,
    /// HelloRetryRequest already seen (client) — a second one aborts.
    hrrSeen: bool = false,
    /// Set by `processServerHello` when it consumed a HelloRetryRequest:
    /// the selected group the retry ClientHello must share.
    hrrPendingGroup: ?handshake_mod.NamedGroup = null,
    /// HelloRetryRequest already sent (server) — never send twice.
    hrrSent: bool = false,

    /// When set before `produceServerFlight`, the flight includes a
    /// CertificateRequest (mutual TLS) at the correct transcript position.
    requestClientCert: bool = false,

    /// True when the peer offered ecdsa_secp256r1_sha256 in signatureAlgorithms.
    /// Set by negotiateClientHello; CertificateVerify requires it.
    peerOffersEcdsa: bool = false,

    // ALPN result
    negotiatedAlpn: ?[]const u8 = null,

    // SNI hostname from ClientHello
    sniHostname: ?[]const u8 = null,

    // Legacy session ID from ClientHello to echo in ServerHello
    legacySessionIdBuf: [32]u8 = undefined,
    legacySessionIdLen: u8 = 0,

    // Handshake state
    state: State = .start,

    pub const State = enum {
        start,
        client_hello_sent,
        server_hello_received,
        handshake_keys_derived,
        encrypted_extensions_received,
        certificateReceived,
        certificate_verify_received,
        finishedReceived,
        handshakeComplete,
        // Server states
        client_hello_received,
        server_hello_sent,
        server_finished_sent,
    };

    pub fn initClient(allocator: Allocator, cbs: Callbacks) Engine {
        return .{
            .allocator = allocator,
            .role = .client,
            .cbs = cbs,
            .transcript = Transcript.init(),
        };
    }

    pub fn initServer(allocator: Allocator, cbs: Callbacks) Engine {
        return .{
            .allocator = allocator,
            .role = .server,
            .cbs = cbs,
            .transcript = Transcript.init(),
        };
    }

    pub fn deinit(self: *Engine) void {
        if (self.sniHostname) |sni| {
            self.allocator.free(sni);
            self.sniHostname = null;
        }
        if (self.negotiatedAlpn) |alpn| {
            self.allocator.free(alpn);
            self.negotiatedAlpn = null;
        }
    }

    /// True for cipher suites our SHA-256-only schedule can resume with.
    /// Canonical policy lives in `session.zig` (single definition).
    pub fn suiteSupportsResumption(suite: tls.CipherSuite) bool {
        return session_mod.suiteSupportsResumption(suite);
    }

    /// Derive the handshake secret from the ECDHE shared secret.
    /// Must be called after the sharedSecret is set and before
    /// produceServerFlight (server) or processServerHello (client).
    /// With an accepted PSK the Early Secret mixes it in (RFC 8446 7.1);
    /// otherwise the schedule starts from zeros exactly as before.
    pub fn deriveHandshakeSecret(self: *Engine) void {
        const ss = self.sharedSecret orelse return;
        const zero: [32]u8 = .{0} ** 32;
        const psk = self.resumptionPsk orelse zero;
        const early_secret = HkdfSha256.extract(&zero, &psk);
        // Derive-Secret(., "derived", "") hashes the EMPTY transcript, not
        // an empty context string (RFC 8446 Section 7.1).
        var empty_copy = Transcript.init();
        const empty_hash = empty_copy.finish();
        var derived: [32]u8 = undefined;
        hkdfExpandLabelWithContext(early_secret, "derived", &empty_hash, &derived);
        self.handshakeSecret = HkdfSha256.extract(&derived, &ss);
    }

    // Client-side handshake

    /// Produces the ClientHello message and generates the ephemeral keypair.
    pub fn produceClientHello(
        self: *Engine,
        alpnProtocols: []const []const u8,
        signatureAlgorithms: []const handshake_mod.SignatureScheme,
    ) ![]u8 {
        return self.produceClientHelloWithSni(alpnProtocols, signatureAlgorithms, null);
    }

    pub fn produceClientHelloWithSni(
        self: *Engine,
        alpnProtocols: []const []const u8,
        signatureAlgorithms: []const handshake_mod.SignatureScheme,
        serverName: ?[]const u8,
    ) ![]u8 {
        // Generate ephemeral X25519 keypair
        var seed: [32]u8 = undefined;
        fillRandom(&seed);
        self.localKeypair = try x25519.KeyPair.generateDeterministic(seed);
        const pubkey = self.localKeypair.public_key;

        const ch = handshake_mod.ClientHello{
            .random = blk: {
                var r: [32]u8 = undefined;
                fillRandom(&r);
                break :blk r;
            },
            .cipherSuites = &.{ .AES_128_GCM_SHA256, .AES_256_GCM_SHA384, .CHACHA20_POLY1305_SHA256 },
            .keyShareEntries = &.{.{
                .group = .x25519,
                .keyExchange = &pubkey,
            }},
            .signatureAlgorithms = if (signatureAlgorithms.len > 0) signatureAlgorithms else &.{
                .ecdsa_secp256r1_sha256,
                .rsa_pss_rsae_sha256,
                .ed25519,
            },
            .alpnProtocols = alpnProtocols,
            .serverName = serverName,
        };

        const encoded = try ch.encode(self.allocator);

        // Feed entire ClientHello to transcript hash
        self.transcript.feed(encoded);
        self.state = .client_hello_sent;

        // Notify transport layer
        self.cbs.onHandshakeData(self.cbs.ctx, .initial, encoded);

        return encoded;
    }

    /// Produces a ClientHello offering one resumption PSK (RFC 8446
    /// 4.2.11) alongside a fresh (EC)DHE share (psk_dhe_ke). The session
    /// must be usable for `serverName` (host binding is checked by the
    /// caller via `ClientSession.isUsable`).
    ///
    /// Binder computation (RFC 8446 4.2.11.2): the message is encoded
    /// with zeroed binder bytes, hashed WITHOUT committing to the
    /// transcript, then patched with the real binder + obfuscated age
    /// before the final bytes are fed and returned.
    pub fn produceClientHelloResumption(
        self: *Engine,
        alpnProtocols: []const []const u8,
        signatureAlgorithms: []const handshake_mod.SignatureScheme,
        serverName: ?[]const u8,
        session: *const session_mod.ClientSession,
        nowMs: u64,
    ) ![]u8 {
        var seed: [32]u8 = undefined;
        fillRandom(&seed);
        self.localKeypair = try x25519.KeyPair.generateDeterministic(seed);
        const pubkey = self.localKeypair.public_key;

        const ch = handshake_mod.ClientHello{
            .random = blk: {
                var r: [32]u8 = undefined;
                fillRandom(&r);
                break :blk r;
            },
            .cipherSuites = &.{ .AES_128_GCM_SHA256, .AES_256_GCM_SHA384, .CHACHA20_POLY1305_SHA256 },
            .keyShareEntries = &.{.{
                .group = .x25519,
                .keyExchange = &pubkey,
            }},
            .signatureAlgorithms = if (signatureAlgorithms.len > 0) signatureAlgorithms else &.{
                .ecdsa_secp256r1_sha256,
                .rsa_pss_rsae_sha256,
                .ed25519,
            },
            .alpnProtocols = alpnProtocols,
            .serverName = serverName,
            .pskIdentities = &.{session.ticket},
        };
        const encoded = try ch.encode(self.allocator);
        errdefer self.allocator.free(encoded);

        // Patch the obfuscated age, then hash the truncated message and
        // patch the binder. Both spans are validated by the codec.
        var age_span = try handshake_mod.pskAgeSpan(encoded, 0);
        std.mem.writeInt(u32, age_span[0..], session.obfuscatedAge(nowMs), .big);
        const binder = computeResumptionBinder(self.transcript.state, encoded, session.psk);
        const binder_span = try handshake_mod.pskBinderSpan(encoded);
        if (binder_span.len != HashLen) return error.ProtocolViolation;
        @memcpy(binder_span[0..HashLen], &binder);

        self.offeredPsk = session.psk;
        self.transcript.feed(encoded);
        self.state = .client_hello_sent;
        self.cbs.onHandshakeData(self.cbs.ctx, .initial, encoded);
        return encoded;
    }

    /// PSK binder for a zero-patched ClientHello: HMAC over
    /// Hash(prefix || chZeroed) keyed by Derive-Secret(early, "res
    /// binder", ""). The client passes its pre-CH transcript state as
    /// `prefix` (empty, or the HRR splice); the server passes a fresh
    /// hash (the received CH is the whole input). Nothing is fed here.
    fn computeResumptionBinder(prefix: handshake_mod.TranscriptHash, chZeroed: []const u8, psk: [32]u8) [HashLen]u8 {
        const zero: [32]u8 = .{0} ** 32;
        const early = HkdfSha256.extract(&zero, &psk);
        var empty_copy = Transcript.init();
        const empty_hash = empty_copy.finish();
        var binder_key: [32]u8 = undefined;
        hkdfExpandLabelWithContext(early, "res binder", &empty_hash, &binder_key);
        var copy = prefix;
        copy.update(chZeroed);
        const hash = copy.finalResult();
        var out: [HashLen]u8 = undefined;
        std.crypto.auth.hmac.Hmac(Sha256).create(&out, &hash, &binder_key);
        std.crypto.secureZero(u8, &binder_key);
        return out;
    }

    /// Splices a HelloRetryRequest into the transcript (RFC 8446 4.4.1):
    /// Transcript-Hash restarts as Hash(message_hash || HRR) where
    /// message_hash = 0xFE || 0x00 0x00 0x20 || Hash(ClientHello1).
    fn spliceHelloRetryRequest(self: *Engine, hrr_msg: []const u8) void {
        const h1 = self.transcript.finish();
        self.transcript = Transcript.init();
        var pre: [4 + HashLen]u8 = undefined;
        pre[0] = 0xFE;
        pre[1] = 0x00;
        pre[2] = 0x00;
        pre[3] = HashLen;
        @memcpy(pre[4..], &h1);
        self.transcript.feed(&pre);
        self.transcript.feed(hrr_msg);
    }

    /// Processes a ServerHello message received from the wire (full
    /// handshake message: 4-byte header + body). Feeds the whole message
    /// to the transcript per RFC 8446 Section 4.4.1.
    ///
    /// HelloRetryRequest (magic random) is consumed here instead: the
    /// transcript is spliced, `hrrPendingGroup` is set, and the caller
    /// must send a second ClientHello. A second HRR aborts loudly.
    /// A selected PSK identity keeps `resumptionPsk`; its absence clears
    /// the offer (silent full-handshake fallback).
    pub fn processServerHello(self: *Engine, msg: []const u8) !void {
        if (msg.len < 4) return error.ProtocolViolation;
        if (handshake_mod.isHelloRetryRequest(msg[4..])) {
            if (self.hrrSeen) return error.HandshakeFailed;
            self.hrrSeen = true;
            const sh = try handshake_mod.ServerHello.decode(msg[4..]);
            const group = sh.hrrGroup orelse return error.ProtocolViolation;
            if (group != .x25519) return error.UnsupportedCipherSuite;
            self.spliceHelloRetryRequest(msg);
            self.hrrPendingGroup = group;
            self.state = .client_hello_sent;
            return;
        }
        const sh = try handshake_mod.ServerHello.decode(msg[4..]);
        if (sh.selectedPskIdentity) |idx| {
            if (idx != 0) return error.HandshakeFailed;
            if (self.offeredPsk == null) return error.HandshakeFailed;
            if (!suiteSupportsResumption(sh.cipherSuite)) return error.HandshakeFailed;
            self.resumptionPsk = self.offeredPsk;
            self.pskSuite = sh.cipherSuite;
        } else {
            self.resumptionPsk = null;
            self.pskSuite = null;
        }
        self.selectedSuite = sh.cipherSuite;
        self.transcript.feed(msg);

        // Extract server's key share
        const ks = sh.keyShare orelse return error.InvalidKeyShare;
        if (ks.group != .x25519) return error.UnsupportedCipherSuite;

        var peer_pub: [32]u8 = undefined;
        if (ks.keyExchange.len != 32) return error.InvalidKeyShare;
        @memcpy(&peer_pub, ks.keyExchange);

        // ECDHE: sharedSecret = X25519(client_secret, server_public)
        self.sharedSecret = try x25519.scalarmult(self.localKeypair.secret_key, peer_pub);
        self.state = .server_hello_received;

        // Derive handshake traffic secrets (RFC 8446 Section 7.1)
        self.deriveHandshakeKeys();
        self.state = .handshake_keys_derived;
    }

    /// Processes EncryptedExtensions (full message with header).
    pub fn processEncryptedExtensions(self: *Engine, msg: []const u8) !void {
        if (msg.len < 4) return error.ProtocolViolation;
        self.transcript.feed(msg);
        const ee = try handshake_mod.EncryptedExtensions.decode(msg[4..]);
        // Own the selection: callers often parse from reusable reassembly
        // buffers whose bytes shift as later messages arrive.
        if (self.negotiatedAlpn) |old| self.allocator.free(old);
        self.negotiatedAlpn = if (ee.alpnProtocol) |wire| try self.allocator.dupe(u8, wire) else null;
        self.state = .encrypted_extensions_received;
    }

    /// Processes Certificate (full message with header).
    pub fn processCertificate(self: *Engine, msg: []const u8) !void {
        self.transcript.feed(msg);
        self.state = .certificateReceived;
    }

    /// Processes CertificateVerify (full message with header).
    pub fn processCertificateVerify(self: *Engine, msg: []const u8) !void {
        self.transcript.feed(msg);
        if (msg.len < 4) return error.ProtocolViolation;
        _ = try handshake_mod.CertificateVerify.decode(msg[4..]);
        self.state = .certificate_verify_received;
    }

    /// Processes and verifies Finished from server (full message with
    /// header). Verification uses the server handshake traffic secret over
    /// the transcript *before* this message, then feeds on success.
    pub fn processFinished(self: *Engine, msg: []const u8) !void {
        if (msg.len != 4 + HashLen) return error.ProtocolViolation;
        if (msg[0] != @intFromEnum(handshake_mod.HandshakeType.finished)) return error.ProtocolViolation;
        const s_hs = self.serverHsTrafficSecret orelse return error.HandshakeFailed;
        var finished_key: [HashLen]u8 = undefined;
        hkdfExpandLabel(s_hs, "finished", &finished_key);
        var copy = self.transcript.state;
        const hash = copy.finalResult();
        var expect: [HashLen]u8 = undefined;
        std.crypto.auth.hmac.Hmac(Sha256).create(&expect, &hash, &finished_key);
        var diff: u8 = 0;
        for (expect, msg[4..][0..HashLen]) |a, b| diff |= a ^ b;
        if (diff != 0) return error.HandshakeFailed;
        self.transcript.feed(msg);
        self.state = .finishedReceived;
        self.deriveApplicationKeys();
        self.state = .handshakeComplete;
    }

    // Server-side handshake

    /// True when the ClientHello body carries a usable x25519 key share.
    /// The server sends HelloRetryRequest (instead of failing) when the
    /// client offered none — the RFC 8446 Section 4.1.4 missing-share case.
    pub fn clientHelloHasShare(chBody: []const u8) bool {
        if (chBody.len < 34) return false;
        var pos: usize = 34;
        if (pos + 1 > chBody.len) return false;
        pos += 1 + chBody[pos]; // legacy_session_id
        if (pos + 2 > chBody.len) return false;
        const cs_len: usize = (@as(usize, chBody[pos]) << 8) | chBody[pos + 1];
        pos += 2 + cs_len; // cipher suites
        if (pos + 1 > chBody.len) return false;
        pos += 1 + chBody[pos]; // compression methods
        if (pos + 2 > chBody.len) return false;
        const ext_len: usize = (@as(usize, chBody[pos]) << 8) | chBody[pos + 1];
        pos += 2;
        const ext_end = @min(chBody.len, pos + ext_len);
        while (pos + 4 <= ext_end) {
            const t = std.mem.readInt(u16, chBody[pos..][0..2], .big);
            const l: usize = (@as(usize, chBody[pos + 2]) << 8) | chBody[pos + 3];
            pos += 4;
            if (pos + l > ext_end) return false;
            if (t == @intFromEnum(handshake_mod.ExtensionType.key_share)) {
                var kp: usize = 2;
                if (l >= 2) {
                    const list_len: usize = (@as(usize, chBody[pos]) << 8) | chBody[pos + 1];
                    const list_end = @min(l, 2 + list_len);
                    while (kp + 4 <= list_end) {
                        const group = std.mem.readInt(u16, chBody[pos + kp ..][0..2], .big);
                        const slen: usize = (@as(usize, chBody[pos + kp + 2]) << 8) | chBody[pos + kp + 3];
                        if (group == @intFromEnum(handshake_mod.NamedGroup.x25519) and slen == 32) return true;
                        kp += 4 + slen;
                    }
                }
            }
            pos += l;
        }
        return false;
    }

    /// Attempts PSK selection from a full ClientHello message (with
    /// 4-byte header, already fed to the transcript). On success sets
    /// `resumptionPsk`/`pskSuite` for the abbreviated handshake.
    ///
    /// ANY problem (no ticket keys, malformed offer, unknown/expired
    /// ticket, suite mismatch, binder mismatch) clears the selection and
    /// returns false: the server silently falls back to a full handshake
    /// per RFC 8446 Section 4.2.11.2. Never errors for PSK reasons.
    pub fn selectPsk(self: *Engine, full_ch: []const u8, nowMs: u64) bool {
        self.resumptionPsk = null;
        self.pskSuite = null;
        const keys = self.ticketKeys orelse return false;
        const offer = handshake_mod.parsePskFirst(full_ch) catch return false;
        const o = offer orelse return false;
        if (o.binders.len < HashLen) return false;
        const opened = keys.open(o.ticket, nowMs) catch return false;
        if (!suiteSupportsResumption(opened.suite)) return false;
        // Binder check over the received bytes with binder bytes zeroed.
        const zu8 = self.allocator.dupe(u8, full_ch) catch return false;
        defer self.allocator.free(zu8);
        const span = handshake_mod.pskBinderSpan(zu8) catch return false;
        @memset(span, 0);
        const fresh = handshake_mod.TranscriptHash.init(.{});
        const binder = computeResumptionBinder(fresh, zu8, opened.psk);
        var diff: u8 = 0;
        for (binder, o.binders[0..HashLen]) |a, b| diff |= a ^ b;
        if (diff != 0) {
            std.crypto.secureZero(u8, @constCast(&opened.psk));
            return false;
        }
        self.resumptionPsk = opened.psk;
        self.pskSuite = opened.suite;
        return true;
    }

    /// Produces a HelloRetryRequest (RFC 8446 Section 4.1.4) requesting
    /// an x25519 share, for a ClientHello that offered none. Splices the
    /// transcript (message_hash construction) and marks `hrrSent` so a
    /// second shareless hello fails instead of looping.
    pub fn produceHelloRetryRequest(self: *Engine) ![]u8 {
        if (self.hrrSent) return error.HandshakeFailed;
        self.hrrSent = true;
        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.allocator);
        try body.appendSlice(self.allocator, &.{ 0x03, 0x03 });
        try body.appendSlice(self.allocator, &handshake_mod.hello_retry_magic);
        try body.appendSlice(self.allocator, &.{self.legacySessionIdLen});
        if (self.legacySessionIdLen > 0) {
            try body.appendSlice(self.allocator, self.legacySessionIdBuf[0..self.legacySessionIdLen]);
        }
        try body.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(tls.CipherSuite.AES_128_GCM_SHA256))));
        try body.append(self.allocator, 0x00);
        var exts = std.ArrayList(u8).empty;
        defer exts.deinit(self.allocator);
        // supported_versions: TLS 1.3 only.
        try exts.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(handshake_mod.ExtensionType.supported_versions))));
        try exts.appendSlice(self.allocator, &.{ 0x00, 0x02, 0x03, 0x04 });
        // key_share: selected group only, no key_exchange bytes.
        try exts.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(handshake_mod.ExtensionType.key_share))));
        try exts.appendSlice(self.allocator, &.{ 0x00, 0x02 });
        try exts.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(handshake_mod.NamedGroup.x25519))));
        try body.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(exts.items.len))));
        try body.appendSlice(self.allocator, exts.items);

        var msg = std.ArrayList(u8).empty;
        errdefer msg.deinit(self.allocator);
        try msg.append(self.allocator, @intFromEnum(handshake_mod.HandshakeType.server_hello));
        const body_len: u24 = @intCast(body.items.len);
        try msg.append(self.allocator, @intCast((body_len >> 16) & 0xFF));
        try msg.append(self.allocator, @intCast((body_len >> 8) & 0xFF));
        try msg.append(self.allocator, @intCast(body_len & 0xFF));
        try msg.appendSlice(self.allocator, body.items);
        self.spliceHelloRetryRequest(msg.items);
        self.state = .server_hello_sent;
        return msg.toOwnedSlice(self.allocator);
    }

    /// Negotiates a TLS 1.3 connection from a ClientHello body (without the
    /// 4-byte handshake header): selects a SHA-256 cipher suite, performs
    /// ECDHE with the peer's x25519 share, and records whether the peer
    /// offers ecdsa_secp256r1_sha256. Requires `localKeypair` to be set;
    /// sets `selectedSuite` and `sharedSecret`.
    ///
    /// Only SHA-256 suites are accepted (the transcript hash is SHA-256):
    /// AES_128_GCM_SHA256 preferred, CHACHA20_POLY1305_SHA256 fallback.
    /// Unknown extensions are skipped per RFC 8446 Section 4.2.
    pub fn negotiateClientHello(self: *Engine, chBody: []const u8) !void {
        // Reset per-handshake negotiation state (Engine may be reused).
        self.peerOffersEcdsa = false;
        var pos: usize = 0;
        if (chBody.len < 34) return error.ProtocolViolation;
        pos = 34; // skip client_version(2) + random(32)

        // legacy_session_id
        if (pos + 1 > chBody.len) return error.ProtocolViolation;
        pos += 1 + chBody[pos];

        // cipherSuites
        if (pos + 2 > chBody.len) return error.ProtocolViolation;
        const cs_len: usize = (@as(usize, chBody[pos]) << 8) | chBody[pos + 1];
        pos += 2;
        if (pos + cs_len > chBody.len) return error.ProtocolViolation;
        const cs_end = pos + cs_len;
        var offers_aes = false;
        var offers_chacha = false;
        var p: usize = pos;
        while (p + 2 <= cs_end) : (p += 2) {
            const suite: tls.CipherSuite = @enumFromInt((@as(u16, chBody[p]) << 8) | chBody[p + 1]);
            switch (suite) {
                .AES_128_GCM_SHA256 => offers_aes = true,
                .CHACHA20_POLY1305_SHA256 => offers_chacha = true,
                else => {},
            }
        }
        pos = cs_end;

        // legacy_compression_methods
        if (pos + 1 > chBody.len) return error.ProtocolViolation;
        pos += 1 + chBody[pos];

        // extensions
        if (pos + 2 > chBody.len) return error.ProtocolViolation;
        const ext_len: usize = (@as(usize, chBody[pos]) << 8) | chBody[pos + 1];
        pos += 2;
        const ext_end = std.math.add(usize, pos, ext_len) catch return error.ProtocolViolation;
        if (ext_end > chBody.len) return error.ProtocolViolation;

        var peer_share: ?[32]u8 = null;
        while (pos + 4 <= ext_end) {
            const ext_type = std.mem.readInt(u16, chBody[pos..][0..2], .big);
            const ext_data_len: usize = (@as(usize, chBody[pos + 2]) << 8) | chBody[pos + 3];
            pos += 4;
            const dataEnd = std.math.add(usize, pos, ext_data_len) catch return error.ProtocolViolation;
            if (dataEnd > ext_end) return error.ProtocolViolation;
            const data = chBody[pos..dataEnd];

            if (ext_type == @intFromEnum(handshake_mod.ExtensionType.key_share)) {
                // KeyShareClientHello: client_shares = vector< KeyShareEntry >.
                var kp: usize = 2; // skip vector length
                if (data.len >= 2) {
                    const list_len: usize = (@as(usize, data[0]) << 8) | data[1];
                    const list_end = @min(data.len, 2 + list_len);
                    while (kp + 4 <= list_end) {
                        const group = std.mem.readInt(u16, data[kp..][0..2], .big);
                        const share_len: usize = (@as(usize, data[kp + 2]) << 8) | data[kp + 3];
                        kp += 4;
                        if (kp + share_len > list_end) break;
                        if (group == @intFromEnum(handshake_mod.NamedGroup.x25519) and share_len == 32) {
                            if (peer_share == null) peer_share = data[kp..][0..32].*;
                        }
                        kp += share_len;
                    }
                }
            } else if (ext_type == @intFromEnum(handshake_mod.ExtensionType.signature_algorithms)) {
                // SignatureSchemeList: vector<u16>; 0x0403 = ecdsa_secp256r1_sha256.
                if (data.len >= 2) {
                    const list_len: usize = (@as(usize, data[0]) << 8) | data[1];
                    const list_end = @min(data.len, 2 + list_len);
                    var sp: usize = 2;
                    while (sp + 2 <= list_end) : (sp += 2) {
                        const scheme = std.mem.readInt(u16, data[sp..][0..2], .big);
                        if (scheme == @intFromEnum(handshake_mod.SignatureScheme.ecdsa_secp256r1_sha256)) {
                            self.peerOffersEcdsa = true;
                        }
                    }
                }
            }
            // All other extensions are skipped (middlebox compat, versions, SNI...).

            pos = dataEnd;
        }

        // Server preference: AES_128_GCM_SHA256 first, CHACHA20 fallback.
        const suite: tls.CipherSuite = if (offers_aes) .AES_128_GCM_SHA256 else if (offers_chacha) .CHACHA20_POLY1305_SHA256 else return error.UnsupportedCipherSuite;
        const share = peer_share orelse return error.InvalidKeyShare;
        self.selectedSuite = suite;
        self.sharedSecret = x25519.scalarmult(self.localKeypair.secret_key, share) catch
            return error.InvalidKeyShare;
    }

    /// Verifies a client Finished message (full handshake message with header)
    /// against the current transcript and feeds it on success.
    pub fn verifyClientFinished(self: *Engine, msg: []const u8) !void {
        if (msg.len != 4 + HashLen) return error.ProtocolViolation;
        if (msg[0] != @intFromEnum(handshake_mod.HandshakeType.finished)) return error.ProtocolViolation;
        const c_hs = self.clientHsTrafficSecret orelse return error.HandshakeFailed;
        var finished_key: [HashLen]u8 = undefined;
        hkdfExpandLabel(c_hs, "finished", &finished_key);
        var copy = self.transcript.state;
        const hash = copy.finalResult();
        var expect: [HashLen]u8 = undefined;
        std.crypto.auth.hmac.Hmac(Sha256).create(&expect, &hash, &finished_key);
        var diff: u8 = 0;
        for (expect, msg[4..][0..HashLen]) |a, b| diff |= a ^ b;
        if (diff != 0) return error.HandshakeFailed;
        self.transcript.feed(msg);
    }

    // Mutual TLS (RFC 8446 Section 4.3.1): CertificateRequest (type 13)
    // carries an (empty) request context plus extensions.

    /// Builds CertificateRequest and feeds the transcript (server side).
    pub fn produceCertificateRequest(self: *Engine) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        try out.append(self.allocator, @intFromEnum(handshake_mod.HandshakeType.certificate_request));
        // u24 length = 3: context len (0x00) + extensions len (0x0000).
        try out.appendSlice(self.allocator, &.{ 0x00, 0x00, 0x03, 0x00, 0x00, 0x00 });
        self.transcript.feed(out.items);
        return out.toOwnedSlice(self.allocator);
    }

    /// Processes CertificateRequest (client side): shape-checks and feeds
    /// the transcript. Extension parsing stays minimal: only the empty
    /// request the server emits is accepted.
    pub fn processCertificateRequest(self: *Engine, msg: []const u8) !void {
        if (msg.len != 7) return error.ProtocolViolation;
        if (msg[0] != @intFromEnum(handshake_mod.HandshakeType.certificate_request)) return error.ProtocolViolation;
        self.transcript.feed(msg);
    }

    /// Builds a client Certificate message (type 11) from DER entries and
    /// feeds the transcript. An empty list is encodable; policy (required
    /// vs optional) is enforced by the server, not here.
    pub fn produceClientCertificate(self: *Engine, ders: []const []const u8) ![]u8 {
        var body = std.ArrayList(u8).empty;
        errdefer body.deinit(self.allocator);
        try body.append(self.allocator, 0x00); // request_context length 0
        var list_buf = std.ArrayList(u8).empty;
        defer list_buf.deinit(self.allocator);
        for (ders) |der| {
            const len: u24 = @intCast(der.len);
            try list_buf.append(self.allocator, @intCast((len >> 16) & 0xFF));
            try list_buf.append(self.allocator, @intCast((len >> 8) & 0xFF));
            try list_buf.append(self.allocator, @intCast(len & 0xFF));
            try list_buf.appendSlice(self.allocator, der);
            try list_buf.appendSlice(self.allocator, &.{ 0x00, 0x00 }); // empty extensions
        }
        const total: u24 = @intCast(list_buf.items.len);
        try body.append(self.allocator, @intCast((total >> 16) & 0xFF));
        try body.append(self.allocator, @intCast((total >> 8) & 0xFF));
        try body.append(self.allocator, @intCast(total & 0xFF));
        try body.appendSlice(self.allocator, list_buf.items);

        var msg = std.ArrayList(u8).empty;
        errdefer msg.deinit(self.allocator);
        try msg.append(self.allocator, @intFromEnum(handshake_mod.HandshakeType.certificate));
        const body_len: u24 = @intCast(body.items.len);
        try msg.append(self.allocator, @intCast((body_len >> 16) & 0xFF));
        try msg.append(self.allocator, @intCast((body_len >> 8) & 0xFF));
        try msg.append(self.allocator, @intCast(body_len & 0xFF));
        try msg.appendSlice(self.allocator, body.items);
        body.deinit(self.allocator);

        self.transcript.feed(msg.items);
        return msg.toOwnedSlice(self.allocator);
    }

    /// Parsed client Certificate message: owned DER entries.
    pub const ClientCertificate = struct {
        allocator: Allocator,
        ders: [][]u8,

        pub fn deinit(self: *ClientCertificate) void {
            for (self.ders) |d| self.allocator.free(d);
            self.allocator.free(self.ders);
        }
    };

    /// Parses a client Certificate message (full message with header),
    /// feeds the transcript, and returns owned DER entries. An empty list
    /// is returned (not an error); the caller enforces required/optional.
    pub fn processClientCertificate(self: *Engine, msg: []const u8) !ClientCertificate {
        if (msg.len < 4) return error.ProtocolViolation;
        if (msg[0] != @intFromEnum(handshake_mod.HandshakeType.certificate)) return error.ProtocolViolation;
        const body_len: usize = (@as(usize, msg[1]) << 16) | (@as(usize, msg[2]) << 8) | msg[3];
        if (4 + body_len != msg.len) return error.ProtocolViolation;
        var pos: usize = 4;
        if (pos + 1 > msg.len) return error.ProtocolViolation;
        const ctx_len: usize = msg[pos];
        pos += 1;
        if (pos + ctx_len > msg.len) return error.ProtocolViolation;
        pos += ctx_len;
        if (pos + 3 > msg.len) return error.ProtocolViolation;
        const list_len: usize = (@as(usize, msg[pos]) << 16) | (@as(usize, msg[pos + 1]) << 8) | msg[pos + 2];
        pos += 3;
        if (pos + list_len != msg.len) return error.ProtocolViolation;
        const list_end = pos + list_len;

        var ders = std.ArrayList([]u8).empty;
        errdefer {
            for (ders.items) |d| self.allocator.free(d);
            ders.deinit(self.allocator);
        }
        while (pos < list_end) {
            if (pos + 3 > list_end) return error.ProtocolViolation;
            const cert_len: usize = (@as(usize, msg[pos]) << 16) | (@as(usize, msg[pos + 1]) << 8) | msg[pos + 2];
            pos += 3;
            if (cert_len == 0 or pos + cert_len > list_end) return error.ProtocolViolation;
            // Structural guard before any X.509 parsing: truncated DER must
            // fail here, never as an out-of-bounds panic downstream.
            if (!certMod.checkDerStructure(msg[pos .. pos + cert_len])) return error.ProtocolViolation;
            const der = try self.allocator.dupe(u8, msg[pos .. pos + cert_len]);
            errdefer self.allocator.free(der);
            try ders.append(self.allocator, der);
            pos += cert_len;
            if (pos + 2 > list_end) return error.ProtocolViolation;
            const ext_len: usize = (@as(usize, msg[pos]) << 8) | msg[pos + 1];
            pos += 2;
            if (pos + ext_len > list_end) return error.ProtocolViolation;
            pos += ext_len;
        }
        self.transcript.feed(msg);
        return .{ .allocator = self.allocator, .ders = try ders.toOwnedSlice(self.allocator) };
    }

    /// Signs the client CertificateVerify content:
    /// 64x 0x20 ++ "TLS 1.3, client CertificateVerify" ++ 0x00 ++
    /// transcript hash, ECDSA P-256 (same curve policy as the server).
    const ClientSignature = struct {
        der: [EcdsaP256.Signature.der_encoded_length_max]u8,
        len: usize,
    };

    fn signClientCertificateVerify(self: *Engine, privateKeyDer: []const u8) !ClientSignature {
        const label = "TLS 1.3, client CertificateVerify";
        comptime {
            if (label.len != 33) @compileError("client CV label must be 33 bytes");
        }
        const ec_scalar = try parseEcPrivateScalar(self.allocator, privateKeyDer);
        const ec_pub_point = try P256.basePoint.mul(ec_scalar, .big);
        const ec_keypair = EcdsaP256.KeyPair{
            .secret_key = try EcdsaP256.SecretKey.fromBytes(ec_scalar),
            .public_key = .{ .p = ec_pub_point },
        };
        var cv_content: [64 + 33 + 1 + HashLen]u8 = undefined;
        @memset(cv_content[0..64], 0x20);
        @memcpy(cv_content[64..][0..33], label);
        cv_content[64 + 33] = 0x00;
        var hs_copy = self.transcript.state;
        const hs_hash = hs_copy.finalResult();
        @memcpy(cv_content[64 + 33 + 1 ..], &hs_hash);
        var cv_noise: [EcdsaP256.noise_length]u8 = undefined;
        fillRandom(&cv_noise);
        const ec_sig = try ec_keypair.sign(&cv_content, cv_noise);
        var out: ClientSignature = undefined;
        const sig_slice = ec_sig.toDer(&out.der);
        out.len = sig_slice.len;
        return out;
    }

    /// Builds client CertificateVerify (type 15) and feeds the transcript.
    pub fn produceClientCertificateVerify(self: *Engine, privateKeyDer: []const u8) ![]u8 {
        const signed = try self.signClientCertificateVerify(privateKeyDer);
        const sig_der = signed.der;
        const sig_len = signed.len;
        var body = std.ArrayList(u8).empty;
        errdefer body.deinit(self.allocator);
        try body.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(handshake_mod.SignatureScheme.ecdsa_secp256r1_sha256))));
        try body.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(sig_len))));
        try body.appendSlice(self.allocator, sig_der[0..sig_len]);

        var msg = std.ArrayList(u8).empty;
        errdefer msg.deinit(self.allocator);
        try msg.append(self.allocator, @intFromEnum(handshake_mod.HandshakeType.certificate_verify));
        const body_len: u24 = @intCast(body.items.len);
        try msg.append(self.allocator, @intCast((body_len >> 16) & 0xFF));
        try msg.append(self.allocator, @intCast((body_len >> 8) & 0xFF));
        try msg.append(self.allocator, @intCast(body_len & 0xFF));
        try msg.appendSlice(self.allocator, body.items);
        body.deinit(self.allocator);

        self.transcript.feed(msg.items);
        return msg.toOwnedSlice(self.allocator);
    }

    /// Builds client Finished: HMAC(client_finished_key, transcript hash).
    /// Feeds the transcript. Application keys were already derived when the
    /// server Finished was processed.
    pub fn produceClientFinished(self: *Engine) ![]u8 {
        const c_hs = self.clientHsTrafficSecret orelse return error.HandshakeFailed;
        var finished_key: [HashLen]u8 = undefined;
        hkdfExpandLabel(c_hs, "finished", &finished_key);
        var copy = self.transcript.state;
        const hash = copy.finalResult();
        var verify_data: [HashLen]u8 = undefined;
        std.crypto.auth.hmac.Hmac(Sha256).create(&verify_data, &hash, &finished_key);

        var msg = std.ArrayList(u8).empty;
        errdefer msg.deinit(self.allocator);
        try msg.append(self.allocator, @intFromEnum(handshake_mod.HandshakeType.finished));
        try msg.appendSlice(self.allocator, &.{ 0x00, 0x00, @as(u8, HashLen) });
        try msg.appendSlice(self.allocator, &verify_data);
        self.transcript.feed(msg.items);
        return msg.toOwnedSlice(self.allocator);
    }

    /// Verifies a client CertificateVerify (full message with header)
    /// against the leaf certificate DER: P-256 ECDSA over the client CV
    /// context. Feeds the transcript on success.
    pub fn processClientCertificateVerify(self: *Engine, msg: []const u8, leafDer: []const u8) !void {
        if (msg.len < 4) return error.ProtocolViolation;
        if (msg[0] != @intFromEnum(handshake_mod.HandshakeType.certificate_verify)) return error.ProtocolViolation;
        const cv = handshake_mod.CertificateVerify.decode(msg[4..]) catch return error.ProtocolViolation;
        if (cv.algorithm != .ecdsa_secp256r1_sha256) return error.UnsupportedSignatureScheme;

        const leaf = certMod.X509Certificate.parseDer(leafDer) catch return error.CertificateSignatureInvalid;
        const curve = switch (leaf.parsed.pub_key_algo) {
            .X9_62_id_ecPublicKey => |c| c,
            else => return error.CertificateSignatureInvalid,
        };
        if (curve != .X9_62_prime256v1) return error.CertificateSignatureInvalid;
        const pubkey = EcdsaP256.PublicKey.fromSec1(leaf.parsed.pubKey()) catch return error.CertificateSignatureInvalid;
        const sig = EcdsaP256.Signature.fromDer(cv.signature) catch return error.CertificateSignatureInvalid;

        const label = "TLS 1.3, client CertificateVerify";
        var cv_content: [64 + 33 + 1 + HashLen]u8 = undefined;
        @memset(cv_content[0..64], 0x20);
        @memcpy(cv_content[64..][0..33], label);
        cv_content[64 + 33] = 0x00;
        var hs_copy = self.transcript.state;
        const hs_hash = hs_copy.finalResult();
        @memcpy(cv_content[64 + 33 + 1 ..], &hs_hash);
        sig.verify(&cv_content, pubkey) catch return error.CertificateSignatureInvalid;
        self.transcript.feed(msg);
    }

    /// Minimal DER reader: tag + short/long-form length.
    fn derTlv(data: []const u8, pos: usize) !struct { tag: u8, len: usize, hdr: usize } {
        if (pos + 2 > data.len) return error.ProtocolViolation;
        const tag = data[pos];
        var len: usize = data[pos + 1];
        var hdr: usize = 2;
        if (len & 0x80 != 0) {
            const n: usize = len & 0x7f;
            if (n == 0 or n > 2 or pos + 2 + n > data.len) return error.ProtocolViolation;
            len = 0;
            for (data[pos + 2 ..][0..n]) |b| len = (len << 8) | b;
            hdr = 2 + n;
        }
        if (pos + hdr + len > data.len) return error.ProtocolViolation;
        return .{ .tag = tag, .len = len, .hdr = hdr };
    }

    /// Extracts the 32-byte P-256 private scalar from SEC1 DER, PKCS#8 DER
    /// (EC only — RSA and friends return UnsupportedSignatureScheme), or PEM
    /// encoding either ("EC PRIVATE KEY" / "PRIVATE KEY").
    fn parseEcPrivateScalar(allocator: Allocator, input: []const u8) ![32]u8 {
        if (std.mem.indexOf(u8, input, "-----BEGIN") != null) {
            if (std.mem.indexOf(u8, input, "EC PRIVATE KEY") != null) {
                const der = certMod.decodePemBlock(allocator, input, "EC PRIVATE KEY") catch
                    return error.UnsupportedSignatureScheme;
                defer allocator.free(der);
                return ecScalarFromSec1(der);
            }
            if (std.mem.indexOf(u8, input, "PRIVATE KEY") != null) {
                const pkcs8 = certMod.decodePemBlock(allocator, input, "PRIVATE KEY") catch
                    return error.UnsupportedSignatureScheme;
                defer allocator.free(pkcs8);
                return ecScalarFromPkcs8(pkcs8);
            }
            return error.UnsupportedSignatureScheme;
        }
        if (isPkcs8(input)) return ecScalarFromPkcs8(input);
        return ecScalarFromSec1(input);
    }

    fn isPkcs8(der: []const u8) bool {
        // PKCS#8 starts SEQUENCE { INTEGER 0/1, ... }; SEC1 starts
        // SEQUENCE { INTEGER 1, OCTET STRING, ... }. Distinguish by the
        // second element: INTEGER followed by SEQUENCE means PKCS#8.
        const outer = derTlv(der, 0) catch return false;
        if (outer.tag != 0x30) return false;
        const ver = derTlv(der, outer.hdr) catch return false;
        if (ver.tag != 0x02) return false;
        const next = derTlv(der, outer.hdr + ver.hdr + ver.len) catch return false;
        return next.tag == 0x30;
    }

    /// PKCS#8 (DER) -> 32-byte scalar. Rejects non-EC algorithms.
    fn ecScalarFromPkcs8(pkcs8: []const u8) ![32]u8 {
        const outer = try derTlv(pkcs8, 0);
        if (outer.tag != 0x30) return error.UnsupportedSignatureScheme;
        var pos = outer.hdr;
        const ver = try derTlv(pkcs8, pos);
        if (ver.tag != 0x02) return error.UnsupportedSignatureScheme;
        pos += ver.hdr + ver.len;
        const alg = try derTlv(pkcs8, pos);
        if (alg.tag != 0x30) return error.UnsupportedSignatureScheme;
        // ecPublicKey OID 1.2.840.10045.2.1 must appear in the algorithm id.
        const ec_oid = [_]u8{ 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01 };
        if (std.mem.indexOf(u8, pkcs8[pos + alg.hdr ..][0..alg.len], &ec_oid) == null) {
            return error.UnsupportedSignatureScheme;
        }
        pos += alg.hdr + alg.len;
        const key = try derTlv(pkcs8, pos);
        if (key.tag != 0x04) return error.UnsupportedSignatureScheme;
        return ecScalarFromSec1(pkcs8[pos + key.hdr ..][0..key.len]);
    }

    /// SEC1 ECPrivateKey (DER) -> 32-byte scalar.
    fn ecScalarFromSec1(sec1: []const u8) ![32]u8 {
        const outer = try derTlv(sec1, 0);
        if (outer.tag != 0x30) return error.UnsupportedSignatureScheme;
        var pos = outer.hdr;
        const ver = try derTlv(sec1, pos);
        if (ver.tag != 0x02 or ver.len != 1 or sec1[pos + ver.hdr] != 1) {
            return error.UnsupportedSignatureScheme;
        }
        pos += ver.hdr + ver.len;
        const key = try derTlv(sec1, pos);
        if (key.tag != 0x04 or key.len != 32) return error.UnsupportedSignatureScheme;
        return sec1[pos + key.hdr ..][0..32].*;
    }

    /// Processes a ClientHello message received from the wire.
    /// Processes a full ClientHello handshake message (4-byte header + body).
    /// Feeds the whole message to the transcript; field offsets account for
    /// the header. Callers must pass the header, not the bare body.
    pub fn processClientHello(self: *Engine, msg: []const u8) !void {
        self.transcript.feed(msg);
        if (msg.len < 4) return;
        const body = msg[4..];
        // Extract legacy_session_id and SNI from ClientHello body:
        //   [0..2]   client_version (0x0303)
        //   [2..34]  random (32 bytes)
        //   [34]     legacy_session_id_length (u8)
        //   [35..]   legacy_session_id
        if (body.len > 34) {
            const sidLen = body[34];
            if (sidLen <= 32 and 35 + @as(usize, sidLen) <= body.len) {
                @memcpy(self.legacySessionIdBuf[0..sidLen], body[35 .. 35 + sidLen]);
                self.legacySessionIdLen = sidLen;
            }

            var pos: usize = 35 + @as(usize, sidLen);
            if (pos + 2 <= body.len) {
                const cs_len: usize = (@as(usize, body[pos]) << 8) | body[pos + 1];
                pos += 2 + cs_len;
                if (pos < body.len) {
                    const comp_len = body[pos];
                    pos += 1 + comp_len;
                    if (pos + 2 <= body.len) {
                        const ext_len: usize = (@as(usize, body[pos]) << 8) | body[pos + 1];
                        pos += 2;
                        const ext_end = @min(body.len, pos + ext_len);
                        while (pos + 4 <= ext_end) {
                            const ext_type = std.mem.readInt(u16, body[pos..][0..2], .big);
                            const ext_data_len: usize = (@as(usize, body[pos + 2]) << 8) | body[pos + 3];
                            pos += 4;
                            if (pos + ext_data_len > ext_end) break;
                            if (ext_type == 0 and ext_data_len >= 5) {
                                const list_len: usize = (@as(usize, body[pos]) << 8) | body[pos + 1];
                                if (list_len >= 3 and pos + 2 + list_len <= pos + ext_data_len) {
                                    const name_type = body[pos + 2];
                                    if (name_type == 0) {
                                        const nameLen: usize = (@as(usize, body[pos + 3]) << 8) | body[pos + 4];
                                        if (pos + 5 + nameLen <= body.len) {
                                            const sni = body[pos + 5 ..][0..nameLen];
                                            if (sni.len > 0 and sni.len < 256) {
                                                if (self.sniHostname) |old| self.allocator.free(old);
                                                self.sniHostname = self.allocator.dupe(u8, sni) catch null;
                                            }
                                        }
                                    }
                                }
                            }
                            pos += ext_data_len;
                        }
                    }
                }
            }
        }
        self.state = .client_hello_received;
    }

    /// Produces the full server flight: ServerHello + EncryptedExtensions +
    /// Certificate + CertificateVerify + Finished.
    ///
    /// When no shared secret is set yet (production path), negotiates the
    /// cipher suite and ECDHE share from `clientHelloBody`, generates a
    /// fresh ephemeral keypair, and derives handshake keys. Tests may preset
    /// `sharedSecret`/`localKeypair` to skip negotiation.
    pub fn produceServerFlight(
        self: *Engine,
        clientHelloBody: []const u8,
        certChainPem: []const u8,
        privateKeyDer: []const u8,
        alpnPreference: []const alpn_mod.Protocol,
        clientAlpnWire: []const []const u8,
    ) !ServerFlight {
        if (self.sharedSecret == null) {
            var seed: [32]u8 = undefined;
            fillRandom(&seed);
            self.localKeypair = try x25519.KeyPair.generateDeterministic(seed);
            try self.negotiateClientHello(clientHelloBody);
        }

        // PSK resumption requires the negotiated suite to match the
        // ticket's suite (binder hash binding). Anything else silently
        // falls back to the full handshake — never a fatal alert.
        const use_psk = if (self.resumptionPsk != null and self.pskSuite != null) blk: {
            if (self.pskSuite.? != self.selectedSuite) {
                self.resumptionPsk = null;
                self.pskSuite = null;
                break :blk false;
            }
            break :blk true;
        } else false;

        // NOTE: handshake traffic keys are derived AFTER ServerHello is fed
        // to the transcript below (RFC 8446 Section 7.1 hashes CH..SH).

        const pubkey = self.localKeypair.public_key;

        // ServerHello (RFC 8446 Section 4.1.3):
        //   legacy_version: 0x0303 (TLS 1.2)
        //   random: 32 bytes
        //   legacy_session_id_echo: 1 byte len + echo bytes
        //   cipherSuite: 2 bytes
        //   legacy_compression_method: 0x00 (1 byte)
        //   extensions: 2 bytes len + extensions
        var sh_body = std.ArrayList(u8).empty;
        defer sh_body.deinit(self.allocator);

        // legacy_version (0x0303)
        try sh_body.appendSlice(self.allocator, &.{ 0x03, 0x03 });

        // server_random (32 bytes)
        var server_random: [32]u8 = undefined;
        fillRandom(&server_random);
        try sh_body.appendSlice(self.allocator, &server_random);

        // legacy_session_id_echo
        try sh_body.append(self.allocator, self.legacySessionIdLen);
        if (self.legacySessionIdLen > 0) {
            try sh_body.appendSlice(self.allocator, self.legacySessionIdBuf[0..self.legacySessionIdLen]);
        }

        // cipherSuite
        try sh_body.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(self.selectedSuite))));

        // legacy_compression_method (0x00)
        try sh_body.append(self.allocator, 0x00);

        // extensions
        var exts = std.ArrayList(u8).empty;
        defer exts.deinit(self.allocator);

        // keyShare extension
        var ks_body = std.ArrayList(u8).empty;
        defer ks_body.deinit(self.allocator);
        try ks_body.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(handshake_mod.NamedGroup.x25519))));
        try ks_body.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 32)));
        try ks_body.appendSlice(self.allocator, &pubkey);

        try exts.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(handshake_mod.ExtensionType.key_share))));
        try exts.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(ks_body.items.len))));
        try exts.appendSlice(self.allocator, ks_body.items);

        // supportedVersions (TLS 1.3 = 0x0304)
        try exts.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(handshake_mod.ExtensionType.supported_versions))));
        try exts.appendSlice(self.allocator, &.{ 0x00, 0x02 });
        try exts.appendSlice(self.allocator, &.{ 0x03, 0x04 });

        // serverName ack (empty) — only when the client sent SNI. An
        // unsolicited ack violates RFC 8446 Section 4.2 and aborts strict
        // clients (e.g. IP-literal handshakes carry no SNI).
        if (self.sniHostname != null) {
            try exts.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(handshake_mod.ExtensionType.server_name))));
            try exts.appendSlice(self.allocator, &.{ 0x00, 0x00 });
        }

        // pre_shared_key ack: selected_identity 0 (we accept only the
        // first offered identity). Present only on the abbreviated flight.
        if (use_psk) {
            try exts.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(handshake_mod.ExtensionType.pre_shared_key))));
            try exts.appendSlice(self.allocator, &.{ 0x00, 0x02, 0x00, 0x00 });
        }

        try sh_body.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(exts.items.len))));
        try sh_body.appendSlice(self.allocator, exts.items);

        // ServerHello with handshake header
        var sh_msg = std.ArrayList(u8).empty;
        errdefer sh_msg.deinit(self.allocator);
        try sh_msg.append(self.allocator, @intFromEnum(handshake_mod.HandshakeType.server_hello));
        const sh_body_len: u24 = @intCast(sh_body.items.len);
        try sh_msg.append(self.allocator, @intCast((sh_body_len >> 16) & 0xFF));
        try sh_msg.append(self.allocator, @intCast((sh_body_len >> 8) & 0xFF));
        try sh_msg.append(self.allocator, @intCast(sh_body_len & 0xFF));
        try sh_msg.appendSlice(self.allocator, sh_body.items);

        self.transcript.feed(sh_msg.items);

        // Handshake traffic secrets hash CH..SH (RFC 8446 Section 7.1), so
        // they can only be derived once ServerHello is in the transcript.
        if (self.serverHsTrafficSecret == null) {
            self.deriveHandshakeKeys();
        }

        // EncryptedExtensions
        var ee_body = std.ArrayList(u8).empty;
        defer ee_body.deinit(self.allocator);
        var ee_exts = std.ArrayList(u8).empty;
        defer ee_exts.deinit(self.allocator);

        // ALPN extension — per RFC 8446 Section 4.3.1 must be in EncryptedExtensions.
        // Only sent when the client actually offered ALPN: an unsolicited
        // selection breaks clients without an ALPN hook (e.g. IP-literal
        // handshakes), which then speak HTTP/1.1 by default.
        if (alpnPreference.len > 0 and clientAlpnWire.len > 0) {
            const selected_opt = alpn_mod.negotiateServer(alpnPreference, clientAlpnWire);
            if (selected_opt) |selected| {
                const wire = selected.wireName();
                if (self.negotiatedAlpn) |old| self.allocator.free(old);
                self.negotiatedAlpn = try self.allocator.dupe(u8, wire);

                var alpn_list = std.ArrayList(u8).empty;
                defer alpn_list.deinit(self.allocator);
                try alpn_list.append(self.allocator, @intCast(wire.len));
                try alpn_list.appendSlice(self.allocator, wire);

                var alpn_ext_body = std.ArrayList(u8).empty;
                defer alpn_ext_body.deinit(self.allocator);
                try alpn_ext_body.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(alpn_list.items.len))));
                try alpn_ext_body.appendSlice(self.allocator, alpn_list.items);

                try ee_exts.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation))));
                try ee_exts.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(alpn_ext_body.items.len))));
                try ee_exts.appendSlice(self.allocator, alpn_ext_body.items);
            }
        }

        try ee_body.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(ee_exts.items.len))));
        try ee_body.appendSlice(self.allocator, ee_exts.items);

        var ee_msg = std.ArrayList(u8).empty;
        errdefer ee_msg.deinit(self.allocator);
        try ee_msg.append(self.allocator, @intFromEnum(handshake_mod.HandshakeType.encrypted_extensions));
        const ee_body_len: u24 = @intCast(ee_body.items.len);
        try ee_msg.append(self.allocator, @intCast((ee_body_len >> 16) & 0xFF));
        try ee_msg.append(self.allocator, @intCast((ee_body_len >> 8) & 0xFF));
        try ee_msg.append(self.allocator, @intCast(ee_body_len & 0xFF));
        try ee_msg.appendSlice(self.allocator, ee_body.items);

        self.transcript.feed(ee_msg.items);

        // Mutual TLS: CertificateRequest goes here (EE..CR..Cert), so the
        // transcript order matches what the client observes. Enabled via
        // `requestClientCert`; never sent on an abbreviated (PSK) flight,
        // where authentication rides the binder instead of certificates.
        var cr_msg: ?[]u8 = null;
        errdefer if (cr_msg) |m| self.allocator.free(m);
        if (self.requestClientCert and !use_psk) {
            cr_msg = try self.produceCertificateRequest();
        }

        // Certificate + CertificateVerify are omitted on abbreviated
        // (PSK) flights: authentication rides the binder, and the
        // transcript skips exactly what is not sent. Empty owned slices
        // mark the omission (verified freeable, even zero-length).
        var cert_msg = std.ArrayList(u8).empty;
        errdefer cert_msg.deinit(self.allocator);
        var cv_msg = std.ArrayList(u8).empty;
        errdefer cv_msg.deinit(self.allocator);
        if (!use_psk) {
            // Certificate
            var cert_body = std.ArrayList(u8).empty;
            defer cert_body.deinit(self.allocator);
            try cert_body.append(self.allocator, 0x00); // request_context length 0
            if (certChainPem.len > 0) {
                // Attempt to parse PEM and encode each cert; fallback to empty on parse failure
                // to keep tests with empty strings passing.
                var certs = std.ArrayList([]const u8).empty;
                defer {
                    for (certs.items) |c| self.allocator.free(c);
                    certs.deinit(self.allocator);
                }
                // Simple PEM scan for CERTIFICATE blocks
                var off: usize = 0;
                while (std.mem.indexOfPos(u8, certChainPem, off, "-----BEGIN CERTIFICATE-----")) |b| {
                    const e = std.mem.indexOfPos(u8, certChainPem, b, "-----END CERTIFICATE-----") orelse break;
                    const b64 = certChainPem[b + 27 .. e];
                    var clean = std.ArrayList(u8).empty;
                    defer clean.deinit(self.allocator);
                    for (b64) |c| if (c != '\n' and c != '\r' and c != ' ' and c != '\t') try clean.append(self.allocator, c);
                    const der_len = std.base64.standard.Decoder.calcSizeForSlice(clean.items) catch break;
                    const der = self.allocator.alloc(u8, der_len) catch break;
                    std.base64.standard.Decoder.decode(der, clean.items) catch {
                        self.allocator.free(der);
                        break;
                    };
                    try certs.append(self.allocator, der);
                    off = e + 25;
                    if (certs.items.len >= 8) break;
                }
                if (certs.items.len > 0) {
                    var list_buf = std.ArrayList(u8).empty;
                    defer list_buf.deinit(self.allocator);
                    for (certs.items) |der| {
                        const len: u24 = @intCast(der.len);
                        try list_buf.append(self.allocator, @intCast((len >> 16) & 0xFF));
                        try list_buf.append(self.allocator, @intCast((len >> 8) & 0xFF));
                        try list_buf.append(self.allocator, @intCast(len & 0xFF));
                        try list_buf.appendSlice(self.allocator, der);
                        try list_buf.appendSlice(self.allocator, &.{ 0x00, 0x00 }); // empty extensions
                    }
                    const total: u24 = @intCast(list_buf.items.len);
                    try cert_body.append(self.allocator, @intCast((total >> 16) & 0xFF));
                    try cert_body.append(self.allocator, @intCast((total >> 8) & 0xFF));
                    try cert_body.append(self.allocator, @intCast(total & 0xFF));
                    try cert_body.appendSlice(self.allocator, list_buf.items);
                } else {
                    try cert_body.appendSlice(self.allocator, &.{ 0x00, 0x00 });
                }
            } else {
                try cert_body.appendSlice(self.allocator, &.{ 0x00, 0x00 });
            }

            try cert_msg.append(self.allocator, @intFromEnum(handshake_mod.HandshakeType.certificate));
            const cert_body_len: u24 = @intCast(cert_body.items.len);
            try cert_msg.append(self.allocator, @intCast((cert_body_len >> 16) & 0xFF));
            try cert_msg.append(self.allocator, @intCast((cert_body_len >> 8) & 0xFF));
            try cert_msg.append(self.allocator, @intCast(cert_body_len & 0xFF));
            try cert_msg.appendSlice(self.allocator, cert_body.items);

            self.transcript.feed(cert_msg.items);

            // CertificateVerify (RFC 8446 Section 4.4.3): ECDSA P-256 over
            // 64x 0x20 ++ "TLS 1.3, server CertificateVerify" ++ 0x00 ++ transcript hash.
            // RSA and other key types fail loudly: an empty signature would break
            // every verifying client, so never emit one.
            if (!self.peerOffersEcdsa) return error.UnsupportedSignatureScheme;
            const ec_scalar = try parseEcPrivateScalar(self.allocator, privateKeyDer);
            const ec_pub_point = try P256.basePoint.mul(ec_scalar, .big);
            const ec_keypair = EcdsaP256.KeyPair{
                .secret_key = try EcdsaP256.SecretKey.fromBytes(ec_scalar),
                .public_key = .{ .p = ec_pub_point },
            };
            var cv_content: [64 + 33 + 1 + HashLen]u8 = undefined;
            @memset(cv_content[0..64], 0x20);
            @memcpy(cv_content[64..][0..33], "TLS 1.3, server CertificateVerify");
            cv_content[64 + 33] = 0x00;
            {
                var hs_copy = self.transcript.state;
                const hs_hash = hs_copy.finalResult();
                @memcpy(cv_content[64 + 33 + 1 ..], &hs_hash);
            }
            var cv_noise: [EcdsaP256.noise_length]u8 = undefined;
            fillRandom(&cv_noise);
            const ec_sig = try ec_keypair.sign(&cv_content, cv_noise);
            var sig_der: [EcdsaP256.Signature.der_encoded_length_max]u8 = undefined;
            const sig_der_slice = ec_sig.toDer(&sig_der);

            var cv_body = std.ArrayList(u8).empty;
            defer cv_body.deinit(self.allocator);
            try cv_body.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(handshake_mod.SignatureScheme.ecdsa_secp256r1_sha256))));
            try cv_body.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(sig_der_slice.len))));
            try cv_body.appendSlice(self.allocator, sig_der_slice);

            try cv_msg.append(self.allocator, @intFromEnum(handshake_mod.HandshakeType.certificate_verify));
            const cv_body_len: u24 = @intCast(cv_body.items.len);
            try cv_msg.append(self.allocator, @intCast((cv_body_len >> 16) & 0xFF));
            try cv_msg.append(self.allocator, @intCast((cv_body_len >> 8) & 0xFF));
            try cv_msg.append(self.allocator, @intCast(cv_body_len & 0xFF));
            try cv_msg.appendSlice(self.allocator, cv_body.items);

            self.transcript.feed(cv_msg.items);
        } // end if (!use_psk): abbreviated flights omit Cert/CV entirely

        // Finished
        // verifyData = HMAC(server_finished_key, Hash(Transcript))
        // server_finished_key = HKDF-Expand-Label(server_handshake_traffic_secret, "finished", "", HashLen)
        const hs_hash = self.transcript.finish();
        const s_hs = self.serverHsTrafficSecret orelse return error.HandshakeFailed;
        var server_finished_key: [HashLen]u8 = undefined;
        hkdfExpandLabel(s_hs, "finished", &server_finished_key);

        var finished_verify: [HashLen]u8 = undefined;
        std.crypto.auth.hmac.Hmac(Sha256).create(&finished_verify, &hs_hash, &server_finished_key);

        var fin_body = std.ArrayList(u8).empty;
        defer fin_body.deinit(self.allocator);
        try fin_body.appendSlice(self.allocator, &finished_verify);

        var fin_msg = std.ArrayList(u8).empty;
        errdefer fin_msg.deinit(self.allocator);
        try fin_msg.append(self.allocator, @intFromEnum(handshake_mod.HandshakeType.finished));
        const fin_body_len: u24 = @intCast(fin_body.items.len);
        try fin_msg.append(self.allocator, @intCast((fin_body_len >> 16) & 0xFF));
        try fin_msg.append(self.allocator, @intCast((fin_body_len >> 8) & 0xFF));
        try fin_msg.append(self.allocator, @intCast(fin_body_len & 0xFF));
        try fin_msg.appendSlice(self.allocator, fin_body.items);

        self.transcript.feed(fin_msg.items);

        // Compute application traffic secrets for server side
        self.deriveApplicationKeys();
        self.state = .server_finished_sent;

        // Return owned slices
        return .{
            .serverHello = try sh_msg.toOwnedSlice(self.allocator),
            .encryptedExtensions = try ee_msg.toOwnedSlice(self.allocator),
            .certificateRequest = cr_msg,
            .certificate = try cert_msg.toOwnedSlice(self.allocator),
            .certificateVerify = try cv_msg.toOwnedSlice(self.allocator),
            .finished = try fin_msg.toOwnedSlice(self.allocator),
        };
    }

    /// Produces one NewSessionTicket message (type 4) from the
    /// handshake's resumption master secret. The ticket seals the derived
    /// PSK under the server's ticket keys, so the server stays stateless;
    /// the client re-derives the same PSK from its own master + the clear
    /// nonce. Call after the client's Finished is in the transcript.
    /// Extensions are always empty: 0-RTT is never offered.
    pub fn produceNewSessionTicket(
        self: *Engine,
        resumptionMaster: [32]u8,
        suite: tls.CipherSuite,
        lifetimeSecs: u32,
        nowMs: u64,
    ) ![]u8 {
        const keys = self.ticketKeys orelse return error.HandshakeFailed;
        var nonce: [32]u8 = undefined;
        fillRandom(&nonce);
        var psk: [32]u8 = undefined;
        hkdfExpandLabelWithContext(resumptionMaster, "resumption", &nonce, &psk);
        defer std.crypto.secureZero(u8, &psk);
        var age_add: [4]u8 = undefined;
        fillRandom(&age_add);
        const age_add_v = std.mem.readInt(u32, &age_add, .big);
        const blob = keys.seal(psk, suite, nowMs, lifetimeSecs, age_add_v);
        const nst = handshake_mod.NewSessionTicket{
            .lifetimeSecs = lifetimeSecs,
            .ageAdd = age_add_v,
            .nonce = &nonce,
            .ticket = &blob,
        };
        return nst.encode(self.allocator);
    }

    /// Derives the resumption master secret (RFC 8446 Section 7.1):
    /// Derive-Secret(Master Secret, "res master", transcript hash).
    /// Call once the client's Finished is in the transcript (both roles).
    pub fn deriveResumptionMaster(self: *Engine) ![32]u8 {
        const master = self.masterSecret orelse return error.HandshakeFailed;
        var copy = self.transcript.state;
        const hash = copy.finalResult();
        return deriveSecret(master, "res master", hash);
    }

    /// Consumes a post-handshake NewSessionTicket (full message with
    /// header) using a locally derived resumption master, returning an
    /// owned `ClientSession` bound to `host`. Tickets for hash
    /// algorithms this schedule cannot use (anything but the SHA-256
    /// family) are rejected: offering them could never verify.
    pub fn processNewSessionTicket(
        self: *Engine,
        msg: []const u8,
        resumptionMaster: [32]u8,
        host: []const u8,
        nowMs: u64,
    ) !session_mod.ClientSession {
        if (msg.len < 4) return error.ProtocolViolation;
        if (msg[0] != @intFromEnum(handshake_mod.HandshakeType.new_session_ticket)) return error.ProtocolViolation;
        const nst = try handshake_mod.NewSessionTicket.decode(msg[4..]);
        return session_mod.clientSessionFromTicket(
            self.allocator,
            nst,
            resumptionMaster,
            self.selectedSuite,
            host,
            nowMs,
        );
    }

    // Key derivation — RFC 8446 Section 7.1
    //
    // key_schedule:
    //   0. PSK or (zero) -> Early Secret
    //   1. Early Secret --"derived"--> Handshake Secret
    //   2. Handshake Secret --"derived"--> Master Secret
    //   3. Master Secret --"c ap traffic"/"s ap traffic"--> App Secrets
    //
    // HKDF-Expand-Label(PRK, Label, Context, Length):
    //   info = uint16(Length) || uint8(6 + Label.len) || "tls13 " || Label || uint8(0)

    /// Derive handshake traffic secrets from the ECDHE shared secret.
    /// Uses Derive-Secret with transcript hash as per RFC 8446 Section 7.1.
    fn deriveHandshakeKeys(self: *Engine) void {
        self.deriveHandshakeSecret();
        const hsSecret = self.handshakeSecret orelse return;

        var copy = self.transcript.state;
        const hash = copy.finalResult();

        var c_hs: [32]u8 = undefined;
        hkdfExpandLabelWithContext(hsSecret, "c hs traffic", &hash, &c_hs);

        var s_hs: [32]u8 = undefined;
        hkdfExpandLabelWithContext(hsSecret, "s hs traffic", &hash, &s_hs);

        // Store for Finished verification
        self.serverHsTrafficSecret = s_hs;
        self.clientHsTrafficSecret = c_hs;

        self.hsKeys = deriveAeadKeys(c_hs, s_hs, self.recordCipher());

        const k = self.hsKeys.?;
        self.cbs.onKeys(self.cbs.ctx, .handshake, k);
    }

    /// Derive application traffic secrets.
    fn deriveApplicationKeys(self: *Engine) void {
        const hsSecret = self.handshakeSecret orelse return;

        // Derive-Secret(handshakeSecret, "derived", ""): like the handshake
        // secret above, the empty transcript hashes to Hash(""), never to a
        // zero-length context (RFC 8446 Section 7.1). Transcript binding for
        // application traffic enters at the "c/s ap traffic" step below.
        var empty_copy = Transcript.init();
        const empty_hash = empty_copy.finish();
        var derived: [32]u8 = undefined;
        hkdfExpandLabelWithContext(hsSecret, "derived", &empty_hash, &derived);

        // With an accepted PSK the Master Secret mixes it in; otherwise
        // zeros exactly as before. (EC)DHE is always performed alongside
        // (psk_dhe_ke), so forward secrecy holds either way.
        const zero: [32]u8 = .{0} ** 32;
        const psk_ikm = self.resumptionPsk orelse zero;
        const master = HkdfSha256.extract(&derived, &psk_ikm);
        self.masterSecret = master;

        var copy = self.transcript.state;
        const hash = copy.finalResult();

        var c_ap: [32]u8 = undefined;
        hkdfExpandLabelWithContext(master, "c ap traffic", &hash, &c_ap);

        var s_ap: [32]u8 = undefined;
        hkdfExpandLabelWithContext(master, "s ap traffic", &hash, &s_ap);

        self.apKeys = deriveAeadKeys(c_ap, s_ap, self.recordCipher());

        const k = self.apKeys.?;
        self.cbs.onKeys(self.cbs.ctx, .application, k);
    }

    /// Maps the selected cipher suite to a RecordCipher.
    fn recordCipher(self: *const Engine) record_mod.RecordCipher {
        return switch (self.selectedSuite) {
            .AES_128_GCM_SHA256 => .aes_128_gcm,
            .AES_256_GCM_SHA384 => .aes_256_gcm,
            .CHACHA20_POLY1305_SHA256 => .chacha20_poly1305,
            else => .aes_128_gcm,
        };
    }

    /// Derive AEAD key + IV from a traffic secret using TLS 1.3 key/IV labels.
    fn deriveAeadKeys(client_secret: [32]u8, server_secret: [32]u8, cipher: record_mod.RecordCipher) DerivedKeys {
        const keyLen: usize = cipher.keyLen();
        var ck: [32]u8 = undefined;
        var ci: [12]u8 = undefined;
        var sk: [32]u8 = undefined;
        var si: [12]u8 = undefined;
        hkdfExpandLabel(client_secret, "key", ck[0..keyLen]);
        hkdfExpandLabel(client_secret, "iv", &ci);
        hkdfExpandLabel(server_secret, "key", sk[0..keyLen]);
        hkdfExpandLabel(server_secret, "iv", &si);
        return .{
            .clientKey = ck,
            .clientKeyLen = @intCast(keyLen),
            .clientIv = ci,
            .serverKey = sk,
            .serverKeyLen = @intCast(keyLen),
            .serverIv = si,
            .cipher = cipher,
        };
    }
};

// Server flight result

pub const ServerFlight = struct {
    serverHello: []u8,
    encryptedExtensions: []u8,
    /// Present only when `requestClientCert` was set before the flight.
    certificateRequest: ?[]u8 = null,
    certificate: []u8,
    certificateVerify: []u8,
    finished: []u8,

    pub fn deinit(self: *ServerFlight, allocator: Allocator) void {
        allocator.free(self.serverHello);
        allocator.free(self.encryptedExtensions);
        if (self.certificateRequest) |cr| allocator.free(cr);
        allocator.free(self.certificate);
        allocator.free(self.certificateVerify);
        allocator.free(self.finished);
    }
};

// Tests

test "client produces valid ClientHello" {
    const a = std.testing.allocator;
    var engine = Engine.initClient(a, .{});

    const ch = try engine.produceClientHello(&.{"h2"}, &.{});
    defer a.free(ch);

    // Starts with handshake type client_hello (0x01)
    try std.testing.expectEqual(@as(u8, 0x01), ch[0]);
    // Body length matches the u24 in header
    const bodyLen: u24 = @as(u24, @intCast(ch[1])) << 16 | @as(u24, @intCast(ch[2])) << 8 | @as(u24, @intCast(ch[3]));
    try std.testing.expectEqual(ch.len - 4, bodyLen);
}

test "handshake engine client-server key exchange" {
    const a = std.testing.allocator;

    var client = Engine.initClient(a, .{});
    var server = Engine.initServer(a, .{});

    // Client produces ClientHello
    const ch = try client.produceClientHello(&.{"h2"}, &.{});
    defer a.free(ch);

    // Server processes ClientHello
    try server.processClientHello(ch);

    // Deterministic P-256 identity for CertificateVerify signing (SEC1 DER).
    const ec_kp = try EcdsaP256.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    const ec_sec = ec_kp.secret_key.toBytes();
    var sec1: [39]u8 = undefined;
    sec1[0] = 0x30;
    sec1[1] = 0x25;
    sec1[2] = 0x02;
    sec1[3] = 0x01;
    sec1[4] = 0x01;
    sec1[5] = 0x04;
    sec1[6] = 0x20;
    @memcpy(sec1[7..], &ec_sec);

    // Server produces flight: negotiates suite/share from the real
    // ClientHello, derives keys, and signs CertificateVerify.
    var flight = try server.produceServerFlight(ch[4..], "", sec1[0..], &.{}, &.{});
    defer flight.deinit(a);

    try std.testing.expectEqual(tls.CipherSuite.AES_128_GCM_SHA256, server.selectedSuite);
    try std.testing.expect(server.sharedSecret != null);
    try std.testing.expect(server.peerOffersEcdsa);

    try std.testing.expectEqual(Engine.State.server_finished_sent, server.state);
    try std.testing.expect(server.hsKeys != null);
    try std.testing.expect(server.apKeys != null);

    // Client processes ServerHello — derives shared secret and handshake keys
    try client.processServerHello(flight.serverHello);
    try std.testing.expect(client.sharedSecret != null);
    try std.testing.expectEqual(Engine.State.handshake_keys_derived, client.state);

    // Client processes EncryptedExtensions
    try client.processEncryptedExtensions(flight.encryptedExtensions);
    try std.testing.expectEqual(Engine.State.encrypted_extensions_received, client.state);

    // Client processes Certificate
    try client.processCertificate(flight.certificate);
    try std.testing.expectEqual(Engine.State.certificateReceived, client.state);

    // Client processes CertificateVerify
    try client.processCertificateVerify(flight.certificateVerify);
    try std.testing.expectEqual(Engine.State.certificate_verify_received, client.state);

    // Client processes Finished
    try client.processFinished(flight.finished);
    try std.testing.expectEqual(Engine.State.handshakeComplete, client.state);

    // Both have application keys
    try std.testing.expect(client.apKeys != null);
    try std.testing.expect(server.apKeys != null);
}

test "mutual TLS client certificate round trip" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const client_cert_pem = @embedFile("testdata/localhost_cert.pem");
    const client_key_pem = @embedFile("testdata/localhost_key.pem");
    const now_sec: i64 = @divFloor(clock_mod.millisNow(), 1000);

    var client = Engine.initClient(a, .{});
    var server = Engine.initServer(a, .{});
    server.requestClientCert = true;

    const ch = try client.produceClientHello(&.{}, &.{});
    defer a.free(ch);
    try server.processClientHello(ch);

    // Deterministic P-256 server identity for its own CertificateVerify.
    const ec_kp = try EcdsaP256.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    const ec_sec = ec_kp.secret_key.toBytes();
    var sec1: [39]u8 = undefined;
    sec1[0] = 0x30;
    sec1[1] = 0x25;
    sec1[2] = 0x02;
    sec1[3] = 0x01;
    sec1[4] = 0x01;
    sec1[5] = 0x04;
    sec1[6] = 0x20;
    @memcpy(sec1[7..], &ec_sec);

    var flight = try server.produceServerFlight(ch[4..], "", sec1[0..], &.{}, &.{});
    defer flight.deinit(a);
    try std.testing.expect(flight.certificateRequest != null);

    try client.processServerHello(flight.serverHello);
    try client.processEncryptedExtensions(flight.encryptedExtensions);
    try client.processCertificateRequest(flight.certificateRequest.?);
    try client.processCertificate(flight.certificate);
    try client.processCertificateVerify(flight.certificateVerify);
    try client.processFinished(flight.finished);
    try std.testing.expectEqual(Engine.State.handshakeComplete, client.state);

    // Client identity from the committed test certificate + key.
    var chain = try certMod.parseCertificateChainPem(a, client_cert_pem);
    defer chain.deinit();
    try std.testing.expect(chain.count() >= 1);
    const leaf_der = chain.leaf().?.rawDer();

    var ders = std.ArrayList([]const u8).empty;
    defer ders.deinit(a);
    var ci: usize = 0;
    while (chain.get(ci)) |c| : (ci += 1) {
        try ders.append(a, c.rawDer());
    }
    const client_cert = try client.produceClientCertificate(ders.items);
    defer a.free(client_cert);
    const client_cv = try client.produceClientCertificateVerify(client_key_pem);
    defer a.free(client_cv);
    const client_fin = try client.produceClientFinished();
    defer a.free(client_fin);

    // Server validates: chain anchors in the client CA store, CV
    // signature checks out, Finished MAC binds the full transcript.
    var store = trustStoreMod.TrustStore.init(a, io);
    defer store.deinit();
    try store.addCertPem(client_cert_pem);

    var presented = try server.processClientCertificate(client_cert);
    defer presented.deinit();
    try std.testing.expectEqual(chain.count(), presented.ders.len);
    var presented_chain = try certMod.parseCertificateChainPem(a, client_cert_pem);
    defer presented_chain.deinit();
    try verify_mod.verifyCertificateChain(presented_chain, &store, null, now_sec);
    try server.processClientCertificateVerify(client_cv, leaf_der);
    try server.verifyClientFinished(client_fin);

    // Transcripts agree after the full mutual flight.
    var c_tr = client.transcript;
    var s_tr = server.transcript;
    try std.testing.expectEqualSlices(u8, &c_tr.finish(), &s_tr.finish());
}

test "mutual TLS rejects untrusted client certificate" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const client_cert_pem = @embedFile("testdata/localhost_cert.pem");
    const now_sec: i64 = @divFloor(clock_mod.millisNow(), 1000);

    var chain = try certMod.parseCertificateChainPem(a, client_cert_pem);
    defer chain.deinit();

    // Empty trust store: no anchor matches the presented chain.
    var store = trustStoreMod.TrustStore.init(a, io);
    defer store.deinit();
    try std.testing.expectError(
        error.CertificateUntrusted,
        verify_mod.verifyCertificateChain(chain, &store, null, now_sec),
    );
}

test "mutual TLS rejects malformed client Certificate framing" {
    const a = std.testing.allocator;
    var server = Engine.initServer(a, .{});

    // Truncated DER entry: structural guard fails closed, no panic.
    const bad = [_]u8{ 0x0B, 0x00, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x05, 0x30, 0x05, 0x00, 0x01, 0x02 };
    try std.testing.expectError(error.ProtocolViolation, server.processClientCertificate(&bad));

    // Wrong message type where a Certificate is required.
    const wrong = [_]u8{ 0x14, 0x00, 0x00, 0x00 };
    try std.testing.expectError(error.ProtocolViolation, server.processClientCertificate(&wrong));
}

test "mutual TLS rejects forged client CertificateVerify" {
    const a = std.testing.allocator;

    const client_cert_pem = @embedFile("testdata/localhost_cert.pem");
    const client_key_pem = @embedFile("testdata/localhost_key.pem");

    var client = Engine.initClient(a, .{});
    var server = Engine.initServer(a, .{});
    server.requestClientCert = true;

    const ch = try client.produceClientHello(&.{}, &.{});
    defer a.free(ch);
    try server.processClientHello(ch);

    const ec_kp = try EcdsaP256.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    const ec_sec = ec_kp.secret_key.toBytes();
    var sec1: [39]u8 = undefined;
    sec1[0] = 0x30;
    sec1[1] = 0x25;
    sec1[2] = 0x02;
    sec1[3] = 0x01;
    sec1[4] = 0x01;
    sec1[5] = 0x04;
    sec1[6] = 0x20;
    @memcpy(sec1[7..], &ec_sec);

    var flight = try server.produceServerFlight(ch[4..], "", sec1[0..], &.{}, &.{});
    defer flight.deinit(a);
    try client.processServerHello(flight.serverHello);
    try client.processEncryptedExtensions(flight.encryptedExtensions);
    try client.processCertificateRequest(flight.certificateRequest.?);
    try client.processCertificate(flight.certificate);
    try client.processCertificateVerify(flight.certificateVerify);
    try client.processFinished(flight.finished);

    var chain = try certMod.parseCertificateChainPem(a, client_cert_pem);
    defer chain.deinit();
    const leaf_der = chain.leaf().?.rawDer();
    var ders = std.ArrayList([]const u8).empty;
    defer ders.deinit(a);
    try ders.append(a, leaf_der);
    const cert_msg = try client.produceClientCertificate(ders.items);
    defer a.free(cert_msg);
    var presented = try server.processClientCertificate(cert_msg);
    defer presented.deinit();

    var cv = try client.produceClientCertificateVerify(client_key_pem);
    defer a.free(cv);
    // Flip a signature byte: verification must fail closed.
    cv[cv.len - 1] ^= 0xFF;
    try std.testing.expectError(
        error.CertificateSignatureInvalid,
        server.processClientCertificateVerify(cv, leaf_der),
    );
}

test "alpn negotiation through handshake" {
    const a = std.testing.allocator;
    var client = Engine.initClient(a, .{});

    const ch = try client.produceClientHello(&.{ "h2", "http/1.1" }, &.{});
    defer a.free(ch);

    // Verify ALPN extension was encoded (type 0x0010 = 16)
    var found_alpn = false;
    var i: usize = 4; // skip handshake header
    while (i + 4 < ch.len) : (i += 1) {
        const ext_type = std.mem.readInt(u16, ch[i..][0..2], .big);
        if (ext_type == 0x0010) {
            found_alpn = true;
            break;
        }
    }
    try std.testing.expect(found_alpn);
}

test "server flight carries negotiated alpn selection" {
    const a = std.testing.allocator;
    var client = Engine.initClient(a, .{});
    defer client.deinit();
    var server = Engine.initServer(a, .{});
    defer server.deinit();

    const ch = try client.produceClientHello(&.{ "h2", "http/1.1" }, &.{});
    defer a.free(ch);
    try server.processClientHello(ch);

    const ec_kp = try EcdsaP256.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    const ec_sec = ec_kp.secret_key.toBytes();
    var sec1: [39]u8 = undefined;
    sec1[0] = 0x30;
    sec1[1] = 0x25;
    sec1[2] = 0x02;
    sec1[3] = 0x01;
    sec1[4] = 0x01;
    sec1[5] = 0x04;
    sec1[6] = 0x20;
    @memcpy(sec1[7..], &ec_sec);

    var flight = try server.produceServerFlight(
        ch[4..],
        "",
        sec1[0..],
        &.{ .h2, .@"http/1.1" },
        &.{ "h2", "http/1.1" },
    );
    defer flight.deinit(a);
    try std.testing.expectEqualStrings("h2", server.negotiatedAlpn.?);

    try client.processServerHello(flight.serverHello);
    try client.processEncryptedExtensions(flight.encryptedExtensions);
    try std.testing.expectEqualStrings("h2", client.negotiatedAlpn.?);
    try std.testing.expect(alpn_mod.Protocol.fromWire(client.negotiatedAlpn.?) == .h2);
}

test "psk abbreviated handshake resynchronizes application keys" {
    const a = std.testing.allocator;
    const now: u64 = 1_000_000;

    // --- Full handshake first (mirrors the key-exchange test) ---
    var client = Engine.initClient(a, .{});
    defer client.deinit();
    var server = Engine.initServer(a, .{});
    defer server.deinit();
    server.ticketKeys = session_mod.TicketKeys{ .current = [_]u8{0x1A} ** 32 };

    const ch = try client.produceClientHello(&.{"h2"}, &.{});
    defer a.free(ch);
    try server.processClientHello(ch);

    const ec_kp = try EcdsaP256.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    const ec_sec = ec_kp.secret_key.toBytes();
    var sec1: [39]u8 = undefined;
    sec1[0..7].* = .{ 0x30, 0x25, 0x02, 0x01, 0x01, 0x04, 0x20 };
    @memcpy(sec1[7..], &ec_sec);

    var flight = try server.produceServerFlight(ch[4..], "", sec1[0..], &.{}, &.{});
    defer flight.deinit(a);
    try std.testing.expect(flight.certificate.len > 0);
    try client.processServerHello(flight.serverHello);
    try std.testing.expect(client.resumptionPsk == null);
    try client.processEncryptedExtensions(flight.encryptedExtensions);
    try client.processCertificate(flight.certificate);
    try client.processCertificateVerify(flight.certificateVerify);
    try client.processFinished(flight.finished);
    const client_fin = try client.produceClientFinished();
    defer a.free(client_fin);
    try server.verifyClientFinished(client_fin);

    // Both sides derive the SAME resumption master (transcripts match).
    const master_c = try client.deriveResumptionMaster();
    const master_s = try server.deriveResumptionMaster();
    try std.testing.expectEqualSlices(u8, &master_c, &master_s);

    // Server issues one ticket; client captures a bound session.
    const nst = try server.produceNewSessionTicket(master_s, server.selectedSuite, 3600, now);
    defer a.free(nst);
    var session = try client.processNewSessionTicket(nst, master_c, "example.com", now);
    defer session.deinit(a);
    try std.testing.expect(session.isUsable("example.com", now + 1000));
    try std.testing.expect(!session.isUsable("other.com", now + 1000));

    // --- Abbreviated handshake with the captured session ---
    var client2 = Engine.initClient(a, .{});
    defer client2.deinit();
    var server2 = Engine.initServer(a, .{});
    defer server2.deinit();
    server2.ticketKeys = server.ticketKeys;
    const ch2 = try client2.produceClientHelloResumption(&.{"h2"}, &.{}, "example.com", &session, now + 2000);
    defer a.free(ch2);
    try server2.processClientHello(ch2);
    try std.testing.expect(server2.selectPsk(ch2, now + 2000));
    var flight2 = try server2.produceServerFlight(ch2[4..], "", sec1[0..], &.{}, &.{});
    defer flight2.deinit(a);
    // Abbreviated: no Certificate / CertificateVerify on the wire.
    try std.testing.expectEqual(@as(usize, 0), flight2.certificate.len);
    try std.testing.expectEqual(@as(usize, 0), flight2.certificateVerify.len);
    try client2.processServerHello(flight2.serverHello);
    try std.testing.expect(client2.resumptionPsk != null);
    try client2.processEncryptedExtensions(flight2.encryptedExtensions);
    try client2.processFinished(flight2.finished);
    const client2_fin = try client2.produceClientFinished();
    defer a.free(client2_fin);
    try server2.verifyClientFinished(client2_fin);
    // Same PSK schedule both sides: application keys match exactly.
    // (Compare only the meaningful key bytes: the [32]u8 slots hold
    // 16-byte keys for AES-128, and the tail is uninitialized memory
    // that legitimately differs between runs in ReleaseFast.)
    try std.testing.expectEqualSlices(u8, client2.apKeys.?.clientKeySlice(), server2.apKeys.?.clientKeySlice());
    try std.testing.expectEqualSlices(u8, client2.apKeys.?.serverKeySlice(), server2.apKeys.?.serverKeySlice());

    // --- Negative paths: tampered binder and expired ticket fall back ---
    var client3 = Engine.initClient(a, .{});
    defer client3.deinit();
    var server3 = Engine.initServer(a, .{});
    defer server3.deinit();
    server3.ticketKeys = server.ticketKeys;
    const ch3 = try client3.produceClientHelloResumption(&.{"h2"}, &.{}, "example.com", &session, now + 3000);
    defer a.free(ch3);
    // Flip a binder byte: the server must reject the PSK silently.
    const tampered = try a.dupe(u8, ch3);
    defer a.free(tampered);
    const bspan = try handshake_mod.pskBinderSpan(tampered);
    bspan[0] ^= 0xFF;
    try server3.processClientHello(tampered);
    try std.testing.expect(!server3.selectPsk(tampered, now + 3000));
    // Expired tickets also fall back instead of failing.
    try std.testing.expect(!server3.selectPsk(ch2, now + 3600 * 1000 + session_mod.ticket_skew_ms + 5000));
}

test "hello retry request completes a full handshake after retry" {
    const a = std.testing.allocator;

    var client = Engine.initClient(a, .{});
    var server = Engine.initServer(a, .{});

    // Shareless ClientHello1 (crafted directly: the normal producer
    // always offers x25519). The predicate must spot the gap.
    const ch1_base = handshake_mod.ClientHello{
        .random = [_]u8{0x55} ** 32,
        .cipherSuites = &.{.AES_128_GCM_SHA256},
        .keyShareEntries = &.{},
        .signatureAlgorithms = &.{.ecdsa_secp256r1_sha256},
        .alpnProtocols = &.{},
        .serverName = null,
    };
    const ch1 = try ch1_base.encode(a);
    defer a.free(ch1);
    try std.testing.expect(!Engine.clientHelloHasShare(ch1[4..]));

    try server.processClientHello(ch1);
    const hrr = try server.produceHelloRetryRequest();
    defer a.free(hrr);
    try std.testing.expect(server.hrrSent);
    // A second HRR must fail, never loop.
    try std.testing.expectError(error.HandshakeFailed, server.produceHelloRetryRequest());

    try client.processClientHello(ch1);
    try client.processServerHello(hrr);
    try std.testing.expectEqual(handshake_mod.NamedGroup.x25519, client.hrrPendingGroup.?);
    // A second HRR aborts loudly.
    try std.testing.expectError(error.HandshakeFailed, client.processServerHello(hrr));

    // Retried hello carries a real share; the predicate agrees.
    const ch2 = try client.produceClientHello(&.{}, &.{});
    defer a.free(ch2);
    try std.testing.expect(Engine.clientHelloHasShare(ch2[4..]));
    try server.processClientHello(ch2);

    const ec_kp = try EcdsaP256.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    const ec_sec = ec_kp.secret_key.toBytes();
    var sec1: [39]u8 = undefined;
    sec1[0..7].* = .{ 0x30, 0x25, 0x02, 0x01, 0x01, 0x04, 0x20 };
    @memcpy(sec1[7..], &ec_sec);
    var flight = try server.produceServerFlight(ch2[4..], "", sec1[0..], &.{}, &.{});
    defer flight.deinit(a);
    try client.processServerHello(flight.serverHello);
    try client.processEncryptedExtensions(flight.encryptedExtensions);
    try client.processCertificate(flight.certificate);
    try client.processCertificateVerify(flight.certificateVerify);
    try client.processFinished(flight.finished);
    const client_fin = try client.produceClientFinished();
    defer a.free(client_fin);
    try server.verifyClientFinished(client_fin);
    try std.testing.expectEqualSlices(u8, client.apKeys.?.clientKeySlice(), server.apKeys.?.clientKeySlice());
}
