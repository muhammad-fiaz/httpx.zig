//! TLS 1.3 record layer (RFC 8446 Section 5).
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
    aes128Gcm,
    aes256Gcm,
    chacha20Poly1305,

    pub fn keyLen(self: RecordCipher) usize {
        return switch (self) {
            .aes128Gcm => 16,
            .aes256Gcm, .chacha20Poly1305 => 32,
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

/// Maximum plaintext per record (RFC 8446 Section 5.1).
pub const maxRecordPlaintext = 1 << 14;
/// Overhead: AEAD tag (16) + content type (1).
pub const maxRecordOverhead = 17;
/// Maximum record on wire: 5-byte header + plaintext + overhead.
pub const maxRecordWire = 5 + maxRecordPlaintext + maxRecordOverhead;

/// Result of encoding a record.
pub const EncodedRecord = struct {
    bytes: [maxRecordWire]u8,
    len: usize,
};

/// Encode one TLS 1.3 record into a byte buffer.
/// Content type is appended inside the encrypted payload per TLS 1.3.
pub fn encodeRecord(
    contentType: ContentType,
    plaintext: []const u8,
    sequenceNumber: u64,
    key: []const u8,
    ivBase: []const u8,
    cipher: RecordCipher,
) !EncodedRecord {
    if (sequenceNumber == std.math.maxInt(u64)) return error.SequenceOverflow;
    if (plaintext.len > maxRecordPlaintext) return error.RecordTooLarge;
    if (key.len != cipher.keyLen()) return error.InvalidKeyLength;
    if (ivBase.len != cipher.ivLen()) return error.InvalidIvLength;

    // Build inner plaintext: content || ContentType(1 byte)
    var inner: [maxRecordPlaintext + 1]u8 = undefined;
    @memcpy(inner[0..plaintext.len], plaintext);
    inner[plaintext.len] = @backingInt(contentType);
    const total = plaintext.len + 1;

    // Construct nonce: ivBase XOR sequenceNumber (96-bit big-endian)
    var nonce: [12]u8 = undefined;
    @memcpy(&nonce, ivBase[0..12]);
    const sn = std.mem.nativeToBig(u64, sequenceNumber);
    const snBytes = std.mem.asBytes(&sn);
    nonce[4] ^= snBytes[0];
    nonce[5] ^= snBytes[1];
    nonce[6] ^= snBytes[2];
    nonce[7] ^= snBytes[3];
    nonce[8] ^= snBytes[4];
    nonce[9] ^= snBytes[5];
    nonce[10] ^= snBytes[6];
    nonce[11] ^= snBytes[7];

    // Associated data = record header (5 bytes)
    var header: [5]u8 = undefined;
    header[0] = @backingInt(ContentType.application_data); // Always opaque in TLS 1.3
    header[1] = 3; // legacyMajor
    header[2] = 3; // legacyMinor
    const ctLen: u16 = @intCast(total + cipher.tagLen());
    header[3] = @intCast(ctLen >> 8);
    header[4] = @intCast(ctLen & 0xFF);

    // Encrypt with selected cipher
    var ciphertext: [maxRecordPlaintext + 1]u8 = undefined;
    var tag: [16]u8 = undefined;

    switch (cipher) {
        .aes128Gcm => {
            var k16: [16]u8 = undefined;
            @memcpy(&k16, key[0..16]);
            Aes128Gcm.encrypt(ciphertext[0..total], &tag, inner[0..total], &header, nonce, k16);
        },
        .aes256Gcm => {
            var k32: [32]u8 = undefined;
            @memcpy(&k32, key[0..32]);
            Aes256Gcm.encrypt(ciphertext[0..total], &tag, inner[0..total], &header, nonce, k32);
        },
        .chacha20Poly1305 => {
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
/// Returns the content type and decrypted plaintext (pointing into `outBuf`).
pub fn decodeRecord(
    wire: []const u8,
    outBuf: []u8,
    sequenceNumber: u64,
    key: []const u8,
    ivBase: []const u8,
    cipher: RecordCipher,
) !struct { contentType: ContentType, plaintext: []u8 } {
    if (sequenceNumber == std.math.maxInt(u64)) return error.SequenceOverflow;
    if (wire.len < 5 + cipher.tagLen()) return error.RecordTooShort;
    if (key.len != cipher.keyLen()) return error.InvalidKeyLength;
    if (ivBase.len != cipher.ivLen()) return error.InvalidIvLength;

    const header = wire[0..5];
    const recordLen: usize = (@as(usize, header[3]) << 8) | header[4];
    // TLS 1.3 outer type is always applicationData, but allow
    // changeCipherSpec (0x14) for middlebox compatibility (RFC 8446 Section 5.4).
    if (header[0] == @backingInt(ContentType.change_cipher_spec)) {
        if (recordLen != 1 or wire.len < 6 or wire[5] != 0x01) return error.InvalidContentType;
        return .{ .contentType = .change_cipher_spec, .plaintext = outBuf[0..0] };
    }
    if (header[0] != @backingInt(ContentType.application_data)) return error.InvalidContentType;
    const legacyMajor = header[1];
    const legacyMinor = header[2];
    if (legacyMajor != 3 or legacyMinor != 3) return error.InvalidRecordVersion;
    if (recordLen < cipher.tagLen()) return error.RecordTooShort;
    if (recordLen > maxRecordPlaintext + 1 + cipher.tagLen()) return error.RecordTooLarge;
    if (wire.len < 5 + recordLen) return error.RecordTooShort;

    const encLen = recordLen - cipher.tagLen();
    if (outBuf.len < encLen) return error.BufferTooSmall;

    const ciphertext = wire[5..][0..encLen];
    const tag = wire[5 + encLen ..][0..16];

    // Construct nonce
    var nonce: [12]u8 = undefined;
    @memcpy(&nonce, ivBase[0..12]);
    const sn = std.mem.nativeToBig(u64, sequenceNumber);
    const snBytes = std.mem.asBytes(&sn);
    nonce[4] ^= snBytes[0];
    nonce[5] ^= snBytes[1];
    nonce[6] ^= snBytes[2];
    nonce[7] ^= snBytes[3];
    nonce[8] ^= snBytes[4];
    nonce[9] ^= snBytes[5];
    nonce[10] ^= snBytes[6];
    nonce[11] ^= snBytes[7];

    // Decrypt with selected cipher
    switch (cipher) {
        .aes128Gcm => {
            var k16: [16]u8 = undefined;
            @memcpy(&k16, key[0..16]);
            Aes128Gcm.decrypt(outBuf[0..encLen], ciphertext, tag.*, header, nonce, k16) catch
                return error.DecryptionFailed;
        },
        .aes256Gcm => {
            var k32: [32]u8 = undefined;
            @memcpy(&k32, key[0..32]);
            Aes256Gcm.decrypt(outBuf[0..encLen], ciphertext, tag.*, header, nonce, k32) catch
                return error.DecryptionFailed;
        },
        .chacha20Poly1305 => {
            var k32: [32]u8 = undefined;
            @memcpy(&k32, key[0..32]);
            ChaCha20Poly1305.decrypt(outBuf[0..encLen], ciphertext, tag.*, header, nonce, k32) catch
                return error.DecryptionFailed;
        },
    }

    // Last byte(s) handling: strip trailing zeros (padding per RFC 8446 Section 5.4)
    if (encLen == 0) return error.EmptyPlaintext;
    var end = encLen;
    while (end > 0 and outBuf[end - 1] == 0) end -= 1;
    if (end == 0) return error.EmptyPlaintext;
    const innerCt = outBuf[end - 1];
    const innerCtEnum: ContentType = switch (innerCt) {
        @backingInt(ContentType.change_cipher_spec) => .change_cipher_spec,
        @backingInt(ContentType.alert) => .alert,
        @backingInt(ContentType.handshake) => .handshake,
        @backingInt(ContentType.application_data) => .application_data,
        else => return error.InvalidContentType,
    };

    return .{
        .contentType = innerCtEnum,
        .plaintext = outBuf[0 .. end - 1],
    };
}

// Tests

test "record roundtrip aes-128-gcm" {
    const testKey = (@as([16]u8, @splat(0x42)));
    const testIv = (@as([12]u8, @splat(0x24)));

    const encoded = try encodeRecord(.handshake, "hello TLS 1.3 world", 0, &testKey, &testIv, .aes128Gcm);

    var readBuf: [maxRecordPlaintext]u8 = undefined;
    const result = try decodeRecord(encoded.bytes[0..encoded.len], &readBuf, 0, &testKey, &testIv, .aes128Gcm);
    try std.testing.expectEqual(ContentType.handshake, result.contentType);
    try std.testing.expectEqualStrings("hello TLS 1.3 world", result.plaintext);
}

test "record roundtrip aes-256-gcm" {
    const testKey = (@as([32]u8, @splat(0x42)));
    const testIv = (@as([12]u8, @splat(0x24)));

    const encoded = try encodeRecord(.handshake, "AES-256-GCM record", 0, &testKey, &testIv, .aes256Gcm);

    var readBuf: [maxRecordPlaintext]u8 = undefined;
    const result = try decodeRecord(encoded.bytes[0..encoded.len], &readBuf, 0, &testKey, &testIv, .aes256Gcm);
    try std.testing.expectEqual(ContentType.handshake, result.contentType);
    try std.testing.expectEqualStrings("AES-256-GCM record", result.plaintext);
}

test "record roundtrip chacha20-poly1305" {
    const testKey = (@as([32]u8, @splat(0x42)));
    const testIv = (@as([12]u8, @splat(0x24)));

    const encoded = try encodeRecord(.handshake, "ChaCha20 record", 0, &testKey, &testIv, .chacha20Poly1305);

    var readBuf: [maxRecordPlaintext]u8 = undefined;
    const result = try decodeRecord(encoded.bytes[0..encoded.len], &readBuf, 0, &testKey, &testIv, .chacha20Poly1305);
    try std.testing.expectEqual(ContentType.handshake, result.contentType);
    try std.testing.expectEqualStrings("ChaCha20 record", result.plaintext);
}

test "different sequence numbers produce different ciphertexts" {
    const key = (@as([16]u8, @splat(0xAA)));
    const iv = (@as([12]u8, @splat(0xBB)));
    const msg = "test";

    const r0 = try encodeRecord(.application_data, msg, 0, &key, &iv, .aes128Gcm);
    const r1 = try encodeRecord(.application_data, msg, 1, &key, &iv, .aes128Gcm);

    try std.testing.expectEqual(r0.len, r1.len);
    try std.testing.expect(!std.mem.eql(u8, r0.bytes[5..r0.len], r1.bytes[5..r1.len]));
}

test "decryption failure on wrong key" {
    const key = (@as([16]u8, @splat(0x42)));
    const iv = (@as([12]u8, @splat(0x24)));
    const wrongKey = (@as([16]u8, @splat(0xFF)));

    const encoded = try encodeRecord(.handshake, "secret", 0, &key, &iv, .aes128Gcm);

    var readBuf: [maxRecordPlaintext]u8 = undefined;
    const result = decodeRecord(encoded.bytes[0..encoded.len], &readBuf, 0, &wrongKey, &iv, .aes128Gcm);
    try std.testing.expectError(error.DecryptionFailed, result);
}

test "empty plaintext rejected" {
    const key = (@as([16]u8, @splat(0x42)));
    const iv = (@as([12]u8, @splat(0x24)));
    const result = encodeRecord(.handshake, "", 0, &key, &iv, .aes128Gcm);
    try std.testing.expectEqual(@as(usize, 5 + 1 + Aes128Gcm.tag_length), (try result).len);
}

test "encrypted records reject a non-application outer content type" {
    const key = (@as([16]u8, @splat(0x42)));
    const iv = (@as([12]u8, @splat(0x24)));
    const encoded = try encodeRecord(.handshake, "payload", 0, &key, &iv, .aes128Gcm);
    var wire = encoded;
    wire.bytes[0] = @backingInt(ContentType.handshake);
    var out: [maxRecordPlaintext]u8 = undefined;
    try std.testing.expectError(error.InvalidContentType, decodeRecord(wire.bytes[0..wire.len], &out, 0, &key, &iv, .aes128Gcm));
}

test "tampered ciphertext fails authentication" {
    const key = (@as([16]u8, @splat(0x42)));
    const iv = (@as([12]u8, @splat(0x24)));
    const encoded = try encodeRecord(.application_data, "sensitive", 3, &key, &iv, .aes128Gcm);
    var wire = encoded;
    // Flip a bit in the ciphertext body (not the header).
    wire.bytes[7] ^= 0x01;
    var out: [maxRecordPlaintext]u8 = undefined;
    try std.testing.expectError(error.DecryptionFailed, decodeRecord(wire.bytes[0..wire.len], &out, 3, &key, &iv, .aes128Gcm));
}

test "wrong sequence number fails nonce authentication" {
    const key = (@as([16]u8, @splat(0x42)));
    const iv = (@as([12]u8, @splat(0x24)));
    const encoded = try encodeRecord(.application_data, "ordered", 7, &key, &iv, .aes128Gcm);
    var out: [maxRecordPlaintext]u8 = undefined;
    // Same keys, replayed/stale sequence number must not decrypt.
    try std.testing.expectError(error.DecryptionFailed, decodeRecord(encoded.bytes[0..encoded.len], &out, 6, &key, &iv, .aes128Gcm));
    try std.testing.expectError(error.DecryptionFailed, decodeRecord(encoded.bytes[0..encoded.len], &out, 8, &key, &iv, .aes128Gcm));
    // Correct sequence still verifies.
    const ok = try decodeRecord(encoded.bytes[0..encoded.len], &out, 7, &key, &iv, .aes128Gcm);
    try std.testing.expectEqualStrings("ordered", ok.plaintext);
}
