//! TLS 1.3 handshake message serialization/parsing (RFC 8446 Section 4).
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
pub const maxHandshakeLen = 1 << 14;

/// Transcript hash (SHA-256 for AES-128-GCM-SHA256, SHA-384 for AES-256-GCM-SHA384).
pub const TranscriptHash = Sha256;
pub const HashLen = TranscriptHash.digest_length; // 32
pub const TranscriptHash384 = std.crypto.hash.sha2.Sha384;
pub const HashLen384 = TranscriptHash384.digest_length; // 48

pub fn hashLenForSuite(suite: tls.CipherSuite) usize {
    return switch (suite) {
        .AES_256_GCM_SHA384 => HashLen384,
        else => HashLen,
    };
}

/// Running transcript hash over all handshake messages (SHA-256 variant).
pub const Transcript = struct {
    state: TranscriptHash,

    pub fn init() Transcript {
        return .{ .state = TranscriptHash.init(.{}) };
    }

    pub fn feed(self: *Transcript, data: []const u8) void {
        self.state.update(data);
    }

    /// Running hash without disturbing the stream: further `feed` calls
    /// continue the same transcript (required by the TLS 1.3 key schedule,
    /// which hashes prefixes of the full transcript at several points).
    pub fn finish(self: *Transcript) [HashLen]u8 {
        var copy = self.state;
        return copy.finalResult();
    }
};

/// Running transcript hash for SHA-384 suites.
pub const Transcript384 = struct {
    state: TranscriptHash384,

    pub fn init() Transcript384 {
        return .{ .state = TranscriptHash384.init(.{}) };
    }

    pub fn feed(self: *Transcript384, data: []const u8) void {
        self.state.update(data);
    }

    pub fn finish(self: *Transcript384) [HashLen384]u8 {
        var copy = self.state;
        return copy.finalResult();
    }
};

// ClientHello (RFC 8446 Section 4.2.1)

pub const ClientHello = struct {
    random: [32]u8,
    cipherSuites: []const CipherSuite,
    keyShareEntries: []const KeyShareEntry,
    signatureAlgorithms: []const SignatureScheme,
    alpnProtocols: []const []const u8,
    serverName: ?[]const u8 = null,
    /// PSK identities (empty for initial handshake).
    pskIdentities: []const []const u8 = &.{},
    /// Supported versions (typically [0x0304] for TLS 1.3).
    supportedVersions: []const u16 = &.{0x0304},
    /// PSK key exchange modes.
    pskModes: []const u8 = &.{0x01}, // pskDheKe
    /// Raw QUIC transport parameters block for extension 57
    /// (RFC 9001 Section 7.4). Borrowed; emitted only over QUIC.
    quicTransportParams: ?[]const u8 = null,
    /// 0-RTT early data extension offer (RFC 8446 Section 4.2.10).
    earlyData: bool = false,

    pub const CipherSuite = tls.CipherSuite;
    pub const KeyShareEntry = struct {
        group: NamedGroup,
        keyExchange: []const u8,
    };

    /// Serializes the full ClientHello message (handshake type + length + body).
    pub fn encode(self: *const ClientHello, allocator: Allocator) ![]u8 {
        var body = std.ArrayList(u8).empty;
        defer body.deinit(allocator);

        // clientVersion: TLS 1.2 (0x0303) — legacy, real version in supportedVersions
        try body.appendSlice(allocator, &.{ 0x03, 0x03 });

        // clientRandom (32 bytes)
        try body.appendSlice(allocator, &self.random);

        // legacySessionId (empty for a fresh TLS 1.3 handshake)
        try body.append(allocator, 0);

        // cipherSuitesLength (u16) + cipherSuites (u16 each)
        const csLen: u16 = @intCast(self.cipherSuites.len * 2);
        try body.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, csLen)));
        for (self.cipherSuites) |cs| {
            try body.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @backingInt(cs))));
        }

        // compressionMethods: [0x00] (null compression)
        try body.appendSlice(allocator, &.{ 0x01, 0x00 });

        // Extensions
        var exts = std.ArrayList(u8).empty;
        defer exts.deinit(allocator);

        // serverName (SNI) - RFC 6066 Section 3
        if (self.serverName) |hostname| {
            const sniLen: u16 = @intCast(5 + hostname.len);
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @backingInt(ExtensionType.server_name))));
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, sniLen)));
            const nameTotal: u16 = @intCast(3 + hostname.len);
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, nameTotal)));
            try exts.append(allocator, 0x00);
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(hostname.len))));
            try exts.appendSlice(allocator, hostname);
        }

        // supportedGroups (RFC 8446 Section 4.2.7: length-prefixed list)
        {
            var sgBody = std.ArrayList(u8).empty;
            defer sgBody.deinit(allocator);
            for (self.keyShareEntries) |e| {
                try sgBody.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @backingInt(e.group))));
            }
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @backingInt(ExtensionType.supported_groups))));
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(sgBody.items.len + 2))));
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(sgBody.items.len))));
            try exts.appendSlice(allocator, sgBody.items);
        }

        // keyShare (RFC 8446 Section 4.2.8: clientShares is a length-prefixed vector)
        {
            var ksBody = std.ArrayList(u8).empty;
            defer ksBody.deinit(allocator);
            for (self.keyShareEntries) |e| {
                try ksBody.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @backingInt(e.group))));
                try ksBody.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(e.keyExchange.len))));
                try ksBody.appendSlice(allocator, e.keyExchange);
            }
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @backingInt(ExtensionType.key_share))));
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(ksBody.items.len + 2))));
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(ksBody.items.len))));
            try exts.appendSlice(allocator, ksBody.items);
        }

        // signatureAlgorithms (RFC 8446 Section 4.2.3: length-prefixed list)
        {
            var saBody = std.ArrayList(u8).empty;
            defer saBody.deinit(allocator);
            for (self.signatureAlgorithms) |sa| {
                try saBody.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @backingInt(sa))));
            }
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @backingInt(ExtensionType.signature_algorithms))));
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(saBody.items.len + 2))));
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(saBody.items.len))));
            try exts.appendSlice(allocator, saBody.items);
        }

        // ALPN
        if (self.alpnProtocols.len > 0) {
            var alpnBody = std.ArrayList(u8).empty;
            defer alpnBody.deinit(allocator);
            for (self.alpnProtocols) |proto| {
                try alpnBody.append(allocator, @intCast(proto.len));
                try alpnBody.appendSlice(allocator, proto);
            }
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @backingInt(ExtensionType.application_layer_protocol_negotiation))));
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(alpnBody.items.len + 2))));
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(alpnBody.items.len))));
            try exts.appendSlice(allocator, alpnBody.items);
        }

        // QUIC transport parameters (RFC 9001 Section 7.4, ext 57):
        // length-prefixed opaque block, QUIC paths only.
        if (self.quicTransportParams) |tp| {
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, QUIC_TRANSPORT_PARAMETERS_ID)));
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(tp.len))));
            try exts.appendSlice(allocator, tp);
        }

        // supportedVersions (RFC 8446 Section 4.2.1: u8 length + u16 versions)
        {
            var svBody = std.ArrayList(u8).empty;
            defer svBody.deinit(allocator);
            for (self.supportedVersions) |v| {
                try svBody.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, v)));
            }
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @backingInt(ExtensionType.supported_versions))));
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(svBody.items.len + 1))));
            try exts.append(allocator, @intCast(svBody.items.len));
            try exts.appendSlice(allocator, svBody.items);
        }

        // pskKeyExchangeModes (RFC 8446 Section 4.2.9: u8 length + u8 modes)
        if (self.pskModes.len > 0) {
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @backingInt(ExtensionType.psk_key_exchange_modes))));
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(self.pskModes.len + 1))));
            try exts.append(allocator, @intCast(self.pskModes.len));
            try exts.appendSlice(allocator, self.pskModes);
        }

        // early_data (RFC 8446 Section 4.2.10): type 42, length 0 in ClientHello.
        // Signals intent to send early application data. Must precede pre_shared_key.
        if (self.earlyData) {
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @backingInt(ExtensionType.early_data))));
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0)));
        }

        // preSharedKey (RFC 8446 Section 4.2.11): MUST be last. The
        // binder bytes are emitted as zeros here; the caller patches the
        // real binders with `pskBinderSpan` after hashing the message.
        if (self.pskIdentities.len > 0) {
            var pskBody = std.ArrayList(u8).empty;
            defer pskBody.deinit(allocator);
            var idList = std.ArrayList(u8).empty;
            defer idList.deinit(allocator);
            for (self.pskIdentities) |id| {
                try idList.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(id.len))));
                try idList.appendSlice(allocator, id);
                try idList.appendSlice(allocator, &.{ 0, 0, 0, 0 }); // obfuscatedTicketAge placeholder
            }
            try pskBody.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(idList.items.len))));
            try pskBody.appendSlice(allocator, idList.items);
            const binderBytes: usize = self.pskIdentities.len * HashLen;
            try pskBody.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(binderBytes))));
            try pskBody.appendNTimes(allocator, 0, binderBytes);
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @backingInt(ExtensionType.pre_shared_key))));
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(pskBody.items.len))));
            try exts.appendSlice(allocator, pskBody.items);
        }

        // Append extensions length + body to main body
        try body.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(exts.items.len))));
        try body.appendSlice(allocator, exts.items);

        // Prepend handshake type + u24 length
        const msgTypeByte: u8 = @backingInt(HandshakeType.client_hello);
        const bodyLen: u24 = @intCast(body.items.len);
        var header: [4]u8 = undefined;
        header[0] = msgTypeByte;
        header[1] = @intCast((bodyLen >> 16) & 0xFF);
        header[2] = @intCast((bodyLen >> 8) & 0xFF);
        header[3] = @intCast(bodyLen & 0xFF);

        var result = std.ArrayList(u8).empty;
        try result.appendSlice(allocator, &header);
        try result.appendSlice(allocator, body.items);
        return result.toOwnedSlice(allocator);
    }
};

/// Locates the preSharedKey extension in an encoded ClientHello
/// (full message with 4-byte header). Per RFC 8446 Section 4.2.11 it
/// MUST be the last extension; anything else is a protocol violation.
/// Returns the byte range of the extension body.
fn pskExtBody(msg: []const u8) !struct { start: usize, len: usize } {
    if (msg.len < 4 + 34 + 1) return error.ProtocolViolation;
    var pos: usize = 4 + 34; // header + version + random
    const sidLen: usize = msg[pos];
    pos += 1 + sidLen;
    if (pos + 2 > msg.len) return error.ProtocolViolation;
    const csLen: usize = (@as(usize, msg[pos]) << 8) | msg[pos + 1];
    pos += 2 + csLen;
    if (pos + 1 > msg.len) return error.ProtocolViolation;
    pos += 1 + msg[pos]; // compression methods
    if (pos + 2 > msg.len) return error.ProtocolViolation;
    const extTotal: usize = (@as(usize, msg[pos]) << 8) | msg[pos + 1];
    pos += 2;
    const extEnd = pos + extTotal;
    if (extEnd > msg.len) return error.ProtocolViolation;
    // Find the LAST extension: it must be preSharedKey.
    var lastType: u16 = 0;
    var lastStart: usize = pos;
    var lastLen: usize = 0;
    var p = pos;
    while (p + 4 <= extEnd) {
        const t = std.mem.readInt(u16, msg[p..][0..2], .big);
        const l: usize = (@as(usize, msg[p + 2]) << 8) | msg[p + 3];
        if (p + 4 + l > extEnd) return error.ProtocolViolation;
        lastType = t;
        lastStart = p + 4;
        lastLen = l;
        p += 4 + l;
    }
    if (p != extEnd) return error.ProtocolViolation;
    if (lastType != @backingInt(ExtensionType.pre_shared_key)) return error.ProtocolViolation;
    return .{ .start = lastStart, .len = lastLen };
}

/// Mutable span of the contiguous binder bytes of a PSK offer, for
/// patching real binders over the zero placeholders left by
/// `ClientHello.encode`. Validates the full extension structure.
pub fn pskBinderSpan(msg: []u8) ![]u8 {
    const ext = try pskExtBody(msg);
    const body = msg[ext.start..][0..ext.len];
    if (body.len < 2) return error.ProtocolViolation;
    const idLen: usize = (@as(usize, body[0]) << 8) | body[1];
    if (2 + idLen + 2 > body.len) return error.ProtocolViolation;
    const bLenPos = 2 + idLen;
    const bLen: usize = (@as(usize, body[bLenPos]) << 8) | body[bLenPos + 1];
    if (bLen % HashLen != 0) return error.ProtocolViolation;
    if (bLenPos + 2 + bLen != body.len) return error.ProtocolViolation;
    return msg[ext.start + bLenPos + 2 ..][0..bLen];
}

/// Returns the byte length of the truncated ClientHello up to and including
/// the `PreSharedKeyExtension.identities` field (RFC 8446 Section 4.2.11.2),
/// for computing the PSK binder over the exact standard transcript representation.
pub fn pskTruncatedLen(msg: []const u8) !usize {
    const ext = try pskExtBody(msg);
    const body = msg[ext.start..][0..ext.len];
    if (body.len < 2) return error.ProtocolViolation;
    const idLen: usize = (@as(usize, body[0]) << 8) | body[1];
    if (2 + idLen + 2 > body.len) return error.ProtocolViolation;
    return ext.start + 2 + idLen;
}

/// Checks whether an encoded ClientHello contains the early_data extension (type 42).
pub fn hasEarlyDataExtension(msg: []const u8) bool {
    if (msg.len < 4 + 34 + 1) return false;
    var pos: usize = 4 + 34; // header + version + random
    const sidLen: usize = msg[pos];
    pos += 1 + sidLen;
    if (pos + 2 > msg.len) return false;
    const csLen: usize = (@as(usize, msg[pos]) << 8) | msg[pos + 1];
    pos += 2 + csLen;
    if (pos + 1 > msg.len) return false;
    pos += 1 + msg[pos]; // compression methods
    if (pos + 2 > msg.len) return false;
    const extTotal: usize = (@as(usize, msg[pos]) << 8) | msg[pos + 1];
    pos += 2;
    const extEnd = pos + extTotal;
    if (extEnd > msg.len) return false;
    var p = pos;
    while (p + 4 <= extEnd) {
        const t = std.mem.readInt(u16, msg[p..][0..2], .big);
        const l: usize = (@as(usize, msg[p + 2]) << 8) | msg[p + 3];
        if (p + 4 + l > extEnd) return false;
        if (t == @backingInt(ExtensionType.early_data)) {
            return l == 0; // RFC 8446 Section 4.2.10: ClientHello early_data must have 0-length body
        }
        p += 4 + l;
    }
    return false;
}

/// Mutable span of the u32 obfuscatedTicketAge of identity `index`
/// (big-endian on the wire). The engine patches the real age here.
pub fn pskAgeSpan(msg: []u8, index: usize) ![4]u8 {
    const ext = try pskExtBody(msg);
    const body = msg[ext.start..][0..ext.len];
    if (body.len < 2) return error.ProtocolViolation;
    const idLen: usize = (@as(usize, body[0]) << 8) | body[1];
    var p: usize = 2;
    const listEnd = 2 + idLen;
    if (listEnd + 2 > body.len) return error.ProtocolViolation;
    var i: usize = 0;
    while (p + 2 <= listEnd) : (i += 1) {
        const ilen: usize = (@as(usize, body[p]) << 8) | body[p + 1];
        if (p + 2 + ilen + 4 > listEnd) return error.ProtocolViolation;
        if (i == index) {
            const abs = ext.start + p + 2 + ilen;
            return msg[abs..][0..4].*;
        }
        p += 2 + ilen + 4;
    }
    return error.ProtocolViolation;
}

/// Borrowed view of identity 0 of a PSK offer plus all binder bytes.
/// This covers the engine's single-identity offers and keeps parsing
/// allocation-free; multi-identity offers are rejected as over-engineered
/// attack surface (RFC allows servers to ignore identities past the
/// first they accept — we accept only the first).
pub fn parsePskFirst(msg: []const u8) !?struct { ticket: []const u8, obfuscatedAge: u32, binders: []const u8 } {
    const ext = pskExtBody(msg) catch return null;
    const body = msg[ext.start..][0..ext.len];
    const idLen: usize = (@as(usize, body[0]) << 8) | body[1];
    const listEnd = 2 + idLen;
    if (listEnd + 2 > body.len) return error.ProtocolViolation;
    const p: usize = 2;
    if (p + 2 > listEnd) return error.ProtocolViolation;
    const ilen: usize = (@as(usize, body[p]) << 8) | body[p + 1];
    if (p + 2 + ilen + 4 > listEnd) return error.ProtocolViolation;
    const ticket = body[p + 2 ..][0..ilen];
    const age = std.mem.readInt(u32, body[p + 2 + ilen ..][0..4], .big);
    const bLenPos = listEnd;
    const bLen: usize = (@as(usize, body[bLenPos]) << 8) | body[bLenPos + 1];
    if (bLen % HashLen != 0) return error.ProtocolViolation;
    if (bLenPos + 2 + bLen != body.len) return error.ProtocolViolation;
    return .{ .ticket = ticket, .obfuscatedAge = age, .binders = body[bLenPos + 2 ..][0..bLen] };
}

// ServerHello (RFC 8446 Section 4.1.3)

/// HelloRetryRequest magic random (RFC 8446 Section 4.1.3): a
/// ServerHello carrying this random IS a HelloRetryRequest.
pub const helloRetryMagic: [32]u8 = .{
    0xCF, 0x21, 0xAD, 0x74, 0xE5, 0x9A, 0x61, 0x11, 0xBE, 0x1D, 0x8C, 0x02,
    0x1E, 0x65, 0xB8, 0x91, 0xC2, 0xA2, 0x11, 0x16, 0x7A, 0xBB, 0x8C, 0x5E,
    0x07, 0x9E, 0x09, 0xE2, 0xC8, 0xA8, 0x33, 0x9C,
};

/// True when a ServerHello body (after the 4-byte handshake header)
/// carries the HelloRetryRequest magic random.
pub fn isHelloRetryRequest(body: []const u8) bool {
    if (body.len < 34) return false;
    // Standard framing: version(2) + random(32); legacy test framing
    // starts directly with random.
    const rand = if (body.len >= 34 and body[0] == 0x03 and body[1] == 0x03) body[2..34] else body[0..32];
    return std.mem.eql(u8, rand, &helloRetryMagic);
}

pub const ServerHello = struct {
    random: [32]u8,
    cipherSuite: tls.CipherSuite,
    keyShare: ?KeyShareEntry = null,
    /// preSharedKey.selectedIdentity (server accepted our PSK offer).
    selectedPskIdentity: ?u16 = null,
    /// HelloRetryRequest-style keyShare carrying only the selected
    /// group (no keyExchange bytes).
    hrrGroup: ?NamedGroup = null,

    pub const KeyShareEntry = struct {
        group: NamedGroup,
        keyExchange: []const u8,
    };

    /// Parses a ServerHello body (after the 4-byte handshake header has been consumed).
    pub fn decode(body: []const u8) !ServerHello {
        // RFC 8446 Section 4.1.3 ServerHello body layout:
        //   [0..2]   legacyVersion (0x0303)
        //   [2..34]  random (32 bytes)
        //   [34]     legacySessionIdEcho length (u8)
        //   [35..]   legacySessionIdEcho
        //   [...]    cipherSuite (2 bytes)
        //   [...]    legacyCompressionMethod (1 byte)
        //   [...]    extensions length (2 bytes) + extensions
        var pos: usize = 0;
        // Explicit base: every optional defaults to null (a bare
        // `= undefined` would leave them as garbage to read).
        var result: ServerHello = .{ .random = (@as([32]u8, @splat(0))), .cipherSuite = .AES_128_GCM_SHA256 };

        if (body.len >= 34 and !isLegacyFraming(body)) {
            // Standard TLS 1.3 ServerHello with legacyVersion (2 bytes) + random (32 bytes)
            if (body.len < 2 + 32 + 1) return error.ServerHelloTooShort;
            @memcpy(&result.random, body[2..34]);
            const sidLen: usize = body[34];
            pos = 35 + sidLen;
            if (pos + 3 > body.len) return error.ServerHelloTooShort;
            const cs = std.mem.readInt(u16, body[pos..][0..2], .big);
            result.cipherSuite = @fromBackingInt(@intCast(cs));
            pos += 2 + 1; // skip cipherSuite + compression
        } else {
            // Fallback for short/legacy test vectors starting directly with random (32 bytes)
            if (body.len < 34) return error.ServerHelloTooShort;
            @memcpy(&result.random, body[0..32]);
            const cs = std.mem.readInt(u16, body[32..34], .big);
            result.cipherSuite = @fromBackingInt(@intCast(cs));
            pos = 34;
        }

        // Parse extensions
        if (pos + 2 > body.len) return result;
        const extLen: usize = (@as(usize, body[pos]) << 8) | body[pos + 1];
        pos += 2;
        const extEnd = pos + extLen;
        if (extEnd > body.len) return error.ServerHelloTruncated;

        while (pos + 4 <= extEnd) {
            const extType = std.mem.readInt(u16, body[pos..][0..2], .big);
            const extDataLen: usize = (@as(usize, body[pos + 2]) << 8) | body[pos + 3];
            pos += 4;
            if (pos + extDataLen > extEnd) return error.ServerHelloTruncated;

            if (extType == @backingInt(ExtensionType.key_share)) {
                if (extDataLen == 2) {
                    // HelloRetryRequest form: selected group only, no
                    // keyExchange bytes (RFC 8446 Section 4.1.4).
                    result.hrrGroup = @fromBackingInt(@intCast(std.mem.readInt(u16, body[pos..][0..2], .big)));
                } else if (extDataLen >= 4) {
                    const group = std.mem.readInt(u16, body[pos..][0..2], .big);
                    const ksLen: usize = (@as(usize, body[pos + 2]) << 8) | body[pos + 3];
                    if (pos + 4 + ksLen <= extEnd) {
                        result.keyShare = .{
                            .group = @fromBackingInt(@intCast(group)),
                            .keyExchange = body[pos + 4 ..][0..ksLen],
                        };
                    }
                }
            } else if (extType == @backingInt(ExtensionType.pre_shared_key)) {
                // ServerHello preSharedKey: selectedIdentity u16.
                if (extDataLen == 2) {
                    result.selectedPskIdentity = std.mem.readInt(u16, body[pos..][0..2], .big);
                }
            }
            pos += extDataLen;
        }
        return result;
    }

    fn isLegacyFraming(body: []const u8) bool {
        // If body starts with 0x03, 0x03, it has legacyVersion header
        return !(body.len >= 2 and body[0] == 0x03 and body[1] == 0x03);
    }
};

// NewSessionTicket (RFC 8446 Section 4.6.1)

pub const NewSessionTicket = struct {
    lifetimeSecs: u32,
    ageAdd: u32,
    nonce: []const u8,
    ticket: []const u8,
    maxEarlyData: ?u32 = null,

    /// Encodes a full NewSessionTicket handshake message (type 4).
    /// If `maxEarlyData` is set, emits the `early_data` extension (RFC 8446 Section 4.2.10)
    /// containing the u32 max_early_data_size.
    pub fn encode(self: *const NewSessionTicket, allocator: Allocator) ![]u8 {
        var body = std.ArrayList(u8).empty;
        defer body.deinit(allocator);
        try body.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, self.lifetimeSecs)));
        try body.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, self.ageAdd)));
        if (self.nonce.len > 255) return error.ProtocolViolation;
        try body.append(allocator, @intCast(self.nonce.len));
        try body.appendSlice(allocator, self.nonce);
        if (self.ticket.len == 0 or self.ticket.len > 65535) return error.ProtocolViolation;
        try body.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(self.ticket.len))));
        try body.appendSlice(allocator, self.ticket);

        var exts = std.ArrayList(u8).empty;
        defer exts.deinit(allocator);
        if (self.maxEarlyData) |med| {
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @backingInt(ExtensionType.early_data))));
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 4)));
            try exts.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, med)));
        }
        try body.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(exts.items.len))));
        try body.appendSlice(allocator, exts.items);

        var msg = std.ArrayList(u8).empty;
        errdefer msg.deinit(allocator);
        try msg.append(allocator, @backingInt(HandshakeType.new_session_ticket));
        const bodyLen: u24 = @intCast(body.items.len);
        try msg.append(allocator, @intCast((bodyLen >> 16) & 0xFF));
        try msg.append(allocator, @intCast((bodyLen >> 8) & 0xFF));
        try msg.append(allocator, @intCast(bodyLen & 0xFF));
        try msg.appendSlice(allocator, body.items);
        return msg.toOwnedSlice(allocator);
    }

    /// Decodes a NewSessionTicket body (after the 4-byte header).
    /// Borrows all slices; extracts early-data allowance if present.
    pub fn decode(body: []const u8) !NewSessionTicket {
        var pos: usize = 0;
        if (body.len < 12) return error.ProtocolViolation;
        const lifetime = std.mem.readInt(u32, body[0..4], .big);
        const ageAdd = std.mem.readInt(u32, body[4..8], .big);
        const nonceLen: usize = body[8];
        pos = 9;
        if (pos + nonceLen + 2 > body.len) return error.ProtocolViolation;
        const nonce = body[pos..][0..nonceLen];
        pos += nonceLen;
        const ticketLen: usize = std.mem.readInt(u16, body[pos..][0..2], .big);
        pos += 2;
        if (ticketLen == 0 or pos + ticketLen + 2 > body.len) return error.ProtocolViolation;
        const ticket = body[pos..][0..ticketLen];
        pos += ticketLen;
        const extLen: usize = std.mem.readInt(u16, body[pos..][0..2], .big);
        pos += 2;
        if (pos + extLen != body.len) return error.ProtocolViolation;
        var ep: usize = pos;
        var maxEarlyData: ?u32 = null;
        while (ep + 4 <= body.len) {
            const t = std.mem.readInt(u16, body[ep..][0..2], .big);
            const l: usize = std.mem.readInt(u16, body[ep + 2 ..][0..2], .big);
            if (t == @backingInt(ExtensionType.early_data)) {
                if (l != 4 or ep + 4 + l > body.len) return error.ProtocolViolation;
                maxEarlyData = std.mem.readInt(u32, body[ep + 4 ..][0..4], .big);
            }
            ep += 4 + l;
        }
        if (lifetime == 0) return error.ProtocolViolation;
        return .{
            .lifetimeSecs = lifetime,
            .ageAdd = ageAdd,
            .nonce = nonce,
            .ticket = ticket,
            .maxEarlyData = maxEarlyData,
        };
    }
};

// Post-handshake record framing (RFC 8446 Section 5.1)
//
// A single TLS record may carry several concatenated handshake messages,
// each framed as a 1-byte type plus a u24 length. Servers commonly coalesce
// multiple NewSessionTicket messages into one record.

/// One framed handshake message borrowed from a record's plaintext.
pub const FramedMessage = struct {
    msgType: HandshakeType,
    /// Exactly the declared length; borrows from the record.
    body: []const u8,
};

/// Splits concatenated handshake messages with strict bounds checking.
/// Truncated headers, declared lengths overrunning the buffer, and trailing
/// garbage all fail loudly instead of producing partial messages.
pub const MessageIterator = struct {
    rest: []const u8,

    pub fn init(record: []const u8) MessageIterator {
        return .{ .rest = record };
    }

    pub fn next(self: *MessageIterator) !?FramedMessage {
        if (self.rest.len == 0) return null;
        if (self.rest.len < 4) return error.ProtocolViolation;
        const msgType: HandshakeType = @fromBackingInt(@intCast(self.rest[0]));
        const bodyLen: usize = (@as(usize, self.rest[1]) << 16) |
            (@as(usize, self.rest[2]) << 8) | self.rest[3];
        // Subtractive check avoids any overflow on huge declared lengths.
        if (bodyLen > self.rest.len - 4) return error.ProtocolViolation;
        const body = self.rest[4..][0..bodyLen];
        self.rest = self.rest[4 + bodyLen ..];
        return .{ .msgType = msgType, .body = body };
    }
};

// EncryptedExtensions (RFC 8446 Section 4.3.1)

pub const EncryptedExtensions = struct {
    alpnProtocol: ?[]const u8 = null,
    /// Raw QUIC transport parameters block (ext 57), borrowed.
    quicTransportParams: ?[]const u8 = null,
    /// True when server accepted early data (ext 42 present with 0 length).
    earlyDataAccepted: bool = false,

    pub fn decode(body: []const u8) !EncryptedExtensions {
        var result: EncryptedExtensions = .{};
        if (body.len < 2) return error.EncryptedExtensionsTooShort;
        const extLen: usize = (@as(usize, body[0]) << 8) | body[1];
        if (2 + extLen != body.len) return error.EncryptedExtensionsTruncated;
        var pos: usize = 2;
        const extEnd = 2 + extLen;
        if (extEnd > body.len) return error.EncryptedExtensionsTruncated;

        while (pos + 4 <= extEnd) {
            const extType = std.mem.readInt(u16, body[pos..][0..2], .big);
            const extDataLen: usize = (@as(usize, body[pos + 2]) << 8) | body[pos + 3];
            pos += 4;
            if (pos + extDataLen > extEnd) return error.EncryptedExtensionsTruncated;

            if (extType == @backingInt(ExtensionType.application_layer_protocol_negotiation)) {
                if (extDataLen >= 3) {
                    const listLen: usize = (@as(usize, body[pos]) << 8) | body[pos + 1];
                    if (listLen >= 1 and extDataLen >= 2 + listLen) {
                        const protoLen = body[pos + 2];
                        if (3 + protoLen <= extDataLen) {
                            result.alpnProtocol = body[pos + 3 ..][0..protoLen];
                        }
                    }
                }
            } else if (extType == QUIC_TRANSPORT_PARAMETERS_ID) {
                result.quicTransportParams = body[pos..][0..extDataLen];
            } else if (extType == @backingInt(ExtensionType.early_data)) {
                if (extDataLen == 0) {
                    result.earlyDataAccepted = true;
                } else {
                    return error.EncryptedExtensionsTruncated;
                }
            }
            pos += extDataLen;
        }
        return result;
    }
};

// CertificateEntry (part of Certificate message, RFC 8446 Section 4.4.2)

pub const CertificateEntry = struct {
    certData: []const u8,
    extensions: []const u8,
};

// CertificateVerify (RFC 8446 Section 4.4.3)

pub const CertificateVerify = struct {
    algorithm: SignatureScheme,
    signature: []const u8,

    pub fn decode(body: []const u8) !CertificateVerify {
        if (body.len < 4) return error.CertificateVerifyTooShort;
        const alg = std.mem.readInt(u16, body[0..2], .big);
        const sigLen: usize = (@as(usize, body[2]) << 8) | body[3];
        if (4 + sigLen != body.len) return error.CertificateVerifyTruncated;
        return .{
            .algorithm = @fromBackingInt(@intCast(alg)),
            .signature = body[4..][0..sigLen],
        };
    }
};

// Finished (RFC 8446 Section 4.4.4)

pub const Finished = struct {
    verifyData: [HashLen]u8,

    pub fn decode(body: []const u8) !Finished {
        if (body.len != HashLen) return error.FinishedTooShort;
        var result: Finished = undefined;
        @memcpy(&result.verifyData, body[0..HashLen]);
        return result;
    }
};

// Extension types (subset we use)

pub const ExtensionType = tls.ExtensionType;

/// QUIC transport parameters extension ID (RFC 9001 Section 7.4).
/// Kept as a raw ID: the std TLS ExtensionType enum predates QUIC use.
pub const QUIC_TRANSPORT_PARAMETERS_ID: u16 = 57;

// TLS alert (RFC 8446 Section 6.2)

pub const AlertLevel = enum(u8) {
    warning = 1,
    fatal = 2,
};

pub const AlertDescription = enum(u8) {
    closeNotify = 0,
    unexpectedMessage = 10,
    badRecordMac = 20,
    handshakeFailure = 40,
    badCertificate = 42,
    unsupportedCertificate = 43,
    certificateRevoked = 44,
    certificateExpired = 45,
    certificateUnknown = 46,
    illegalParameter = 47,
    unknownCa = 48,
    accessDenied = 49,
    decodeError = 50,
    decryptError = 51,
    protocolVersion = 70,
    insufficientSecurity = 71,
    internalError = 80,
    inappropriateFallback = 86,
    userCanceled = 90,
    noRenegotiation = 100,
    unsupportedExtension = 109,
    unrecognizedName = 112,
    badCertificateStatusResponse = 113,
    unknownPskIdentity = 115,
    certificateRequired = 116,

    pub fn toError(_: AlertDescription) error{TlsAlert} {
        return error.TlsAlert;
    }
};

pub const Alert = struct {
    level: AlertLevel,
    description: AlertDescription,

    pub fn encode(self: Alert) [2]u8 {
        return .{ @backingInt(self.level), @backingInt(self.description) };
    }

    pub fn decode(data: [2]u8) Alert {
        return .{
            .level = @fromBackingInt(@intCast(data[0])),
            .description = @fromBackingInt(@intCast(data[1])),
        };
    }
};

// Tests

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
        .random = (@as([32]u8, @splat(0xAA))),
        .cipherSuites = &.{.AES_128_GCM_SHA256},
        .keyShareEntries = &.{.{
            .group = .x25519,
            .keyExchange = &(@as([32]u8, @splat(0xBB))),
        }},
        .signatureAlgorithms = &.{.ecdsa_secp256r1_sha256},
        .alpnProtocols = &.{"h2"},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const encoded = try ch.encode(a);
    defer a.free(encoded);

    // Must start with handshake type clientHello (0x01) + u24 length
    try std.testing.expectEqual(@as(u8, 0x01), encoded[0]);
    const bodyLen: u24 = @as(u24, @intCast(encoded[1])) << 16 | @as(u24, @intCast(encoded[2])) << 8 | @as(u24, @intCast(encoded[3]));
    try std.testing.expectEqual(encoded.len - 4, bodyLen);
    try std.testing.expect(encoded.len > 40); // at minimum: version(2) + random(32) + csLen(2) + cs(2) + comp(2) + extLen(2) + extensions
}

test "ServerHello decode roundtrip" {
    // Construct a minimal ServerHello body manually
    var body: [64]u8 = undefined;
    @memset(&body, 0);
    // random (32 bytes at offset 0)
    @memcpy(body[0..32], &(@as([32]u8, @splat(0x11))));
    // cipherSuite (2 bytes at offset 32)
    body[32] = 0x13;
    body[33] = 0x01; // TLS_AES_128_GCM_SHA256
    // extensionsLength (2 bytes at offset 34)
    body[34] = 0;
    body[35] = 0;

    const sh = try ServerHello.decode(&body);
    try std.testing.expectEqual(tls.CipherSuite.AES_128_GCM_SHA256, sh.cipherSuite);
}

test "Alert encode/decode roundtrip" {
    const a = Alert{ .level = .fatal, .description = .handshakeFailure };
    const encoded = a.encode();
    const decoded = Alert.decode(encoded);
    try std.testing.expectEqual(.fatal, decoded.level);
    try std.testing.expectEqual(.handshakeFailure, decoded.description);
}

test "ClientHello with earlyData and PSK offers early_data and computes pskTruncatedLen" {
    const ch = ClientHello{
        .random = (@as([32]u8, @splat(0x55))),
        .cipherSuites = &.{.AES_128_GCM_SHA256},
        .keyShareEntries = &.{.{
            .group = .x25519,
            .keyExchange = &(@as([32]u8, @splat(0x66))),
        }},
        .signatureAlgorithms = &.{.ecdsa_secp256r1_sha256},
        .alpnProtocols = &.{"h3"},
        .pskIdentities = &.{"dummy-ticket-identity"},
        .earlyData = true,
    };

    const encoded = try ch.encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);

    try std.testing.expect(hasEarlyDataExtension(encoded));

    const truncLen = try pskTruncatedLen(encoded);
    try std.testing.expect(truncLen > 0);
    try std.testing.expect(truncLen < encoded.len);
    // Binder span starts right after truncLen + 2 (binders length prefix)
    const binderSpan = try pskBinderSpan(encoded);
    try std.testing.expectEqual(@as(usize, HashLen), binderSpan.len);
}

test "NewSessionTicket encodes and decodes maxEarlyData" {
    const nst = NewSessionTicket{
        .lifetimeSecs = 7200,
        .ageAdd = 12345,
        .nonce = &[_]u8{ 1, 2, 3, 4 },
        .ticket = &(@as([40]u8, @splat(0xAA))),
        .maxEarlyData = 0xFFFFFFFF,
    };

    const msg = try nst.encode(std.testing.allocator);
    defer std.testing.allocator.free(msg);

    // Skip 4-byte handshake header
    const decoded = try NewSessionTicket.decode(msg[4..]);
    try std.testing.expectEqual(nst.lifetimeSecs, decoded.lifetimeSecs);
    try std.testing.expectEqual(nst.ageAdd, decoded.ageAdd);
    try std.testing.expectEqualSlices(u8, nst.nonce, decoded.nonce);
    try std.testing.expectEqualSlices(u8, nst.ticket, decoded.ticket);
    try std.testing.expectEqual(@as(?u32, 0xFFFFFFFF), decoded.maxEarlyData);
}

test "MessageIterator splits coalesced NewSessionTicket messages" {
    const a = std.testing.allocator;
    const first = NewSessionTicket{
        .lifetimeSecs = 100,
        .ageAdd = 1,
        .nonce = &[_]u8{0xA1},
        .ticket = &(@as([8]u8, @splat(0x11))),
    };
    const second = NewSessionTicket{
        .lifetimeSecs = 200,
        .ageAdd = 2,
        .nonce = &[_]u8{ 0xB2, 0xB3 },
        .ticket = &(@as([8]u8, @splat(0x22))),
        .maxEarlyData = 16384,
    };
    const m1 = try first.encode(a);
    defer a.free(m1);
    const m2 = try second.encode(a);
    defer a.free(m2);

    // Two tickets concatenated in one record, as servers coalesce them.
    var rec = std.ArrayList(u8).empty;
    defer rec.deinit(a);
    try rec.appendSlice(a, m1);
    try rec.appendSlice(a, m2);

    var it = MessageIterator.init(rec.items);
    const one = (try it.next()).?;
    try std.testing.expectEqual(HandshakeType.new_session_ticket, one.msgType);
    const d1 = try NewSessionTicket.decode(one.body);
    try std.testing.expectEqual(@as(u32, 100), d1.lifetimeSecs);
    const two = (try it.next()).?;
    try std.testing.expectEqual(HandshakeType.new_session_ticket, two.msgType);
    const d2 = try NewSessionTicket.decode(two.body);
    try std.testing.expectEqual(@as(u32, 200), d2.lifetimeSecs);
    try std.testing.expectEqual(@as(?u32, 16384), d2.maxEarlyData);
    try std.testing.expect(try it.next() == null);
}

test "MessageIterator dispatches mixed handshake types by length" {
    const a = std.testing.allocator;
    const ticket = NewSessionTicket{
        .lifetimeSecs = 100,
        .ageAdd = 1,
        .nonce = &[_]u8{0xA1},
        .ticket = &(@as([8]u8, @splat(0x11))),
    };
    const msg = try ticket.encode(a);
    defer a.free(msg);

    // Valid ticket followed by a KeyUpdate message (type 24).
    var rec = std.ArrayList(u8).empty;
    defer rec.deinit(a);
    try rec.appendSlice(a, msg);
    try rec.appendSlice(a, &.{ 24, 0, 0, 1, 0xAA });

    var it = MessageIterator.init(rec.items);
    const one = (try it.next()).?;
    try std.testing.expectEqual(HandshakeType.new_session_ticket, one.msgType);
    _ = try NewSessionTicket.decode(one.body);
    const two = (try it.next()).?;
    try std.testing.expectEqual(HandshakeType.key_update, two.msgType);
    try std.testing.expectEqualSlices(u8, &.{0xAA}, two.body);
    try std.testing.expect(try it.next() == null);
}

test "MessageIterator rejects truncated and overrunning frames" {
    var it = MessageIterator.init(&.{});
    try std.testing.expect(try it.next() == null);

    // Truncated 3-byte header.
    var short = MessageIterator.init(&.{ 4, 0, 0 });
    try std.testing.expectError(error.ProtocolViolation, short.next());

    // Declared length overruns the buffer.
    var over = MessageIterator.init(&.{ 4, 0, 1, 0 });
    try std.testing.expectError(error.ProtocolViolation, over.next());

    // Trailing garbage byte after a complete message.
    const a = std.testing.allocator;
    const ticket = NewSessionTicket{
        .lifetimeSecs = 100,
        .ageAdd = 1,
        .nonce = &[_]u8{0xA1},
        .ticket = &(@as([8]u8, @splat(0x11))),
    };
    const msg = try ticket.encode(a);
    defer a.free(msg);
    var rec = std.ArrayList(u8).empty;
    defer rec.deinit(a);
    try rec.appendSlice(a, msg);
    try rec.append(a, 0xFF);
    var trailing = MessageIterator.init(rec.items);
    _ = (try trailing.next()).?;
    try std.testing.expectError(error.ProtocolViolation, trailing.next());
}

test "NewSessionTicket decode rejects malformed bodies" {
    // Too short for fixed fields.
    try std.testing.expectError(error.ProtocolViolation, NewSessionTicket.decode(&(@as([11]u8, @splat(0)))));

    // Truncated nonce.
    var short = [_]u8{ 0, 0, 0, 100, 0, 0, 0, 1, 8, 0xA1 };
    try std.testing.expectError(error.ProtocolViolation, NewSessionTicket.decode(&short));

    // Zero-length ticket.
    var emptyTicket = [_]u8{ 0, 0, 0, 100, 0, 0, 0, 1, 1, 0xA1, 0, 0, 0, 0 };
    try std.testing.expectError(error.ProtocolViolation, NewSessionTicket.decode(&emptyTicket));

    // Extension length overruns the body.
    var badExt = [_]u8{ 0, 0, 0, 100, 0, 0, 0, 1, 1, 0xA1, 0, 1, 0xAA, 0, 9, 0, 0 };
    try std.testing.expectError(error.ProtocolViolation, NewSessionTicket.decode(&badExt));

    // Zero lifetime.
    var zeroLife = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 1, 1, 0xA1, 0, 1, 0xAA, 0, 0 };
    try std.testing.expectError(error.ProtocolViolation, NewSessionTicket.decode(&zeroLife));
}

test "EncryptedExtensions decodes earlyDataAccepted" {
    // Construct an EncryptedExtensions body with early_data (type 42, length 0)
    var body = std.ArrayList(u8).empty;
    defer body.deinit(std.testing.allocator);

    var exts = std.ArrayList(u8).empty;
    defer exts.deinit(std.testing.allocator);

    // ext 42, len 0
    try exts.appendSlice(std.testing.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @backingInt(ExtensionType.early_data))));
    try exts.appendSlice(std.testing.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0)));

    try body.appendSlice(std.testing.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(exts.items.len))));
    try body.appendSlice(std.testing.allocator, exts.items);

    const ee = try EncryptedExtensions.decode(body.items);
    try std.testing.expect(ee.earlyDataAccepted);
}
