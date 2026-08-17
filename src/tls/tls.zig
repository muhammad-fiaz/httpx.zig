const builtin = @import("builtin");
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const crypto = std.crypto;
const tls = std.crypto.tls;

const Socket = @import("../net/socket.zig").Socket;
const SocketIoReader = @import("../net/socket.zig").SocketIoReader;
const SocketIoWriter = @import("../net/socket.zig").SocketIoWriter;
const alpn = @import("alpn.zig");
const errors = @import("errors.zig");
const TlsClient = @import("client.zig");
const any_io = @import("../util/any_io.zig");
const dbg = @import("../util/debug.zig");

pub const server = @import("server.zig");
pub const acceptServer = server.acceptServer;

pub const record_header_len = 5;
const max_plaintext_len = 1 << 14;
const max_ciphertext_len = max_plaintext_len + 256;
const max_record_len = record_header_len + max_ciphertext_len;

const ContentType = tls.ContentType;

const RecordHeader = struct {
    content_type: ContentType,
    version: tls.ProtocolVersion,
    length: u16,

    fn format(self: RecordHeader, buf: *[record_header_len]u8) void {
        buf[0] = @intFromEnum(self.content_type);
        buf[1] = 0x03;
        buf[2] = 0x03;
        mem.writeInt(u16, buf[3..5], self.length, .big);
    }

    fn parse(buf: *[record_header_len]u8) RecordHeader {
        return .{
            .content_type = @enumFromInt(buf[0]),
            .version = .tls_1_2,
            .length = mem.readInt(u16, buf[3..5], .big),
        };
    }
};

pub fn nonceTls13(iv: *const [12]u8, seq: u64) [12]u8 {
    dbg.log("TLS", "nonceTls13: seq={d}", .{seq});
    var nonce: [12]u8 = iv.*;
    var seq_bytes: [8]u8 = undefined;
    mem.writeInt(u64, &seq_bytes, seq, .big);
    for (0..8) |i| {
        nonce[4 + i] = nonce[4 + i] ^ seq_bytes[i];
    }
    return nonce;
}

pub fn encryptTls13(
    comptime Aead: type,
    out: []u8,
    plaintext: []const u8,
    record_header: *const [record_header_len]u8,
    nonce: *const [12]u8,
    key: *const [Aead.key_length]u8,
) ![]u8 {
    var tag: [Aead.tag_length]u8 = undefined;
    Aead.encrypt(out[0..plaintext.len], &tag, plaintext, &record_header.*, nonce.*, key.*);
    @memcpy(out[plaintext.len..][0..Aead.tag_length], &tag);
    return out[0 .. plaintext.len + Aead.tag_length];
}

pub fn decryptTls13(
    comptime Aead: type,
    ciphertext: []u8,
    record_header: *const [record_header_len]u8,
    nonce: *const [12]u8,
    key: *const [Aead.key_length]u8,
) ![]u8 {
    if (ciphertext.len < Aead.tag_length) return error.TlsDecryptError;
    const tag: [Aead.tag_length]u8 = ciphertext[ciphertext.len - Aead.tag_length ..][0..Aead.tag_length].*;
    const ct_len = ciphertext.len - Aead.tag_length;
    Aead.decrypt(ciphertext[0..ct_len], ciphertext[0..ct_len], tag, &record_header.*, nonce.*, key.*) catch return error.TlsDecryptError;
    return ciphertext[0..ct_len];
}

pub fn encryptTls12(
    comptime Aead: type,
    out: []u8,
    plaintext: []const u8,
    hdr: *const [record_header_len]u8,
    seq: u64,
    iv: *const [12]u8,
    key: *const [Aead.key_length]u8,
) ![]u8 {
    var explicit_iv: [12]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&explicit_iv);
    var nonce: [12]u8 = iv.*;
    var seq_bytes: [8]u8 = undefined;
    mem.writeInt(u64, &seq_bytes, seq, .big);
    for (0..8) |i| {
        nonce[4 + i] = nonce[4 + i] ^ seq_bytes[i];
    }
    for (0..12) |i| {
        nonce[i] = nonce[i] ^ explicit_iv[i];
    }
    @memcpy(out[0..12], &explicit_iv);
    var tag: [Aead.tag_length]u8 = undefined;
    Aead.encrypt(out[12..][0..plaintext.len], &tag, plaintext, hdr, nonce, key.*);
    @memcpy(out[12 + plaintext.len ..][0..Aead.tag_length], &tag);
    return out[0 .. 12 + plaintext.len + Aead.tag_length];
}

pub fn decryptTls12(
    comptime Aead: type,
    ciphertext: []u8,
    hdr: *const [record_header_len]u8,
    seq: u64,
    iv: *const [12]u8,
    key: *const [Aead.key_length]u8,
) ![]u8 {
    if (ciphertext.len < 12 + Aead.tag_length) return error.TlsDecryptError;
    const explicit_iv: [12]u8 = ciphertext[0..12].*;
    var nonce: [12]u8 = iv.*;
    var seq_bytes: [8]u8 = undefined;
    mem.writeInt(u64, &seq_bytes, seq, .big);
    for (0..8) |i| {
        nonce[4 + i] = nonce[4 + i] ^ seq_bytes[i];
    }
    for (0..12) |i| {
        nonce[i] = nonce[i] ^ explicit_iv[i];
    }
    const tag: [Aead.tag_length]u8 = ciphertext[ciphertext.len - Aead.tag_length ..][0..Aead.tag_length].*;
    const ct_len = ciphertext.len - 12 - Aead.tag_length;
    Aead.decrypt(ciphertext[12..][0..ct_len], ciphertext[12..][0..ct_len], tag, hdr, nonce, key.*) catch return error.TlsDecryptError;
    return ciphertext[12..][0..ct_len];
}

pub fn hmacSha256Expand(secret: *const [32]u8, label: []const u8, seed: []const u8, out: []u8) void {
    const Hmac = crypto.auth.hmac.sha2.HmacSha256;
    const ls_len = label.len + seed.len;
    var ls: [128]u8 = undefined;
    @memcpy(ls[0..label.len], label);
    @memcpy(ls[label.len..][0..seed.len], seed);
    var a: [32]u8 = undefined;
    var result: [32]u8 = undefined;
    Hmac.create(&a, ls[0..ls_len], secret);
    var offset: usize = 0;
    while (offset + 32 <= out.len) : (offset += 32) {
        var a_ls: [32 + 128]u8 = undefined;
        @memcpy(a_ls[0..32], &a);
        @memcpy(a_ls[32..][0..ls_len], ls[0..ls_len]);
        Hmac.create(&result, a_ls[0 .. 32 + ls_len], secret);
        @memcpy(out[offset..][0..32], &result);
        Hmac.create(&a, a_ls[0 .. 32 + ls_len], secret);
    }
    if (offset < out.len) {
        var a_ls: [32 + 128]u8 = undefined;
        @memcpy(a_ls[0..32], &a);
        @memcpy(a_ls[32..][0..ls_len], ls[0..ls_len]);
        Hmac.create(&result, a_ls[0 .. 32 + ls_len], secret);
        @memcpy(out[offset..], result[0 .. out.len - offset]);
    }
}

pub fn hmacSha384Expand(secret: *const [48]u8, label: []const u8, seed: []const u8, out: []u8) void {
    const Hmac = crypto.auth.hmac.sha2.HmacSha384;
    const ls_len = label.len + seed.len;
    var ls: [128]u8 = undefined;
    @memcpy(ls[0..label.len], label);
    @memcpy(ls[label.len..][0..seed.len], seed);
    var a: [48]u8 = undefined;
    var result: [48]u8 = undefined;
    Hmac.create(&a, ls[0..ls_len], secret);
    var offset: usize = 0;
    while (offset + 48 <= out.len) : (offset += 48) {
        var a_ls: [48 + 128]u8 = undefined;
        @memcpy(a_ls[0..48], &a);
        @memcpy(a_ls[48..][0..ls_len], ls[0..ls_len]);
        Hmac.create(&result, a_ls[0 .. 48 + ls_len], secret);
        @memcpy(out[offset..][0..48], &result);
        Hmac.create(&a, a_ls[0 .. 48 + ls_len], secret);
    }
    if (offset < out.len) {
        var a_ls: [48 + 128]u8 = undefined;
        @memcpy(a_ls[0..48], &a);
        @memcpy(a_ls[48..][0..ls_len], ls[0..ls_len]);
        Hmac.create(&result, a_ls[0 .. 48 + ls_len], secret);
        @memcpy(out[offset..], result[0 .. out.len - offset]);
    }
}

pub fn deriveMasterSecret256(
    pre_master_secret: *const [32]u8,
    client_random: *const [32]u8,
    server_random: *const [32]u8,
) [32]u8 {
    const seed_len = 32 + 32;
    var seed: [64]u8 = undefined;
    @memcpy(seed[0..32], client_random);
    @memcpy(seed[32..64], server_random);
    const Hmac = crypto.auth.hmac.sha2.HmacSha256;

    var ms_label: [13 + 64]u8 = undefined;
    @memcpy(ms_label[0..13], "master secret");
    @memcpy(ms_label[13..][0..seed_len], &seed);

    var a1: [32]u8 = undefined;
    Hmac.create(&a1, ms_label[0 .. 13 + seed_len], pre_master_secret);

    var a1_ms_seed: [32 + 13 + 64]u8 = undefined;
    @memcpy(a1_ms_seed[0..32], &a1);
    @memcpy(a1_ms_seed[32..][0..13], "master secret");
    @memcpy(a1_ms_seed[45..][0..seed_len], &seed);
    var a2: [32]u8 = undefined;
    Hmac.create(&a2, a1_ms_seed[0 .. 32 + 13 + seed_len], pre_master_secret);

    var a2_ms_seed: [32 + 13 + 64]u8 = undefined;
    @memcpy(a2_ms_seed[0..32], &a2);
    @memcpy(a2_ms_seed[32..][0..13], "master secret");
    @memcpy(a2_ms_seed[45..][0..seed_len], &seed);
    var master_secret: [32]u8 = undefined;
    Hmac.create(&master_secret, a2_ms_seed[0 .. 32 + 13 + seed_len], pre_master_secret);
    return master_secret;
}

pub fn deriveMasterSecret384(
    pre_master_secret: *const [48]u8,
    client_random: *const [32]u8,
    server_random: *const [32]u8,
) [48]u8 {
    const seed_len = 32 + 32;
    var seed: [64]u8 = undefined;
    @memcpy(seed[0..32], client_random);
    @memcpy(seed[32..64], server_random);
    const Hmac = crypto.auth.hmac.sha2.HmacSha384;

    var ms_label: [13 + 64]u8 = undefined;
    @memcpy(ms_label[0..13], "master secret");
    @memcpy(ms_label[13..][0..seed_len], &seed);

    var a1: [48]u8 = undefined;
    Hmac.create(&a1, ms_label[0 .. 13 + seed_len], pre_master_secret);

    var a1_ms_seed: [48 + 13 + 64]u8 = undefined;
    @memcpy(a1_ms_seed[0..48], &a1);
    @memcpy(a1_ms_seed[48..][0..13], "master secret");
    @memcpy(a1_ms_seed[61..][0..seed_len], &seed);
    var a2: [48]u8 = undefined;
    Hmac.create(&a2, a1_ms_seed[0 .. 48 + 13 + seed_len], pre_master_secret);

    var a2_ms_seed: [48 + 13 + 64]u8 = undefined;
    @memcpy(a2_ms_seed[0..48], &a2);
    @memcpy(a2_ms_seed[48..][0..13], "master secret");
    @memcpy(a2_ms_seed[61..][0..seed_len], &seed);
    var master_secret: [48]u8 = undefined;
    Hmac.create(&master_secret, a2_ms_seed[0 .. 48 + 13 + seed_len], pre_master_secret);
    return master_secret;
}

pub fn deriveKeyBlock256(
    master_secret: *const [32]u8,
    server_random: *const [32]u8,
    client_random: *const [32]u8,
    comptime length: usize,
) [length]u8 {
    const seed = server_random.* ++ client_random.*;
    var key_block: [length]u8 = undefined;
    hmacSha256Expand(master_secret, "key expansion", &seed, &key_block);
    return key_block;
}

pub fn deriveKeyBlock384(
    master_secret: *const [48]u8,
    server_random: *const [32]u8,
    client_random: *const [32]u8,
    comptime length: usize,
) [length]u8 {
    const seed = server_random.* ++ client_random.*;
    var key_block: [length]u8 = undefined;
    hmacSha384Expand(master_secret, "key expansion", &seed, &key_block);
    return key_block;
}

pub fn hkdfExtract(ikm: []const u8, salt: []const u8, comptime hash_len: usize) [hash_len]u8 {
    if (hash_len == 32) {
        const Hmac = crypto.auth.hmac.sha2.HmacSha256;
        var prk: [hash_len]u8 = undefined;
        Hmac.create(&prk, ikm, salt);
        return prk;
    } else {
        const Hmac = crypto.auth.hmac.sha2.HmacSha384;
        var prk: [hash_len]u8 = undefined;
        Hmac.create(&prk, ikm, salt);
        return prk;
    }
}

pub fn hkdfExpandLabel(
    prk: []const u8,
    comptime label: []const u8,
    context: []const u8,
    comptime out_len: usize,
) [out_len]u8 {
    const max_label_len = 255;
    const max_context_len = 255;
    const tls13 = "tls13 ";
    var buf: [2 + 1 + tls13.len + max_label_len + 1 + max_context_len]u8 = undefined;
    // RFC 8446 Section 7.1: HkdfLabel = uint16 length || opaque label<7..255-1> || opaque context<0..255-1>
    // The u16 length field is the desired OUTPUT length, NOT the size of the info buffer.
    mem.writeInt(u16, buf[0..2], out_len, .big);
    buf[2] = @as(u8, @intCast(tls13.len + label.len));
    buf[3..][0..tls13.len].* = tls13.*;
    var i: usize = 3 + tls13.len;
    @memcpy(buf[i..][0..label.len], label);
    i += label.len;
    buf[i] = @as(u8, @intCast(context.len));
    i += 1;
    @memcpy(buf[i..][0..context.len], context);
    i += context.len;
    const info = buf[0..i];

    // HKDF-Expand: T(1) = HMAC(PRK, info || 0x01), T(2) = HMAC(PRK, T(1) || info || 0x02), ...
    if (out_len <= 32) {
        const Hmac = crypto.auth.hmac.sha2.HmacSha256;
        const mac_len = Hmac.mac_length;
        var result: [out_len]u8 = undefined;
        // T(1) = HMAC(PRK, info || 0x01)
        var a: [mac_len]u8 = undefined;
        var st = Hmac.init(prk);
        st.update(info);
        st.update(&[_]u8{0x01});
        st.final(&a);
        if (out_len <= mac_len) {
            @memcpy(&result, a[0..out_len]);
            return result;
        }
        // T(2) = HMAC(PRK, T(1) || info || 0x02) -- needed when out_len > mac_len
        var t: [mac_len]u8 = undefined;
        st = Hmac.init(prk);
        st.update(&a);
        st.update(info);
        st.update(&[_]u8{0x02});
        st.final(&t);
        @memcpy(&result, a[0..mac_len]);
        if (out_len > mac_len) {
            const remaining = out_len - mac_len;
            @memcpy(result[mac_len..][0..remaining], t[0..remaining]);
        }
        return result;
    } else {
        const Hmac = crypto.auth.hmac.sha2.HmacSha384;
        const mac_len = Hmac.mac_length;
        var result: [out_len]u8 = undefined;
        // T(1) = HMAC(PRK, info || 0x01)
        var a: [mac_len]u8 = undefined;
        var st = Hmac.init(prk);
        st.update(info);
        st.update(&[_]u8{0x01});
        st.final(&a);
        if (out_len <= mac_len) {
            @memcpy(&result, a[0..out_len]);
            return result;
        }
        // T(2) = HMAC(PRK, T(1) || info || 0x02)
        var t: [mac_len]u8 = undefined;
        st = Hmac.init(prk);
        st.update(&a);
        st.update(info);
        st.update(&[_]u8{0x02});
        st.final(&t);
        @memcpy(&result, a[0..mac_len]);
        if (out_len > mac_len) {
            const remaining = out_len - mac_len;
            @memcpy(result[mac_len..][0..remaining], t[0..remaining]);
        }
        return result;
    }
}

pub fn deriveHandshakeSecret13(
    shared_secret: []const u8,
    comptime hash_len: usize,
) [hash_len]u8 {
    // TLS 1.3 key derivation (RFC 8446 Section 7.1):
    // 1. early_secret = HKDF-Extract(zero PSK, zero salt) — both are hash_len zeros
    // 2. derived_secret = HKDF-Expand-Label(early_secret, "derived", Hash(""), hash_len)
    //    Hash("") = empty hash digest (32 bytes of SHA-256 or 48 bytes of SHA-384)
    // 3. handshake_secret = HKDF-Extract(handshake_derived_secret, shared_secret)
    //
    // Note: hkdfExtract(ikm, salt) = HKDF-Extract(salt, ikm)
    const zero_psk: [hash_len]u8 = .{0} ** hash_len;
    const zero_salt: [hash_len]u8 = .{0} ** hash_len;
    const early_secret = hkdfExtract(&zero_psk, &zero_salt, hash_len);

    // Compute Hash("") — the hash of an empty string, used as context for "derived"
    const empty_hash: [hash_len]u8 = blk: {
        if (hash_len == 32) {
            var h = crypto.hash.sha2.Sha256.init(.{});
            var result: [32]u8 = undefined;
            h.final(&result);
            break :blk result;
        } else {
            var h = crypto.hash.sha2.Sha384.init(.{});
            var result: [48]u8 = undefined;
            h.final(&result);
            break :blk result;
        }
    };

    const handshake_derived_secret = hkdfExpandLabel(&early_secret, "derived", &empty_hash, hash_len);
    // HKDF-Extract(handshake_derived_secret, shared_secret)
    // = hkdfExtract(ikm=shared_secret, salt=handshake_derived_secret)
    return hkdfExtract(shared_secret, &handshake_derived_secret, hash_len);
}

pub fn deriveTrafficKeys13(
    secret: []const u8,
) struct { key: [32]u8, iv: [12]u8 } {
    dbg.log("TLS", "deriveTrafficKeys13: secret_len={d}", .{secret.len});
    var secret_arr: [32]u8 = undefined;
    @memcpy(&secret_arr, secret[0..32]);
    const key_label = hkdfExpandLabel(&secret_arr, "key", "", 32);
    const iv_label = hkdfExpandLabel(&secret_arr, "iv", "", 12);
    return .{ .key = key_label, .iv = iv_label };
}

pub fn readTlsRecord(socket: *Socket, buf: *[4096]u8) ![]const u8 {
    var total: usize = 0;
    while (total < 5) {
        const n = socket.recv(buf[total..5]) catch |err| switch (err) {
            error.ConnectionResetByPeer => return error.TlsConnectionTruncated,
            else => return error.ReadFailed,
        };
        if (n == 0) return error.TlsConnectionTruncated;
        total += n;
    }
    const length = mem.readInt(u16, buf[3..5], .big);
    if (length > max_ciphertext_len) return error.TlsRecordOverflow;
    while (total < 5 + length) {
        const n = socket.recv(buf[total..][0 .. 5 + length - total]) catch |err| switch (err) {
            error.ConnectionResetByPeer => return error.TlsConnectionTruncated,
            else => return error.ReadFailed,
        };
        if (n == 0) return error.TlsConnectionTruncated;
        total += n;
    }
    return buf[5..][0..length];
}

fn readHandshakeRecord(socket: *Socket, buf: *[4096]u8) ![]const u8 {
    const data = try readTlsRecord(socket, buf);
    switch (buf[0]) {
        @intFromEnum(ContentType.handshake) => return data,
        @intFromEnum(ContentType.alert) => {
            if (data.len >= 2) {
                const alert_desc: tls.Alert.Description = @enumFromInt(data[1]);
                return errors.fromAlert(alert_desc);
            }
            return error.TlsHandshakeFailure;
        },
        @intFromEnum(ContentType.change_cipher_spec) => return data,
        else => return error.TlsUnexpectedMessage,
    }
}

pub fn sendTlsHandshakeRecord(socket: *Socket, msg: []const u8) !void {
    var buf: [5 + max_plaintext_len]u8 = undefined;
    buf[0] = @intFromEnum(ContentType.handshake);
    buf[1] = 0x03;
    buf[2] = 0x03;
    mem.writeInt(u16, buf[3..5], @intCast(msg.len), .big);
    @memcpy(buf[5..][0..msg.len], msg);
    socket.sendAll(buf[0 .. 5 + msg.len]) catch return error.WriteFailed;
}

pub fn sendTlsChangeCipherSpec(socket: *Socket) !void {
    const ccs = [_]u8{
        @intFromEnum(ContentType.change_cipher_spec),
        0x03,
        0x01,
        0x00,
        0x01,
        0x01,
    };
    socket.sendAll(&ccs) catch return error.WriteFailed;
}

pub fn sendTls13EncryptedHandshake(
    socket: *Socket,
    msg: []const u8,
    key: []const u8,
    iv: []const u8,
    seq: *u64,
    cs: tls.CipherSuite,
) !void {
    var inner_buf: [max_plaintext_len + 1]u8 = undefined;
    @memcpy(inner_buf[0..msg.len], msg);
    inner_buf[msg.len] = @intFromEnum(ContentType.handshake);
    const inner_len = msg.len + 1;

    var hdr_buf: [record_header_len]u8 = undefined;
    const hdr_val = RecordHeader{
        .content_type = .application_data,
        .version = .tls_1_2,
        .length = @intCast(inner_len + 16),
    };
    hdr_val.format(&hdr_buf);

    var nonce_storage = nonceTls13(iv[0..12], seq.*);
    const nonce = &nonce_storage;
    var out_buf: [record_header_len + max_plaintext_len + 256]u8 = undefined;
    @memcpy(out_buf[0..record_header_len], &hdr_buf);

    const enc_len = switch (cs) {
        .AES_128_GCM_SHA256 => blk: {
            var k: [16]u8 = undefined;
            @memcpy(&k, key[0..16]);
            const enc = try encryptTls13(crypto.aead.aes_gcm.Aes128Gcm, out_buf[record_header_len..], inner_buf[0..inner_len], &hdr_buf, nonce, &k);
            break :blk enc.len;
        },
        .AES_256_GCM_SHA384 => blk: {
            var k: [32]u8 = undefined;
            @memcpy(&k, key[0..32]);
            const enc = try encryptTls13(crypto.aead.aes_gcm.Aes256Gcm, out_buf[record_header_len..], inner_buf[0..inner_len], &hdr_buf, nonce, &k);
            break :blk enc.len;
        },
        .CHACHA20_POLY1305_SHA256 => blk: {
            var k: [32]u8 = undefined;
            @memcpy(&k, key[0..32]);
            const enc = try encryptTls13(crypto.aead.chacha_poly.ChaCha20Poly1305, out_buf[record_header_len..], inner_buf[0..inner_len], &hdr_buf, nonce, &k);
            break :blk enc.len;
        },
        else => return error.TlsUnsupportedCipherSuite,
    };

    const total = record_header_len + enc_len;
    socket.sendAll(out_buf[0..total]) catch return error.WriteFailed;
    seq.* += 1;
}

pub fn readTls13EncryptedHandshake(
    socket: *Socket,
    buf: *[4096]u8,
    key: []const u8,
    iv: []const u8,
    seq: *u64,
    cs: tls.CipherSuite,
) ![]const u8 {
    const record_data = try readTlsRecord(socket, buf);
    const hdr_ptr: *const [record_header_len]u8 = buf[0..record_header_len];
    var nonce_storage = nonceTls13(iv[0..12], seq.*);
    const nonce = &nonce_storage;

    const decrypted = switch (cs) {
        .AES_128_GCM_SHA256 => blk: {
            var k: [16]u8 = undefined;
            @memcpy(&k, key[0..16]);
            break :blk try decryptTls13(crypto.aead.aes_gcm.Aes128Gcm, @constCast(record_data), hdr_ptr, nonce, &k);
        },
        .AES_256_GCM_SHA384 => blk: {
            var k: [32]u8 = undefined;
            @memcpy(&k, key[0..32]);
            break :blk try decryptTls13(crypto.aead.aes_gcm.Aes256Gcm, @constCast(record_data), hdr_ptr, nonce, &k);
        },
        .CHACHA20_POLY1305_SHA256 => blk: {
            var k: [32]u8 = undefined;
            @memcpy(&k, key[0..32]);
            break :blk try decryptTls13(crypto.aead.chacha_poly.ChaCha20Poly1305, @constCast(record_data), hdr_ptr, nonce, &k);
        },
        else => return error.TlsUnsupportedCipherSuite,
    };

    seq.* += 1;
    if (decrypted.len == 0) return error.TlsDecryptError;
    return decrypted[0 .. decrypted.len - 1];
}

const HmacSha256 = crypto.auth.hmac.sha2.HmacSha256;
const HmacSha384 = crypto.auth.hmac.sha2.HmacSha384;

fn pemDecode(allocator: Allocator, pem: []const u8) ![]const u8 {
    const begin_marker = "-----BEGIN ";
    var start: usize = 0;
    var found_start = false;
    var i: usize = 0;
    while (i < pem.len) : (i += 1) {
        if (pem[i] == '-' and i + begin_marker.len <= pem.len) {
            if (mem.startsWith(u8, pem[i..], begin_marker)) {
                while (i < pem.len and pem[i] != '\n') : (i += 1) {}
                i += 1;
                start = i;
                found_start = true;
                break;
            }
        }
    }
    if (!found_start) return error.TlsInvalidPem;
    var end: usize = pem.len;
    i = start;
    while (i < pem.len) : (i += 1) {
        if (pem[i] == '-' and i + 5 <= pem.len) {
            if (mem.startsWith(u8, pem[i..], "-----END ")) {
                end = i;
                break;
            }
        }
    }
    var b64_len: usize = 0;
    for (pem[start..end]) |c| {
        if (c != '\n' and c != '\r' and c != ' ' and c != '\t') b64_len += 1;
    }
    var b64_buf = try allocator.alloc(u8, b64_len);
    defer allocator.free(b64_buf);
    var pos: usize = 0;
    for (pem[start..end]) |c| {
        if (c != '\n' and c != '\r' and c != ' ' and c != '\t') {
            b64_buf[pos] = c;
            pos += 1;
        }
    }
    const Decoder = std.base64.standard.Decoder;
    const decoded_len = Decoder.calcSizeForSlice(b64_buf[0..b64_len]) catch return error.TlsInvalidPem;
    const decoded = try allocator.alloc(u8, decoded_len);
    Decoder.decode(decoded, b64_buf[0..b64_len]) catch {
        allocator.free(decoded);
        return error.TlsInvalidPem;
    };
    return decoded;
}

pub fn loadCertChain(allocator: Allocator, path: []const u8) ![]const []const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = std.Io.Dir.cwd();
    const pem = try dir.readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(pem);
    var count: usize = 0;
    var search_pos: usize = 0;
    while (search_pos < pem.len) {
        if (mem.indexOf(u8, pem[search_pos..], "-----BEGIN CERTIFICATE-----")) |_| {
            count += 1;
            if (mem.indexOf(u8, pem[search_pos..], "-----END CERTIFICATE-----")) |end_pos| {
                search_pos += end_pos + 25;
            } else break;
        } else break;
    }
    if (count == 0) return error.TlsNoCertificates;
    var certs = try allocator.alloc([]const u8, count);
    var cert_idx: usize = 0;
    search_pos = 0;
    while (cert_idx < count) {
        const begin_pos = mem.indexOf(u8, pem[search_pos..], "-----BEGIN CERTIFICATE-----") orelse break;
        const cert_start = search_pos + begin_pos;
        const end_pos = mem.indexOf(u8, pem[cert_start..], "-----END CERTIFICATE-----") orelse break;
        const cert_end = cert_start + end_pos + 25;
        certs[cert_idx] = try pemDecode(allocator, pem[cert_start..cert_end]);
        search_pos = cert_end;
        cert_idx += 1;
    }
    return certs;
}

pub fn loadPrivateKey(allocator: Allocator, path: []const u8) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = std.Io.Dir.cwd();
    const pem = try dir.readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(pem);
    const rsa_begin = "-----BEGIN RSA PRIVATE KEY-----";
    const pkcs8_begin = "-----BEGIN PRIVATE KEY-----";
    const ec_begin = "-----BEGIN EC PRIVATE KEY-----";
    const rsa_start = mem.indexOf(u8, pem, rsa_begin);
    const pkcs8_start = mem.indexOf(u8, pem, pkcs8_begin);
    const ec_start = mem.indexOf(u8, pem, ec_begin);
    const is_pkcs1 = rsa_start != null;
    const is_ec = ec_start != null and rsa_start == null;
    const final_start = if (rsa_start) |s| s else if (pkcs8_start) |s| s else ec_start orelse return error.TlsInvalidPrivateKey;
    const end_marker = if (is_pkcs1) "-----END RSA PRIVATE KEY-----" else if (is_ec) "-----END EC PRIVATE KEY-----" else "-----END PRIVATE KEY-----";
    const end_pos = mem.indexOf(u8, pem[final_start..], end_marker) orelse return error.TlsInvalidPrivateKey;
    const key_end = final_start + end_pos + end_marker.len;
    return pemDecode(allocator, pem[final_start..key_end]);
}

pub const ServerTlsConfig = struct {
    cert_chain_der: []const []const u8 = &.{},
    key_der: ?[]const u8 = null,
    allocator: ?Allocator = null,
    ecdsa_keypair: ?crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair = null,

    pub fn deinit(self: *ServerTlsConfig) void {
        if (self.allocator) |a| {
            for (self.cert_chain_der) |cert| a.free(cert);
            a.free(self.cert_chain_der);
            if (self.key_der) |k| a.free(k);
        }
    }
};

pub fn loadServerTlsConfig(allocator: Allocator, cert_path: []const u8, key_path: []const u8) !ServerTlsConfig {
    const cert_chain = try loadCertChain(allocator, cert_path);
    const key_der = try loadPrivateKey(allocator, key_path);
    var config = ServerTlsConfig{
        .cert_chain_der = cert_chain,
        .key_der = key_der,
        .allocator = allocator,
    };
    // Try to parse ECDSA P-256 private key from PKCS#8 DER
    if (config.key_der) |kd| {
        config.ecdsa_keypair = parseEcdsaP256KeyFromPkcs8(kd);
    }
    return config;
}

fn parseEcdsaP256KeyFromPkcs8(der: []const u8) ?crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair {
    // Supports both:
    // PKCS#8: SEQUENCE { INTEGER, SEQUENCE { OID, OID }, OCTET STRING { ECPrivateKey } }
    // SEC1:   SEQUENCE { INTEGER(1), OCTET STRING(32 bytes private key), [0] OID, [1] pub }
    // Strategy: recursively scan for OCTET STRING (tag 0x04) with exactly 32 bytes content.
    return scanDerForEcKey(der, 0, der.len);
}

fn scanDerForEcKey(der: []const u8, start: usize, end: usize) ?crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair {
    var i = start;
    while (i + 1 < end) {
        const tag = der[i];
        i += 1;
        if (i >= end) return null;
        var length: usize = 0;
        const len_byte = der[i];
        i += 1;
        if (len_byte < 0x80) {
            length = len_byte;
        } else if (len_byte == 0x81) {
            if (i >= end) return null;
            length = der[i];
            i += 1;
        } else if (len_byte == 0x82) {
            if (i + 1 >= end) return null;
            length = @as(usize, der[i]) << 8 | der[i + 1];
            i += 2;
        } else if (len_byte >= 0x83 and len_byte <= 0x86) {
            const len_len: usize = @intCast(len_byte & 0x0f);
            if (i + len_len > end) return null;
            length = 0;
            for (0..len_len) |j| {
                length = (length << 8) | der[i + j];
            }
            i += len_len;
        } else {
            i += length;
            continue;
        }
        if (i + length > end) return null;
        // OCTET STRING containing 32 bytes of EC private key
        if (tag == 0x04 and length == 32) {
            const raw_key: [32]u8 = der[i..][0..32].*;
            const sk = crypto.sign.ecdsa.EcdsaP256Sha256.SecretKey.fromBytes(raw_key) catch {
                i += length;
                continue;
            };
            return crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair.fromSecretKey(sk) catch return null;
        }
        // If this is a constructed/SEQUENCE type (bit 5 set), descend into it
        if (tag & 0x20 != 0) {
            if (scanDerForEcKey(der, i, i + length)) |kp| return kp;
        }
        i += length;
    }
    return null;
}

pub const Connection = struct {
    allocator: Allocator,
    socket: *Socket,
    negotiated_alpn: alpn.NegotiatedAlpn = .{},
    tls_version: tls.ProtocolVersion = .tls_1_2,
    is_server: bool = false,
    connected: bool = false,
    app_write_key: ?[32]u8 = null,
    app_write_iv: ?[12]u8 = null,
    app_read_key: ?[32]u8 = null,
    app_read_iv: ?[12]u8 = null,
    write_seq: u64 = 0,
    read_seq: u64 = 0,
    hs_write_seq: u64 = 0,
    hs_read_seq: u64 = 0,
    cipher_suite: ?tls.CipherSuite = null,
    read_buf: [max_record_len]u8 = undefined,
    read_buf_len: usize = 0,
    read_buf_pos: usize = 0,

    pub fn negotiatedAlpn(self: *const Connection) ?[]const u8 {
        return self.negotiated_alpn.get();
    }

    pub fn isHttp2(self: *const Connection) bool {
        return self.negotiated_alpn.isHttp2Result();
    }

    pub fn isHttp3(self: *const Connection) bool {
        return self.negotiated_alpn.isHttp3Result();
    }

    pub fn tlsVersion(self: *const Connection) tls.ProtocolVersion {
        return self.tls_version;
    }

    pub fn sendAlert(self: *Connection, level: tls.Alert.Level, desc: tls.Alert.Description) void {
        var buf: [7]u8 = undefined;
        buf[0] = @intFromEnum(ContentType.alert);
        buf[1] = 0x03;
        buf[2] = 0x03;
        buf[3] = 0;
        buf[4] = 2;
        buf[5] = @intFromEnum(level);
        buf[6] = @intFromEnum(desc);
        _ = self.socket.send(buf[0..7]) catch {};
    }

    pub fn closeNotify(self: *Connection) void {
        dbg.log("TLS", "close_notify", .{});
        self.sendAlert(.warning, .close_notify);
    }

    pub fn reader(self: *Connection) any_io.AnyReader {
        return .{
            .context = @ptrCast(self),
            .readFn = struct {
                fn read(ctx: *anyopaque, buffer: []u8) anyerror!usize {
                    const c: *Connection = @ptrCast(@alignCast(ctx));
                    return c.read(buffer);
                }
            }.read,
        };
    }

    pub fn writer(self: *Connection) any_io.AnyWriter {
        return .{
            .context = @ptrCast(self),
            .writeFn = struct {
                fn write(ctx: *anyopaque, data: []const u8) anyerror!usize {
                    const c: *Connection = @ptrCast(@alignCast(ctx));
                    return c.write(data);
                }
            }.write,
        };
    }

    pub fn write(self: *Connection, data: []const u8) !usize {
        dbg.log("TLS", "write: {d} bytes", .{data.len});
        const socket = self.socket;
        const version = self.tls_version;
        const key = self.app_write_key orelse return error.TlsHandshakeNotComplete;
        const iv = self.app_write_iv orelse return error.TlsHandshakeNotComplete;
        const cs = self.cipher_suite orelse return error.TlsHandshakeNotComplete;

        switch (version) {
            .tls_1_3 => {
                var hdr: [record_header_len]u8 = undefined;
                const hdr_val = RecordHeader{
                    .content_type = .application_data,
                    .version = .tls_1_2,
                    .length = @intCast(data.len + 16),
                };
                hdr_val.format(&hdr);
                const nonce_val = nonceTls13(&iv, self.write_seq);
                var out_buf: [record_header_len + max_plaintext_len + 256]u8 = undefined;
                @memcpy(out_buf[0..record_header_len], &hdr);
                const enc_len = switch (cs) {
                    .AES_128_GCM_SHA256 => blk: {
                        var k: [16]u8 = undefined;
                        @memcpy(&k, key[0..16]);
                        const enc = try encryptTls13(crypto.aead.aes_gcm.Aes128Gcm, out_buf[record_header_len..], data, &hdr, &nonce_val, &k);
                        break :blk enc.len;
                    },
                    .AES_256_GCM_SHA384 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        const enc = try encryptTls13(crypto.aead.aes_gcm.Aes256Gcm, out_buf[record_header_len..], data, &hdr, &nonce_val, &k);
                        break :blk enc.len;
                    },
                    .CHACHA20_POLY1305_SHA256 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        const enc = try encryptTls13(crypto.aead.chacha_poly.ChaCha20Poly1305, out_buf[record_header_len..], data, &hdr, &nonce_val, &k);
                        break :blk enc.len;
                    },
                    else => return error.TlsUnsupportedCipherSuite,
                };
                const total = record_header_len + enc_len;
                socket.sendAll(out_buf[0..total]) catch return error.WriteFailed;
                self.write_seq += 1;
                return data.len;
            },
            .tls_1_2 => {
                var hdr: [record_header_len]u8 = undefined;
                const hdr_val = RecordHeader{
                    .content_type = .application_data,
                    .version = .tls_1_2,
                    .length = @intCast(12 + data.len + 16),
                };
                hdr_val.format(&hdr);
                var out_buf: [record_header_len + 32 + max_plaintext_len + 256]u8 = undefined;
                @memcpy(out_buf[0..record_header_len], &hdr);
                const enc_len = switch (cs) {
                    .ECDHE_RSA_WITH_AES_128_GCM_SHA256 => blk: {
                        var k: [16]u8 = undefined;
                        @memcpy(&k, key[0..16]);
                        const enc = try encryptTls12(crypto.aead.aes_gcm.Aes128Gcm, out_buf[record_header_len..], data, &hdr, self.write_seq, &iv, &k);
                        break :blk enc.len;
                    },
                    .ECDHE_RSA_WITH_AES_256_GCM_SHA384 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        const enc = try encryptTls12(crypto.aead.aes_gcm.Aes256Gcm, out_buf[record_header_len..], data, &hdr, self.write_seq, &iv, &k);
                        break :blk enc.len;
                    },
                    .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        const enc = try encryptTls12(crypto.aead.chacha_poly.ChaCha20Poly1305, out_buf[record_header_len..], data, &hdr, self.write_seq, &iv, &k);
                        break :blk enc.len;
                    },
                    else => return error.TlsUnsupportedCipherSuite,
                };
                const total = record_header_len + enc_len;
                socket.sendAll(out_buf[0..total]) catch return error.WriteFailed;
                self.write_seq += 1;
                return data.len;
            },
            else => return error.TlsUnsupportedCipherSuite,
        }
    }

    pub fn writeAll(self: *Connection, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            const n = try self.write(data[written..]);
            if (n == 0) return error.WriteFailed;
            written += n;
        }
    }

    pub fn flush(_: *Connection) !void {}

    pub fn read(self: *Connection, buf: []u8) !usize {
        dbg.log("TLS", "read: buf_len={d}", .{buf.len});
        const socket = self.socket;
        const version = self.tls_version;
        const key = self.app_read_key orelse return error.TlsHandshakeNotComplete;
        const iv = self.app_read_iv orelse return error.TlsHandshakeNotComplete;
        const cs = self.cipher_suite orelse return error.TlsHandshakeNotComplete;

        if (self.read_buf_pos < self.read_buf_len) {
            const available = self.read_buf_len - self.read_buf_pos;
            const to_copy = @min(available, buf.len);
            @memcpy(buf[0..to_copy], self.read_buf[self.read_buf_pos..][0..to_copy]);
            self.read_buf_pos += to_copy;
            return to_copy;
        }

        var total: usize = 0;
        while (total < 5) {
            const n = socket.recv(self.read_buf[total..5]) catch |err| switch (err) {
                error.ConnectionResetByPeer => return error.TlsConnectionTruncated,
                else => return error.ReadFailed,
            };
            if (n == 0) return error.TlsConnectionTruncated;
            total += n;
        }
        const length = mem.readInt(u16, self.read_buf[3..5], .big);
        if (length > max_ciphertext_len) return error.TlsRecordOverflow;
        while (total < 5 + length) {
            const n = socket.recv(self.read_buf[total..][0 .. 5 + length - total]) catch |err| switch (err) {
                error.ConnectionResetByPeer => return error.TlsConnectionTruncated,
                else => return error.ReadFailed,
            };
            if (n == 0) return error.TlsConnectionTruncated;
            total += n;
        }
        const record_body = self.read_buf[5..][0..length];

        switch (version) {
            .tls_1_3 => {
                const nonce_val = nonceTls13(&iv, self.read_seq);
                const plaintext = switch (cs) {
                    .AES_128_GCM_SHA256 => blk: {
                        var k: [16]u8 = undefined;
                        @memcpy(&k, key[0..16]);
                        break :blk try decryptTls13(crypto.aead.aes_gcm.Aes128Gcm, record_body, self.read_buf[0..5], &nonce_val, &k);
                    },
                    .AES_256_GCM_SHA384 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        break :blk try decryptTls13(crypto.aead.aes_gcm.Aes256Gcm, record_body, self.read_buf[0..5], &nonce_val, &k);
                    },
                    .CHACHA20_POLY1305_SHA256 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        break :blk try decryptTls13(crypto.aead.chacha_poly.ChaCha20Poly1305, record_body, self.read_buf[0..5], &nonce_val, &k);
                    },
                    else => return error.TlsUnsupportedCipherSuite,
                };
                self.read_seq += 1;
                if (plaintext.len == 0) return 0;
                const data_len = plaintext.len - 1;
                const to_copy = @min(data_len, buf.len);
                @memcpy(buf[0..to_copy], plaintext[0..to_copy]);
                return to_copy;
            },
            .tls_1_2 => {
                const plaintext = switch (cs) {
                    .ECDHE_RSA_WITH_AES_128_GCM_SHA256 => blk: {
                        var k: [16]u8 = undefined;
                        @memcpy(&k, key[0..16]);
                        break :blk try decryptTls12(crypto.aead.aes_gcm.Aes128Gcm, record_body, self.read_buf[0..5], self.read_seq, &iv, &k);
                    },
                    .ECDHE_RSA_WITH_AES_256_GCM_SHA384 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        break :blk try decryptTls12(crypto.aead.aes_gcm.Aes256Gcm, record_body, self.read_buf[0..5], self.read_seq, &iv, &k);
                    },
                    .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        break :blk try decryptTls12(crypto.aead.chacha_poly.ChaCha20Poly1305, record_body, self.read_buf[0..5], self.read_seq, &iv, &k);
                    },
                    else => return error.TlsUnsupportedCipherSuite,
                };
                self.read_seq += 1;
                const to_copy = @min(plaintext.len, buf.len);
                @memcpy(buf[0..to_copy], plaintext[0..to_copy]);
                if (plaintext.len > to_copy) {
                    @memcpy(self.read_buf[0 .. plaintext.len - to_copy], plaintext[to_copy..]);
                    self.read_buf_len = plaintext.len - to_copy;
                    self.read_buf_pos = 0;
                } else {
                    self.read_buf_len = 0;
                    self.read_buf_pos = 0;
                }
                return to_copy;
            },
            else => return error.TlsUnsupportedCipherSuite,
        }
    }
};

pub const TlsConfig = struct {
    allocator: Allocator,
    alpn_protocols: []const []const u8 = &.{"http/1.1"},
    verify_server: bool = true,
    ca_bundle_path: ?[]const u8 = null,

    pub fn init(allocator: Allocator) TlsConfig {
        return .{ .allocator = allocator };
    }

    pub fn insecure(allocator: Allocator) TlsConfig {
        return .{ .allocator = allocator, .verify_server = false };
    }

    pub fn withH2(allocator: Allocator) TlsConfig {
        return .{ .allocator = allocator, .alpn_protocols = &.{ "h2", "http/1.1" } };
    }

    pub fn insecureWithH2(allocator: Allocator) TlsConfig {
        return .{ .allocator = allocator, .alpn_protocols = &.{ "h2", "http/1.1" }, .verify_server = false };
    }

    pub fn withH3(allocator: Allocator) TlsConfig {
        return .{ .allocator = allocator, .alpn_protocols = &.{ "h3", "h2", "http/1.1" } };
    }

    pub fn insecureWithH3(allocator: Allocator) TlsConfig {
        return .{ .allocator = allocator, .alpn_protocols = &.{ "h3", "h2", "http/1.1" }, .verify_server = false };
    }

    pub fn wantsHttp2(self: TlsConfig) bool {
        for (self.alpn_protocols) |proto| {
            if (mem.eql(u8, proto, "h2")) return true;
        }
        return false;
    }
};

pub const TlsSession = struct {
    config: TlsConfig,
    negotiated_alpn: alpn.NegotiatedAlpn = .{},
    tls_version: ?tls.ProtocolVersion = null,
    socket: ?*Socket = null,
    cipher_suite: ?tls.CipherSuite = null,
    reconnect_fn: ?*const fn (ctx: ?*anyopaque) ?*Socket = null,
    reconnect_ctx: ?*anyopaque = null,
    stored_client: ?TlsClient = null,
    hs_read_buf: [TlsClient.min_buffer_len]u8 = undefined,
    hs_write_buf: [TlsClient.min_buffer_len]u8 = undefined,
    hs_write_key: ?[32]u8 = null,
    hs_write_iv: ?[12]u8 = null,
    hs_write_seq: u64 = 0,
    hs_read_key: ?[32]u8 = null,
    hs_read_iv: ?[12]u8 = null,
    hs_read_seq: u64 = 0,
    app_write_key: ?[32]u8 = null,
    app_write_iv: ?[12]u8 = null,
    app_read_key: ?[32]u8 = null,
    app_read_iv: ?[12]u8 = null,
    write_seq: u64 = 0,
    read_seq: u64 = 0,
    read_buf: [max_record_len]u8 = undefined,
    read_buf_len: usize = 0,
    read_buf_pos: usize = 0,

    pub fn negotiatedProtocol(self: *const TlsSession) ?[]const u8 {
        return self.negotiated_alpn.get();
    }

    pub fn init(config: TlsConfig) TlsSession {
        dbg.log("TLS", "TlsSession init, verify={any}", .{config.verify_server});
        return .{ .config = config };
    }

    pub fn deinit(self: *TlsSession) void {
        if (self.app_write_key) |*k| @memset(k, 0);
        if (self.app_write_iv) |*k| @memset(k, 0);
        if (self.app_read_key) |*k| @memset(k, 0);
        if (self.app_read_iv) |*k| @memset(k, 0);
        self.read_buf_len = 0;
        self.read_buf_pos = 0;
    }

    pub fn attachSocket(self: *TlsSession, socket: *Socket) void {
        self.socket = socket;
    }

    pub fn handshake(self: *TlsSession, host: []const u8) !void {
        dbg.entry("TLS", "handshake");
        const socket = self.socket orelse return error.TlsMissingTransport;
        self.handshakeTls13(socket, host) catch {
            if (self.reconnect_fn) |reconnect| {
                if (reconnect(self.reconnect_ctx)) |new_socket| {
                    self.socket = new_socket;
                    try self.handshakeTls12(new_socket, host);
                    return;
                }
            }
            try self.handshakeTls12(socket, host);
        };
    }

    fn handshakeTls13(self: *TlsSession, socket: *Socket, host: []const u8) !void {
        var io_reader = SocketIoReader.init(socket, &self.hs_read_buf);
        var io_writer = SocketIoWriter.init(socket, &self.hs_write_buf);

        var entropy: [TlsClient.Options.entropy_len]u8 = undefined;
        std.Io.Threaded.global_single_threaded.io().random(&entropy);

        self.stored_client = try TlsClient.init(&io_reader.reader, &io_writer.writer, .{
            .host = if (self.config.verify_server)
                .{ .explicit = host }
            else
                .no_verification,
            .ca = if (self.config.verify_server)
                .self_signed
            else
                .no_verification,
            .write_buffer = &self.hs_write_buf,
            .read_buffer = &self.hs_read_buf,
            .entropy = &entropy,
            .realtime_now = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real),
            .alpn_protocols = self.config.alpn_protocols,
        });
        self.tls_version = self.stored_client.?.tls_version;
        self.cipher_suite = switch (self.stored_client.?.application_cipher) {
            .AES_128_GCM_SHA256 => .AES_128_GCM_SHA256,
            .AES_256_GCM_SHA384 => .AES_256_GCM_SHA384,
            .CHACHA20_POLY1305_SHA256 => .CHACHA20_POLY1305_SHA256,
            .AEGIS_256_SHA512 => .AEGIS_256_SHA512,
            .AEGIS_128L_SHA256 => .AEGIS_128L_SHA256,
        };
        switch (self.stored_client.?.application_cipher) {
            inline else => |*p| {
                const pv = &p.tls_1_3;
                self.app_write_key = .{0} ** 32;
                self.app_write_iv = .{0} ** 12;
                self.app_read_key = .{0} ** 32;
                self.app_read_iv = .{0} ** 12;
                const wk = &self.app_write_key.?;
                const wi = &self.app_write_iv.?;
                const rk = &self.app_read_key.?;
                const ri = &self.app_read_iv.?;
                const key_len = @min(pv.client_key.len, 32);
                const iv_len = @min(pv.client_iv.len, 12);
                @memcpy(wk[0..key_len], pv.client_key[0..key_len]);
                @memcpy(wi[0..iv_len], pv.client_iv[0..iv_len]);
                @memcpy(rk[0..key_len], pv.server_key[0..key_len]);
                @memcpy(ri[0..iv_len], pv.server_iv[0..iv_len]);
            },
        }

        if (self.stored_client.?.negotiated_alpn) |alpn_data| {
            const len = self.stored_client.?.negotiated_alpn_len;
            if (len > 0) {
                self.negotiated_alpn.set(alpn_data[0..len]);
            }
        }
    }

    fn handshakeTls12(self: *TlsSession, socket: *Socket, host: []const u8) !void {
        try self.handshakeTls13(socket, host);
    }

    pub fn isHttp2(self: *const TlsSession) bool {
        return self.negotiated_alpn.isHttp2Result();
    }

    pub fn isHttp3(self: *const TlsSession) bool {
        return self.negotiated_alpn.isHttp3Result();
    }

    pub fn write(self: *TlsSession, data: []const u8) !usize {
        const socket = self.socket orelse return 0;
        const version = self.tls_version orelse return error.TlsHandshakeNotComplete;
        const key = self.app_write_key orelse return error.TlsHandshakeNotComplete;
        const iv = self.app_write_iv orelse return error.TlsHandshakeNotComplete;
        const cs = self.cipher_suite orelse return error.TlsHandshakeNotComplete;

        switch (version) {
            .tls_1_3 => {
                var hdr: [record_header_len]u8 = undefined;
                const inner_len = data.len + 1;
                const hdr_val = RecordHeader{
                    .content_type = .application_data,
                    .version = .tls_1_2,
                    .length = @intCast(inner_len + 16),
                };
                hdr_val.format(&hdr);
                const nonce_val = nonceTls13(&iv, self.write_seq);
                var out_buf: [record_header_len + max_plaintext_len + 256]u8 = undefined;
                @memcpy(out_buf[0..record_header_len], &hdr);
                var inner_plaintext: [max_plaintext_len]u8 = undefined;
                @memcpy(inner_plaintext[0..data.len], data);
                inner_plaintext[data.len] = 0x17;
                const enc_len = switch (cs) {
                    .AES_128_GCM_SHA256 => blk: {
                        var k: [16]u8 = undefined;
                        @memcpy(&k, key[0..16]);
                        const enc = try encryptTls13(crypto.aead.aes_gcm.Aes128Gcm, out_buf[record_header_len..], inner_plaintext[0..inner_len], &hdr, &nonce_val, &k);
                        break :blk enc.len;
                    },
                    .AES_256_GCM_SHA384 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        const enc = try encryptTls13(crypto.aead.aes_gcm.Aes256Gcm, out_buf[record_header_len..], inner_plaintext[0..inner_len], &hdr, &nonce_val, &k);
                        break :blk enc.len;
                    },
                    .CHACHA20_POLY1305_SHA256 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        const enc = try encryptTls13(crypto.aead.chacha_poly.ChaCha20Poly1305, out_buf[record_header_len..], inner_plaintext[0..inner_len], &hdr, &nonce_val, &k);
                        break :blk enc.len;
                    },
                    else => return error.TlsUnsupportedCipherSuite,
                };
                const total = record_header_len + enc_len;
                socket.sendAll(out_buf[0..total]) catch return error.WriteFailed;
                self.write_seq += 1;
                return data.len;
            },
            .tls_1_2 => {
                var hdr: [record_header_len]u8 = undefined;
                const hdr_val = RecordHeader{
                    .content_type = .application_data,
                    .version = .tls_1_2,
                    .length = @intCast(12 + data.len + 16),
                };
                hdr_val.format(&hdr);
                var out_buf: [record_header_len + 32 + max_plaintext_len + 256]u8 = undefined;
                @memcpy(out_buf[0..record_header_len], &hdr);
                const enc_len = switch (cs) {
                    .ECDHE_RSA_WITH_AES_128_GCM_SHA256 => blk: {
                        var k: [16]u8 = undefined;
                        @memcpy(&k, key[0..16]);
                        const enc = try encryptTls12(crypto.aead.aes_gcm.Aes128Gcm, out_buf[record_header_len..], data, &hdr, self.write_seq, &iv, &k);
                        break :blk enc.len;
                    },
                    .ECDHE_RSA_WITH_AES_256_GCM_SHA384 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        const enc = try encryptTls12(crypto.aead.aes_gcm.Aes256Gcm, out_buf[record_header_len..], data, &hdr, self.write_seq, &iv, &k);
                        break :blk enc.len;
                    },
                    .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        const enc = try encryptTls12(crypto.aead.chacha_poly.ChaCha20Poly1305, out_buf[record_header_len..], data, &hdr, self.write_seq, &iv, &k);
                        break :blk enc.len;
                    },
                    else => return error.TlsUnsupportedCipherSuite,
                };
                const total = record_header_len + enc_len;
                socket.sendAll(out_buf[0..total]) catch return error.WriteFailed;
                self.write_seq += 1;
                return data.len;
            },
            else => return error.TlsUnsupportedCipherSuite,
        }
    }

    pub fn flush(_: *TlsSession) !void {}

    pub fn writeAll(self: *TlsSession, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            const n = try self.write(data[written..]);
            if (n == 0) return error.WriteFailed;
            written += n;
        }
    }

    pub fn read(self: *TlsSession, buf: []u8) !usize {
        const socket = self.socket orelse return 0;
        const version = self.tls_version orelse return error.TlsHandshakeNotComplete;
        const key = self.app_read_key orelse return error.TlsHandshakeNotComplete;
        const iv = self.app_read_iv orelse return error.TlsHandshakeNotComplete;
        const cs = self.cipher_suite orelse return error.TlsHandshakeNotComplete;

        if (self.read_buf_pos < self.read_buf_len) {
            const available = self.read_buf_len - self.read_buf_pos;
            const to_copy = @min(available, buf.len);
            @memcpy(buf[0..to_copy], self.read_buf[self.read_buf_pos..][0..to_copy]);
            self.read_buf_pos += to_copy;
            return to_copy;
        }

        var total: usize = 0;
        while (total < 5) {
            const n = socket.recv(self.read_buf[total..5]) catch |err| switch (err) {
                error.ConnectionResetByPeer => return error.TlsConnectionTruncated,
                else => return error.ReadFailed,
            };
            if (n == 0) return error.TlsConnectionTruncated;
            total += n;
        }
        const length = mem.readInt(u16, self.read_buf[3..5], .big);
        if (length > max_ciphertext_len) return error.TlsRecordOverflow;
        while (total < 5 + length) {
            const n = socket.recv(self.read_buf[total..][0 .. 5 + length - total]) catch |err| switch (err) {
                error.ConnectionResetByPeer => return error.TlsConnectionTruncated,
                else => return error.ReadFailed,
            };
            if (n == 0) return error.TlsConnectionTruncated;
            total += n;
        }
        const record_body = self.read_buf[5..][0..length];

        switch (version) {
            .tls_1_3 => {
                const nonce_val = nonceTls13(&iv, self.read_seq);
                const plaintext = switch (cs) {
                    .AES_128_GCM_SHA256 => blk: {
                        var k: [16]u8 = undefined;
                        @memcpy(&k, key[0..16]);
                        break :blk try decryptTls13(crypto.aead.aes_gcm.Aes128Gcm, record_body, self.read_buf[0..5], &nonce_val, &k);
                    },
                    .AES_256_GCM_SHA384 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        break :blk try decryptTls13(crypto.aead.aes_gcm.Aes256Gcm, record_body, self.read_buf[0..5], &nonce_val, &k);
                    },
                    .CHACHA20_POLY1305_SHA256 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        break :blk try decryptTls13(crypto.aead.chacha_poly.ChaCha20Poly1305, record_body, self.read_buf[0..5], &nonce_val, &k);
                    },
                    else => return error.TlsUnsupportedCipherSuite,
                };
                self.read_seq += 1;
                if (plaintext.len == 0) return 0;
                const data_len = plaintext.len - 1;
                const to_copy = @min(data_len, buf.len);
                @memcpy(buf[0..to_copy], plaintext[0..to_copy]);
                return to_copy;
            },
            .tls_1_2 => {
                const plaintext = switch (cs) {
                    .ECDHE_RSA_WITH_AES_128_GCM_SHA256 => blk: {
                        var k: [16]u8 = undefined;
                        @memcpy(&k, key[0..16]);
                        break :blk try decryptTls12(crypto.aead.aes_gcm.Aes128Gcm, record_body, self.read_buf[0..5], self.read_seq, &iv, &k);
                    },
                    .ECDHE_RSA_WITH_AES_256_GCM_SHA384 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        break :blk try decryptTls12(crypto.aead.aes_gcm.Aes256Gcm, record_body, self.read_buf[0..5], self.read_seq, &iv, &k);
                    },
                    .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        break :blk try decryptTls12(crypto.aead.chacha_poly.ChaCha20Poly1305, record_body, self.read_buf[0..5], self.read_seq, &iv, &k);
                    },
                    else => return error.TlsUnsupportedCipherSuite,
                };
                self.read_seq += 1;
                const to_copy = @min(plaintext.len, buf.len);
                @memcpy(buf[0..to_copy], plaintext[0..to_copy]);
                if (plaintext.len > to_copy) {
                    @memcpy(self.read_buf[0 .. plaintext.len - to_copy], plaintext[to_copy..]);
                    self.read_buf_len = plaintext.len - to_copy;
                    self.read_buf_pos = 0;
                } else {
                    self.read_buf_len = 0;
                    self.read_buf_pos = 0;
                }
                return to_copy;
            },
            else => return error.TlsUnsupportedCipherSuite,
        }
    }
};

pub fn connectClient(
    allocator: Allocator,
    socket: *Socket,
    config: *const TlsConfig,
    host: []const u8,
) !Connection {
    var conn = Connection{
        .allocator = allocator,
        .socket = socket,
        .is_server = false,
        .connected = true,
    };

    var session = TlsSession.init(config.*);
    session.socket = socket;
    try session.handshake(host);

    conn.tls_version = session.tls_version orelse .tls_1_2;
    conn.app_write_key = session.app_write_key;
    conn.app_write_iv = session.app_write_iv;
    conn.app_read_key = session.app_read_key;
    conn.app_read_iv = session.app_read_iv;
    conn.negotiated_alpn = session.negotiated_alpn;

    return conn;
}

fn detectTls13(client_hello: []const u8) bool {
    if (client_hello.len < 42) return false;
    var off: usize = 4 + 2 + 32;
    if (off >= client_hello.len) return false;
    const session_id_len = client_hello[off];
    off += 1 + session_id_len;
    if (off + 2 > client_hello.len) return false;
    const cs_len = mem.readInt(u16, client_hello[off..][0..2], .big);
    off += 2 + cs_len;
    if (off >= client_hello.len) return false;
    const comp_len = client_hello[off];
    off += 1 + comp_len;
    if (off + 2 > client_hello.len) return false;
    const ext_len = mem.readInt(u16, client_hello[off..][0..2], .big);
    off += 2;
    const ext_end = @min(off + ext_len, client_hello.len);
    while (off + 4 <= ext_end) {
        const ext_type = mem.readInt(u16, client_hello[off..][0..2], .big);
        const ext_data_len = mem.readInt(u16, client_hello[off + 2 ..][0..2], .big);
        off += 4;
        if (ext_type == @intFromEnum(tls.ExtensionType.supported_versions)) {
            var voff: usize = off;
            if (voff + 1 <= ext_end) {
                _ = client_hello[voff];
                voff += 1;
                while (voff + 2 <= off + ext_data_len) {
                    const ver = mem.readInt(u16, client_hello[voff..][0..2], .big);
                    if (ver == @intFromEnum(tls.ProtocolVersion.tls_1_3)) return true;
                    voff += 2;
                }
            }
        }
        off += ext_data_len;
    }
    return false;
}

test "TlsConfig withH2 sets correct ALPN" {
    const config = TlsConfig.withH2(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), config.alpn_protocols.len);
    try std.testing.expectEqualStrings("h2", config.alpn_protocols[0]);
    try std.testing.expectEqualStrings("http/1.1", config.alpn_protocols[1]);
}

test "TlsConfig insecure disables verification" {
    const config = TlsConfig.insecure(std.testing.allocator);
    try std.testing.expect(!config.verify_server);
}

test "TlsSession init" {
    const session = TlsSession.init(TlsConfig.init(std.testing.allocator));
    try std.testing.expect(session.negotiated_alpn.get() == null);
    try std.testing.expect(session.tls_version == null);
}

test "TlsConfig withH3 sets correct ALPN" {
    const config = TlsConfig.withH3(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), config.alpn_protocols.len);
    try std.testing.expectEqualStrings("h3", config.alpn_protocols[0]);
    try std.testing.expectEqualStrings("h2", config.alpn_protocols[1]);
    try std.testing.expectEqualStrings("http/1.1", config.alpn_protocols[2]);
}

test "TlsConfig insecureWithH2" {
    const config = TlsConfig.insecureWithH2(std.testing.allocator);
    try std.testing.expect(!config.verify_server);
    try std.testing.expectEqual(@as(usize, 2), config.alpn_protocols.len);
}

test "TlsConfig insecureWithH3" {
    const config = TlsConfig.insecureWithH3(std.testing.allocator);
    try std.testing.expect(!config.verify_server);
    try std.testing.expectEqual(@as(usize, 3), config.alpn_protocols.len);
    try std.testing.expectEqualStrings("h3", config.alpn_protocols[0]);
}

test "TlsConfig init defaults" {
    const config = TlsConfig.init(std.testing.allocator);
    try std.testing.expect(config.verify_server);
    try std.testing.expectEqual(@as(usize, 1), config.alpn_protocols.len);
    try std.testing.expectEqualStrings("http/1.1", config.alpn_protocols[0]);
}

test "detectTls13 returns false for short data" {
    try std.testing.expect(!detectTls13(&[_]u8{0}));
}

test "detectTls13 returns false for no supported_versions extension" {
    var buf: [50]u8 = [_]u8{0} ** 50;
    buf[0] = 1;
    buf[1] = 0x33;
    try std.testing.expect(!detectTls13(&buf));
}

test "TlsSession isHttp2/isHttp3" {
    var session = TlsSession.init(TlsConfig.init(std.testing.allocator));
    try std.testing.expect(!session.isHttp2());
    try std.testing.expect(!session.isHttp3());
    session.negotiated_alpn.set("h2");
    try std.testing.expect(session.isHttp2());
    try std.testing.expect(!session.isHttp3());
}

test "TlsSession negotiatedProtocol returns null initially" {
    const session = TlsSession.init(TlsConfig.init(std.testing.allocator));
    try std.testing.expect(session.negotiatedProtocol() == null);
}

test "TlsSession negotiatedProtocol returns protocol after set" {
    var session = TlsSession.init(TlsConfig.init(std.testing.allocator));
    session.negotiated_alpn.set("h3");
    const proto = session.negotiatedProtocol();
    try std.testing.expect(proto != null);
    try std.testing.expectEqualStrings("h3", proto.?);
}

test "TlsSession deinit zeros key material" {
    var session = TlsSession.init(TlsConfig.init(std.testing.allocator));
    session.app_write_key = [_]u8{0xAB} ** 32;
    session.app_read_key = [_]u8{0xCD} ** 32;
    session.deinit();
    if (session.app_write_key) |k| {
        for (k) |b| try std.testing.expectEqual(@as(u8, 0), b);
    }
    if (session.app_read_key) |k| {
        for (k) |b| try std.testing.expectEqual(@as(u8, 0), b);
    }
}

test "Connection struct field defaults" {
    const defaults = Connection{
        .allocator = undefined,
        .socket = undefined,
    };
    try std.testing.expect(!defaults.is_server);
    try std.testing.expect(!defaults.connected);
    try std.testing.expect(defaults.tls_version == .tls_1_2);
    try std.testing.expect(defaults.negotiated_alpn.get() == null);
}

test "nonceTls13 XORs IV correctly" {
    const iv = [_]u8{0} ** 12;
    const nonce_val = nonceTls13(&iv, 1);
    try std.testing.expectEqual(@as(u8, 0), nonce_val[0]);
    try std.testing.expectEqual(@as(u8, 0), nonce_val[7]);
    try std.testing.expectEqual(@as(u8, 1), nonce_val[11]);
}

test "RecordHeader format/parse round-trip" {
    var hdr_buf: [record_header_len]u8 = undefined;
    const hdr = RecordHeader{
        .content_type = .handshake,
        .version = .tls_1_2,
        .length = 256,
    };
    hdr.format(&hdr_buf);
    try std.testing.expectEqual(@intFromEnum(ContentType.handshake), hdr_buf[0]);
    try std.testing.expectEqual(@as(u16, 256), mem.readInt(u16, hdr_buf[3..5], .big));
}
