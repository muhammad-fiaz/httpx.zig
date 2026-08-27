//! TLS 1.3 handshake message serialization/parsing (RFC 8446 §4).
//!
//! Every handshake message has: u8 type + u24 length + body.
//! This module encodes/decodes each message type and provides
//! transcript-hash helpers needed for CertificateVerify and Finished.
//!
//! Thread-safety: thread-confined.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tls = std.crypto.tls;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const HandshakeType = tls.HandshakeType;
pub const ContentType = tls.ContentType;
pub const SignatureScheme = tls.SignatureScheme;
pub const NamedGroup = tls.NamedGroup;

/// Maximum handshake message size we handle.
pub const max_handshake_len = 1 << 14;

/// Transcript hash (SHA-256 for TLS 1.3 with AES-128-GCM-SHA256).
pub const TranscriptHash = Sha256;
pub const HashLen = TranscriptHash.digest_length; // 32

/// Running transcript hash over all handshake messages.
pub const Transcript = struct {
    state: TranscriptHash,

    pub fn init() Transcript {
        return .{ .state = TranscriptHash.init(.{}) };
    }

    pub fn feed(self: *Transcript, data: []const u8) void {
        self.state.update(data);
    }

    pub fn finish(self: *Transcript) [HashLen]u8 {
        return self.state.finalResult();
    }
};

// ---------------------------------------------------------------------------
// ClientHello (RFC 8446 §4.2.1)
// ---------------------------------------------------------------------------

pub const ClientHello = struct {
    random: [32]u8,
    cipher_suites: []const CipherSuite,
    key_share_entries: []const KeyShareEntry,
    signature_algorithms: []const SignatureScheme,
    alpn_protocols: []const []const u8,
    /// PSK identities (empty for initial handshake).
    psk_identities: []const []const u8 = &.{},
    /// Supported versions (typically [0x0304] for TLS 1.3).
    supported_versions: []const u16 = &.{0x0304},
    /// PSK key exchange modes.
    psk_modes: []const u8 = &.{0x01}, // psk_dhe_ke

    pub const CipherSuite = tls.CipherSuite;
    pub const KeyShareEntry = struct {
        group: NamedGroup,
        key_exchange: []const u8,
    };

    /// Serializes the full ClientHello message (handshake type + length + body).
    pub fn encode(self: *const ClientHello, allocator: Allocator) ![]u8 {
        var body = std.ArrayList(u8).empty;
        defer body.deinit(allocator);

        // client_version: TLS 1.2 (0x0303) — legacy, real version in supported_versions
        try body.appendSlice(allocator, &.{ 0x03, 0x03 });

        // client_random (32 bytes)
        try body.appendSlice(allocator, &self.random);

        // cipher_suites_length (u16) + cipher_suites (u16 each)
        const cs_len: u16 = @intCast(self.cipher_suites.len * 2);
        try body.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, cs_len)));
        for (self.cipher_suites) |cs| {
            try body.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(cs))));
        }

        // compression_methods: [0x00] (null compression)
        try body.appendSlice(allocator, &.{ 0x01, 0x00 });

        // Extensions
        var exts = std.ArrayList(u8).empty;
        defer exts.deinit(allocator);

        // server_name (SNI) — first protocol as the hostname
        if (self.alpn_protocols.len > 0) {
            const hostname = self.alpn_protocols[0];
            const sni_len: u16 = @intCast(5 + 2 + hostname.len); // list_hdr(2) + type(1) + len(1) + name_len(1) + name
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(ExtensionType.server_name))));
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, sni_len)));
            // SNI list length
            const name_total: u16 = @intCast(3 + hostname.len);
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, name_total)));
            // host_name type (0) + length
            try exts.append(allocator, 0x00);
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(hostname.len))));
            try exts.appendSlice(allocator, hostname);
        }

        // supported_groups
        {
            var sg_body = std.ArrayList(u8).empty;
            defer sg_body.deinit(allocator);
            for (self.key_share_entries) |e| {
                try sg_body.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(e.group))));
            }
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(ExtensionType.supported_groups))));
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(sg_body.items.len))));
            try exts.appendSlice(allocator, sg_body.items);
        }

        // key_share
        {
            var ks_body = std.ArrayList(u8).empty;
            defer ks_body.deinit(allocator);
            for (self.key_share_entries) |e| {
                try ks_body.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(e.group))));
                try ks_body.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(e.key_exchange.len))));
                try ks_body.appendSlice(allocator, e.key_exchange);
            }
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(ExtensionType.key_share))));
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(ks_body.items.len))));
            try exts.appendSlice(allocator, ks_body.items);
        }

        // signature_algorithms
        {
            var sa_body = std.ArrayList(u8).empty;
            defer sa_body.deinit(allocator);
            for (self.signature_algorithms) |sa| {
                try sa_body.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(sa))));
            }
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(ExtensionType.signature_algorithms))));
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(sa_body.items.len))));
            try exts.appendSlice(allocator, sa_body.items);
        }

        // ALPN
        if (self.alpn_protocols.len > 0) {
            var alpn_body = std.ArrayList(u8).empty;
            defer alpn_body.deinit(allocator);
            for (self.alpn_protocols) |proto| {
                try alpn_body.append(allocator, @intCast(proto.len));
                try alpn_body.appendSlice(allocator, proto);
            }
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(ExtensionType.application_layer_protocol_negotiation))));
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(alpn_body.items.len + 2))));
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(alpn_body.items.len))));
            try exts.appendSlice(allocator, alpn_body.items);
        }

        // supported_versions (extension)
        {
            var sv_body = std.ArrayList(u8).empty;
            defer sv_body.deinit(allocator);
            for (self.supported_versions) |v| {
                try sv_body.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, v)));
            }
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(ExtensionType.supported_versions))));
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(sv_body.items.len))));
            try exts.appendSlice(allocator, sv_body.items);
        }

        // psk_key_exchange_modes
        if (self.psk_modes.len > 0) {
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intFromEnum(ExtensionType.psk_key_exchange_modes))));
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(self.psk_modes.len))));
            try exts.appendSlice(allocator, self.psk_modes);
        }

        // Append extensions length + body to main body
        try body.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(exts.items.len))));
        try body.appendSlice(allocator, exts.items);

        // Prepend handshake type + u24 length
        const msg_type_byte: u8 = @intFromEnum(HandshakeType.client_hello);
        const body_len: u24 = @intCast(body.items.len);
        var header: [4]u8 = undefined;
        header[0] = msg_type_byte;
        header[1] = @intCast((body_len >> 16) & 0xFF);
        header[2] = @intCast((body_len >> 8) & 0xFF);
        header[3] = @intCast(body_len & 0xFF);

        var result = std.ArrayList(u8).empty;
        try result.appendSlice(allocator, &header);
        try result.appendSlice(allocator, body.items);
        return result.toOwnedSlice(allocator);
    }
};

// ---------------------------------------------------------------------------
// ServerHello (RFC 8446 §4.1.3)
// ---------------------------------------------------------------------------

pub const ServerHello = struct {
    random: [32]u8,
    cipher_suite: tls.CipherSuite,
    key_share: ?KeyShareEntry = null,

    pub const KeyShareEntry = struct {
        group: NamedGroup,
        key_exchange: []const u8,
    };

    /// Parses a ServerHello body (after the 4-byte handshake header has been consumed).
    pub fn decode(body: []const u8) !ServerHello {
        if (body.len < 34) return error.ServerHelloTooShort;
        var result: ServerHello = undefined;
        @memcpy(&result.random, body[0..32]);

        const cs = std.mem.readInt(u16, body[32..34], .big);
        result.cipher_suite = @enumFromInt(cs);

        // Parse extensions
        if (body.len < 36) return error.ServerHelloTooShort;
        const ext_len: usize = (@as(usize, body[34]) << 8) | body[35];
        var pos: usize = 36;
        const ext_end = 36 + ext_len;
        if (ext_end > body.len) return error.ServerHelloTruncated;

        while (pos + 4 <= ext_end) {
            const ext_type = std.mem.readInt(u16, body[pos..][0..2], .big);
            const ext_data_len: usize = (@as(usize, body[pos + 2]) << 8) | body[pos + 3];
            pos += 4;
            if (pos + ext_data_len > ext_end) return error.ServerHelloTruncated;

            if (ext_type == @intFromEnum(ExtensionType.key_share)) {
                if (ext_data_len >= 4) {
                    const group = std.mem.readInt(u16, body[pos..][0..2], .big);
                    const ks_len: usize = (@as(usize, body[pos + 2]) << 8) | body[pos + 3];
                    if (pos + 4 + ks_len <= ext_end) {
                        result.key_share = .{
                            .group = @enumFromInt(group),
                            .key_exchange = body[pos + 4 ..][0..ks_len],
                        };
                    }
                }
            }
            pos += ext_data_len;
        }
        return result;
    }
};

// ---------------------------------------------------------------------------
// EncryptedExtensions (RFC 8446 §4.3.1)
// ---------------------------------------------------------------------------

pub const EncryptedExtensions = struct {
    alpn_protocol: ?[]const u8 = null,

    pub fn decode(body: []const u8) !EncryptedExtensions {
        var result: EncryptedExtensions = .{};
        if (body.len < 2) return error.EncryptedExtensionsTooShort;
        const ext_len: usize = (@as(usize, body[0]) << 8) | body[1];
        var pos: usize = 2;
        const ext_end = 2 + ext_len;
        if (ext_end > body.len) return error.EncryptedExtensionsTruncated;

        while (pos + 4 <= ext_end) {
            const ext_type = std.mem.readInt(u16, body[pos..][0..2], .big);
            const ext_data_len: usize = (@as(usize, body[pos + 2]) << 8) | body[pos + 3];
            pos += 4;
            if (pos + ext_data_len > ext_end) return error.EncryptedExtensionsTruncated;

            if (ext_type == @intFromEnum(ExtensionType.application_layer_protocol_negotiation)) {
                if (ext_data_len >= 3) {
                    const list_len: usize = (@as(usize, body[pos]) << 8) | body[pos + 1];
                    if (list_len >= 1 and ext_data_len >= 2 + list_len) {
                        const proto_len = body[pos + 2];
                        if (3 + proto_len <= ext_data_len) {
                            result.alpn_protocol = body[pos + 3 ..][0..proto_len];
                        }
                    }
                }
            }
            pos += ext_data_len;
        }
        return result;
    }
};

// ---------------------------------------------------------------------------
// CertificateEntry (part of Certificate message, RFC 8446 §4.4.2)
// ---------------------------------------------------------------------------

pub const CertificateEntry = struct {
    cert_data: []const u8,
    extensions: []const u8,
};

// ---------------------------------------------------------------------------
// CertificateVerify (RFC 8446 §4.4.3)
// ---------------------------------------------------------------------------

pub const CertificateVerify = struct {
    algorithm: SignatureScheme,
    signature: []const u8,

    pub fn decode(body: []const u8) !CertificateVerify {
        if (body.len < 4) return error.CertificateVerifyTooShort;
        const alg = std.mem.readInt(u16, body[0..2], .big);
        const sig_len: usize = (@as(usize, body[2]) << 8) | body[3];
        if (4 + sig_len > body.len) return error.CertificateVerifyTruncated;
        return .{
            .algorithm = @enumFromInt(alg),
            .signature = body[4..][0..sig_len],
        };
    }
};

// ---------------------------------------------------------------------------
// Finished (RFC 8446 §4.4.4)
// ---------------------------------------------------------------------------

pub const Finished = struct {
    verify_data: [HashLen]u8,

    pub fn decode(body: []const u8) !Finished {
        if (body.len < HashLen) return error.FinishedTooShort;
        var result: Finished = undefined;
        @memcpy(&result.verify_data, body[0..HashLen]);
        return result;
    }
};

// ---------------------------------------------------------------------------
// Extension types (subset we use)
// ---------------------------------------------------------------------------

pub const ExtensionType = tls.ExtensionType;

// ---------------------------------------------------------------------------
// TLS alert (RFC 8446 §6.2)
// ---------------------------------------------------------------------------

pub const AlertLevel = enum(u8) {
    warning = 1,
    fatal = 2,
};

pub const AlertDescription = enum(u8) {
    close_notify = 0,
    unexpected_message = 10,
    bad_record_mac = 20,
    handshake_failure = 40,
    bad_certificate = 42,
    unsupported_certificate = 43,
    certificate_revoked = 44,
    certificate_expired = 45,
    certificate_unknown = 46,
    illegal_parameter = 47,
    unknown_ca = 48,
    access_denied = 49,
    decode_error = 50,
    decrypt_error = 51,
    protocol_version = 70,
    insufficient_security = 71,
    internal_error = 80,
    inappropriate_fallback = 86,
    user_canceled = 90,
    no_renegotiation = 100,
    unsupported_extension = 109,
    unrecognized_name = 112,
    bad_certificate_status_response = 113,
    unknown_psk_identity = 115,
    certificate_required = 116,

    pub fn toError(_: AlertDescription) error{TlsAlert} {
        return error.TlsAlert;
    }
};

pub const Alert = struct {
    level: AlertLevel,
    description: AlertDescription,

    pub fn encode(self: Alert) [2]u8 {
        return .{ @intFromEnum(self.level), @intFromEnum(self.description) };
    }

    pub fn decode(data: [2]u8) Alert {
        return .{
            .level = @enumFromInt(data[0]),
            .description = @enumFromInt(data[1]),
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "transcript hash determinism" {
    var t1 = Transcript.init();
    var t2 = Transcript.init();
    const msg = "hello handshake";
    t1.feed(msg);
    t2.feed(msg);
    try std.testing.expectEqual(t1.finish(), t2.finish());
}

test "transcript hash accumulates" {
    var t = Transcript.init();
    t.feed("part1");
    const h1 = t.finish();
    t.feed("part2");
    const h2 = t.finish();
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "ClientHello encode produces valid frame" {
    const ch = ClientHello{
        .random = [_]u8{0xAA} ** 32,
        .cipher_suites = &.{.AES_128_GCM_SHA256},
        .key_share_entries = &.{.{
            .group = .x25519,
            .key_exchange = &[_]u8{0xBB} ** 32,
        }},
        .signature_algorithms = &.{.ecdsa_secp256r1_sha256},
        .alpn_protocols = &.{"h2"},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const encoded = try ch.encode(a);
    defer a.free(encoded);

    // Must start with handshake type client_hello (0x01) + u24 length
    try std.testing.expectEqual(@as(u8, 0x01), encoded[0]);
    const body_len: u24 = @as(u24, @intCast(encoded[1])) << 16 | @as(u24, @intCast(encoded[2])) << 8 | @as(u24, @intCast(encoded[3]));
    try std.testing.expectEqual(encoded.len - 4, body_len);
    try std.testing.expect(encoded.len > 40); // at minimum: version(2) + random(32) + cs_len(2) + cs(2) + comp(2) + ext_len(2) + extensions
}

test "ServerHello decode roundtrip" {
    // Construct a minimal ServerHello body manually
    var body: [64]u8 = undefined;
    @memset(&body, 0);
    // random (32 bytes at offset 0)
    @memcpy(body[0..32], &[_]u8{0x11} ** 32);
    // cipher_suite (2 bytes at offset 32)
    body[32] = 0x13;
    body[33] = 0x01; // TLS_AES_128_GCM_SHA256
    // extensions_length (2 bytes at offset 34)
    body[34] = 0;
    body[35] = 0;

    const sh = try ServerHello.decode(&body);
    try std.testing.expectEqual(tls.CipherSuite.AES_128_GCM_SHA256, sh.cipher_suite);
}

test "Alert encode/decode roundtrip" {
    const a = Alert{ .level = .fatal, .description = .handshake_failure };
    const encoded = a.encode();
    const decoded = Alert.decode(encoded);
    try std.testing.expectEqual(.fatal, decoded.level);
    try std.testing.expectEqual(.handshake_failure, decoded.description);
}
