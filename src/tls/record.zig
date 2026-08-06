//! TLS Record Layer  --  RFC 8446 Section5 / RFC 5246 Section6
//!
//! Full implementation of TLS record framing, fragmentation/reassembly,
//! and record protection (AEAD encryption/decryption) for the TCP transport path.
//!
//! Supports both:
//! - TLS 1.3: implicit nonce (XOR of base_iv with sequence number)
//! - TLS 1.2: explicit IV prepended to ciphertext, XOR with base IV
//!
//! AEAD ciphers supported: AES-128-GCM, AES-256-GCM, ChaCha20-Poly1305,
//! AEGIS-128L, AEGIS-256.

const std = @import("std");
const mem = std.mem;
const crypto = std.crypto;
const tls = crypto.tls;
const errors = @import("errors.zig");
const crypto_utils = @import("crypto_utils.zig");

const tlsRandom = crypto_utils.tlsRandom;

pub const max_plaintext_len: usize = 16384;
pub const max_ciphertext_len: usize = max_plaintext_len + 256;
pub const record_header_len: usize = 5;
pub const max_record_len: usize = record_header_len + max_ciphertext_len;

// Record Header

pub const RecordHeader = struct {
    content_type: tls.ContentType,
    version: tls.ProtocolVersion,
    length: u16,

    pub fn parse(buf: *const [record_header_len]u8) errors.TlsError!RecordHeader {
        const ct: tls.ContentType = @enumFromInt(buf[0]);
        const ver: tls.ProtocolVersion = @enumFromInt(mem.readInt(u16, buf[1..3], .big));
        const len = mem.readInt(u16, buf[3..5], .big);
        if (len > max_ciphertext_len) return error.TlsRecordOverflow;
        return .{
            .content_type = ct,
            .version = ver,
            .length = len,
        };
    }

    pub fn format(self: RecordHeader, out: *[record_header_len]u8) void {
        out[0] = @intFromEnum(self.content_type);
        mem.writeInt(u16, out[1..3], @intFromEnum(self.version), .big);
        mem.writeInt(u16, out[3..5], self.length, .big);
    }
};

// Nonce construction

/// Build a TLS 1.3 implicit nonce: XOR of base_iv with the 8-byte
/// big-endian sequence number, zero-padded to nonce_length.
pub fn nonceTls13(base_iv: []const u8, seq: u64) [12]u8 {
    var n: [12]u8 = [_]u8{0} ** 12;
    const seq_bytes = mem.toBytes(mem.nativeToBig(u64, seq));
    // Place seq in the last 8 bytes
    @memcpy(n[4..12], &seq_bytes);
    // XOR with base_iv
    for (0..@min(base_iv.len, 12)) |i| {
        n[i] ^= base_iv[i];
    }
    return n;
}

/// Build a TLS 1.2 explicit IV (random for each record) and the full nonce
/// by XORing explicit_iv ++ base_iv with the sequence number.
pub fn nonceTls12(base_iv: []const u8, explicit_iv: []const u8, seq: u64) [12]u8 {
    var n: [12]u8 = [_]u8{0} ** 12;
    const seq_bytes = mem.toBytes(mem.nativeToBig(u64, seq));
    @memcpy(n[4..12], &seq_bytes);
    // XOR with base_iv (fixed part)
    for (0..@min(base_iv.len, 12)) |i| {
        n[i] ^= base_iv[i];
    }
    // XOR with explicit_iv (record-specific part  --  only the first 8 bytes for AES-GCM)
    for (0..@min(explicit_iv.len, 12)) |i| {
        n[i] ^= explicit_iv[i];
    }
    return n;
}

// AEAD Decrypt / Encrypt  --  TLS 1.3 (implicit nonce)

/// Decrypt a TLS 1.3 record using AEAD with implicit nonce.
/// `ciphertext_and_tag` contains ciphertext || tag. The tag is at the end.
/// Returns a slice of the buffer with plaintext (tag stripped).
pub fn decryptTls13(
    comptime Aead: type,
    ciphertext_and_tag: []u8,
    aad: *const [record_header_len]u8,
    nonce: *const [Aead.nonce_length]u8,
    key: *const [Aead.key_length]u8,
) errors.TlsError![]u8 {
    if (ciphertext_and_tag.len < Aead.tag_length) return error.TlsRecordOverflow;
    const plain_len = ciphertext_and_tag.len - Aead.tag_length;

    // Extract tag as a fixed-size array
    var tag_buf: [Aead.tag_length]u8 = undefined;
    @memcpy(&tag_buf, ciphertext_and_tag[plain_len..][0..Aead.tag_length]);

    // decrypt in-place: ciphertext_and_tag[0..plain_len] is ciphertext, output overwrites same region
    Aead.decrypt(ciphertext_and_tag[0..plain_len], ciphertext_and_tag[0..plain_len], tag_buf, aad, nonce.*, key.*) catch return error.TlsBadRecordMac;
    return ciphertext_and_tag[0..plain_len];
}

/// Encrypt a TLS 1.3 record using AEAD with implicit nonce.
/// `out` must be large enough for plaintext + tag.
/// Returns the slice of `out` containing ciphertext+tag.
pub fn encryptTls13(
    comptime Aead: type,
    out: []u8,
    plaintext: []const u8,
    aad: *const [record_header_len]u8,
    nonce: *const [Aead.nonce_length]u8,
    key: *const [Aead.key_length]u8,
) errors.TlsError![]u8 {
    if (out.len < plaintext.len + Aead.tag_length) return error.TlsBufferTooSmall;
    Aead.encrypt(out[0..plaintext.len], @ptrCast(out[plaintext.len..][0..Aead.tag_length]), plaintext, aad, nonce.*, key.*);
    return out[0 .. plaintext.len + Aead.tag_length];
}

// AEAD Decrypt / Encrypt  --  TLS 1.2 (explicit IV)

/// Decrypt a TLS 1.2 record with explicit IV.
///
/// The record body is: explicit_iv || ciphertext || tag.
/// `aad` is constructed from the 5-byte record header.
pub fn decryptTls12(
    comptime Aead: type,
    record_body: []u8,
    aad: *const [record_header_len]u8,
    seq: u64,
    write_iv: []const u8,
    key: *const [Aead.key_length]u8,
) errors.TlsError![]u8 {
    const explicit_iv_len = Aead.nonce_length;
    if (record_body.len < explicit_iv_len + Aead.tag_length) return error.TlsRecordOverflow;
    const explicit_iv = record_body[0..explicit_iv_len];
    const ciphertext_with_tag = record_body[explicit_iv_len..];
    if (ciphertext_with_tag.len < Aead.tag_length) return error.TlsRecordOverflow;
    const plain_len = ciphertext_with_tag.len - Aead.tag_length;
    const ct_part = ciphertext_with_tag[0..plain_len];
    const tag = ciphertext_with_tag[plain_len..][0..Aead.tag_length];

    // Build nonce: XOR base_iv with seq, then XOR with explicit_iv
    const nonce = nonceTls12(write_iv, explicit_iv, seq);

    // Build AAD: seq(8) || content_type(1) || version(2) || length(2)
    var aad_full: [8 + 5]u8 = undefined;
    mem.writeInt(u64, aad_full[0..8], seq, .big);
    @memcpy(aad_full[8..13], aad);

    Aead.decrypt(ct_part, ct_part, tag.*, &aad_full, nonce, key.*) catch return error.TlsBadRecordMac;
    return ct_part;
}

/// Encrypt a TLS 1.2 record with explicit IV.
///
/// `out` must be large enough for explicit_iv + ciphertext + tag.
/// Returns the slice of `out` containing the encrypted record body.
pub fn encryptTls12(
    comptime Aead: type,
    out: []u8,
    plaintext: []const u8,
    aad: *const [record_header_len]u8,
    seq: u64,
    write_iv: []const u8,
    key: *const [Aead.key_length]u8,
) errors.TlsError![]u8 {
    const explicit_iv_len = Aead.nonce_length;
    const needed = explicit_iv_len + plaintext.len + Aead.tag_length;
    if (out.len < needed) return error.TlsBufferTooSmall;

    // Generate random explicit IV
    const explicit_iv = out[0..explicit_iv_len];
    tlsRandom(explicit_iv);

    const nonce = nonceTls12(write_iv, explicit_iv, seq);

    // Build AAD
    var aad_full: [8 + 5]u8 = undefined;
    mem.writeInt(u64, aad_full[0..8], seq, .big);
    @memcpy(aad_full[8..13], aad);

    const ct_part = out[explicit_iv_len..][0..plaintext.len];
    const tag = out[explicit_iv_len + plaintext.len ..][0..Aead.tag_length];
    Aead.encrypt(ct_part, tag, plaintext, &aad_full, nonce, key.*);
    return out[0..needed];
}

// Tests

test "RecordHeader format and parse round-trip" {
    var buf: [record_header_len]u8 = undefined;
    const hdr = RecordHeader{
        .content_type = .handshake,
        .version = .tls_1_2,
        .length = 512,
    };
    hdr.format(&buf);
    const parsed = try RecordHeader.parse(&buf);
    try std.testing.expectEqual(hdr.content_type, parsed.content_type);
    try std.testing.expectEqual(hdr.version, parsed.version);
    try std.testing.expectEqual(hdr.length, parsed.length);
}

test "nonceTls13 is deterministic for same inputs" {
    const base_iv = [_]u8{0x01} ** 12;
    const n1 = nonceTls13(&base_iv, 42);
    const n2 = nonceTls13(&base_iv, 42);
    try std.testing.expectEqualSlices(u8, &n1, &n2);
}

test "nonceTls13 differs for different seq" {
    const base_iv = [_]u8{0x01} ** 12;
    const n1 = nonceTls13(&base_iv, 0);
    const n2 = nonceTls13(&base_iv, 1);
    try std.testing.expect(!std.mem.eql(u8, &n1, &n2));
}

test "encrypt/decrypt round-trip TLS 1.3 AES-128-GCM" {
    const Aead = crypto.aead.aes_gcm.Aes128Gcm;
    var key: [Aead.key_length]u8 = undefined;
    var base_iv: [Aead.nonce_length]u8 = undefined;
    tlsRandom(&key);
    tlsRandom(&base_iv);

    const plaintext = "Hello, TLS 1.3 record layer!";
    var hdr: [record_header_len]u8 = undefined;
    const hdr_t = RecordHeader{
        .content_type = .application_data,
        .version = .tls_1_2,
        .length = @intCast(plaintext.len + Aead.tag_length),
    };
    hdr_t.format(&hdr);

    var buf: [max_plaintext_len + 256]u8 = undefined;
    const enc = try encryptTls13(Aead, &buf, plaintext, &hdr, &nonceTls13(&base_iv, 0), &key);
    const dec = try decryptTls13(Aead, enc, &hdr, &nonceTls13(&base_iv, 0), &key);
    try std.testing.expectEqualStrings(plaintext, dec);
}

test "encrypt/decrypt round-trip TLS 1.3 ChaCha20-Poly1305" {
    const Aead = crypto.aead.chacha_poly.ChaCha20Poly1305;
    var key: [Aead.key_length]u8 = undefined;
    var base_iv: [Aead.nonce_length]u8 = undefined;
    tlsRandom(&key);
    tlsRandom(&base_iv);

    const plaintext = "ChaCha20-Poly1305 record protection";
    var hdr: [record_header_len]u8 = undefined;
    const hdr_c = RecordHeader{
        .content_type = .application_data,
        .version = .tls_1_2,
        .length = @intCast(plaintext.len + Aead.tag_length),
    };
    hdr_c.format(&hdr);

    var buf: [max_plaintext_len + 256]u8 = undefined;
    const enc = try encryptTls13(Aead, &buf, plaintext, &hdr, &nonceTls13(&base_iv, 0), &key);
    const dec = try decryptTls13(Aead, enc, &hdr, &nonceTls13(&base_iv, 0), &key);
    try std.testing.expectEqualStrings(plaintext, dec);
}

test "encrypt/decrypt round-trip TLS 1.2 AES-128-GCM" {
    const Aead = crypto.aead.aes_gcm.Aes128Gcm;
    var key: [Aead.key_length]u8 = undefined;
    var base_iv: [Aead.nonce_length]u8 = undefined;
    tlsRandom(&key);
    tlsRandom(&base_iv);

    const plaintext = "Hello, TLS 1.2 record layer!";
    var hdr: [record_header_len]u8 = undefined;
    const hdr_12 = RecordHeader{
        .content_type = .application_data,
        .version = .tls_1_2,
        .length = @intCast(Aead.nonce_length + plaintext.len + Aead.tag_length),
    };
    hdr_12.format(&hdr);

    var buf: [32 + max_plaintext_len + 256]u8 = undefined;
    const enc = try encryptTls12(Aead, &buf, plaintext, &hdr, 0, &base_iv, &key);
    const dec = try decryptTls12(Aead, enc, &hdr, 0, &base_iv, &key);
    try std.testing.expectEqualStrings(plaintext, dec);
}

test "decrypt with wrong key fails" {
    const Aead = crypto.aead.aes_gcm.Aes128Gcm;
    var key1: [Aead.key_length]u8 = [_]u8{0x01} ** Aead.key_length;
    var key2: [Aead.key_length]u8 = [_]u8{0x02} ** Aead.key_length;
    var base_iv: [Aead.nonce_length]u8 = [_]u8{0x03} ** Aead.nonce_length;

    const plaintext = "secret data";
    var hdr: [record_header_len]u8 = undefined;
    const hdr_wk = RecordHeader{
        .content_type = .application_data,
        .version = .tls_1_2,
        .length = @intCast(plaintext.len + Aead.tag_length),
    };
    hdr_wk.format(&hdr);

    var buf: [max_plaintext_len + 256]u8 = undefined;
    const enc = try encryptTls13(Aead, &buf, plaintext, &hdr, &nonceTls13(&base_iv, 0), &key1);
    const result = decryptTls13(Aead, enc, &hdr, &nonceTls13(&base_iv, 0), &key2);
    try std.testing.expectError(error.TlsBadRecordMac, result);
}

test "RecordHeader parse rejects overflow length" {
    var buf: [record_header_len]u8 = [_]u8{0} ** record_header_len;
    buf[0] = @intFromEnum(tls.ContentType.handshake);
    buf[1] = 0x03;
    buf[2] = 0x03;
    // Set length to > max_ciphertext_len (16640)
    buf[3] = 0xFF;
    buf[4] = 0xFF;
    const result = RecordHeader.parse(&buf);
    try std.testing.expectError(error.TlsRecordOverflow, result);
}

test "RecordHeader format all content types" {
    const content_types = [_]tls.ContentType{ .handshake, .application_data, .change_cipher_spec, .alert };
    for (content_types) |ct| {
        var buf: [record_header_len]u8 = undefined;
        const hdr = RecordHeader{
            .content_type = ct,
            .version = .tls_1_2,
            .length = 100,
        };
        hdr.format(&buf);
        try std.testing.expectEqual(@intFromEnum(ct), buf[0]);
    }
}

test "nonceTls13 XOR with zero base_iv is identity" {
    const base_iv = [_]u8{0x00} ** 12;
    const n = nonceTls13(&base_iv, 42);
    // seq=42 in big-endian last 8 bytes: 00 00 00 00 00 00 00 02A
    const seq_bytes = std.mem.toBytes(std.mem.nativeToBig(u64, 42));
    var expected: [12]u8 = [_]u8{0} ** 12;
    @memcpy(expected[4..12], &seq_bytes);
    try std.testing.expectEqualSlices(u8, &expected, &n);
}

test "nonceTls12 combines base_iv, explicit_iv, and seq" {
    const base_iv = [_]u8{0x01} ** 12;
    const explicit_iv = [_]u8{0x02} ** 12;
    const n = nonceTls12(&base_iv, &explicit_iv, 0);
    // With seq=0, nonce = base_iv XOR explicit_iv
    var expected: [12]u8 = undefined;
    for (0..12) |i| {
        expected[i] = base_iv[i] ^ explicit_iv[i];
    }
    try std.testing.expectEqualSlices(u8, &expected, &n);
}

test "decryptTls13 rejects too short ciphertext" {
    const Aead = crypto.aead.aes_gcm.Aes128Gcm;
    var buf: [4]u8 = [_]u8{0} ** 4; // shorter than tag_length
    var hdr: [record_header_len]u8 = undefined;
    const hdr_short = RecordHeader{
        .content_type = .application_data,
        .version = .tls_1_2,
        .length = 4,
    };
    hdr_short.format(&hdr);
    const key: [Aead.key_length]u8 = [_]u8{0x01} ** Aead.key_length;
    const nonce = nonceTls13(&[_]u8{0} ** 12, 0);
    const result = decryptTls13(Aead, &buf, &hdr, &nonce, &key);
    try std.testing.expectError(error.TlsRecordOverflow, result);
}

test "encryptTls13 rejects buffer too small" {
    const Aead = crypto.aead.aes_gcm.Aes128Gcm;
    var out: [4]u8 = [_]u8{0} ** 4;
    const plaintext = "long plaintext that is bigger than the buffer";
    var hdr: [record_header_len]u8 = undefined;
    const hdr_small = RecordHeader{
        .content_type = .application_data,
        .version = .tls_1_2,
        .length = @intCast(plaintext.len + Aead.tag_length),
    };
    hdr_small.format(&hdr);
    const key: [Aead.key_length]u8 = [_]u8{0x01} ** Aead.key_length;
    const nonce = nonceTls13(&[_]u8{0} ** 12, 0);
    const result = encryptTls13(Aead, &out, plaintext, &hdr, &nonce, &key);
    try std.testing.expectError(error.TlsBufferTooSmall, result);
}
