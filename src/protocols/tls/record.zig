//! TLS 1.3 record layer (RFC 8446 §5).
//!
//! Handles framing (content type + version + length), AEAD protection
//! (AES-128-GCM, AES-256-GCM, ChaCha20-Poly1305), and the TLS 1.3
//! simplified record format where content type is appended inside the
//! encrypted payload.
//!
//! Thread-safety: thread-confined — one record layer per connection.

const std = @import("std");
const tls = std.crypto.tls;
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

pub const ContentType = tls.ContentType;

/// Cipher suite selector for the record layer.
pub const RecordCipher = enum {
    aes_128_gcm,
    aes_256_gcm,
    chacha20_poly1305,

    pub fn keyLen(self: RecordCipher) usize {
        return switch (self) {
            .aes_128_gcm => 16,
            .aes_256_gcm, .chacha20_poly1305 => 32,
        };
    }

    pub fn tagLen(self: RecordCipher) usize {
        _ = self;
        return 16; // All three have 16-byte tags
    }

    pub fn ivLen(self: RecordCipher) usize {
        _ = self;
        return 12; // All three use 96-bit IVs
    }
};

/// Maximum plaintext per record (RFC 8446 §5.1).
pub const max_record_plaintext = 1 << 14;
/// Overhead: AEAD tag (16) + content type (1).
pub const max_record_overhead = 17;
/// Maximum record on wire: 5-byte header + plaintext + overhead.
pub const max_record_wire = 5 + max_record_plaintext + max_record_overhead;

/// Result of encoding a record.
pub const EncodedRecord = struct {
    bytes: [max_record_wire]u8,
    len: usize,
};

/// Encode one TLS 1.3 record into a byte buffer.
/// Content type is appended inside the encrypted payload per TLS 1.3.
pub fn encodeRecord(
    content_type: ContentType,
    plaintext: []const u8,
    sequence_number: u64,
    key: []const u8,
    iv_base: []const u8,
    cipher: RecordCipher,
) !EncodedRecord {
    if (sequence_number == std.math.maxInt(u64)) return error.SequenceOverflow;
    if (plaintext.len > max_record_plaintext) return error.RecordTooLarge;
    if (key.len != cipher.keyLen()) return error.InvalidKeyLength;
    if (iv_base.len != cipher.ivLen()) return error.InvalidIvLength;

    // Build inner plaintext: content || ContentType(1 byte)
    var inner: [max_record_plaintext + 1]u8 = undefined;
    @memcpy(inner[0..plaintext.len], plaintext);
    inner[plaintext.len] = @intFromEnum(content_type);
    const total = plaintext.len + 1;

    // Construct nonce: iv_base XOR sequence_number (96-bit big-endian)
    var nonce: [12]u8 = undefined;
    @memcpy(&nonce, iv_base[0..12]);
    const sn = std.mem.nativeToBig(u64, sequence_number);
    const sn_bytes = std.mem.asBytes(&sn);
    nonce[4] ^= sn_bytes[0];
    nonce[5] ^= sn_bytes[1];
    nonce[6] ^= sn_bytes[2];
    nonce[7] ^= sn_bytes[3];
    nonce[8] ^= sn_bytes[4];
    nonce[9] ^= sn_bytes[5];
    nonce[10] ^= sn_bytes[6];
    nonce[11] ^= sn_bytes[7];

    // Associated data = record header (5 bytes)
    var header: [5]u8 = undefined;
    header[0] = @intFromEnum(ContentType.application_data); // Always opaque in TLS 1.3
    header[1] = 3; // legacy_major
    header[2] = 3; // legacy_minor
    const ct_len: u16 = @intCast(total + cipher.tagLen());
    header[3] = @intCast(ct_len >> 8);
    header[4] = @intCast(ct_len & 0xFF);

    // Encrypt with selected cipher
    var ciphertext: [max_record_plaintext + 1]u8 = undefined;
    var tag: [16]u8 = undefined;

    switch (cipher) {
        .aes_128_gcm => {
            var k16: [16]u8 = undefined;
            @memcpy(&k16, key[0..16]);
            Aes128Gcm.encrypt(ciphertext[0..total], &tag, inner[0..total], &header, nonce, k16);
        },
        .aes_256_gcm => {
            var k32: [32]u8 = undefined;
            @memcpy(&k32, key[0..32]);
            Aes256Gcm.encrypt(ciphertext[0..total], &tag, inner[0..total], &header, nonce, k32);
        },
        .chacha20_poly1305 => {
            var k32: [32]u8 = undefined;
            @memcpy(&k32, key[0..32]);
            ChaCha20Poly1305.encrypt(ciphertext[0..total], &tag, inner[0..total], &header, nonce, k32);
        },
    }

    // Assemble: header + ciphertext + tag
    var result: EncodedRecord = .{ .bytes = undefined, .len = 0 };
    @memcpy(result.bytes[0..5], &header);
    @memcpy(result.bytes[5..][0..total], ciphertext[0..total]);
    @memcpy(result.bytes[5 + total ..][0..16], &tag);
    result.len = 5 + total + cipher.tagLen();
    return result;
}

/// Decode one TLS 1.3 record from a byte buffer.
/// Returns the content type and decrypted plaintext (pointing into `out_buf`).
pub fn decodeRecord(
    wire: []const u8,
    out_buf: []u8,
    sequence_number: u64,
    key: []const u8,
    iv_base: []const u8,
    cipher: RecordCipher,
) !struct { content_type: ContentType, plaintext: []u8 } {
    if (sequence_number == std.math.maxInt(u64)) return error.SequenceOverflow;
    if (wire.len < 5 + cipher.tagLen()) return error.RecordTooShort;
    if (key.len != cipher.keyLen()) return error.InvalidKeyLength;
    if (iv_base.len != cipher.ivLen()) return error.InvalidIvLength;

    const header = wire[0..5];
    const record_len: usize = (@as(usize, header[3]) << 8) | header[4];
    // TLS 1.3 outer type is always application_data, but allow
    // change_cipher_spec (0x14) for middlebox compatibility (RFC 8446 §5.4).
    if (header[0] == @intFromEnum(ContentType.change_cipher_spec)) {
        if (record_len != 1 or wire.len < 6 or wire[5] != 0x01) return error.InvalidContentType;
        return .{ .content_type = .change_cipher_spec, .plaintext = out_buf[0..0] };
    }
    if (header[0] != @intFromEnum(ContentType.application_data)) return error.InvalidContentType;
    const legacy_major = header[1];
    const legacy_minor = header[2];
    if (legacy_major != 3 or legacy_minor != 3) return error.InvalidRecordVersion;
    if (record_len < cipher.tagLen()) return error.RecordTooShort;
    if (record_len > max_record_plaintext + 1 + cipher.tagLen()) return error.RecordTooLarge;
    if (wire.len < 5 + record_len) return error.RecordTooShort;

    const enc_len = record_len - cipher.tagLen();
    if (out_buf.len < enc_len) return error.BufferTooSmall;

    const ciphertext = wire[5..][0..enc_len];
    const tag = wire[5 + enc_len ..][0..16];

    // Construct nonce
    var nonce: [12]u8 = undefined;
    @memcpy(&nonce, iv_base[0..12]);
    const sn = std.mem.nativeToBig(u64, sequence_number);
    const sn_bytes = std.mem.asBytes(&sn);
    nonce[4] ^= sn_bytes[0];
    nonce[5] ^= sn_bytes[1];
    nonce[6] ^= sn_bytes[2];
    nonce[7] ^= sn_bytes[3];
    nonce[8] ^= sn_bytes[4];
    nonce[9] ^= sn_bytes[5];
    nonce[10] ^= sn_bytes[6];
    nonce[11] ^= sn_bytes[7];

    // Decrypt with selected cipher
    switch (cipher) {
        .aes_128_gcm => {
            var k16: [16]u8 = undefined;
            @memcpy(&k16, key[0..16]);
            Aes128Gcm.decrypt(out_buf[0..enc_len], ciphertext, tag.*, header, nonce, k16) catch
                return error.DecryptionFailed;
        },
        .aes_256_gcm => {
            var k32: [32]u8 = undefined;
            @memcpy(&k32, key[0..32]);
            Aes256Gcm.decrypt(out_buf[0..enc_len], ciphertext, tag.*, header, nonce, k32) catch
                return error.DecryptionFailed;
        },
        .chacha20_poly1305 => {
            var k32: [32]u8 = undefined;
            @memcpy(&k32, key[0..32]);
            ChaCha20Poly1305.decrypt(out_buf[0..enc_len], ciphertext, tag.*, header, nonce, k32) catch
                return error.DecryptionFailed;
        },
    }

    // Last byte(s) handling: strip trailing zeros (padding per RFC 8446 §5.4)
    if (enc_len == 0) return error.EmptyPlaintext;
    var end = enc_len;
    while (end > 0 and out_buf[end - 1] == 0) end -= 1;
    if (end == 0) return error.EmptyPlaintext;
    const inner_ct = out_buf[end - 1];
    const inner_ct_enum: ContentType = switch (inner_ct) {
        @intFromEnum(ContentType.change_cipher_spec) => .change_cipher_spec,
        @intFromEnum(ContentType.alert) => .alert,
        @intFromEnum(ContentType.handshake) => .handshake,
        @intFromEnum(ContentType.application_data) => .application_data,
        else => return error.InvalidContentType,
    };

    return .{
        .content_type = inner_ct_enum,
        .plaintext = out_buf[0 .. end - 1],
    };
}

// Tests

test "record roundtrip aes-128-gcm" {
    const test_key = [_]u8{0x42} ** 16;
    const test_iv = [_]u8{0x24} ** 12;

    const encoded = try encodeRecord(.handshake, "hello TLS 1.3 world", 0, &test_key, &test_iv, .aes_128_gcm);

    var read_buf: [max_record_plaintext]u8 = undefined;
    const result = try decodeRecord(encoded.bytes[0..encoded.len], &read_buf, 0, &test_key, &test_iv, .aes_128_gcm);
    try std.testing.expectEqual(ContentType.handshake, result.content_type);
    try std.testing.expectEqualStrings("hello TLS 1.3 world", result.plaintext);
}

test "record roundtrip aes-256-gcm" {
    const test_key = [_]u8{0x42} ** 32;
    const test_iv = [_]u8{0x24} ** 12;

    const encoded = try encodeRecord(.handshake, "AES-256-GCM record", 0, &test_key, &test_iv, .aes_256_gcm);

    var read_buf: [max_record_plaintext]u8 = undefined;
    const result = try decodeRecord(encoded.bytes[0..encoded.len], &read_buf, 0, &test_key, &test_iv, .aes_256_gcm);
    try std.testing.expectEqual(ContentType.handshake, result.content_type);
    try std.testing.expectEqualStrings("AES-256-GCM record", result.plaintext);
}

test "record roundtrip chacha20-poly1305" {
    const test_key = [_]u8{0x42} ** 32;
    const test_iv = [_]u8{0x24} ** 12;

    const encoded = try encodeRecord(.handshake, "ChaCha20 record", 0, &test_key, &test_iv, .chacha20_poly1305);

    var read_buf: [max_record_plaintext]u8 = undefined;
    const result = try decodeRecord(encoded.bytes[0..encoded.len], &read_buf, 0, &test_key, &test_iv, .chacha20_poly1305);
    try std.testing.expectEqual(ContentType.handshake, result.content_type);
    try std.testing.expectEqualStrings("ChaCha20 record", result.plaintext);
}

test "different sequence numbers produce different ciphertexts" {
    const key = [_]u8{0xAA} ** 16;
    const iv = [_]u8{0xBB} ** 12;
    const msg = "test";

    const r0 = try encodeRecord(.application_data, msg, 0, &key, &iv, .aes_128_gcm);
    const r1 = try encodeRecord(.application_data, msg, 1, &key, &iv, .aes_128_gcm);

    try std.testing.expectEqual(r0.len, r1.len);
    try std.testing.expect(!std.mem.eql(u8, r0.bytes[5..r0.len], r1.bytes[5..r1.len]));
}

test "decryption failure on wrong key" {
    const key = [_]u8{0x42} ** 16;
    const iv = [_]u8{0x24} ** 12;
    const wrong_key = [_]u8{0xFF} ** 16;

    const encoded = try encodeRecord(.handshake, "secret", 0, &key, &iv, .aes_128_gcm);

    var read_buf: [max_record_plaintext]u8 = undefined;
    const result = decodeRecord(encoded.bytes[0..encoded.len], &read_buf, 0, &wrong_key, &iv, .aes_128_gcm);
    try std.testing.expectError(error.DecryptionFailed, result);
}

test "empty plaintext rejected" {
    const key = [_]u8{0x42} ** 16;
    const iv = [_]u8{0x24} ** 12;
    const result = encodeRecord(.handshake, "", 0, &key, &iv, .aes_128_gcm);
    try std.testing.expectEqual(@as(usize, 5 + 1 + Aes128Gcm.tag_length), (try result).len);
}

test "encrypted records reject a non-application outer content type" {
    const key = [_]u8{0x42} ** 16;
    const iv = [_]u8{0x24} ** 12;
    const encoded = try encodeRecord(.handshake, "payload", 0, &key, &iv, .aes_128_gcm);
    var wire = encoded;
    wire.bytes[0] = @intFromEnum(ContentType.handshake);
    var out: [max_record_plaintext]u8 = undefined;
    try std.testing.expectError(error.InvalidContentType, decodeRecord(wire.bytes[0..wire.len], &out, 0, &key, &iv, .aes_128_gcm));
}
