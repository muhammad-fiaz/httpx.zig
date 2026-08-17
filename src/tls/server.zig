const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const crypto = std.crypto;
const tls = std.crypto.tls;
const dbg = @import("../util/debug.zig");

const Socket = @import("../net/socket.zig").Socket;
const tls_mod = @import("tls.zig");
const alpn = @import("alpn.zig");

const Connection = tls_mod.Connection;
const ServerTlsConfig = tls_mod.ServerTlsConfig;

const HmacSha256 = crypto.auth.hmac.sha2.HmacSha256;
const HmacSha384 = crypto.auth.hmac.sha2.HmacSha384;

fn BoundedArray(comptime T: type, comptime capacity: usize) type {
    return struct {
        buf: [capacity]T = undefined,
        len: usize = 0,

        fn append(self: *@This(), item: T) error{Overflow}!void {
            if (self.len >= capacity) return error.Overflow;
            self.buf[self.len] = item;
            self.len += 1;
        }

        fn slice(self: *const @This()) []const T {
            return self.buf[0..self.len];
        }
    };
}

const ClientHelloParsed = struct {
    alpn_protocols: BoundedArray([]const u8, 8),
    supports_tls13: bool,
    cipher_suites: BoundedArray(tls.CipherSuite, 32),
};

/// Extract the client's legacy_session_id from the ClientHello.
fn extractClientSessionId(ch_data: []const u8) ?[32]u8 {
    if (ch_data.len < 4 + 2 + 32 + 1) return null;
    const session_id_len = ch_data[4 + 2 + 32]; // after handshake_hdr + version + random
    if (session_id_len != 32) return null;
    const start = 4 + 2 + 32 + 1;
    if (ch_data.len < start + 32) return null;
    var id: [32]u8 = undefined;
    @memcpy(&id, ch_data[start..][0..32]);
    return id;
}

/// Extract X25519 public key from the key_share extension in ClientHello.
fn findX25519ClientKey(ch_data: []const u8) ?*const [32]u8 {
    // ClientHello body starts at offset 4 (after handshake type + length)
    // [4..6] = legacy_version (2)
    // [6..38] = random (32)
    // [38] = session_id_len (1)
    if (ch_data.len < 44) return null;
    var off: usize = 4 + 2 + 32; // skip legacy_version + random
    const session_id_len = ch_data[off];
    off += 1 + session_id_len;
    // cipher_suites
    if (off + 2 > ch_data.len) return null;
    const cs_len = mem.readInt(u16, ch_data[off..][0..2], .big);
    off += 2 + cs_len;
    // compression methods
    if (off >= ch_data.len) return null;
    const comp_len = ch_data[off];
    off += 1 + comp_len;
    // extensions
    if (off + 2 > ch_data.len) return null;
    const ext_len = mem.readInt(u16, ch_data[off..][0..2], .big);
    off += 2;
    const ext_end = @min(off + ext_len, ch_data.len);

    while (off + 4 <= ext_end) {
        const ext_type = mem.readInt(u16, ch_data[off..][0..2], .big);
        const ext_data_len = mem.readInt(u16, ch_data[off + 2 ..][0..2], .big);
        off += 4;
        if (ext_type == @intFromEnum(tls.ExtensionType.key_share)) {
            // Key share entry list: each entry is group(2) + length(2) + key
            var koff = off;
            while (koff + 4 <= off + ext_data_len) {
                const group = mem.readInt(u16, ch_data[koff..][0..2], .big);
                const key_len = mem.readInt(u16, ch_data[koff + 2 ..][0..2], .big);
                koff += 4;
                if (group == @intFromEnum(tls.NamedGroup.x25519) and key_len == 32 and koff + 32 <= ch_data.len) {
                    return ch_data[koff..][0..32];
                }
                koff += key_len;
            }
        }
        off += ext_data_len;
    }
    return null;
}

fn parseClientHelloExtensions(data: []const u8) ClientHelloParsed {
    var result = BoundedArray([]const u8, 8){};
    var supports_tls13 = false;
    var cipher_suites_list = BoundedArray(tls.CipherSuite, 32){};

    if (data.len < 44) return ClientHelloParsed{ .alpn_protocols = result, .supports_tls13 = supports_tls13, .cipher_suites = cipher_suites_list };

    var off: usize = 4 + 2 + 32;
    if (off >= data.len) return ClientHelloParsed{ .alpn_protocols = result, .supports_tls13 = supports_tls13, .cipher_suites = cipher_suites_list };

    const session_id_len = data[off];
    off += 1 + session_id_len;

    if (off + 2 > data.len) return ClientHelloParsed{ .alpn_protocols = result, .supports_tls13 = supports_tls13, .cipher_suites = cipher_suites_list };
    const cs_len = mem.readInt(u16, data[off..][0..2], .big);
    off += 2;
    var cs_off: usize = off;
    while (cs_off + 2 <= off + cs_len and cs_off + 2 <= data.len) {
        const cs_val = mem.readInt(u16, data[cs_off..][0..2], .big);
        if (cs_val != 0x0000 and cs_val != 0x00FF) {
            const cs_enum: tls.CipherSuite = @enumFromInt(cs_val);
            cipher_suites_list.append(cs_enum) catch {};
        }
        cs_off += 2;
    }
    off += cs_len;

    if (off >= data.len) return ClientHelloParsed{ .alpn_protocols = result, .supports_tls13 = supports_tls13, .cipher_suites = cipher_suites_list };
    const comp_len = data[off];
    off += 1 + comp_len;

    if (off + 2 > data.len) return ClientHelloParsed{ .alpn_protocols = result, .supports_tls13 = supports_tls13, .cipher_suites = cipher_suites_list };
    const ext_len = mem.readInt(u16, data[off..][0..2], .big);
    off += 2;
    const ext_end = @min(off + ext_len, data.len);

    while (off + 4 <= ext_end) {
        const ext_type = mem.readInt(u16, data[off..][0..2], .big);
        const ext_data_len = mem.readInt(u16, data[off + 2 ..][0..2], .big);
        off += 4;

        if (ext_type == @intFromEnum(tls.ExtensionType.supported_versions)) {
            if (off + 1 <= ext_end) {
                const vlen = data[off];
                var voff = off + 1;
                while (voff + 2 <= off + 1 + vlen and voff + 2 <= ext_end) {
                    const ver = mem.readInt(u16, data[voff..][0..2], .big);
                    if (ver == @intFromEnum(tls.ProtocolVersion.tls_1_3)) supports_tls13 = true;
                    voff += 2;
                }
            }
        } else if (ext_type == 0x0010) {
            if (off + 1 <= ext_end) {
                const list_len = data[off];
                var loff = off + 1;
                while (loff + 1 <= off + 1 + list_len and loff + 1 <= ext_end) {
                    const proto_len = data[loff];
                    loff += 1;
                    if (loff + proto_len <= ext_end) {
                        result.append(data[loff..][0..proto_len]) catch {};
                    }
                    loff += proto_len;
                }
            }
        }
        off += ext_data_len;
    }

    return ClientHelloParsed{ .alpn_protocols = result, .supports_tls13 = supports_tls13, .cipher_suites = cipher_suites_list };
}

fn buildServerHello13(
    out: []u8,
    cipher_suite: tls.CipherSuite,
    server_random: *const [32]u8,
    server_public_key: *const [32]u8,
    legacy_session_id: *const [32]u8,
) usize {
    var off: usize = 0;
    out[0] = 2; // ServerHello
    off = 4;
    // legacy_version
    mem.writeInt(u16, out[off..][0..2], @intFromEnum(tls.ProtocolVersion.tls_1_2), .big);
    off += 2;
    // random
    @memcpy(out[off..][0..32], server_random);
    off += 32;
    // legacy_session_id_echo
    out[off] = 32;
    off += 1;
    @memcpy(out[off..][0..32], legacy_session_id);
    off += 32;
    // cipher_suite
    mem.writeInt(u16, out[off..][0..2], @intFromEnum(cipher_suite), .big);
    off += 2;
    // legacy_compression_method
    out[off] = 0;
    off += 1;

    // extensions length placeholder (filled after extensions)
    const ext_len_pos = off;
    off += 2;

    const ext_start = off;
    // supported_versions extension
    mem.writeInt(u16, out[off..][0..2], @intFromEnum(tls.ExtensionType.supported_versions), .big);
    off += 2;
    mem.writeInt(u16, out[off..][0..2], 2, .big); // data length = 2 (one u16 version)
    off += 2;
    mem.writeInt(u16, out[off..][0..2], @intFromEnum(tls.ProtocolVersion.tls_1_3), .big);
    off += 2;
    // key_share extension
    mem.writeInt(u16, out[off..][0..2], @intFromEnum(tls.ExtensionType.key_share), .big);
    off += 2;
    const ks_len: u16 = 2 + 2 + 32; // group(2) + key_len(2) + key(32)
    mem.writeInt(u16, out[off..][0..2], ks_len, .big);
    off += 2;
    mem.writeInt(u16, out[off..][0..2], @intFromEnum(tls.NamedGroup.x25519), .big);
    off += 2;
    mem.writeInt(u16, out[off..][0..2], 32, .big); // key_exchange_length
    off += 2;
    @memcpy(out[off..][0..32], server_public_key);
    off += 32;

    // write extensions length
    const ext_data_len: u16 = @intCast(off - ext_start);
    mem.writeInt(u16, out[ext_len_pos..][0..2], ext_data_len, .big);
    // legacy_version(2) + random(32) + session_id_len(1) + session_id(32) + cipher_suite(2) + compression(1) + extensions(2) + ext_data
    const msg_body_len: usize = 2 + 32 + 1 + 32 + 2 + 1 + 2 + ext_data_len;
    const total_len: usize = 1 + 3 + msg_body_len;
    mem.writeInt(u24, out[1..][0..3], @intCast(msg_body_len), .big);
    return total_len;
}

fn buildServerHello12(
    out: []u8,
    cipher_suite: tls.CipherSuite,
    server_random: *const [32]u8,
    legacy_session_id: *const [32]u8,
) usize {
    var off: usize = 0;
    out[0] = 2;
    off = 4;
    // legacy_version
    mem.writeInt(u16, out[off..][0..2], @intFromEnum(tls.ProtocolVersion.tls_1_2), .big);
    off += 2;
    // random
    @memcpy(out[off..][0..32], server_random);
    off += 32;
    // legacy_session_id_echo
    out[off] = 32;
    off += 1;
    @memcpy(out[off..][0..32], legacy_session_id);
    off += 32;
    // cipher_suite
    mem.writeInt(u16, out[off..][0..2], @intFromEnum(cipher_suite), .big);
    off += 2;
    // legacy_compression_method
    out[off] = 0;
    off += 1;

    // extensions length placeholder (filled after extensions)
    const ext_len_pos = off;
    off += 2;

    const ext_start = off;
    mem.writeInt(u16, out[off..][0..2], @intFromEnum(tls.ExtensionType.supported_versions), .big);
    off += 2;
    mem.writeInt(u16, out[off..][0..2], 2, .big);
    off += 2;
    mem.writeInt(u16, out[off..][0..2], @intFromEnum(tls.ProtocolVersion.tls_1_2), .big);
    off += 2;

    const ext_data_len: u16 = @intCast(off - ext_start);
    mem.writeInt(u16, out[ext_len_pos..][0..2], ext_data_len, .big);
    const msg_body_len: usize = 2 + 32 + 1 + 32 + 2 + 1 + 2 + ext_data_len;
    const total_len: usize = 1 + 3 + msg_body_len;
    mem.writeInt(u24, out[1..][0..3], @intCast(msg_body_len), .big);
    return total_len;
}

fn buildServerKeyExchange12(
    out: []u8,
    server_public_key: *const [32]u8,
    client_random: *const [32]u8,
    server_random: *const [32]u8,
    ecdsa_keypair: ?crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair,
) !usize {
    var off: usize = 4;
    out[off] = 3; // ServerKeyExchange
    off += 1;
    off += 2; // skip length (filled in later)
    off += 1; // skip curve type (filled below)

    // ECCurveType: named_curve
    out[4 + 1 + 2] = 3;
    // Named curve
    mem.writeInt(u16, out[off..][0..2], @intFromEnum(tls.NamedGroup.x25519), .big);
    off += 2;
    // Key length
    out[off] = 32;
    off += 1;
    // Public key
    @memcpy(out[off..][0..32], server_public_key);
    off += 32;

    // Sign: client_random(32) + server_random(32) + curve_type(1) + named_group(2) + key_size(1) + public_key(32)
    if (ecdsa_keypair) |kp| {
        // ECDSA P-256 signing
        var sign_msg: [32 + 32 + 1 + 2 + 1 + 32]u8 = undefined;
        @memcpy(sign_msg[0..32], client_random);
        @memcpy(sign_msg[32..][0..32], server_random);
        sign_msg[64] = 3; // curve_type
        mem.writeInt(u16, sign_msg[65..][0..2], @intFromEnum(tls.NamedGroup.x25519), .big);
        sign_msg[67] = 32; // key_size
        @memcpy(sign_msg[68..][0..32], server_public_key);
        const sig = kp.sign(&sign_msg, null) catch return error.TlsHandshakeFailure;
        var der_buf: [crypto.sign.ecdsa.EcdsaP256Sha256.Signature.der_encoded_length_max]u8 = undefined;
        const der_sig = sig.toDer(&der_buf);
        mem.writeInt(u16, out[off..][0..2], @intFromEnum(tls.SignatureScheme.ecdsa_secp256r1_sha256), .big);
        off += 2;
        mem.writeInt(u16, out[off..][0..2], @intCast(der_sig.len), .big);
        off += 2;
        @memcpy(out[off..][0..der_sig.len], der_sig);
        off += der_sig.len;
    } else {
        // No signing key available — cannot sign
        return error.TlsHandshakeFailure;
    }

    // Fill in the ServerKeyExchange body length
    const msg_body_len = off - 4;
    mem.writeInt(u24, out[1..][0..3], @intCast(msg_body_len), .big);
    return off;
}

fn selectCipherSuite13(client_list: []const tls.CipherSuite) ?tls.CipherSuite {
    const preferred = [_]tls.CipherSuite{
        .CHACHA20_POLY1305_SHA256,
        .AES_128_GCM_SHA256,
        .AES_256_GCM_SHA384,
    };
    for (preferred) |server_cs| {
        for (client_list) |client_cs| {
            if (server_cs == client_cs) return server_cs;
        }
    }
    return null;
}

fn selectCipherSuite12(client_list: []const tls.CipherSuite) ?tls.CipherSuite {
    const preferred = [_]tls.CipherSuite{
        .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
        .ECDHE_RSA_WITH_AES_128_GCM_SHA256,
        .ECDHE_RSA_WITH_AES_256_GCM_SHA384,
    };
    for (preferred) |server_cs| {
        for (client_list) |client_cs| {
            if (server_cs == client_cs) return server_cs;
        }
    }
    return null;
}

pub fn acceptServer(
    allocator: Allocator,
    socket: *Socket,
    server_alpn: []const []const u8,
    server_tls: ?ServerTlsConfig,
) !Connection {
    dbg.entry("TLS_SRV", "acceptServer");
    var conn = Connection{
        .allocator = allocator,
        .socket = socket,
        .is_server = true,
        .connected = true,
    };

    var buf: [4096]u8 = undefined;
    const ch_data = try tls_mod.readTlsRecord(socket, &buf);

    const parsed = parseClientHelloExtensions(ch_data);

    dbg.log("TLS_SRV", "ClientHello: tls13={any}, cipher_count={d}", .{ parsed.supports_tls13, parsed.cipher_suites.len });

    if (parsed.supports_tls13) {
        if (acceptServerTls13(&conn, socket, ch_data, &parsed, server_alpn, server_tls, &buf)) |result| {
            return result;
        } else |_| {}
    }

    return try acceptServerTls12(&conn, socket, ch_data, &parsed, server_alpn, server_tls, &buf);
}

fn acceptServerTls13(
    conn: *Connection,
    socket: *Socket,
    ch_data: []const u8,
    parsed: *const ClientHelloParsed,
    server_alpn: []const []const u8,
    server_tls: ?ServerTlsConfig,
    buf: *[4096]u8,
) !Connection {
    var cs_list: [32]tls.CipherSuite = undefined;
    var cs_count: usize = 0;
    for (parsed.cipher_suites.slice()) |cs| {
        if (cs_count < cs_list.len) {
            cs_list[cs_count] = cs;
            cs_count += 1;
        }
    }
    const negotiated_cs = selectCipherSuite13(cs_list[0..cs_count]) orelse return error.TlsHandshakeFailure;

    dbg.log("TLS_SRV", "TLS 1.3 negotiated cipher={any}", .{negotiated_cs});

    if (negotiated_cs == .AES_256_GCM_SHA384) {
        return acceptServerTls13Comptime(conn, socket, ch_data, parsed, server_alpn, server_tls, buf, negotiated_cs, 48);
    } else {
        return acceptServerTls13Comptime(conn, socket, ch_data, parsed, server_alpn, server_tls, buf, negotiated_cs, 32);
    }
}

fn acceptServerTls13Comptime(
    conn: *Connection,
    socket: *Socket,
    ch_data: []const u8,
    parsed: *const ClientHelloParsed,
    server_alpn: []const []const u8,
    server_tls: ?ServerTlsConfig,
    buf: *[4096]u8,
    negotiated_cs: tls.CipherSuite,
    comptime hash_len: usize,
) !Connection {
    // BUG 2 fix: client_random is at offset 6 in the ClientHello body
    var client_random: [32]u8 = undefined;
    if (ch_data.len >= 38) {
        @memcpy(&client_random, ch_data[6..38]);
    } else {
        std.Io.Threaded.global_single_threaded.io().random(&client_random);
    }

    var server_random: [32]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&server_random);

    const kp = crypto.dh.X25519.KeyPair.generate(std.Io.Threaded.global_single_threaded.io());
    var server_public_key: [32]u8 = kp.public_key;

    // BUG 3 fix: parse key_share extension to find X25519 client public key
    const client_public_key_ptr = findX25519ClientKey(ch_data) orelse {
        return error.TlsKeyExchangeFailed;
    };

    const shared_secret = crypto.dh.X25519.scalarmult(kp.secret_key, client_public_key_ptr.*) catch {
        return error.TlsKeyExchangeFailed;
    };

    // BUG 4 fix: transcript must include ClientHello + ServerHello
    var transcript: [4096]u8 = undefined;
    var transcript_len: usize = 0;
    // Add ClientHello to transcript
    @memcpy(transcript[transcript_len..][0..ch_data.len], ch_data);
    transcript_len += ch_data.len;

    // Generate and send ServerHello - echo client's session_id
    var legacy_session_id: [32]u8 = undefined;
    if (extractClientSessionId(ch_data)) |sid| {
        legacy_session_id = sid;
    } else {
        std.Io.Threaded.global_single_threaded.io().random(&legacy_session_id);
    }
    const sh_len = buildServerHello13(buf, negotiated_cs, &server_random, &server_public_key, &legacy_session_id);
    try tls_mod.sendTlsHandshakeRecord(socket, buf[0..sh_len]);
    try tls_mod.sendTlsChangeCipherSpec(socket);
    dbg.log("TLS_SRV", "ServerHello sent, {d} bytes", .{sh_len});

    // Add ServerHello to transcript
    @memcpy(transcript[transcript_len..][0..sh_len], buf[0..sh_len]);
    transcript_len += sh_len;

    const handshake_secret = tls_mod.deriveHandshakeSecret13(&shared_secret, hash_len);

    dbg.log("TLS_SRV", "handshake secret derived, hash_len={d}", .{hash_len});

    // Derive handshake traffic keys using transcript hash
    var sh_hash_buf: [hash_len]u8 = undefined;
    if (hash_len == 32) {
        var h = crypto.hash.sha2.Sha256.init(.{});
        h.update(transcript[0..transcript_len]);
        h.final(&sh_hash_buf);
    } else {
        var h = crypto.hash.sha2.Sha384.init(.{});
        h.update(transcript[0..transcript_len]);
        h.final(&sh_hash_buf);
    }
    const sh_hash = sh_hash_buf[0..hash_len];

    const server_hs_traffic_secret = tls_mod.hkdfExpandLabel(&handshake_secret, "s hs traffic", sh_hash, hash_len);

    const hs_keys = tls_mod.deriveTrafficKeys13(&server_hs_traffic_secret);

    // Send EncryptedExtensions
    var ee_msg: [256]u8 = undefined;
    ee_msg[0] = 8; // encrypted_extensions handshake type
    mem.writeInt(u24, ee_msg[1..][0..3], 2, .big); // body length = 2 (extensions length field)
    mem.writeInt(u16, ee_msg[4..][0..2], 0, .big); // extensions length = 0
    const ee_len: usize = 6;
    try tls_mod.sendTls13EncryptedHandshake(socket, ee_msg[0..ee_len], &hs_keys.key, &hs_keys.iv, &conn.hs_write_seq, negotiated_cs);

    @memcpy(transcript[transcript_len..][0..ee_len], ee_msg[0..ee_len]);
    transcript_len += ee_len;

    // Send Certificate (TLS 1.3 format)
    var cert_msg: [2048]u8 = undefined;
    cert_msg[0] = 11;
    var cert_off: usize = 4;
    // TLS 1.3 Certificate body starts with cert_request_context_len (= 0)
    cert_msg[cert_off] = 0;
    cert_off += 1;
    // Placeholder for total certificates_list length (u24)
    const certs_list_len_pos = cert_off;
    cert_off += 3;
    if (server_tls) |tls_cfg| {
        for (tls_cfg.cert_chain_der) |cert| {
            // Each CertificateEntry: cert_data_length(u24) + cert_data + extensions_length(u16) + extensions
            const copy_len = @min(cert.len, 2048 - cert_off - 3 - 2);
            mem.writeInt(u24, cert_msg[cert_off..][0..3], @intCast(copy_len), .big);
            cert_off += 3;
            @memcpy(cert_msg[cert_off..][0..copy_len], cert[0..copy_len]);
            cert_off += copy_len;
            // TLS 1.3 extensions per cert entry (empty)
            mem.writeInt(u16, cert_msg[cert_off..][0..2], 0, .big);
            cert_off += 2;
        }
    }
    // Fill in total certificates_list length
    const certs_list_len = cert_off - certs_list_len_pos - 3;
    mem.writeInt(u24, cert_msg[certs_list_len_pos..][0..3], @intCast(certs_list_len), .big);
    const cert_msg_body = cert_off - 4;
    mem.writeInt(u24, cert_msg[1..][0..3], @intCast(cert_msg_body), .big);
    try tls_mod.sendTls13EncryptedHandshake(socket, cert_msg[0..cert_off], &hs_keys.key, &hs_keys.iv, &conn.hs_write_seq, negotiated_cs);

    @memcpy(transcript[transcript_len..][0..cert_off], cert_msg[0..cert_off]);
    transcript_len += cert_off;

    // BUG 6 fix: CertificateVerify — sign the transcript hash with the server private key
    var cv_msg: [512]u8 = undefined;
    cv_msg[0] = 15;

    // TLS 1.3 CertificateVerify message for ECDSA:
    // " " ** 64 + "TLS 1.3, server CertificateVerify\x00" + Hash(transcript)
    const ecdsa_p256 = crypto.sign.ecdsa.EcdsaP256Sha256;
    if (server_tls) |tls_cfg| {
        if (tls_cfg.ecdsa_keypair) |ecdsa_kp| {
            // Sign using ECDSA P-256
            // Build the data to sign: " " ** 64 + "TLS 1.3, server CertificateVerify\x00" + Hash(transcript)
            var sign_data: [64 + 34 + hash_len]u8 = undefined;
            @memset(sign_data[0..64], ' ');
            const ctx_str = "TLS 1.3, server CertificateVerify\x00";
            @memcpy(sign_data[64..][0..ctx_str.len], ctx_str);
            if (hash_len == 32) {
                var h = crypto.hash.sha2.Sha256.init(.{});
                h.update(transcript[0..transcript_len]);
                h.final(sign_data[64 + ctx_str.len ..][0..32]);
            } else {
                var h = crypto.hash.sha2.Sha384.init(.{});
                h.update(transcript[0..transcript_len]);
                h.final(sign_data[64 + ctx_str.len ..][0..48]);
            }
            const sig = ecdsa_kp.sign(sign_data[0 .. 64 + ctx_str.len + hash_len], null) catch return error.TlsHandshakeFailure;
            var der_buf: [ecdsa_p256.Signature.der_encoded_length_max]u8 = undefined;
            const der_sig = sig.toDer(&der_buf);
            mem.writeInt(u16, cv_msg[4..][0..2], @intFromEnum(tls.SignatureScheme.ecdsa_secp256r1_sha256), .big);
            mem.writeInt(u16, cv_msg[6..][0..2], @intCast(der_sig.len), .big);
            @memcpy(cv_msg[8..][0..der_sig.len], der_sig);
            const cv_len: usize = 8 + der_sig.len;
            mem.writeInt(u24, cv_msg[1..][0..3], @intCast(cv_len - 4), .big);
            try tls_mod.sendTls13EncryptedHandshake(socket, cv_msg[0..cv_len], &hs_keys.key, &hs_keys.iv, &conn.hs_write_seq, negotiated_cs);
            @memcpy(transcript[transcript_len..][0..cv_len], cv_msg[0..cv_len]);
            transcript_len += cv_len;
        } else {
            // Fallback: no private key available, send empty signature (will fail verification)
            mem.writeInt(u16, cv_msg[4..][0..2], @intFromEnum(tls.SignatureScheme.rsa_pkcs1_sha256), .big);
            mem.writeInt(u16, cv_msg[6..][0..2], 0, .big);
            const cv_len: usize = 8;
            mem.writeInt(u24, cv_msg[1..][0..3], @intCast(cv_len - 4), .big);
            try tls_mod.sendTls13EncryptedHandshake(socket, cv_msg[0..cv_len], &hs_keys.key, &hs_keys.iv, &conn.hs_write_seq, negotiated_cs);
            @memcpy(transcript[transcript_len..][0..cv_len], cv_msg[0..cv_len]);
            transcript_len += cv_len;
        }
    } else {
        mem.writeInt(u16, cv_msg[4..][0..2], @intFromEnum(tls.SignatureScheme.rsa_pkcs1_sha256), .big);
        mem.writeInt(u16, cv_msg[6..][0..2], 0, .big);
        const cv_len: usize = 8;
        mem.writeInt(u24, cv_msg[1..][0..3], @intCast(cv_len - 4), .big);
        try tls_mod.sendTls13EncryptedHandshake(socket, cv_msg[0..cv_len], &hs_keys.key, &hs_keys.iv, &conn.hs_write_seq, negotiated_cs);
        @memcpy(transcript[transcript_len..][0..cv_len], cv_msg[0..cv_len]);
        transcript_len += cv_len;
    }

    // BUG 5 fix: Finished MAC must be HMAC(key, transcript_hash), not HMAC(key, transcript)
    // finished_key = HKDF-Expand-Label(server_hs_traffic_secret, "finished", "", hash_len)
    const finished_key = tls_mod.hkdfExpandLabel(&server_hs_traffic_secret, "finished", "", hash_len);
    var verify_data: [hash_len]u8 = undefined;
    if (hash_len == 32) {
        var h = crypto.hash.sha2.Sha256.init(.{});
        h.update(transcript[0..transcript_len]);
        var th: [32]u8 = undefined;
        h.final(&th);
        HmacSha256.create(&verify_data, &th, &finished_key);
    } else {
        var h = crypto.hash.sha2.Sha384.init(.{});
        h.update(transcript[0..transcript_len]);
        var th: [48]u8 = undefined;
        h.final(&th);
        HmacSha384.create(&verify_data, &th, &finished_key);
    }

    var fin_msg: [64]u8 = undefined;
    fin_msg[0] = 20;
    mem.writeInt(u24, fin_msg[1..][0..3], hash_len, .big);
    const fin_len: usize = 4 + hash_len;
    @memcpy(fin_msg[4..][0..hash_len], &verify_data);
    try tls_mod.sendTls13EncryptedHandshake(socket, fin_msg[0..fin_len], &hs_keys.key, &hs_keys.iv, &conn.hs_write_seq, negotiated_cs);

    @memcpy(transcript[transcript_len..][0..fin_len], fin_msg[0..fin_len]);
    transcript_len += fin_len;

    // Read and skip client's CCS record before reading client Finished
    {
        const _ccs_record = try tls_mod.readTlsRecord(socket, buf);
        _ = _ccs_record;
    }

    // BUG 10 fix: Read client's Finished message using client handshake traffic keys
    const client_hs_traffic_secret = tls_mod.hkdfExpandLabel(&handshake_secret, "c hs traffic", sh_hash, hash_len);
    const client_hs_keys = tls_mod.deriveTrafficKeys13(&client_hs_traffic_secret);
    var hs_read_seq: u64 = 0;
    const client_fin_data = tls_mod.readTls13EncryptedHandshake(socket, buf, &client_hs_keys.key, &client_hs_keys.iv, &hs_read_seq, negotiated_cs) catch return error.TlsHandshakeFailure;
    if (client_fin_data.len < 4 + hash_len) return error.TlsHandshakeFailure;
    // Verify client Finished MAC
    // client_finished_key = HKDF-Expand-Label(client_hs_traffic_secret, "finished", "", hash_len)
    const client_finished_key = tls_mod.hkdfExpandLabel(&client_hs_traffic_secret, "finished", "", hash_len);
    var expected_client_verify: [hash_len]u8 = undefined;
    if (hash_len == 32) {
        var h = crypto.hash.sha2.Sha256.init(.{});
        h.update(transcript[0..transcript_len]);
        var th: [32]u8 = undefined;
        h.final(&th);
        HmacSha256.create(&expected_client_verify, &th, &client_finished_key);
    } else {
        var h = crypto.hash.sha2.Sha384.init(.{});
        h.update(transcript[0..transcript_len]);
        var th: [48]u8 = undefined;
        h.final(&th);
        HmacSha384.create(&expected_client_verify, &th, &client_finished_key);
    }
    if (!mem.eql(u8, client_fin_data[4..][0..hash_len], &expected_client_verify)) {
        return error.TlsDecryptError;
    }
    dbg.log("TLS_SRV", "client Finished MAC verified", .{});

    // TLS 1.3 master secret derivation:
    // ap_derived_secret = HKDF-Expand-Label(handshake_secret, "derived", Hash(""), hash_len)
    // master_secret = HKDF-Extract(ap_derived_secret, zeros)
    const master_secret = ms_blk: {
        // Compute Hash("") for context
        const empty_hash_val: [hash_len]u8 = if (hash_len == 32) eh_blk: {
            var h = crypto.hash.sha2.Sha256.init(.{});
            var r: [32]u8 = undefined;
            h.final(&r);
            break :eh_blk r;
        } else eh_blk: {
            var h = crypto.hash.sha2.Sha384.init(.{});
            var r: [48]u8 = undefined;
            h.final(&r);
            break :eh_blk r;
        };
        const ap_derived = tls_mod.hkdfExpandLabel(&handshake_secret, "derived", &empty_hash_val, hash_len);
        const zero_bytes: [hash_len]u8 = .{0} ** hash_len;
        // hkdfExtract(ikm, salt) = HKDF-Extract(salt, ikm)
        // We want HKDF-Extract(ap_derived, zeros) = hkdfExtract(zeros, ap_derived)
        break :ms_blk tls_mod.hkdfExtract(&zero_bytes, &ap_derived, hash_len);
    };

    var hs_transcript_hash_buf: [hash_len]u8 = undefined;
    if (hash_len == 32) {
        var h = crypto.hash.sha2.Sha256.init(.{});
        h.update(transcript[0..transcript_len]);
        h.final(&hs_transcript_hash_buf);
    } else {
        var h = crypto.hash.sha2.Sha384.init(.{});
        h.update(transcript[0..transcript_len]);
        h.final(&hs_transcript_hash_buf);
    }
    const transcript_hash = hs_transcript_hash_buf[0..hash_len];

    const server_app_traffic_secret = tls_mod.hkdfExpandLabel(&master_secret, "s ap traffic", transcript_hash, hash_len);
    const client_app_traffic_secret = tls_mod.hkdfExpandLabel(&master_secret, "c ap traffic", transcript_hash, hash_len);

    const server_app_keys = tls_mod.deriveTrafficKeys13(&server_app_traffic_secret);
    const client_app_keys = tls_mod.deriveTrafficKeys13(&client_app_traffic_secret);

    conn.app_write_key = server_app_keys.key;
    conn.app_write_iv = server_app_keys.iv;
    conn.app_read_key = client_app_keys.key;
    conn.app_read_iv = client_app_keys.iv;
    conn.tls_version = .tls_1_3;
    conn.cipher_suite = negotiated_cs;
    dbg.log("TLS_SRV", "TLS 1.3 handshake complete, cipher={any}", .{negotiated_cs});

    for (server_alpn) |sp| {
        for (parsed.alpn_protocols.slice()) |cp| {
            if (mem.eql(u8, sp, cp)) {
                conn.negotiated_alpn.set(sp);
                break;
            }
        }
    }

    return conn.*;
}

fn acceptServerTls12(
    conn: *Connection,
    socket: *Socket,
    ch_data: []const u8,
    parsed: *const ClientHelloParsed,
    server_alpn: []const []const u8,
    server_tls: ?ServerTlsConfig,
    buf: *[4096]u8,
) !Connection {
    var client_random: [32]u8 = undefined;
    if (ch_data.len >= 38) {
        @memcpy(&client_random, ch_data[6..38]);
    } else {
        std.Io.Threaded.global_single_threaded.io().random(&client_random);
    }

    var server_random: [32]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&server_random);

    var legacy_session_id: [32]u8 = undefined;
    if (extractClientSessionId(ch_data)) |sid| {
        legacy_session_id = sid;
    } else {
        std.Io.Threaded.global_single_threaded.io().random(&legacy_session_id);
    }

    var cs_list: [32]tls.CipherSuite = undefined;
    var cs_count: usize = 0;
    for (parsed.cipher_suites.slice()) |cs| {
        if (cs_count < cs_list.len) {
            cs_list[cs_count] = cs;
            cs_count += 1;
        }
    }
    const negotiated_cs = selectCipherSuite12(cs_list[0..cs_count]) orelse return error.TlsHandshakeFailure;

    dbg.log("TLS_SRV", "TLS 1.2 negotiated cipher={any}", .{negotiated_cs});

    const sh_len = buildServerHello12(buf, negotiated_cs, &server_random, &legacy_session_id);
    try tls_mod.sendTlsHandshakeRecord(socket, buf[0..sh_len]);

    // Build handshake transcript: all handshake messages (excluding record headers)
    var hs_transcript: [4096]u8 = undefined;
    var hs_transcript_len: usize = 0;
    @memcpy(hs_transcript[hs_transcript_len..][0..sh_len], buf[0..sh_len]);
    hs_transcript_len += sh_len;

    if (server_tls) |tls_cfg| {
        if (tls_cfg.cert_chain_der.len > 0) {
            var cert_msg: [2048]u8 = undefined;
            cert_msg[0] = 11;
            var off: usize = 4;
            var total_cert_body: usize = 0;
            for (tls_cfg.cert_chain_der) |cert| {
                mem.writeInt(u24, cert_msg[off..][0..3], @intCast(cert.len), .big);
                off += 3;
                const copy_len = @min(cert.len, 2048 - off);
                @memcpy(cert_msg[off..][0..copy_len], cert[0..copy_len]);
                off += copy_len;
                total_cert_body += 3 + cert.len;
            }
            mem.writeInt(u24, cert_msg[1..][0..3], @intCast(total_cert_body), .big);
            @memcpy(hs_transcript[hs_transcript_len..][0..off], cert_msg[0..off]);
            hs_transcript_len += off;
            try tls_mod.sendTlsHandshakeRecord(socket, cert_msg[0..off]);
        }
    }

    const kp = crypto.dh.X25519.KeyPair.generate(std.Io.Threaded.global_single_threaded.io());

    var ske_out: [1024]u8 = undefined;
    const ske_len = try buildServerKeyExchange12(&ske_out, &kp.public_key, &client_random, &server_random, if (server_tls) |tls_cfg| tls_cfg.ecdsa_keypair else null);
    @memcpy(hs_transcript[hs_transcript_len..][0..ske_len], ske_out[0..ske_len]);
    hs_transcript_len += ske_len;
    try tls_mod.sendTlsHandshakeRecord(socket, ske_out[0..ske_len]);

    var shd_msg: [4]u8 = undefined;
    shd_msg[0] = 14;
    shd_msg[1] = 0;
    shd_msg[2] = 0;
    shd_msg[3] = 0;
    @memcpy(hs_transcript[hs_transcript_len..][0..4], &shd_msg);
    hs_transcript_len += 4;
    try tls_mod.sendTlsHandshakeRecord(socket, &shd_msg);

    const cke_data = try tls_mod.readTlsRecord(socket, buf);
    if (cke_data.len < 5) return error.TlsHandshakeFailure;
    const client_pub_key: [32]u8 = cke_data[cke_data.len - 32 ..][0..32].*;

    const shared_secret = crypto.dh.X25519.scalarmult(kp.secret_key, client_pub_key) catch return error.TlsKeyExchangeFailed;

    // Store ClientKeyExchange in handshake transcript (including handshake header)
    @memcpy(hs_transcript[hs_transcript_len..][0..cke_data.len], cke_data);
    hs_transcript_len += cke_data.len;

    _ = try tls_mod.readTlsRecord(socket, buf); // ChangeCipherSpec (not in handshake hash)

    const cf_data = try tls_mod.readTlsRecord(socket, buf);
    // Store Client Finished in handshake transcript
    @memcpy(hs_transcript[hs_transcript_len..][0..cf_data.len], cf_data);
    hs_transcript_len += cf_data.len;

    const use_sha384 = negotiated_cs == .ECDHE_RSA_WITH_AES_256_GCM_SHA384;

    var master_secret_256: [32]u8 = undefined;
    var master_secret_384: [48]u8 = undefined;
    if (use_sha384) {
        var padded_secret: [48]u8 = .{0} ** 48;
        @memcpy(padded_secret[0..32], &shared_secret);
        master_secret_384 = tls_mod.deriveMasterSecret384(&padded_secret, &client_random, &server_random);
    } else {
        master_secret_256 = tls_mod.deriveMasterSecret256(&shared_secret, &client_random, &server_random);
    }

    var key_block_buf: [104]u8 = undefined;
    if (use_sha384) {
        const kb = tls_mod.deriveKeyBlock384(&master_secret_384, &server_random, &client_random, 104);
        @memcpy(&key_block_buf, &kb);
    } else {
        const kb = tls_mod.deriveKeyBlock256(&master_secret_256, &server_random, &client_random, 72);
        @memcpy(key_block_buf[0..72], &kb);
    }

    conn.app_write_key = key_block_buf[0..32].*;
    conn.app_write_iv = key_block_buf[40..][0..12].*;
    conn.app_read_key = key_block_buf[32..][0..32].*;
    conn.app_read_iv = key_block_buf[72..][0..12].*;

    tls_mod.sendTlsChangeCipherSpec(socket) catch return error.WriteFailed;

    var verify_data: [12]u8 = undefined;
    if (use_sha384) {
        var finished_key: [48]u8 = undefined;
        HmacSha384.create(&finished_key, "server finished", &master_secret_384);
        var finished_hash: [48]u8 = undefined;
        HmacSha384.create(&finished_hash, hs_transcript[0..hs_transcript_len], &finished_key);
        @memcpy(&verify_data, finished_hash[0..12]);
    } else {
        var finished_key: [32]u8 = undefined;
        HmacSha256.create(&finished_key, "server finished", &master_secret_256);
        var finished_hash: [32]u8 = undefined;
        HmacSha256.create(&finished_hash, hs_transcript[0..hs_transcript_len], &finished_key);
        @memcpy(&verify_data, finished_hash[0..12]);
    }

    var fin_msg: [17]u8 = undefined;
    fin_msg[0] = 20;
    fin_msg[1] = 0;
    fin_msg[2] = 0;
    fin_msg[3] = 12;
    @memcpy(fin_msg[4..][0..12], &verify_data);
    try tls_mod.sendTlsHandshakeRecord(socket, &fin_msg);

    conn.tls_version = .tls_1_2;
    conn.cipher_suite = negotiated_cs;
    dbg.log("TLS_SRV", "TLS 1.2 handshake complete, cipher={any}", .{negotiated_cs});

    for (server_alpn) |sp| {
        for (parsed.alpn_protocols.slice()) |cp| {
            if (mem.eql(u8, sp, cp)) {
                conn.negotiated_alpn.set(sp);
                break;
            }
        }
    }

    return conn.*;
}
