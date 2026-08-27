//! TLS 1.3 record layer (RFC 8446 §5).
//!
//! Handles framing (content type + version + length), AEAD protection
//! (AES-128-GCM), and the TLS 1.3 simplified record format where content
//! type is appended inside the encrypted payload.
//!
//! Thread-safety: thread-confined — one record layer per connection.

const std = @import("std");
const tls = std.crypto.tls;
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;

pub const ContentType = tls.ContentType;

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
    key: [16]u8,
    iv_base: [12]u8,
) !EncodedRecord {
    if (plaintext.len > max_record_plaintext) return error.RecordTooLarge;

    // Build inner plaintext: content || ContentType(1 byte)
    var inner: [max_record_plaintext + 1]u8 = undefined;
    @memcpy(inner[0..plaintext.len], plaintext);
    inner[plaintext.len] = @intFromEnum(content_type);
    const total = plaintext.len + 1;

    // Construct nonce: iv_base XOR sequence_number (96-bit big-endian)
    var nonce: [12]u8 = undefined;
    @memcpy(&nonce, &iv_base);
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
    const ct_len: u16 = @intCast(total + Aes128Gcm.tag_length);
    header[3] = @intCast(ct_len >> 8);
    header[4] = @intCast(ct_len & 0xFF);

    // Encrypt
    var ciphertext: [max_record_plaintext + 1]u8 = undefined;
    var tag: [Aes128Gcm.tag_length]u8 = undefined;
    Aes128Gcm.encrypt(
        ciphertext[0..total],
        &tag,
        inner[0..total],
        &header,
        nonce,
        key,
    );

    // Assemble: header + ciphertext + tag
    var result: EncodedRecord = .{ .bytes = undefined, .len = 0 };
    @memcpy(result.bytes[0..5], &header);
    @memcpy(result.bytes[5..][0..total], ciphertext[0..total]);
    @memcpy(result.bytes[5 + total ..][0..Aes128Gcm.tag_length], &tag);
    result.len = 5 + total + Aes128Gcm.tag_length;
    return result;
}

/// Decode one TLS 1.3 record from a byte buffer.
/// Returns the content type and decrypted plaintext (pointing into `out_buf`).
pub fn decodeRecord(
    wire: []const u8,
    out_buf: []u8,
    sequence_number: u64,
    key: [16]u8,
    iv_base: [12]u8,
) !struct { content_type: ContentType, plaintext: []u8 } {
    if (wire.len < 5 + Aes128Gcm.tag_length) return error.RecordTooShort;

    const header = wire[0..5];
    // TLS 1.3 protected records use application_data as the outer content
    // type; the real type is authenticated inside the encrypted payload.
    // Accepting another outer type would permit record-layer state confusion.
    if (header[0] != @intFromEnum(ContentType.application_data)) return error.InvalidContentType;
    const legacy_major = header[1];
    const legacy_minor = header[2];
    if (legacy_major != 3 or legacy_minor != 3) return error.InvalidRecordVersion;

    const record_len: usize = (@as(usize, header[3]) << 8) | header[4];
    if (record_len < Aes128Gcm.tag_length) return error.RecordTooShort;
    if (record_len > max_record_plaintext + 1 + Aes128Gcm.tag_length) return error.RecordTooLarge;
    if (wire.len < 5 + record_len) return error.RecordTooShort;

    const enc_len = record_len - Aes128Gcm.tag_length;
    if (out_buf.len < enc_len) return error.BufferTooSmall;

    const ciphertext = wire[5..][0..enc_len];
    const tag = wire[5 + enc_len ..][0..Aes128Gcm.tag_length];

    // Construct nonce
    var nonce: [12]u8 = undefined;
    @memcpy(&nonce, &iv_base);
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

    // Decrypt into out_buf
    Aes128Gcm.decrypt(
        out_buf[0..enc_len],
        ciphertext,
        tag.*,
        header,
        nonce,
        key,
    ) catch return error.DecryptionFailed;

    // Last byte of plaintext is the content type
    if (enc_len == 0) return error.EmptyPlaintext;
    const inner_ct = out_buf[enc_len - 1];
    const inner_ct_enum: ContentType = switch (inner_ct) {
        @intFromEnum(ContentType.change_cipher_spec) => .change_cipher_spec,
        @intFromEnum(ContentType.alert) => .alert,
        @intFromEnum(ContentType.handshake) => .handshake,
        @intFromEnum(ContentType.application_data) => .application_data,
        else => return error.InvalidContentType,
    };

    return .{
        .content_type = inner_ct_enum,
        .plaintext = out_buf[0 .. enc_len - 1],
    };
}

// Tests

test "record roundtrip aes-128-gcm" {
    const test_key = [_]u8{0x42} ** 16;
    const test_iv = [_]u8{0x24} ** 12;

    const encoded = try encodeRecord(.handshake, "hello TLS 1.3 world", 0, test_key, test_iv);

    var read_buf: [max_record_plaintext]u8 = undefined;
    const result = try decodeRecord(encoded.bytes[0..encoded.len], &read_buf, 0, test_key, test_iv);
    try std.testing.expectEqual(ContentType.handshake, result.content_type);
    try std.testing.expectEqualStrings("hello TLS 1.3 world", result.plaintext);
}

test "different sequence numbers produce different ciphertexts" {
    const key = [_]u8{0xAA} ** 16;
    const iv = [_]u8{0xBB} ** 12;
    const msg = "test";

    const r0 = try encodeRecord(.application_data, msg, 0, key, iv);
    const r1 = try encodeRecord(.application_data, msg, 1, key, iv);

    try std.testing.expectEqual(r0.len, r1.len);
    // Record payload starts at offset 5 (after header)
    try std.testing.expect(!std.mem.eql(u8, r0.bytes[5..r0.len], r1.bytes[5..r1.len]));
}

test "decryption failure on wrong key" {
    const key = [_]u8{0x42} ** 16;
    const iv = [_]u8{0x24} ** 12;
    const wrong_key = [_]u8{0xFF} ** 16;

    const encoded = try encodeRecord(.handshake, "secret", 0, key, iv);

    var read_buf: [max_record_plaintext]u8 = undefined;
    const result = decodeRecord(encoded.bytes[0..encoded.len], &read_buf, 0, wrong_key, iv);
    try std.testing.expectError(error.DecryptionFailed, result);
}

test "empty plaintext rejected" {
    const key = [_]u8{0x42} ** 16;
    const iv = [_]u8{0x24} ** 12;
    const result = encodeRecord(.handshake, "", 0, key, iv);
    // Empty is allowed at record level (inner = just content type byte)
    try std.testing.expectEqual(@as(usize, 5 + 1 + Aes128Gcm.tag_length), (try result).len);
}

test "encrypted records reject a non-application outer content type" {
    const key = [_]u8{0x42} ** 16;
    const iv = [_]u8{0x24} ** 12;
    const encoded = try encodeRecord(.handshake, "payload", 0, key, iv);
    var wire = encoded;
    wire.bytes[0] = @intFromEnum(ContentType.handshake);
    var out: [max_record_plaintext]u8 = undefined;
    try std.testing.expectError(error.InvalidContentType, decodeRecord(wire.bytes[0..wire.len], &out, 0, key, iv));
}
