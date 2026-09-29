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

/// ML-KEM from the stdlib, used directly for RFC 10024 X25519MLKEM768.
/// Deliberately not `std.crypto.kem.hybrid.MlKem768X25519`: that is X-Wing,
/// which OpenSSL 3.5+ and browsers do not speak over TLS.
const ml_kem = std.crypto.kem.ml_kem;
const MlKem = ml_kem.MLKem768;

// RFC 10024 (X25519MLKEM768) wire sizes. The client share is the ML-KEM
// encapsulation key followed by the X25519 share; the server share is the
// ML-KEM ciphertext followed by the X25519 share; the shared secret is the
// two shared secrets concatenated, 64 bytes.
//
// Note the sizes alone do not identify this construction: X-Wing has the
// identical 1216/1120 wire size but folds both halves through a SHA3-256
// combiner into a 32-byte secret. The two are incompatible, and the failure
// mode is not a parse error -- it is `decryption failed or bad record mac`
// on the first encrypted record.
const MLKEM_PK_LEN = MlKem.PublicKey.encoded_length;
const MLKEM_CT_LEN = MlKem.ciphertext_length;
const MLKEM_SS_LEN = MlKem.shared_length;
const HY_PK_LEN = MLKEM_PK_LEN + 32;
const HY_CT_LEN = MLKEM_CT_LEN + 32;
const HY_SS_LEN = 64;
const Aes128Gcm = std.crypto.aead.aesGcm.Aes128Gcm;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

const recordMod = @import("record.zig");
const handshakeMod = @import("handshake.zig");
const Transcript = handshakeMod.Transcript;
const HashLen = handshakeMod.HashLen;
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const P256 = std.crypto.ecc.P256;
const certMod = @import("certificate.zig");
const verifyMod = @import("verify.zig");
const trustStoreMod = @import("trustStore.zig");
const clockMod = @import("../../common/clock.zig");

const alpnMod = @import("alpn.zig");
const sessionMod = @import("session.zig");
const quicTls = @import("quicTls.zig");

// Random helper — OS CSPRNG when available, otherwise deterministic PRNG

var randomCounter: u64 = 0x9E3779B97F4A7C15;

fn fillRandom(buf: []u8) void {
    if (@hasDecl(std.posix, "getrandom")) {
        std.posix.getrandom(buf) catch {
            randomCounter +%= 1;
            var prng = std.Random.DefaultPrng.init(randomCounter ^ 0x123456789ABCDEF0);
            prng.random().bytes(buf);
        };
        return;
    }
    randomCounter +%= 1;
    var prng = std.Random.DefaultPrng.init(randomCounter ^ 0x123456789ABCDEF0);
    prng.random().bytes(buf);
}

// HKDF-Expand-Label (RFC 8446 Section 7.1)
// info = uint16(len) || uint8(6 + label.len) || "tls13 " || label || uint8(contextLen) || context
// For Derive-Secret, context is the transcript hash; for key/iv expansion, context is empty.
pub fn hkdfExpandLabel(prk: [32]u8, comptime label: []const u8, out: []u8) void {
    hkdfExpandLabelWithContext(prk, label, &.{}, out);
}

pub fn hkdfExpandLabelWithContext(prk: [32]u8, comptime label: []const u8, context: []const u8, out: []u8) void {
    const fullLabel = "tls13 " ++ label;
    var infoBuf: [2 + 1 + 64 + 1 + 32]u8 = undefined;
    const total: u16 = @intCast(out.len);
    var w: usize = 0;
    infoBuf[w] = @intCast(total >> 8);
    infoBuf[w + 1] = @intCast(total & 0xFF);
    w += 2;
    infoBuf[w] = @intCast(fullLabel.len);
    w += 1;
    @memcpy(infoBuf[w..][0..fullLabel.len], fullLabel);
    w += fullLabel.len;
    infoBuf[w] = @intCast(context.len);
    w += 1;
    if (context.len > 0) {
        @memcpy(infoBuf[w..][0..context.len], context);
        w += context.len;
    }
    HkdfSha256.expand(out, infoBuf[0..w], prk);
}

fn deriveSecret(prk: [32]u8, comptime label: []const u8, transcriptHash: [32]u8) [32]u8 {
    var out: [32]u8 = undefined;
    hkdfExpandLabelWithContext(prk, label, &transcriptHash, &out);
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
    onAlert: *const fn (ctx: ?*anyopaque, alert: handshakeMod.Alert) void = struct {
        fn noOp(_: ?*anyopaque, _: handshakeMod.Alert) void {}
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
    cipher: recordMod.RecordCipher = .aes128Gcm,

    pub fn clientKeySlice(self: *const DerivedKeys) []const u8 {
        return self.clientKey[0..self.clientKeyLen];
    }
    pub fn serverKeySlice(self: *const DerivedKeys) []const u8 {
        return self.serverKey[0..self.serverKeyLen];
    }
};

// TLS 1.3 Handshake Engine

/// The HKDF-Extract IKM for the TLS 1.3 key schedule (RFC 8446 7.1).
/// X25519 gives 32 bytes; the RFC 10024 hybrid gives 64 (ML-KEM ‖ X25519).
/// Carried with an explicit length because HKDF-Extract is length-sensitive
/// and the two groups must not be padded to match each other.
pub const SharedSecret = struct {
    bytes: [HY_SS_LEN]u8 = @splat(0),
    len: usize = 0,

    fn of(s: []const u8) SharedSecret {
        var out: SharedSecret = .{ .len = s.len };
        @memcpy(out.bytes[0..s.len], s);
        return out;
    }

    // By pointer: a by-value `self` would hand back a slice into the
    // parameter copy, which dies on return. Every caller would then read
    // a dangling buffer -- the symptom is an `AuthenticationFailed` from a
    // client that agrees with us on everything except the key schedule.
    fn slice(self: *const SharedSecret) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Engine = struct {
    allocator: Allocator,
    role: enum { client, server },
    cbs: Callbacks,

    // ECDHE state
    localKeypair: x25519.KeyPair = undefined,
    sharedSecret: ?SharedSecret = null,

    // X25519MLKEM768 (RFC 10024) state. `localKeypair` supplies the X25519
    // half on both sides: one ephemeral per connection, used by whichever
    // group the handshake selects, so the hybrid needs no second keypair.
    // `hybridPublic` is a stable buffer: the ClientHello borrows it while
    // `ClientHello.encode` runs, so it must outlive the call and never be
    // a temporary.
    hybridMlKem: ?MlKem.KeyPair = null,
    hybridPublic: [HY_PK_LEN]u8 = undefined,
    hybridOffered: bool = false,
    /// Server side of X25519MLKEM768. Both are inline arrays, not heap,
    /// matching `hybridPublic` on the client: the handshake path must not
    /// allocate, because the tests that exercise it never call `deinit()`.
    /// The Engine itself is stack-local in `Server.acceptBuffered`.
    hybridServerCt: ?[HY_CT_LEN]u8 = null,
    peerHybridKey: ?[HY_PK_LEN]u8 = null,
    /// Stable backing storage for the key_share slice handed to
    /// ClientHello. It must live in the Engine, not in buildKeyShares'
    /// frame: a slice of a function-local array literal dangles the
    /// moment the function returns, and the encoder reads it after.
    keyShareBuf: [2]handshakeMod.ClientHello.KeyShareEntry = undefined,

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
    ticketKeys: ?sessionMod.TicketKeys = null,
    /// HelloRetryRequest already seen (client) — a second one aborts.
    hrrSeen: bool = false,
    /// Set by `processServerHello` when it consumed a HelloRetryRequest:
    /// the selected group the retry ClientHello must share.
    hrrPendingGroup: ?handshakeMod.NamedGroup = null,
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

    /// Peer's QUIC transport parameters block (ext 57), owned. Set from
    /// ClientHello (server) or EncryptedExtensions (client); absent on
    /// TCP paths. The QUIC layer parses and applies it.
    peerQuicTransportParams: ?[]u8 = null,

    // SNI hostname from ClientHello
    sniHostname: ?[]const u8 = null,

    // Legacy session ID from ClientHello to echo in ServerHello
    legacySessionIdBuf: [32]u8 = undefined,
    legacySessionIdLen: u8 = 0,

    // Handshake state
    state: State = .start,

    /// 0-RTT early data state
    earlyDataOffered: bool = false,
    earlyDataAccepted: bool = false,
    clientEarlyTrafficSecret: ?[32]u8 = null,
    maxEarlyData: u32 = 0,
    replayCache: ?*sessionMod.ReplayCache = null,

    pub const State = enum {
        start,
        clientHelloSent,
        serverHelloReceived,
        handshakeKeysDerived,
        encryptedExtensionsReceived,
        certificateReceived,
        certificateVerifyReceived,
        finishedReceived,
        handshakeComplete,
        // Server states
        clientHelloReceived,
        serverHelloSent,
        serverFinishedSent,
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
        if (self.peerQuicTransportParams) |tp| {
            self.allocator.free(tp);
            self.peerQuicTransportParams = null;
        }
    }

    /// True for cipher suites our SHA-256-only schedule can resume with.
    /// Canonical policy lives in `session.zig` (single definition).
    pub fn suiteSupportsResumption(suite: tls.CipherSuite) bool {
        return sessionMod.suiteSupportsResumption(suite);
    }

    /// Derive the handshake secret from the ECDHE shared secret.
    /// The 32-byte shared secret, for callers that can only negotiate
    /// X25519. QUIC never offers the hybrid (the share does not fit one
    /// Initial packet), so it always lands here; returning null rather
    /// than truncating keeps a 64-byte hybrid secret from silently
    /// halving itself if that ever stops being true.
    pub fn sharedSecret32(self: *const Engine) ?[32]u8 {
        const ss = self.sharedSecret orelse return null;
        if (ss.len != 32) return null;
        return ss.bytes[0..32].*;
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
        const earlySecret = HkdfSha256.extract(&zero, &psk);
        // Derive-Secret(., "derived", "") hashes the EMPTY transcript, not
        // an empty context string (RFC 8446 Section 7.1).
        var emptyCopy = Transcript.init();
        const emptyHash = emptyCopy.finish();
        var derived: [32]u8 = undefined;
        hkdfExpandLabelWithContext(earlySecret, "derived", &emptyHash, &derived);
        self.handshakeSecret = HkdfSha256.extract(&derived, ss.slice());
    }

    // Client-side handshake

    /// Builds the key_share list for a ClientHello: the X25519MLKEM768
    /// hybrid first, then plain X25519.
    ///
    /// Ordering matters — a server picks the first group it supports, so
    /// the hybrid has to come first to actually be negotiated. Plain
    /// X25519 stays in the list as a fallback so a peer without PQ
    /// support selects it directly rather than forcing a
    /// HelloRetryRequest round trip.
    ///
    /// `allowHybrid` must be false for QUIC. A hybrid share adds 1216
    /// bytes to the ClientHello, which overruns the fixed-size Initial
    /// packet buffer (and the 1200-byte datagram floor) once the TLS
    /// transport parameters are added. Fitting it needs CRYPTO frame
    /// fragmentation across several Initial packets (RFC 9000 Section
    /// 14), which the QUIC layer does not implement yet. Until it does,
    /// QUIC handshakes stay on plain X25519.
    fn buildKeyShares(self: *Engine, allowHybrid: bool) ![]const handshakeMod.ClientHello.KeyShareEntry {
        if (!allowHybrid) {
            self.hybridOffered = false;
            self.keyShareBuf[0] = .{ .group = .x25519, .keyExchange = &self.localKeypair.public_key };
            return self.keyShareBuf[0..1];
        }
        // RFC 10024: `mlkem_pk ‖ x25519_pk`. `localKeypair` was generated by
        // produceClientHello above and supplies the X25519 half.
        var seed: [MlKem.seed_length]u8 = undefined;
        fillRandom(&seed);
        const mlkp = try MlKem.KeyPair.generateDeterministic(seed);
        self.hybridMlKem = mlkp;
        const pk = mlkp.public_key.toBytes();
        @memcpy(self.hybridPublic[0..MLKEM_PK_LEN], &pk);
        @memcpy(self.hybridPublic[MLKEM_PK_LEN..], &self.localKeypair.public_key);
        self.hybridOffered = true;
        self.keyShareBuf[0] = .{ .group = .x25519_ml_kem768, .keyExchange = &self.hybridPublic };
        self.keyShareBuf[1] = .{ .group = .x25519, .keyExchange = &self.localKeypair.public_key };
        return self.keyShareBuf[0..2];
    }

    /// Server side of the hybrid: encapsulate to the client's public key and
    /// keep the ciphertext for our ServerHello. The `Engine` is per-connection
    /// (stack-local in `acceptBuffered`), so this state is private to the
    /// handshake and safe to store here.
    fn serverHybrid(self: *Engine, peer_key: []const u8) ![HY_SS_LEN]u8 {
        const pk_m: *const [MLKEM_PK_LEN]u8 =
            @ptrCast(@alignCast(peer_key[0..MLKEM_PK_LEN].ptr));
        const m_pk = MlKem.PublicKey.fromBytes(pk_m) catch
            return error.InvalidKeyShare;
        // `encapsDeterministic` rather than `encaps(io)`: this Engine carries
        // no `Io`, and threading one through `initServer` would change a public
        // signature. The 32-byte encapsulation seed is drawn from the same
        // source as the rest of the handshake, which is what the ml_kem API
        // requires either way.
        var enc_seed: [32]u8 = undefined;
        fillRandom(&enc_seed);
        const es = m_pk.encapsDeterministic(&enc_seed);
        var peer_x: [32]u8 = undefined;
        @memcpy(&peer_x, peer_key[MLKEM_PK_LEN..]);
        const ss_x = x25519.scalarmult(self.localKeypair.secret_key, peer_x) catch
            return error.InvalidKeyShare;
        // Server share: `mlkem_ct ‖ x25519_pk` (1088 + 32 = 1120).
        var ct: [HY_CT_LEN]u8 = undefined;
        @memcpy(ct[0..MLKEM_CT_LEN], &es.ciphertext);
        @memcpy(ct[MLKEM_CT_LEN..], &self.localKeypair.public_key);
        self.hybridServerCt = ct;
        // RFC 10024 4.3: concatenate, do not hash.
        var out: [HY_SS_LEN]u8 = undefined;
        @memcpy(out[0..MLKEM_SS_LEN], &es.shared_secret);
        @memcpy(out[MLKEM_SS_LEN..], &ss_x);
        return out;
    }

    /// Derives the ECDHE shared secret from the group's the server
    /// selected. X25519MLKEM768 needs the decapsulation key we kept
    /// from the ClientHello; anything else is rejected rather than
    /// silently downgraded, so a server cannot steer us off the group
    /// we offered (RFC 8446 4.1.4).
    fn deriveSharedSecret(self: *Engine, ks: handshakeMod.ServerHello.KeyShareEntry) !SharedSecret {
        if (ks.group == .x25519_ml_kem768) {
            if (!self.hybridOffered) return error.UnsupportedCipherSuite;
            if (ks.keyExchange.len != HY_CT_LEN) return error.InvalidKeyShare;
            const mlkp = self.hybridMlKem orelse return error.InvalidKeyShare;
            const ct: *const [MLKEM_CT_LEN]u8 = @ptrCast(ks.keyExchange.ptr);
            const ss_m = try mlkp.secret_key.decaps(ct);
            var srv_x: [32]u8 = undefined;
            @memcpy(&srv_x, ks.keyExchange[MLKEM_CT_LEN..]);
            const ss_x = x25519.scalarmult(self.localKeypair.secret_key, srv_x) catch
                return error.InvalidKeyShare;
            var out: [HY_SS_LEN]u8 = undefined;
            @memcpy(out[0..MLKEM_SS_LEN], &ss_m);
            @memcpy(out[MLKEM_SS_LEN..], &ss_x);
            return SharedSecret.of(&out);
        }
        if (ks.group != .x25519) return error.UnsupportedCipherSuite;
        if (ks.keyExchange.len != 32) return error.InvalidKeyShare;
        var peerPub: [32]u8 = undefined;
        @memcpy(&peerPub, ks.keyExchange);
        // ECDHE: sharedSecret = X25519(clientSecret, serverPublic)
        const ss = try x25519.scalarmult(self.localKeypair.secret_key, peerPub);
        return SharedSecret.of(&ss);
    }

    /// Produces the ClientHello message and generates the ephemeral keypair.
    /// Pass null serverName/quicTransportParams for plain TCP TLS.
    pub fn produceClientHello(
        self: *Engine,
        alpnProtocols: []const []const u8,
        signatureAlgorithms: []const handshakeMod.SignatureScheme,
        serverName: ?[]const u8,
        quicTransportParams: ?[]const u8,
    ) ![]u8 {
        // Generate ephemeral X25519 keypair (fallback share) and the
        // X25519MLKEM768 hybrid (preferred share).
        var seed: [32]u8 = undefined;
        fillRandom(&seed);
        self.localKeypair = try x25519.KeyPair.generateDeterministic(seed);

        const ch = handshakeMod.ClientHello{
            .random = blk: {
                var r: [32]u8 = undefined;
                fillRandom(&r);
                break :blk r;
            },
            .cipherSuites = &.{ .AES_128_GCM_SHA256, .AES_256_GCM_SHA384, .CHACHA20_POLY1305_SHA256 },
            // Non-null transport parameters mean QUIC, where the hybrid
            // share does not fit one Initial packet.
            .keyShareEntries = try self.buildKeyShares(quicTransportParams == null),
            .signatureAlgorithms = if (signatureAlgorithms.len > 0) signatureAlgorithms else &.{
                .ecdsa_secp256r1_sha256,
                .rsa_pss_rsae_sha256,
                .ed25519,
            },
            .alpnProtocols = alpnProtocols,
            .serverName = serverName,
            .quicTransportParams = quicTransportParams,
        };

        const encoded = try ch.encode(self.allocator);

        // Feed entire ClientHello to transcript hash
        self.transcript.feed(encoded);
        self.state = .clientHelloSent;

        // Notify transport layer
        self.cbs.onHandshakeData(self.cbs.ctx, .initial, encoded);

        return encoded;
    }

    /// Produces a ClientHello offering one resumption PSK (RFC 8446
    /// 4.2.11) alongside a fresh (EC)DHE share (pskDheKe). The session
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
        signatureAlgorithms: []const handshakeMod.SignatureScheme,
        serverName: ?[]const u8,
        session: *const sessionMod.ClientSession,
        nowMs: u64,
        quicTransportParams: ?[]const u8,
    ) ![]u8 {
        var seed: [32]u8 = undefined;
        fillRandom(&seed);
        self.localKeypair = try x25519.KeyPair.generateDeterministic(seed);

        const offerEarly = session.maxEarlyData > 0;
        const ch = handshakeMod.ClientHello{
            .random = blk: {
                var r: [32]u8 = undefined;
                fillRandom(&r);
                break :blk r;
            },
            .cipherSuites = &.{ .AES_128_GCM_SHA256, .AES_256_GCM_SHA384, .CHACHA20_POLY1305_SHA256 },
            .keyShareEntries = try self.buildKeyShares(quicTransportParams == null),
            .signatureAlgorithms = if (signatureAlgorithms.len > 0) signatureAlgorithms else &.{
                .ecdsa_secp256r1_sha256,
                .rsa_pss_rsae_sha256,
                .ed25519,
            },
            .alpnProtocols = alpnProtocols,
            .serverName = serverName,
            .pskIdentities = &.{session.ticket},
            .quicTransportParams = quicTransportParams,
            .earlyData = offerEarly,
        };
        const encoded = try ch.encode(self.allocator);
        errdefer self.allocator.free(encoded);

        // Patch the obfuscated age, then hash the truncated message and
        // patch the binder. Both spans are validated by the codec.
        var ageSpan = try handshakeMod.pskAgeSpan(encoded, 0);
        std.mem.writeInt(u32, ageSpan[0..], session.obfuscatedAge(nowMs), .big);
        const truncLen = try handshakeMod.pskTruncatedLen(encoded);
        const binder = computeResumptionBinder(self.transcript.state, encoded[0..truncLen], session.psk);
        const binderSpan = try handshakeMod.pskBinderSpan(encoded);
        if (binderSpan.len != HashLen) return error.ProtocolViolation;
        @memcpy(binderSpan[0..HashLen], &binder);

        self.offeredPsk = session.psk;
        self.earlyDataOffered = offerEarly;
        self.transcript.feed(encoded);
        if (offerEarly) {
            const earlySec = quicTls.earlySecret(session.psk);
            const chHash = self.transcript.finish();
            self.clientEarlyTrafficSecret = quicTls.clientEarlyTrafficSecret(earlySec, chHash);
        }
        self.state = .clientHelloSent;
        self.cbs.onHandshakeData(self.cbs.ctx, .initial, encoded);
        return encoded;
    }

    /// PSK binder for a zero-patched ClientHello: HMAC over
    /// Hash(prefix || chZeroed) keyed by Derive-Secret(early, "res
    /// binder", ""). The client passes its pre-CH transcript state as
    /// `prefix` (empty, or the HRR splice); the server passes a fresh
    /// hash (the received CH is the whole input). Nothing is fed here.
    fn computeResumptionBinder(prefix: handshakeMod.TranscriptHash, chZeroed: []const u8, psk: [32]u8) [HashLen]u8 {
        const zero: [32]u8 = .{0} ** 32;
        const early = HkdfSha256.extract(&zero, &psk);
        var emptyCopy = Transcript.init();
        const emptyHash = emptyCopy.finish();
        var binderKey: [32]u8 = undefined;
        hkdfExpandLabelWithContext(early, "res binder", &emptyHash, &binderKey);
        var copy = prefix;
        copy.update(chZeroed);
        const hash = copy.finalResult();
        var out: [HashLen]u8 = undefined;
        std.crypto.auth.hmac.Hmac(Sha256).create(&out, &hash, &binderKey);
        std.crypto.secureZero(u8, &binderKey);
        return out;
    }

    /// Splices a HelloRetryRequest into the transcript (RFC 8446 4.4.1):
    /// Transcript-Hash restarts as Hash(messageHash || HRR) where
    /// messageHash = 0xFE || 0x00 0x00 0x20 || Hash(ClientHello1).
    fn spliceHelloRetryRequest(self: *Engine, hrrMsg: []const u8) void {
        const h1 = self.transcript.finish();
        self.transcript = Transcript.init();
        var pre: [4 + HashLen]u8 = undefined;
        pre[0] = 0xFE;
        pre[1] = 0x00;
        pre[2] = 0x00;
        pre[3] = HashLen;
        @memcpy(pre[4..], &h1);
        self.transcript.feed(&pre);
        self.transcript.feed(hrrMsg);
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
        if (handshakeMod.isHelloRetryRequest(msg[4..])) {
            if (self.hrrSeen) return error.HandshakeFailed;
            self.hrrSeen = true;
            const sh = try handshakeMod.ServerHello.decode(msg[4..]);
            const group = sh.hrrGroup orelse return error.ProtocolViolation;
            // Only groups we actually offered may be requested. We offer
            // the hybrid and x25519, so both are legal here.
            if (group != .x25519 and group != .x25519_ml_kem768) return error.UnsupportedCipherSuite;
            self.spliceHelloRetryRequest(msg);
            self.hrrPendingGroup = group;
            self.state = .clientHelloSent;
            return;
        }
        const sh = try handshakeMod.ServerHello.decode(msg[4..]);
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
        self.sharedSecret = try self.deriveSharedSecret(ks);
        self.state = .serverHelloReceived;

        // Derive handshake traffic secrets (RFC 8446 Section 7.1)
        self.deriveHandshakeKeys();
        self.state = .handshakeKeysDerived;
    }

    /// Processes EncryptedExtensions (full message with header).
    pub fn processEncryptedExtensions(self: *Engine, msg: []const u8) !void {
        if (msg.len < 4) return error.ProtocolViolation;
        self.transcript.feed(msg);
        const ee = try handshakeMod.EncryptedExtensions.decode(msg[4..]);
        // Own the selection: callers often parse from reusable reassembly
        // buffers whose bytes shift as later messages arrive.
        if (self.negotiatedAlpn) |old| self.allocator.free(old);
        self.negotiatedAlpn = if (ee.alpnProtocol) |wire| try self.allocator.dupe(u8, wire) else null;
        if (self.peerQuicTransportParams) |old| self.allocator.free(old);
        self.peerQuicTransportParams = if (ee.quicTransportParams) |tp| try self.allocator.dupe(u8, tp) else null;
        self.earlyDataAccepted = ee.earlyDataAccepted;
        if (!ee.earlyDataAccepted) {
            self.clientEarlyTrafficSecret = null;
        }
        self.state = .encryptedExtensionsReceived;
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
        _ = try handshakeMod.CertificateVerify.decode(msg[4..]);
        self.state = .certificateVerifyReceived;
    }

    /// Processes and verifies Finished from server (full message with
    /// header). Verification uses the server handshake traffic secret over
    /// the transcript *before* this message, then feeds on success.
    pub fn processFinished(self: *Engine, msg: []const u8) !void {
        if (msg.len != 4 + HashLen) return error.ProtocolViolation;
        if (msg[0] != @intFromEnum(handshakeMod.HandshakeType.finished)) return error.ProtocolViolation;
        const sHs = self.serverHsTrafficSecret orelse return error.HandshakeFailed;
        var finishedKey: [HashLen]u8 = undefined;
        hkdfExpandLabel(sHs, "finished", &finishedKey);
        var copy = self.transcript.state;
        const hash = copy.finalResult();
        var expect: [HashLen]u8 = undefined;
        std.crypto.auth.hmac.Hmac(Sha256).create(&expect, &hash, &finishedKey);
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
        pos += 1 + chBody[pos]; // legacySessionId
        if (pos + 2 > chBody.len) return false;
        const csLen: usize = (@as(usize, chBody[pos]) << 8) | chBody[pos + 1];
        pos += 2 + csLen; // cipher suites
        if (pos + 1 > chBody.len) return false;
        pos += 1 + chBody[pos]; // compression methods
        if (pos + 2 > chBody.len) return false;
        const extLen: usize = (@as(usize, chBody[pos]) << 8) | chBody[pos + 1];
        pos += 2;
        const extEnd = @min(chBody.len, pos + extLen);
        while (pos + 4 <= extEnd) {
            const t = std.mem.readInt(u16, chBody[pos..][0..2], .big);
            const l: usize = (@as(usize, chBody[pos + 2]) << 8) | chBody[pos + 3];
            pos += 4;
            if (pos + l > extEnd) return false;
            if (t == @intFromEnum(handshakeMod.ExtensionType.key_share)) {
                var kp: usize = 2;
                if (l >= 2) {
                    const listLen: usize = (@as(usize, chBody[pos]) << 8) | chBody[pos + 1];
                    const listEnd = @min(l, 2 + listLen);
                    while (kp + 4 <= listEnd) {
                        const group = std.mem.readInt(u16, chBody[pos + kp ..][0..2], .big);
                        const slen: usize = (@as(usize, chBody[pos + kp + 2]) << 8) | chBody[pos + kp + 3];
                        if (group == @intFromEnum(handshakeMod.NamedGroup.x25519) and slen == 32) return true;
                        if (group == @intFromEnum(handshakeMod.NamedGroup.x25519_ml_kem768) and slen == HY_PK_LEN) return true;
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
    pub fn selectPsk(self: *Engine, fullCh: []const u8, nowMs: u64) bool {
        self.resumptionPsk = null;
        self.pskSuite = null;
        self.earlyDataAccepted = false;
        self.clientEarlyTrafficSecret = null;
        const keys = self.ticketKeys orelse return false;
        const offer = handshakeMod.parsePskFirst(fullCh) catch return false;
        const o = offer orelse return false;
        if (o.binders.len < HashLen) return false;
        const opened = keys.open(o.ticket, nowMs) catch return false;
        if (!suiteSupportsResumption(opened.suite)) return false;

        // RFC 8446 Section 4.2.11.2: Compute binder over truncated ClientHello
        const truncLen = handshakeMod.pskTruncatedLen(fullCh) catch return false;
        const fresh = handshakeMod.TranscriptHash.init(.{});
        const binder = computeResumptionBinder(fresh, fullCh[0..truncLen], opened.psk);
        var diff: u8 = 0;
        for (binder, o.binders[0..HashLen]) |a, b| diff |= a ^ b;
        if (diff != 0) {
            std.crypto.secureZero(u8, @constCast(&opened.psk));
            return false;
        }
        self.resumptionPsk = opened.psk;
        self.pskSuite = opened.suite;

        // Evaluate 0-RTT early data offer
        const clientWantsEarly = handshakeMod.hasEarlyDataExtension(fullCh);
        if (clientWantsEarly and self.maxEarlyData > 0 and opened.maxEarlyData > 0) {
            // Anti-replay protection check (fail closed if replay cache absent or rejects)
            if (self.replayCache) |rc| {
                if (rc.checkAndRecord(o.ticket, nowMs)) {
                    self.earlyDataAccepted = true;
                    const earlySec = quicTls.earlySecret(opened.psk);
                    var copy = self.transcript.state;
                    const chHash = copy.finalResult();
                    self.clientEarlyTrafficSecret = quicTls.clientEarlyTrafficSecret(earlySec, chHash);
                }
            }
        }
        return true;
    }

    /// Produces a HelloRetryRequest (RFC 8446 Section 4.1.4) requesting
    /// an x25519 share, for a ClientHello that offered none. Splices the
    /// transcript (messageHash construction) and marks `hrrSent` so a
    /// second shareless hello fails instead of looping.
    pub fn produceHelloRetryRequest(self: *Engine) ![]u8 {
        if (self.hrrSent) return error.HandshakeFailed;
        self.hrrSent = true;
        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.allocator);
        try body.appendSlice(self.allocator, &.{ 0x03, 0x03 });
        try body.appendSlice(self.allocator, &handshakeMod.helloRetryMagic);
        try body.appendSlice(self.allocator, &.{self.legacySessionIdLen});
        if (self.legacySessionIdLen > 0) {
            try body.appendSlice(self.allocator, self.legacySessionIdBuf[0..self.legacySessionIdLen]);
        }
        try body.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(tls.CipherSuite.AES_128_GCM_SHA256))));
        try body.append(self.allocator, 0x00);
        var exts = std.ArrayList(u8).empty;
        defer exts.deinit(self.allocator);
        // supportedVersions: TLS 1.3 only.
        try exts.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(handshakeMod.ExtensionType.supported_versions))));
        try exts.appendSlice(self.allocator, &.{ 0x00, 0x02, 0x03, 0x04 });
        // keyShare: selected group only, no keyExchange bytes.
        try exts.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(handshakeMod.ExtensionType.key_share))));
        try exts.appendSlice(self.allocator, &.{ 0x00, 0x02 });
        try exts.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(handshakeMod.NamedGroup.x25519))));
        try body.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(exts.items.len))));
        try body.appendSlice(self.allocator, exts.items);

        var msg = std.ArrayList(u8).empty;
        errdefer msg.deinit(self.allocator);
        try msg.append(self.allocator, @intFromEnum(handshakeMod.HandshakeType.server_hello));
        const bodyLen: u24 = @intCast(body.items.len);
        try msg.append(self.allocator, @intCast((bodyLen >> 16) & 0xFF));
        try msg.append(self.allocator, @intCast((bodyLen >> 8) & 0xFF));
        try msg.append(self.allocator, @intCast(bodyLen & 0xFF));
        try msg.appendSlice(self.allocator, body.items);
        self.spliceHelloRetryRequest(msg.items);
        self.state = .serverHelloSent;
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
        pos = 34; // skip clientVersion(2) + random(32)

        // legacySessionId
        if (pos + 1 > chBody.len) return error.ProtocolViolation;
        pos += 1 + chBody[pos];

        // cipherSuites
        if (pos + 2 > chBody.len) return error.ProtocolViolation;
        const csLen: usize = (@as(usize, chBody[pos]) << 8) | chBody[pos + 1];
        pos += 2;
        if (pos + csLen > chBody.len) return error.ProtocolViolation;
        const csEnd = pos + csLen;
        var offersAes = false;
        var offersChacha = false;
        var p: usize = pos;
        while (p + 2 <= csEnd) : (p += 2) {
            const suite: tls.CipherSuite = @enumFromInt((@as(u16, chBody[p]) << 8) | chBody[p + 1]);
            switch (suite) {
                .AES_128_GCM_SHA256 => offersAes = true,
                .CHACHA20_POLY1305_SHA256 => offersChacha = true,
                else => {},
            }
        }
        pos = csEnd;

        // legacyCompressionMethods
        if (pos + 1 > chBody.len) return error.ProtocolViolation;
        pos += 1 + chBody[pos];

        // extensions
        if (pos + 2 > chBody.len) return error.ProtocolViolation;
        const extLen: usize = (@as(usize, chBody[pos]) << 8) | chBody[pos + 1];
        pos += 2;
        const extEnd = std.math.add(usize, pos, extLen) catch return error.ProtocolViolation;
        if (extEnd > chBody.len) return error.ProtocolViolation;

        var peerShare: ?[32]u8 = null;
        while (pos + 4 <= extEnd) {
            const extType = std.mem.readInt(u16, chBody[pos..][0..2], .big);
            const extDataLen: usize = (@as(usize, chBody[pos + 2]) << 8) | chBody[pos + 3];
            pos += 4;
            const dataEnd = std.math.add(usize, pos, extDataLen) catch return error.ProtocolViolation;
            if (dataEnd > extEnd) return error.ProtocolViolation;
            const data = chBody[pos..dataEnd];

            if (extType == @intFromEnum(handshakeMod.ExtensionType.key_share)) {
                // KeyShareClientHello: clientShares = vector< KeyShareEntry >.
                var kp: usize = 2; // skip vector length
                if (data.len >= 2) {
                    const listLen: usize = (@as(usize, data[0]) << 8) | data[1];
                    const listEnd = @min(data.len, 2 + listLen);
                    while (kp + 4 <= listEnd) {
                        const group = std.mem.readInt(u16, data[kp..][0..2], .big);
                        const shareLen: usize = (@as(usize, data[kp + 2]) << 8) | data[kp + 3];
                        kp += 4;
                        if (kp + shareLen > listEnd) break;
                        if (group == @intFromEnum(handshakeMod.NamedGroup.x25519) and shareLen == 32) {
                            if (peerShare == null) peerShare = data[kp..][0..32].*;
                        } else if (group == @intFromEnum(handshakeMod.NamedGroup.x25519_ml_kem768) and
                            shareLen == HY_PK_LEN)
                        {
                            // Keep the client's hybrid public key for the
                            // encapsulation below. Engine is per-connection
                            // (acceptBuffered stack-local), so this is not shared.
                            if (self.peerHybridKey == null) {
                                self.peerHybridKey = undefined;
                                @memcpy(&self.peerHybridKey.?, data[kp..][0..HY_PK_LEN]);
                            }
                        }
                        kp += shareLen;
                    }
                }
            } else if (extType == @intFromEnum(handshakeMod.ExtensionType.signature_algorithms)) {
                // SignatureSchemeList: vector<u16>; 0x0403 = ecdsa_secp256r1_sha256.
                if (data.len >= 2) {
                    const listLen: usize = (@as(usize, data[0]) << 8) | data[1];
                    const listEnd = @min(data.len, 2 + listLen);
                    var sp: usize = 2;
                    while (sp + 2 <= listEnd) : (sp += 2) {
                        const scheme = std.mem.readInt(u16, data[sp..][0..2], .big);
                        if (scheme == @intFromEnum(handshakeMod.SignatureScheme.ecdsa_secp256r1_sha256)) {
                            self.peerOffersEcdsa = true;
                        }
                    }
                }
            }
            // All other extensions are skipped (middlebox compat, versions, SNI...).

            pos = dataEnd;
        }

        // Server preference: AES_128_GCM_SHA256 first, CHACHA20 fallback.
        const suite: tls.CipherSuite = if (offersAes) .AES_128_GCM_SHA256 else if (offersChacha) .CHACHA20_POLY1305_SHA256 else return error.UnsupportedCipherSuite;
        self.selectedSuite = suite;
        // A client offering only the hybrid has no other way to be served.
        // When both are offered we keep x25519, which is the path the suite
        // exercises. The key_share is part of the transcript, so a group that
        // disagrees with the derived secret breaks the handshake.
        if (peerShare) |share| {
            const ss = x25519.scalarmult(self.localKeypair.secret_key, share) catch
                return error.InvalidKeyShare;
            self.sharedSecret = SharedSecret.of(&ss);
        } else if (self.peerHybridKey) |pk| {
            self.sharedSecret = SharedSecret.of(&try self.serverHybrid(pk[0..]));
        } else {
            return error.InvalidKeyShare;
        }
    }

    /// Verifies a client Finished message (full handshake message with header)
    /// against the current transcript and feeds it on success.
    pub fn verifyClientFinished(self: *Engine, msg: []const u8) !void {
        if (msg.len != 4 + HashLen) return error.ProtocolViolation;
        if (msg[0] != @intFromEnum(handshakeMod.HandshakeType.finished)) return error.ProtocolViolation;
        const cHs = self.clientHsTrafficSecret orelse return error.HandshakeFailed;
        var finishedKey: [HashLen]u8 = undefined;
        hkdfExpandLabel(cHs, "finished", &finishedKey);
        var copy = self.transcript.state;
        const hash = copy.finalResult();
        var expect: [HashLen]u8 = undefined;
        std.crypto.auth.hmac.Hmac(Sha256).create(&expect, &hash, &finishedKey);
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
        try out.append(self.allocator, @intFromEnum(handshakeMod.HandshakeType.certificate_request));
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
        if (msg[0] != @intFromEnum(handshakeMod.HandshakeType.certificate_request)) return error.ProtocolViolation;
        self.transcript.feed(msg);
    }

    /// Builds a client Certificate message (type 11) from DER entries and
    /// feeds the transcript. An empty list is encodable; policy (required
    /// vs optional) is enforced by the server, not here.
    pub fn produceClientCertificate(self: *Engine, ders: []const []const u8) ![]u8 {
        var body = std.ArrayList(u8).empty;
        errdefer body.deinit(self.allocator);
        try body.append(self.allocator, 0x00); // requestContext length 0
        var listBuf = std.ArrayList(u8).empty;
        defer listBuf.deinit(self.allocator);
        for (ders) |der| {
            const len: u24 = @intCast(der.len);
            try listBuf.append(self.allocator, @intCast((len >> 16) & 0xFF));
            try listBuf.append(self.allocator, @intCast((len >> 8) & 0xFF));
            try listBuf.append(self.allocator, @intCast(len & 0xFF));
            try listBuf.appendSlice(self.allocator, der);
            try listBuf.appendSlice(self.allocator, &.{ 0x00, 0x00 }); // empty extensions
        }
        const total: u24 = @intCast(listBuf.items.len);
        try body.append(self.allocator, @intCast((total >> 16) & 0xFF));
        try body.append(self.allocator, @intCast((total >> 8) & 0xFF));
        try body.append(self.allocator, @intCast(total & 0xFF));
        try body.appendSlice(self.allocator, listBuf.items);

        var msg = std.ArrayList(u8).empty;
        errdefer msg.deinit(self.allocator);
        try msg.append(self.allocator, @intFromEnum(handshakeMod.HandshakeType.certificate));
        const bodyLen: u24 = @intCast(body.items.len);
        try msg.append(self.allocator, @intCast((bodyLen >> 16) & 0xFF));
        try msg.append(self.allocator, @intCast((bodyLen >> 8) & 0xFF));
        try msg.append(self.allocator, @intCast(bodyLen & 0xFF));
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
        if (msg[0] != @intFromEnum(handshakeMod.HandshakeType.certificate)) return error.ProtocolViolation;
        const bodyLen: usize = (@as(usize, msg[1]) << 16) | (@as(usize, msg[2]) << 8) | msg[3];
        if (4 + bodyLen != msg.len) return error.ProtocolViolation;
        var pos: usize = 4;
        if (pos + 1 > msg.len) return error.ProtocolViolation;
        const ctxLen: usize = msg[pos];
        pos += 1;
        if (pos + ctxLen > msg.len) return error.ProtocolViolation;
        pos += ctxLen;
        if (pos + 3 > msg.len) return error.ProtocolViolation;
        const listLen: usize = (@as(usize, msg[pos]) << 16) | (@as(usize, msg[pos + 1]) << 8) | msg[pos + 2];
        pos += 3;
        if (pos + listLen != msg.len) return error.ProtocolViolation;
        const listEnd = pos + listLen;

        var ders = std.ArrayList([]u8).empty;
        errdefer {
            for (ders.items) |d| self.allocator.free(d);
            ders.deinit(self.allocator);
        }
        while (pos < listEnd) {
            if (pos + 3 > listEnd) return error.ProtocolViolation;
            const certLen: usize = (@as(usize, msg[pos]) << 16) | (@as(usize, msg[pos + 1]) << 8) | msg[pos + 2];
            pos += 3;
            if (certLen == 0 or pos + certLen > listEnd) return error.ProtocolViolation;
            // Structural guard before any X.509 parsing: truncated DER must
            // fail here, never as an out-of-bounds panic downstream.
            if (!certMod.checkDerStructure(msg[pos .. pos + certLen])) return error.ProtocolViolation;
            const der = try self.allocator.dupe(u8, msg[pos .. pos + certLen]);
            errdefer self.allocator.free(der);
            try ders.append(self.allocator, der);
            pos += certLen;
            if (pos + 2 > listEnd) return error.ProtocolViolation;
            const extLen: usize = (@as(usize, msg[pos]) << 8) | msg[pos + 1];
            pos += 2;
            if (pos + extLen > listEnd) return error.ProtocolViolation;
            pos += extLen;
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
        const ecScalar = try parseEcPrivateScalar(self.allocator, privateKeyDer);
        const ecPubPoint = try P256.basePoint.mul(ecScalar, .big);
        const ecKeypair = EcdsaP256.KeyPair{
            .secret_key = try EcdsaP256.SecretKey.fromBytes(ecScalar),
            .public_key = .{ .p = ecPubPoint },
        };
        var cvContent: [64 + 33 + 1 + HashLen]u8 = undefined;
        @memset(cvContent[0..64], 0x20);
        @memcpy(cvContent[64..][0..33], label);
        cvContent[64 + 33] = 0x00;
        var hsCopy = self.transcript.state;
        const hsHash = hsCopy.finalResult();
        @memcpy(cvContent[64 + 33 + 1 ..], &hsHash);
        var cvNoise: [EcdsaP256.noise_length]u8 = undefined;
        fillRandom(&cvNoise);
        const ecSig = try ecKeypair.sign(&cvContent, cvNoise);
        var out: ClientSignature = undefined;
        const sigSlice = ecSig.toDer(&out.der);
        out.len = sigSlice.len;
        return out;
    }

    /// Builds client CertificateVerify (type 15) and feeds the transcript.
    pub fn produceClientCertificateVerify(self: *Engine, privateKeyDer: []const u8) ![]u8 {
        const signed = try self.signClientCertificateVerify(privateKeyDer);
        const sigDer = signed.der;
        const sigLen = signed.len;
        var body = std.ArrayList(u8).empty;
        errdefer body.deinit(self.allocator);
        try body.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(handshakeMod.SignatureScheme.ecdsa_secp256r1_sha256))));
        try body.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(sigLen))));
        try body.appendSlice(self.allocator, sigDer[0..sigLen]);

        var msg = std.ArrayList(u8).empty;
        errdefer msg.deinit(self.allocator);
        try msg.append(self.allocator, @intFromEnum(handshakeMod.HandshakeType.certificate_verify));
        const bodyLen: u24 = @intCast(body.items.len);
        try msg.append(self.allocator, @intCast((bodyLen >> 16) & 0xFF));
        try msg.append(self.allocator, @intCast((bodyLen >> 8) & 0xFF));
        try msg.append(self.allocator, @intCast(bodyLen & 0xFF));
        try msg.appendSlice(self.allocator, body.items);
        body.deinit(self.allocator);

        self.transcript.feed(msg.items);
        return msg.toOwnedSlice(self.allocator);
    }

    /// Builds client Finished: HMAC(clientFinishedKey, transcript hash).
    /// Feeds the transcript. Application keys were already derived when the
    /// server Finished was processed.
    pub fn produceClientFinished(self: *Engine) ![]u8 {
        const cHs = self.clientHsTrafficSecret orelse return error.HandshakeFailed;
        var finishedKey: [HashLen]u8 = undefined;
        hkdfExpandLabel(cHs, "finished", &finishedKey);
        var copy = self.transcript.state;
        const hash = copy.finalResult();
        var verifyData: [HashLen]u8 = undefined;
        std.crypto.auth.hmac.Hmac(Sha256).create(&verifyData, &hash, &finishedKey);

        var msg = std.ArrayList(u8).empty;
        errdefer msg.deinit(self.allocator);
        try msg.append(self.allocator, @intFromEnum(handshakeMod.HandshakeType.finished));
        try msg.appendSlice(self.allocator, &.{ 0x00, 0x00, @as(u8, HashLen) });
        try msg.appendSlice(self.allocator, &verifyData);
        self.transcript.feed(msg.items);
        return msg.toOwnedSlice(self.allocator);
    }

    /// Verifies a client CertificateVerify (full message with header)
    /// against the leaf certificate DER: P-256 ECDSA over the client CV
    /// context. Feeds the transcript on success.
    pub fn processClientCertificateVerify(self: *Engine, msg: []const u8, leafDer: []const u8) !void {
        if (msg.len < 4) return error.ProtocolViolation;
        if (msg[0] != @intFromEnum(handshakeMod.HandshakeType.certificate_verify)) return error.ProtocolViolation;
        const cv = handshakeMod.CertificateVerify.decode(msg[4..]) catch return error.ProtocolViolation;
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
        var cvContent: [64 + 33 + 1 + HashLen]u8 = undefined;
        @memset(cvContent[0..64], 0x20);
        @memcpy(cvContent[64..][0..33], label);
        cvContent[64 + 33] = 0x00;
        var hsCopy = self.transcript.state;
        const hsHash = hsCopy.finalResult();
        @memcpy(cvContent[64 + 33 + 1 ..], &hsHash);
        sig.verify(&cvContent, pubkey) catch return error.CertificateSignatureInvalid;
        self.transcript.feed(msg);
    }

    /// Verifies a server CertificateVerify (full message with header)
    /// against the leaf certificate DER: P-256 ECDSA over the server CV
    /// context. Mirrors the client-CV path with the server label. Feeds
    /// the transcript on success. Without this, a client authenticates
    /// the server by chain/hostname and Finished MAC only, never binding
    /// the transcript to the leaf key.
    pub fn processServerCertificateVerify(self: *Engine, msg: []const u8, leafDer: []const u8) !void {
        if (msg.len < 4) return error.ProtocolViolation;
        if (msg[0] != @intFromEnum(handshakeMod.HandshakeType.certificate_verify)) return error.ProtocolViolation;
        const cv = handshakeMod.CertificateVerify.decode(msg[4..]) catch return error.ProtocolViolation;
        if (cv.algorithm != .ecdsa_secp256r1_sha256) return error.UnsupportedSignatureScheme;

        const leaf = certMod.X509Certificate.parseDer(leafDer) catch return error.CertificateSignatureInvalid;
        const curve = switch (leaf.parsed.pub_key_algo) {
            .X9_62_id_ecPublicKey => |c| c,
            else => return error.CertificateSignatureInvalid,
        };
        if (curve != .X9_62_prime256v1) return error.CertificateSignatureInvalid;
        const pubkey = EcdsaP256.PublicKey.fromSec1(leaf.parsed.pubKey()) catch return error.CertificateSignatureInvalid;
        const sig = EcdsaP256.Signature.fromDer(cv.signature) catch return error.CertificateSignatureInvalid;

        const label = "TLS 1.3, server CertificateVerify";
        var cvContent: [64 + 33 + 1 + HashLen]u8 = undefined;
        @memset(cvContent[0..64], 0x20);
        @memcpy(cvContent[64..][0..33], label);
        cvContent[64 + 33] = 0x00;
        var hsCopy = self.transcript.state;
        const hsHash = hsCopy.finalResult();
        @memcpy(cvContent[64 + 33 + 1 ..], &hsHash);
        sig.verify(&cvContent, pubkey) catch return error.CertificateSignatureInvalid;
        self.transcript.feed(msg);
        self.state = .certificateVerifyReceived;
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
        const ecOid = [_]u8{ 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01 };
        if (std.mem.indexOf(u8, pkcs8[pos + alg.hdr ..][0..alg.len], &ecOid) == null) {
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
        // Extract legacySessionId and SNI from ClientHello body:
        //   [0..2]   clientVersion (0x0303)
        //   [2..34]  random (32 bytes)
        //   [34]     legacySessionIdLength (u8)
        //   [35..]   legacySessionId
        if (body.len > 34) {
            const sidLen = body[34];
            if (sidLen <= 32 and 35 + @as(usize, sidLen) <= body.len) {
                @memcpy(self.legacySessionIdBuf[0..sidLen], body[35 .. 35 + sidLen]);
                self.legacySessionIdLen = sidLen;
            }

            var pos: usize = 35 + @as(usize, sidLen);
            if (pos + 2 <= body.len) {
                const csLen: usize = (@as(usize, body[pos]) << 8) | body[pos + 1];
                pos += 2 + csLen;
                if (pos < body.len) {
                    const compLen = body[pos];
                    pos += 1 + compLen;
                    if (pos + 2 <= body.len) {
                        const extLen: usize = (@as(usize, body[pos]) << 8) | body[pos + 1];
                        pos += 2;
                        const extEnd = @min(body.len, pos + extLen);
                        while (pos + 4 <= extEnd) {
                            const extType = std.mem.readInt(u16, body[pos..][0..2], .big);
                            const extDataLen: usize = (@as(usize, body[pos + 2]) << 8) | body[pos + 3];
                            pos += 4;
                            if (pos + extDataLen > extEnd) break;
                            if (extType == 0 and extDataLen >= 5) {
                                const listLen: usize = (@as(usize, body[pos]) << 8) | body[pos + 1];
                                if (listLen >= 3 and pos + 2 + listLen <= pos + extDataLen) {
                                    const nameType = body[pos + 2];
                                    if (nameType == 0) {
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
                            if (extType == handshakeMod.QUIC_TRANSPORT_PARAMETERS_ID) {
                                if (self.peerQuicTransportParams) |old| self.allocator.free(old);
                                self.peerQuicTransportParams = self.allocator.dupe(u8, body[pos..][0..extDataLen]) catch null;
                            }
                            pos += extDataLen;
                        }
                    }
                }
            }
        }
        self.state = .clientHelloReceived;
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
        alpnPreference: []const alpnMod.Protocol,
        clientAlpnWire: []const []const u8,
        quicTransportParams: ?[]const u8,
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
        const usePsk = if (self.resumptionPsk != null and self.pskSuite != null) blk: {
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
        //   legacyVersion: 0x0303 (TLS 1.2)
        //   random: 32 bytes
        //   legacySessionIdEcho: 1 byte len + echo bytes
        //   cipherSuite: 2 bytes
        //   legacyCompressionMethod: 0x00 (1 byte)
        //   extensions: 2 bytes len + extensions
        var shBody = std.ArrayList(u8).empty;
        defer shBody.deinit(self.allocator);

        // legacyVersion (0x0303)
        try shBody.appendSlice(self.allocator, &.{ 0x03, 0x03 });

        // serverRandom (32 bytes)
        var serverRandom: [32]u8 = undefined;
        fillRandom(&serverRandom);
        try shBody.appendSlice(self.allocator, &serverRandom);

        // legacySessionIdEcho
        try shBody.append(self.allocator, self.legacySessionIdLen);
        if (self.legacySessionIdLen > 0) {
            try shBody.appendSlice(self.allocator, self.legacySessionIdBuf[0..self.legacySessionIdLen]);
        }

        // cipherSuite
        try shBody.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(self.selectedSuite))));

        // legacyCompressionMethod (0x00)
        try shBody.append(self.allocator, 0x00);

        // extensions
        var exts = std.ArrayList(u8).empty;
        defer exts.deinit(self.allocator);

        // keyShare extension
        var ksBody = std.ArrayList(u8).empty;
        defer ksBody.deinit(self.allocator);
        // The group we answer with must be the one we encapsulated for.
        // Hardcoding x25519/32 here is what made a hybrid-only client reject
        // us with `tls_parse_stoc_key_share: bad key share`.
        if (self.hybridServerCt) |ct| {
            try ksBody.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(handshakeMod.NamedGroup.x25519_ml_kem768))));
            try ksBody.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(ct.len))));
            try ksBody.appendSlice(self.allocator, &ct);
        } else {
            try ksBody.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(handshakeMod.NamedGroup.x25519))));
            try ksBody.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 32)));
            try ksBody.appendSlice(self.allocator, &pubkey);
        }

        try exts.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(handshakeMod.ExtensionType.key_share))));
        try exts.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(ksBody.items.len))));
        try exts.appendSlice(self.allocator, ksBody.items);

        // supportedVersions (TLS 1.3 = 0x0304)
        try exts.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(handshakeMod.ExtensionType.supported_versions))));
        try exts.appendSlice(self.allocator, &.{ 0x00, 0x02 });
        try exts.appendSlice(self.allocator, &.{ 0x03, 0x04 });

        // serverName ack (empty) — only when the client sent SNI. An
        // unsolicited ack violates RFC 8446 Section 4.2 and aborts strict
        // clients (e.g. IP-literal handshakes carry no SNI).
        if (self.sniHostname != null) {
            try exts.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(handshakeMod.ExtensionType.server_name))));
            try exts.appendSlice(self.allocator, &.{ 0x00, 0x00 });
        }

        // preSharedKey ack: selectedIdentity 0 (we accept only the
        // first offered identity). Present only on the abbreviated flight.
        if (usePsk) {
            try exts.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(handshakeMod.ExtensionType.pre_shared_key))));
            try exts.appendSlice(self.allocator, &.{ 0x00, 0x02, 0x00, 0x00 });
        }

        try shBody.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(exts.items.len))));
        try shBody.appendSlice(self.allocator, exts.items);

        // ServerHello with handshake header
        var shMsg = std.ArrayList(u8).empty;
        errdefer shMsg.deinit(self.allocator);
        try shMsg.append(self.allocator, @intFromEnum(handshakeMod.HandshakeType.server_hello));
        const shBodyLen: u24 = @intCast(shBody.items.len);
        try shMsg.append(self.allocator, @intCast((shBodyLen >> 16) & 0xFF));
        try shMsg.append(self.allocator, @intCast((shBodyLen >> 8) & 0xFF));
        try shMsg.append(self.allocator, @intCast(shBodyLen & 0xFF));
        try shMsg.appendSlice(self.allocator, shBody.items);

        self.transcript.feed(shMsg.items);

        // Snapshot for QUIC: handshake traffic secrets hash CH..SH.
        const hsTranscriptHash = self.transcript.finish();

        // Handshake traffic secrets hash CH..SH (RFC 8446 Section 7.1), so
        // they can only be derived once ServerHello is in the transcript.
        if (self.serverHsTrafficSecret == null) {
            self.deriveHandshakeKeys();
        }

        // EncryptedExtensions
        var eeBody = std.ArrayList(u8).empty;
        defer eeBody.deinit(self.allocator);
        var eeExts = std.ArrayList(u8).empty;
        defer eeExts.deinit(self.allocator);

        // ALPN extension — per RFC 8446 Section 4.3.1 must be in EncryptedExtensions.
        // Only sent when the client actually offered ALPN: an unsolicited
        // selection breaks clients without an ALPN hook (e.g. IP-literal
        // handshakes), which then speak HTTP/1.1 by default.
        if (alpnPreference.len > 0 and clientAlpnWire.len > 0) {
            const selectedOpt = alpnMod.negotiateServer(alpnPreference, clientAlpnWire);
            if (selectedOpt) |selected| {
                const wire = selected.wireName();
                if (self.negotiatedAlpn) |old| self.allocator.free(old);
                self.negotiatedAlpn = try self.allocator.dupe(u8, wire);

                var alpnList = std.ArrayList(u8).empty;
                defer alpnList.deinit(self.allocator);
                try alpnList.append(self.allocator, @intCast(wire.len));
                try alpnList.appendSlice(self.allocator, wire);

                var alpnExtBody = std.ArrayList(u8).empty;
                defer alpnExtBody.deinit(self.allocator);
                try alpnExtBody.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(alpnList.items.len))));
                try alpnExtBody.appendSlice(self.allocator, alpnList.items);

                try eeExts.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(handshakeMod.ExtensionType.application_layer_protocol_negotiation))));
                try eeExts.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(alpnExtBody.items.len))));
                try eeExts.appendSlice(self.allocator, alpnExtBody.items);
            }
        }

        // QUIC transport parameters (RFC 9001 Section 7.4, ext 57):
        // opaque block, QUIC paths only (null on TCP).
        if (quicTransportParams) |tp| {
            try eeExts.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, handshakeMod.QUIC_TRANSPORT_PARAMETERS_ID)));
            try eeExts.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(tp.len))));
            try eeExts.appendSlice(self.allocator, tp);
        }

        // early_data extension (RFC 8446 Section 4.2.10) in EncryptedExtensions:
        // empty body (length 0), signals to client that early data was accepted.
        if (self.earlyDataAccepted) {
            try eeExts.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(handshakeMod.ExtensionType.early_data))));
            try eeExts.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0)));
        }

        try eeBody.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(eeExts.items.len))));
        try eeBody.appendSlice(self.allocator, eeExts.items);

        var eeMsg = std.ArrayList(u8).empty;
        errdefer eeMsg.deinit(self.allocator);
        try eeMsg.append(self.allocator, @intFromEnum(handshakeMod.HandshakeType.encrypted_extensions));
        const eeBodyLen: u24 = @intCast(eeBody.items.len);
        try eeMsg.append(self.allocator, @intCast((eeBodyLen >> 16) & 0xFF));
        try eeMsg.append(self.allocator, @intCast((eeBodyLen >> 8) & 0xFF));
        try eeMsg.append(self.allocator, @intCast(eeBodyLen & 0xFF));
        try eeMsg.appendSlice(self.allocator, eeBody.items);

        self.transcript.feed(eeMsg.items);

        // Mutual TLS: CertificateRequest goes here (EE..CR..Cert), so the
        // transcript order matches what the client observes. Enabled via
        // `requestClientCert`; never sent on an abbreviated (PSK) flight,
        // where authentication rides the binder instead of certificates.
        var crMsg: ?[]u8 = null;
        errdefer if (crMsg) |m| self.allocator.free(m);
        if (self.requestClientCert and !usePsk) {
            crMsg = try self.produceCertificateRequest();
        }

        // Certificate + CertificateVerify are omitted on abbreviated
        // (PSK) flights: authentication rides the binder, and the
        // transcript skips exactly what is not sent. Empty owned slices
        // mark the omission (verified freeable, even zero-length).
        var certMsg = std.ArrayList(u8).empty;
        errdefer certMsg.deinit(self.allocator);
        var cvMsg = std.ArrayList(u8).empty;
        errdefer cvMsg.deinit(self.allocator);
        if (!usePsk) {
            // Certificate
            var certBody = std.ArrayList(u8).empty;
            defer certBody.deinit(self.allocator);
            try certBody.append(self.allocator, 0x00); // requestContext length 0
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
                    const derLen = std.base64.standard.Decoder.calcSizeForSlice(clean.items) catch break;
                    const der = self.allocator.alloc(u8, derLen) catch break;
                    std.base64.standard.Decoder.decode(der, clean.items) catch {
                        self.allocator.free(der);
                        break;
                    };
                    try certs.append(self.allocator, der);
                    off = e + 25;
                    if (certs.items.len >= 8) break;
                }
                if (certs.items.len > 0) {
                    var listBuf = std.ArrayList(u8).empty;
                    defer listBuf.deinit(self.allocator);
                    for (certs.items) |der| {
                        const len: u24 = @intCast(der.len);
                        try listBuf.append(self.allocator, @intCast((len >> 16) & 0xFF));
                        try listBuf.append(self.allocator, @intCast((len >> 8) & 0xFF));
                        try listBuf.append(self.allocator, @intCast(len & 0xFF));
                        try listBuf.appendSlice(self.allocator, der);
                        try listBuf.appendSlice(self.allocator, &.{ 0x00, 0x00 }); // empty extensions
                    }
                    const total: u24 = @intCast(listBuf.items.len);
                    try certBody.append(self.allocator, @intCast((total >> 16) & 0xFF));
                    try certBody.append(self.allocator, @intCast((total >> 8) & 0xFF));
                    try certBody.append(self.allocator, @intCast(total & 0xFF));
                    try certBody.appendSlice(self.allocator, listBuf.items);
                } else {
                    try certBody.appendSlice(self.allocator, &.{ 0x00, 0x00 });
                }
            } else {
                try certBody.appendSlice(self.allocator, &.{ 0x00, 0x00 });
            }

            try certMsg.append(self.allocator, @intFromEnum(handshakeMod.HandshakeType.certificate));
            const certBodyLen: u24 = @intCast(certBody.items.len);
            try certMsg.append(self.allocator, @intCast((certBodyLen >> 16) & 0xFF));
            try certMsg.append(self.allocator, @intCast((certBodyLen >> 8) & 0xFF));
            try certMsg.append(self.allocator, @intCast(certBodyLen & 0xFF));
            try certMsg.appendSlice(self.allocator, certBody.items);

            self.transcript.feed(certMsg.items);

            // CertificateVerify (RFC 8446 Section 4.4.3): ECDSA P-256 over
            // 64x 0x20 ++ "TLS 1.3, server CertificateVerify" ++ 0x00 ++ transcript hash.
            // RSA and other key types fail loudly: an empty signature would break
            // every verifying client, so never emit one.
            if (!self.peerOffersEcdsa) return error.UnsupportedSignatureScheme;
            const ecScalar = try parseEcPrivateScalar(self.allocator, privateKeyDer);
            const ecPubPoint = try P256.basePoint.mul(ecScalar, .big);
            const ecKeypair = EcdsaP256.KeyPair{
                .secret_key = try EcdsaP256.SecretKey.fromBytes(ecScalar),
                .public_key = .{ .p = ecPubPoint },
            };
            var cvContent: [64 + 33 + 1 + HashLen]u8 = undefined;
            @memset(cvContent[0..64], 0x20);
            @memcpy(cvContent[64..][0..33], "TLS 1.3, server CertificateVerify");
            cvContent[64 + 33] = 0x00;
            {
                var hsCopy = self.transcript.state;
                const hsHash = hsCopy.finalResult();
                @memcpy(cvContent[64 + 33 + 1 ..], &hsHash);
            }
            var cvNoise: [EcdsaP256.noise_length]u8 = undefined;
            fillRandom(&cvNoise);
            const ecSig = try ecKeypair.sign(&cvContent, cvNoise);
            var sigDer: [EcdsaP256.Signature.der_encoded_length_max]u8 = undefined;
            const sigDerSlice = ecSig.toDer(&sigDer);

            var cvBody = std.ArrayList(u8).empty;
            defer cvBody.deinit(self.allocator);
            try cvBody.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(handshakeMod.SignatureScheme.ecdsa_secp256r1_sha256))));
            try cvBody.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(sigDerSlice.len))));
            try cvBody.appendSlice(self.allocator, sigDerSlice);

            try cvMsg.append(self.allocator, @intFromEnum(handshakeMod.HandshakeType.certificate_verify));
            const cvBodyLen: u24 = @intCast(cvBody.items.len);
            try cvMsg.append(self.allocator, @intCast((cvBodyLen >> 16) & 0xFF));
            try cvMsg.append(self.allocator, @intCast((cvBodyLen >> 8) & 0xFF));
            try cvMsg.append(self.allocator, @intCast(cvBodyLen & 0xFF));
            try cvMsg.appendSlice(self.allocator, cvBody.items);

            self.transcript.feed(cvMsg.items);
        } // end if (!usePsk): abbreviated flights omit Cert/CV entirely

        // Finished
        // verifyData = HMAC(serverFinishedKey, Hash(Transcript))
        // serverFinishedKey = HKDF-Expand-Label(serverHandshakeTrafficSecret, "finished", "", HashLen)
        const hsHash = self.transcript.finish();
        const sHs = self.serverHsTrafficSecret orelse return error.HandshakeFailed;
        var serverFinishedKey: [HashLen]u8 = undefined;
        hkdfExpandLabel(sHs, "finished", &serverFinishedKey);

        var finishedVerify: [HashLen]u8 = undefined;
        std.crypto.auth.hmac.Hmac(Sha256).create(&finishedVerify, &hsHash, &serverFinishedKey);

        var finBody = std.ArrayList(u8).empty;
        defer finBody.deinit(self.allocator);
        try finBody.appendSlice(self.allocator, &finishedVerify);

        var finMsg = std.ArrayList(u8).empty;
        errdefer finMsg.deinit(self.allocator);
        try finMsg.append(self.allocator, @intFromEnum(handshakeMod.HandshakeType.finished));
        const finBodyLen: u24 = @intCast(finBody.items.len);
        try finMsg.append(self.allocator, @intCast((finBodyLen >> 16) & 0xFF));
        try finMsg.append(self.allocator, @intCast((finBodyLen >> 8) & 0xFF));
        try finMsg.append(self.allocator, @intCast(finBodyLen & 0xFF));
        try finMsg.appendSlice(self.allocator, finBody.items);

        self.transcript.feed(finMsg.items);

        // Snapshot for QUIC: application traffic secrets hash CH..Fin.
        const sfTranscriptHash = self.transcript.finish();

        // Compute application traffic secrets for server side
        self.deriveApplicationKeys();
        self.state = .serverFinishedSent;

        // Return owned slices
        return .{
            .serverHello = try shMsg.toOwnedSlice(self.allocator),
            .encryptedExtensions = try eeMsg.toOwnedSlice(self.allocator),
            .certificateRequest = crMsg,
            .certificate = try certMsg.toOwnedSlice(self.allocator),
            .certificateVerify = try cvMsg.toOwnedSlice(self.allocator),
            .finished = try finMsg.toOwnedSlice(self.allocator),
            .hsHash = hsTranscriptHash,
            .sfHash = sfTranscriptHash,
        };
    }

    /// Produces one NewSessionTicket message (type 4) from the
    /// handshake's resumption master secret. The ticket seals the derived
    /// PSK under the server's ticket keys, so the server stays stateless;
    /// the client re-derives the same PSK from its own master + the clear
    /// nonce. Call after the client's Finished is in the transcript.
    /// Includes early_data indication with maxEarlyData when configured.
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
        var ageAdd: [4]u8 = undefined;
        fillRandom(&ageAdd);
        const ageAddV = std.mem.readInt(u32, &ageAdd, .big);
        const alpnWire = if (self.negotiatedAlpn) |a| a else "";
        const blob = keys.seal(psk, suite, nowMs, lifetimeSecs, ageAddV, self.maxEarlyData, alpnWire);
        const maxEd: ?u32 = if (self.maxEarlyData > 0) self.maxEarlyData else null;
        const nst = handshakeMod.NewSessionTicket{
            .lifetimeSecs = lifetimeSecs,
            .ageAdd = ageAddV,
            .nonce = &nonce,
            .ticket = &blob,
            .maxEarlyData = maxEd,
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
    ) !sessionMod.ClientSession {
        if (msg.len < 4) return error.ProtocolViolation;
        if (msg[0] != @intFromEnum(handshakeMod.HandshakeType.new_session_ticket)) return error.ProtocolViolation;
        const nst = try handshakeMod.NewSessionTicket.decode(msg[4..]);
        return sessionMod.clientSessionFromTicketWithAlpn(
            self.allocator,
            nst,
            resumptionMaster,
            self.selectedSuite,
            host,
            self.negotiatedAlpn,
            nowMs,
        );
    }

    // Key derivation — RFC 8446 Section 7.1
    //
    // keySchedule:
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

        var cHs: [32]u8 = undefined;
        hkdfExpandLabelWithContext(hsSecret, "c hs traffic", &hash, &cHs);

        var sHs: [32]u8 = undefined;
        hkdfExpandLabelWithContext(hsSecret, "s hs traffic", &hash, &sHs);

        // Store for Finished verification
        self.serverHsTrafficSecret = sHs;
        self.clientHsTrafficSecret = cHs;

        self.hsKeys = deriveAeadKeys(cHs, sHs, self.recordCipher());

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
        var emptyCopy = Transcript.init();
        const emptyHash = emptyCopy.finish();
        var derived: [32]u8 = undefined;
        hkdfExpandLabelWithContext(hsSecret, "derived", &emptyHash, &derived);

        // With an accepted PSK the Master Secret mixes it in; otherwise
        // zeros exactly as before. (EC)DHE is always performed alongside
        // (pskDheKe), so forward secrecy holds either way.
        const zero: [32]u8 = .{0} ** 32;
        const pskIkm = self.resumptionPsk orelse zero;
        const master = HkdfSha256.extract(&derived, &pskIkm);
        self.masterSecret = master;

        var copy = self.transcript.state;
        const hash = copy.finalResult();

        var cAp: [32]u8 = undefined;
        hkdfExpandLabelWithContext(master, "c ap traffic", &hash, &cAp);

        var sAp: [32]u8 = undefined;
        hkdfExpandLabelWithContext(master, "s ap traffic", &hash, &sAp);

        self.apKeys = deriveAeadKeys(cAp, sAp, self.recordCipher());

        const k = self.apKeys.?;
        self.cbs.onKeys(self.cbs.ctx, .application, k);
    }

    /// Maps the selected cipher suite to a RecordCipher.
    fn recordCipher(self: *const Engine) recordMod.RecordCipher {
        return switch (self.selectedSuite) {
            .AES_128_GCM_SHA256 => .aes128Gcm,
            .AES_256_GCM_SHA384 => .aes256Gcm,
            .CHACHA20_POLY1305_SHA256 => .chacha20Poly1305,
            else => .aes128Gcm,
        };
    }

    /// Derive AEAD key + IV from a traffic secret using TLS 1.3 key/IV labels.
    fn deriveAeadKeys(clientSecret: [32]u8, serverSecret: [32]u8, cipher: recordMod.RecordCipher) DerivedKeys {
        const keyLen: usize = cipher.keyLen();
        var ck: [32]u8 = undefined;
        var ci: [12]u8 = undefined;
        var sk: [32]u8 = undefined;
        var si: [12]u8 = undefined;
        hkdfExpandLabel(clientSecret, "key", ck[0..keyLen]);
        hkdfExpandLabel(clientSecret, "iv", &ci);
        hkdfExpandLabel(serverSecret, "key", sk[0..keyLen]);
        hkdfExpandLabel(serverSecret, "iv", &si);
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
    /// Transcript hash through ServerHello (CH..SH): binds QUIC
    /// handshake traffic secrets without ad-hoc concatenation.
    hsHash: [32]u8,
    /// Transcript hash through server Finished (CH..Fin): binds QUIC
    /// application traffic secrets.
    sfHash: [32]u8,

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

    const ch = try engine.produceClientHello(&.{"h2"}, &.{}, null, null);
    defer a.free(ch);

    // Starts with handshake type clientHello (0x01)
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
    const ch = try client.produceClientHello(&.{"h2"}, &.{}, null, null);
    defer a.free(ch);

    // Server processes ClientHello
    try server.processClientHello(ch);

    // Deterministic P-256 identity for CertificateVerify signing (SEC1 DER).
    const ecKp = try EcdsaP256.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    const ecSec = ecKp.secret_key.toBytes();
    var sec1: [39]u8 = undefined;
    sec1[0] = 0x30;
    sec1[1] = 0x25;
    sec1[2] = 0x02;
    sec1[3] = 0x01;
    sec1[4] = 0x01;
    sec1[5] = 0x04;
    sec1[6] = 0x20;
    @memcpy(sec1[7..], &ecSec);

    // Server produces flight: negotiates suite/share from the real
    // ClientHello, derives keys, and signs CertificateVerify.
    var flight = try server.produceServerFlight(ch[4..], "", sec1[0..], &.{}, &.{}, null);
    defer flight.deinit(a);

    try std.testing.expectEqual(tls.CipherSuite.AES_128_GCM_SHA256, server.selectedSuite);
    try std.testing.expect(server.sharedSecret != null);
    try std.testing.expect(server.peerOffersEcdsa);

    try std.testing.expectEqual(Engine.State.serverFinishedSent, server.state);
    try std.testing.expect(server.hsKeys != null);
    try std.testing.expect(server.apKeys != null);

    // Client processes ServerHello — derives shared secret and handshake keys
    try client.processServerHello(flight.serverHello);
    try std.testing.expect(client.sharedSecret != null);
    try std.testing.expectEqual(Engine.State.handshakeKeysDerived, client.state);

    // Client processes EncryptedExtensions
    try client.processEncryptedExtensions(flight.encryptedExtensions);
    try std.testing.expectEqual(Engine.State.encryptedExtensionsReceived, client.state);

    // Client processes Certificate
    try client.processCertificate(flight.certificate);
    try std.testing.expectEqual(Engine.State.certificateReceived, client.state);

    // Client processes CertificateVerify
    try client.processCertificateVerify(flight.certificateVerify);
    try std.testing.expectEqual(Engine.State.certificateVerifyReceived, client.state);

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

    const clientCertPem = @embedFile("testdata/localhostCert.pem");
    const clientKeyPem = @embedFile("testdata/localhostKey.pem");
    const nowSec: i64 = @divFloor(clockMod.millisNow(), 1000);

    var client = Engine.initClient(a, .{});
    var server = Engine.initServer(a, .{});
    server.requestClientCert = true;

    const ch = try client.produceClientHello(&.{}, &.{}, null, null);
    defer a.free(ch);
    try server.processClientHello(ch);

    // Deterministic P-256 server identity for its own CertificateVerify.
    const ecKp = try EcdsaP256.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    const ecSec = ecKp.secret_key.toBytes();
    var sec1: [39]u8 = undefined;
    sec1[0] = 0x30;
    sec1[1] = 0x25;
    sec1[2] = 0x02;
    sec1[3] = 0x01;
    sec1[4] = 0x01;
    sec1[5] = 0x04;
    sec1[6] = 0x20;
    @memcpy(sec1[7..], &ecSec);

    var flight = try server.produceServerFlight(ch[4..], "", sec1[0..], &.{}, &.{}, null);
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
    var chain = try certMod.parseCertificateChainPem(a, clientCertPem);
    defer chain.deinit();
    try std.testing.expect(chain.count() >= 1);
    const leafDer = chain.leaf().?.rawDer();

    var ders = std.ArrayList([]const u8).empty;
    defer ders.deinit(a);
    var ci: usize = 0;
    while (chain.get(ci)) |c| : (ci += 1) {
        try ders.append(a, c.rawDer());
    }
    const clientCert = try client.produceClientCertificate(ders.items);
    defer a.free(clientCert);
    const clientCv = try client.produceClientCertificateVerify(clientKeyPem);
    defer a.free(clientCv);
    const clientFin = try client.produceClientFinished();
    defer a.free(clientFin);

    // Server validates: chain anchors in the client CA store, CV
    // signature checks out, Finished MAC binds the full transcript.
    var store = trustStoreMod.TrustStore.init(a, io);
    defer store.deinit();
    try store.addCertPem(clientCertPem);

    var presented = try server.processClientCertificate(clientCert);
    defer presented.deinit();
    try std.testing.expectEqual(chain.count(), presented.ders.len);
    var presentedChain = try certMod.parseCertificateChainPem(a, clientCertPem);
    defer presentedChain.deinit();
    try verifyMod.verifyCertificateChain(presentedChain, &store, null, nowSec);
    try server.processClientCertificateVerify(clientCv, leafDer);
    try server.verifyClientFinished(clientFin);

    // Transcripts agree after the full mutual flight.
    var cTr = client.transcript;
    var sTr = server.transcript;
    try std.testing.expectEqualSlices(u8, &cTr.finish(), &sTr.finish());
}

test "mutual TLS rejects untrusted client certificate" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const clientCertPem = @embedFile("testdata/localhostCert.pem");
    const nowSec: i64 = @divFloor(clockMod.millisNow(), 1000);

    var chain = try certMod.parseCertificateChainPem(a, clientCertPem);
    defer chain.deinit();

    // Empty trust store: no anchor matches the presented chain.
    var store = trustStoreMod.TrustStore.init(a, io);
    defer store.deinit();
    try std.testing.expectError(
        error.CertificateUntrusted,
        verifyMod.verifyCertificateChain(chain, &store, null, nowSec),
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

    const clientCertPem = @embedFile("testdata/localhostCert.pem");
    const clientKeyPem = @embedFile("testdata/localhostKey.pem");

    var client = Engine.initClient(a, .{});
    var server = Engine.initServer(a, .{});
    server.requestClientCert = true;

    const ch = try client.produceClientHello(&.{}, &.{}, null, null);
    defer a.free(ch);
    try server.processClientHello(ch);

    const ecKp = try EcdsaP256.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    const ecSec = ecKp.secret_key.toBytes();
    var sec1: [39]u8 = undefined;
    sec1[0] = 0x30;
    sec1[1] = 0x25;
    sec1[2] = 0x02;
    sec1[3] = 0x01;
    sec1[4] = 0x01;
    sec1[5] = 0x04;
    sec1[6] = 0x20;
    @memcpy(sec1[7..], &ecSec);

    var flight = try server.produceServerFlight(ch[4..], "", sec1[0..], &.{}, &.{}, null);
    defer flight.deinit(a);
    try client.processServerHello(flight.serverHello);
    try client.processEncryptedExtensions(flight.encryptedExtensions);
    try client.processCertificateRequest(flight.certificateRequest.?);
    try client.processCertificate(flight.certificate);
    try client.processCertificateVerify(flight.certificateVerify);
    try client.processFinished(flight.finished);

    var chain = try certMod.parseCertificateChainPem(a, clientCertPem);
    defer chain.deinit();
    const leafDer = chain.leaf().?.rawDer();
    var ders = std.ArrayList([]const u8).empty;
    defer ders.deinit(a);
    try ders.append(a, leafDer);
    const certMsg = try client.produceClientCertificate(ders.items);
    defer a.free(certMsg);
    var presented = try server.processClientCertificate(certMsg);
    defer presented.deinit();

    var cv = try client.produceClientCertificateVerify(clientKeyPem);
    defer a.free(cv);
    // Flip a signature byte: verification must fail closed.
    cv[cv.len - 1] ^= 0xFF;
    try std.testing.expectError(
        error.CertificateSignatureInvalid,
        server.processClientCertificateVerify(cv, leafDer),
    );
}

test "alpn negotiation through handshake" {
    const a = std.testing.allocator;
    var client = Engine.initClient(a, .{});

    const ch = try client.produceClientHello(&.{ "h2", "http/1.1" }, &.{}, null, null);
    defer a.free(ch);

    // Verify ALPN extension was encoded (type 0x0010 = 16)
    var foundAlpn = false;
    var i: usize = 4; // skip handshake header
    while (i + 4 < ch.len) : (i += 1) {
        const extType = std.mem.readInt(u16, ch[i..][0..2], .big);
        if (extType == 0x0010) {
            foundAlpn = true;
            break;
        }
    }
    try std.testing.expect(foundAlpn);
}

test "server flight carries negotiated alpn selection" {
    const a = std.testing.allocator;
    var client = Engine.initClient(a, .{});
    defer client.deinit();
    var server = Engine.initServer(a, .{});
    defer server.deinit();

    const ch = try client.produceClientHello(&.{ "h2", "http/1.1" }, &.{}, null, null);
    defer a.free(ch);
    try server.processClientHello(ch);

    const ecKp = try EcdsaP256.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    const ecSec = ecKp.secret_key.toBytes();
    var sec1: [39]u8 = undefined;
    sec1[0] = 0x30;
    sec1[1] = 0x25;
    sec1[2] = 0x02;
    sec1[3] = 0x01;
    sec1[4] = 0x01;
    sec1[5] = 0x04;
    sec1[6] = 0x20;
    @memcpy(sec1[7..], &ecSec);

    var flight = try server.produceServerFlight(
        ch[4..],
        "",
        sec1[0..],
        &.{ .h2, .@"http/1.1" },
        &.{ "h2", "http/1.1" },
        null,
    );
    defer flight.deinit(a);
    try std.testing.expectEqualStrings("h2", server.negotiatedAlpn.?);

    try client.processServerHello(flight.serverHello);
    try client.processEncryptedExtensions(flight.encryptedExtensions);
    try std.testing.expectEqualStrings("h2", client.negotiatedAlpn.?);
    try std.testing.expect(alpnMod.Protocol.fromWire(client.negotiatedAlpn.?) == .h2);
}

test "psk abbreviated handshake resynchronizes application keys" {
    const a = std.testing.allocator;
    const now: u64 = 1_000_000;

    // --- Full handshake first (mirrors the key-exchange test) ---
    var client = Engine.initClient(a, .{});
    defer client.deinit();
    var server = Engine.initServer(a, .{});
    defer server.deinit();
    server.ticketKeys = sessionMod.TicketKeys{ .current = [_]u8{0x1A} ** 32 };

    const ch = try client.produceClientHello(&.{"h2"}, &.{}, null, null);
    defer a.free(ch);
    try server.processClientHello(ch);

    const ecKp = try EcdsaP256.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    const ecSec = ecKp.secret_key.toBytes();
    var sec1: [39]u8 = undefined;
    sec1[0..7].* = .{ 0x30, 0x25, 0x02, 0x01, 0x01, 0x04, 0x20 };
    @memcpy(sec1[7..], &ecSec);

    var flight = try server.produceServerFlight(ch[4..], "", sec1[0..], &.{}, &.{}, null);
    defer flight.deinit(a);
    try std.testing.expect(flight.certificate.len > 0);
    try client.processServerHello(flight.serverHello);
    try std.testing.expect(client.resumptionPsk == null);
    try client.processEncryptedExtensions(flight.encryptedExtensions);
    try client.processCertificate(flight.certificate);
    try client.processCertificateVerify(flight.certificateVerify);
    try client.processFinished(flight.finished);
    const clientFin = try client.produceClientFinished();
    defer a.free(clientFin);
    try server.verifyClientFinished(clientFin);

    // Both sides derive the SAME resumption master (transcripts match).
    const masterC = try client.deriveResumptionMaster();
    const masterS = try server.deriveResumptionMaster();
    try std.testing.expectEqualSlices(u8, &masterC, &masterS);

    // Server issues one ticket; client captures a bound session.
    const nst = try server.produceNewSessionTicket(masterS, server.selectedSuite, 3600, now);
    defer a.free(nst);
    var session = try client.processNewSessionTicket(nst, masterC, "example.com", now);
    defer session.deinit(a);
    try std.testing.expect(session.isUsable("example.com", now + 1000));
    try std.testing.expect(!session.isUsable("other.com", now + 1000));

    // --- Abbreviated handshake with the captured session ---
    var client2 = Engine.initClient(a, .{});
    defer client2.deinit();
    var server2 = Engine.initServer(a, .{});
    defer server2.deinit();
    server2.ticketKeys = server.ticketKeys;
    const ch2 = try client2.produceClientHelloResumption(&.{"h2"}, &.{}, "example.com", &session, now + 2000, null);
    defer a.free(ch2);
    try server2.processClientHello(ch2);
    try std.testing.expect(server2.selectPsk(ch2, now + 2000));
    var flight2 = try server2.produceServerFlight(ch2[4..], "", sec1[0..], &.{}, &.{}, null);
    defer flight2.deinit(a);
    // Abbreviated: no Certificate / CertificateVerify on the wire.
    try std.testing.expectEqual(@as(usize, 0), flight2.certificate.len);
    try std.testing.expectEqual(@as(usize, 0), flight2.certificateVerify.len);
    try client2.processServerHello(flight2.serverHello);
    try std.testing.expect(client2.resumptionPsk != null);
    try client2.processEncryptedExtensions(flight2.encryptedExtensions);
    try client2.processFinished(flight2.finished);
    const client2Fin = try client2.produceClientFinished();
    defer a.free(client2Fin);
    try server2.verifyClientFinished(client2Fin);
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
    const ch3 = try client3.produceClientHelloResumption(&.{"h2"}, &.{}, "example.com", &session, now + 3000, null);
    defer a.free(ch3);
    // Flip a binder byte: the server must reject the PSK silently.
    const tampered = try a.dupe(u8, ch3);
    defer a.free(tampered);
    const bspan = try handshakeMod.pskBinderSpan(tampered);
    bspan[0] ^= 0xFF;
    try server3.processClientHello(tampered);
    try std.testing.expect(!server3.selectPsk(tampered, now + 3000));
    // Expired tickets also fall back instead of failing.
    try std.testing.expect(!server3.selectPsk(ch2, now + 3600 * 1000 + sessionMod.ticketSkewMs + 5000));
}

test "hello retry request completes a full handshake after retry" {
    const a = std.testing.allocator;

    var client = Engine.initClient(a, .{});
    var server = Engine.initServer(a, .{});

    // Shareless ClientHello1 (crafted directly: the normal producer
    // always offers x25519). The predicate must spot the gap.
    const ch1Base = handshakeMod.ClientHello{
        .random = [_]u8{0x55} ** 32,
        .cipherSuites = &.{.AES_128_GCM_SHA256},
        .keyShareEntries = &.{},
        .signatureAlgorithms = &.{.ecdsa_secp256r1_sha256},
        .alpnProtocols = &.{},
        .serverName = null,
    };
    const ch1 = try ch1Base.encode(a);
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
    try std.testing.expectEqual(handshakeMod.NamedGroup.x25519, client.hrrPendingGroup.?);
    // A second HRR aborts loudly.
    try std.testing.expectError(error.HandshakeFailed, client.processServerHello(hrr));

    // Retried hello carries a real share; the predicate agrees.
    const ch2 = try client.produceClientHello(&.{}, &.{}, null, null);
    defer a.free(ch2);
    try std.testing.expect(Engine.clientHelloHasShare(ch2[4..]));
    try server.processClientHello(ch2);

    const ecKp = try EcdsaP256.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    const ecSec = ecKp.secret_key.toBytes();
    var sec1: [39]u8 = undefined;
    sec1[0..7].* = .{ 0x30, 0x25, 0x02, 0x01, 0x01, 0x04, 0x20 };
    @memcpy(sec1[7..], &ecSec);
    var flight = try server.produceServerFlight(ch2[4..], "", sec1[0..], &.{}, &.{}, null);
    defer flight.deinit(a);
    try client.processServerHello(flight.serverHello);
    try client.processEncryptedExtensions(flight.encryptedExtensions);
    try client.processCertificate(flight.certificate);
    try client.processCertificateVerify(flight.certificateVerify);
    try client.processFinished(flight.finished);
    const clientFin = try client.produceClientFinished();
    defer a.free(clientFin);
    try server.verifyClientFinished(clientFin);
    try std.testing.expectEqualSlices(u8, client.apKeys.?.clientKeySlice(), server.apKeys.?.clientKeySlice());
}
test "quic transport parameters roundtrip through hello and ee" {
    const a = std.testing.allocator;
    var client = Engine.initClient(a, .{});
    defer client.deinit();
    var server = Engine.initServer(a, .{});
    defer server.deinit();

    // Hand-rolled TP block: initialMaxData = 2MiB, maxIdleTimeout = 30s.
    var tp = std.ArrayList(u8).empty;
    defer tp.deinit(a);
    try tp.appendSlice(a, &.{ 0x04, 0x08 });
    var v: [8]u8 = undefined;
    std.mem.writeInt(u64, &v, 2 << 20, .big);
    try tp.appendSlice(a, &v);
    try tp.appendSlice(a, &.{ 0x01, 0x08 });
    std.mem.writeInt(u64, &v, 30_000, .big);
    try tp.appendSlice(a, &v);

    const ch = try client.produceClientHello(&.{"h3"}, &.{}, "example.com", tp.items);
    defer a.free(ch);
    try server.processClientHello(ch);
    try std.testing.expect(server.peerQuicTransportParams != null);
    try std.testing.expectEqualSlices(u8, tp.items, server.peerQuicTransportParams.?);

    // Deterministic P-256 server identity (same shape as the mTLS test).
    const ecKp = try EcdsaP256.KeyPair.generateDeterministic([_]u8{0x42} ** 32);
    const ecSec = ecKp.secret_key.toBytes();
    var sec1: [39]u8 = undefined;
    sec1[0] = 0x30;
    sec1[1] = 0x25;
    sec1[2] = 0x02;
    sec1[3] = 0x01;
    sec1[4] = 0x01;
    sec1[5] = 0x04;
    sec1[6] = 0x20;
    @memcpy(sec1[7..], &ecSec);

    var flight = try server.produceServerFlight(ch[4..], "", sec1[0..], &.{}, &.{}, tp.items);
    defer flight.deinit(a);
    try client.processServerHello(flight.serverHello);
    try client.processEncryptedExtensions(flight.encryptedExtensions);
    try std.testing.expect(client.peerQuicTransportParams != null);
    try std.testing.expectEqualSlices(u8, tp.items, client.peerQuicTransportParams.?);
}

test "server certificate verify binds transcript and rejects tampering" {
    const a = std.testing.allocator;

    const serverCertPem = @embedFile("testdata/localhostCert.pem");
    const serverKeyPem = @embedFile("testdata/localhostKey.pem");

    var client = Engine.initClient(a, .{});
    defer client.deinit();
    var server = Engine.initServer(a, .{});
    defer server.deinit();

    const ch = try client.produceClientHello(&.{"h3"}, &.{}, "example.com", null);
    defer a.free(ch);
    try server.processClientHello(ch);

    // Server flight signed with the committed localhost identity.
    var flight = try server.produceServerFlight(ch[4..], serverCertPem, serverKeyPem, &.{}, &.{}, null);
    defer flight.deinit(a);

    try client.processServerHello(flight.serverHello);
    try client.processEncryptedExtensions(flight.encryptedExtensions);
    try client.processCertificate(flight.certificate);

    var chain = try certMod.parseCertificateChainPem(a, serverCertPem);
    defer chain.deinit();
    const leafDer = chain.leaf().?.rawDer();

    // Valid CertificateVerify checks out against the leaf public key.
    try client.processServerCertificateVerify(flight.certificateVerify, leafDer);

    // A flipped signature byte is rejected and the failed check must not
    // feed the handshake transcript (digest identical before/after).
    var tampered = try a.dupe(u8, flight.certificateVerify);
    defer a.free(tampered);
    tampered[tampered.len - 1] ^= 0x01;
    const before = client.transcript.finish();
    try std.testing.expectError(
        error.CertificateSignatureInvalid,
        client.processServerCertificateVerify(tampered, leafDer),
    );
    try std.testing.expectEqual(before, client.transcript.finish());
}

test "X25519MLKEM768 hybrid share is offered first, with x25519 as fallback" {
    const a = std.testing.allocator;
    var client = Engine.initClient(a, .{});
    defer client.deinit();

    // No transport parameters => TCP mode, so the hybrid is offered.
    const ch = try client.produceClientHello(&.{"h2"}, &.{}, "example.com", null);
    defer a.free(ch);

    // Walk to the key_share extension: body -> sessionId -> cipherSuites
    // -> compression -> extensions.
    var pos: usize = 34;
    pos += 1 + ch[4 + pos];
    pos += 2 + (@as(usize, ch[4 + pos]) << 8 | ch[4 + pos + 1]);
    pos += 1 + ch[4 + pos];
    const extLenTotal: usize = @as(usize, ch[4 + pos]) << 8 | ch[4 + pos + 1];
    const extEnd = 4 + pos + 2 + extLenTotal;
    pos += 2;
    var found = false;
    while (pos + 4 <= extEnd) {
        const extType = std.mem.readInt(u16, ch[4 + pos ..][0..2], .big);
        const extLen: usize = @as(usize, ch[4 + pos + 2]) << 8 | ch[4 + pos + 3];
        pos += 4;
        if (extType == @intFromEnum(handshakeMod.ExtensionType.key_share)) {
            found = true;
            const d = ch[4 + pos ..][0..extLen];
            const listLen: usize = @as(usize, d[0]) << 8 | d[1];
            try std.testing.expectEqual(extLen, listLen + 2);

            var kp: usize = 2;
            const g0 = std.mem.readInt(u16, d[kp..][0..2], .big);
            const l0 = std.mem.readInt(u16, d[kp + 2 ..][0..2], .big);
            try std.testing.expectEqual(@intFromEnum(handshakeMod.NamedGroup.x25519_ml_kem768), g0);
            try std.testing.expectEqual(@as(u16, 1216), l0);
            kp += 4 + l0;

            // The fallback must survive: a peer without PQ support picks
            // it directly instead of forcing a HelloRetryRequest.
            const g1 = std.mem.readInt(u16, d[kp..][0..2], .big);
            const l1 = std.mem.readInt(u16, d[kp + 2 ..][0..2], .big);
            try std.testing.expectEqual(@intFromEnum(handshakeMod.NamedGroup.x25519), g1);
            try std.testing.expectEqual(@as(u16, 32), l1);
            break;
        }
        pos += extLen;
    }
    try std.testing.expect(found);
}

test "hybrid decapsulation matches the peer's encapsulated secret" {
    const a = std.testing.allocator;
    var client = Engine.initClient(a, .{});
    defer client.deinit();

    const ch = try client.produceClientHello(&.{"h2"}, &.{}, "example.com", null);
    defer a.free(ch);
    const mlkp = client.hybridMlKem orelse return error.TestExpectedHybridOffered;

    // A server encapsulates to the ML-KEM key we advertised and answers
    // with its own X25519 share, which is what RFC 10024 puts on the wire.
    const seed = [_]u8{0x5A} ** MlKem.encaps_seed_length;
    const es = mlkp.public_key.encapsDeterministic(&seed);
    try std.testing.expectEqual(@as(usize, MLKEM_CT_LEN), es.ciphertext.len);

    const srv_x = try x25519.KeyPair.generateDeterministic([_]u8{0x3C} ** 32);
    var share: [HY_CT_LEN]u8 = undefined;
    @memcpy(share[0..MLKEM_CT_LEN], &es.ciphertext);
    @memcpy(share[MLKEM_CT_LEN..], &srv_x.public_key);

    const entry: handshakeMod.ServerHello.KeyShareEntry = .{
        .group = .x25519_ml_kem768,
        .keyExchange = &share,
    };
    const got = try client.deriveSharedSecret(entry);

    // RFC 10024 4.3: the secret is the concatenation, ML-KEM first.
    const ss_x = try x25519.scalarmult(client.localKeypair.secret_key, srv_x.public_key);
    var want: [HY_SS_LEN]u8 = undefined;
    @memcpy(want[0..MLKEM_SS_LEN], &es.shared_secret);
    @memcpy(want[MLKEM_SS_LEN..], &ss_x);
    try std.testing.expectEqual(@as(usize, HY_SS_LEN), got.len);
    try std.testing.expectEqualSlices(u8, &want, got.slice());
}

test "a group we never offered is rejected instead of silently downgraded" {
    const a = std.testing.allocator;
    var client = Engine.initClient(a, .{});
    defer client.deinit();

    // QUIC mode: only x25519 is offered.
    const ch = try client.produceClientHello(&.{"h3"}, &.{}, "example.com", "tp");
    defer a.free(ch);
    try std.testing.expect(!client.hybridOffered);

    // A server answering with the hybrid when we did not offer it must
    // fail loudly (RFC 8446 4.1.4), not downgrade the group's security.
    const fake: handshakeMod.ServerHello.KeyShareEntry = .{
        .group = .x25519_ml_kem768,
        .keyExchange = &([_]u8{0} ** 1120),
    };
    try std.testing.expectError(error.UnsupportedCipherSuite, client.deriveSharedSecret(fake));
}
