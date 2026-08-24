const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const crypto = std.crypto;
const tls = std.crypto.tls;

const Socket = @import("../net/socket.zig").Socket;
const tls_mod = @import("tls.zig");
const alpn = @import("alpn.zig");

const Connection = tls_mod.Connection;
const ServerTLSConfig = tls_mod.ServerTLSConfig;

const HmacSha256 = crypto.auth.hmac.sha2.HmacSha256;
const HmacSha384 = crypto.auth.hmac.sha2.HmacSha384;

/// Handshake tracing gate (disabled; enable locally when debugging).
const tls_debug = false;

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
    sni_hostname: ?[]const u8 = null,
};

/// Extract the client's legacy_session_id from the ClientHello (any length).
fn extractClientSessionId(ch_data: []const u8) ?[]const u8 {
    if (ch_data.len < 4 + 2 + 32 + 1) return null;
    const session_id_len = ch_data[4 + 2 + 32]; // after handshake_hdr + version + random
    const start = 4 + 2 + 32 + 1;
    if (session_id_len > 32) return null;
    if (ch_data.len < start + session_id_len) return null;
    return ch_data[start .. start + session_id_len];
}

/// Find a key_share entry for `group_id` with exactly `expected_len` bytes
/// in the ClientHello's key_share extension.
fn findClientKeyShare(ch_data: []const u8, comptime group_id: u16, comptime expected_len: usize) ?[]const u8 {
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
            // ClientHello key_share data begins with the uint16
            // client_shares LIST LENGTH (RFC 8446 �4.2.8).
            var koff = off + 2;
            const shares_len: usize = mem.readInt(u16, ch_data[off..][0..2], .big);
            var shares_end = off + 2 + shares_len;
            if (shares_end > off + ext_data_len) shares_end = off + ext_data_len;
            if (shares_end > ch_data.len) shares_end = ch_data.len;
            while (koff + 4 <= shares_end) {
                const group = mem.readInt(u16, ch_data[koff..][0..2], .big);
                const key_len = mem.readInt(u16, ch_data[koff + 2 ..][0..2], .big);
                koff += 4;
                if (group == group_id and key_len == expected_len and koff + expected_len <= ch_data.len) {
                    return ch_data[koff..][0..expected_len];
                }
                koff += key_len;
            }
        }
        off += ext_data_len;
    }
    return null;
}

/// Extract the pure X25519 public key from the ClientHello key_share
/// extension, if the client offered one.
fn findX25519ClientKey(ch_data: []const u8) ?[32]u8 {
    const s = findClientKeyShare(ch_data, @intFromEnum(tls.NamedGroup.x25519), 32) orelse return null;
    return s[0..32].*;
}

/// Key-exchange flavour negotiated for a TLS 1.3 handshake.
pub const Tls13Kex = enum {
    /// Classic ECDHE with pure X25519 (client share: 32 bytes).
    x25519,
    /// X25519MLKEM768 (group 0x4588): final FIPS-203 ML-KEM-768.
    x25519mlkem768,
};

/// X25519MLKEM768 hybrid composition (group 0x4588, draft-ietf-tls-ecdhe-mlkem):
/// client share = kem_ek(1184) || x25519_pub(32); server share =
/// kem_ct(1088) || x25519_pub(32); handshake input = x25519_ss || kem_ss.
fn computeHybridKeyShare(
    comptime Kem: type,
    client_share: *const [1216]u8,
    io: std.Io,
    shared_out: *[64]u8,
    server_share_out: *[1152]u8,
) !usize {
    // KEM leg first (draft-ietf-tls-ecdhe-mlkem / draft-campagna-tls-ecdhe-kyber):
    var ek: [1184]u8 = undefined;
    @memcpy(&ek, client_share[0..1184]);
    const pk = Kem.PublicKey.fromBytes(&ek) catch return error.TlsKeyExchangeFailed;
    const enc = pk.encaps(io);
    @memcpy(shared_out[0..32], &enc.shared_secret);

    const kp = crypto.dh.X25519.KeyPair.generate(io);
    const ss1 = crypto.dh.X25519.scalarmult(kp.secret_key, client_share[1184..1216].*) catch return error.TlsKeyExchangeFailed;
    @memcpy(shared_out[32..64], &ss1);

    @memcpy(server_share_out[0..1088], &enc.ciphertext);
    @memcpy(server_share_out[1088..1120], &kp.public_key);
    return 1120;
}

fn parseClientHelloExtensions(data: []const u8) ClientHelloParsed {
    var result = BoundedArray([]const u8, 8){};
    var supports_tls13 = false;
    var cipher_suites_list = BoundedArray(tls.CipherSuite, 32){};
    var sni_hostname: ?[]const u8 = null;

    if (data.len < 44) return ClientHelloParsed{ .alpn_protocols = result, .supports_tls13 = supports_tls13, .cipher_suites = cipher_suites_list, .sni_hostname = sni_hostname };

    var off: usize = 4 + 2 + 32;
    if (off >= data.len) return ClientHelloParsed{ .alpn_protocols = result, .supports_tls13 = supports_tls13, .cipher_suites = cipher_suites_list, .sni_hostname = sni_hostname };

    const session_id_len = data[off];
    off += 1 + session_id_len;

    if (off + 2 > data.len) return ClientHelloParsed{ .alpn_protocols = result, .supports_tls13 = supports_tls13, .cipher_suites = cipher_suites_list, .sni_hostname = sni_hostname };
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

    if (off >= data.len) return ClientHelloParsed{ .alpn_protocols = result, .supports_tls13 = supports_tls13, .cipher_suites = cipher_suites_list, .sni_hostname = sni_hostname };
    const comp_len = data[off];
    off += 1 + comp_len;

    if (off + 2 > data.len) return ClientHelloParsed{ .alpn_protocols = result, .supports_tls13 = supports_tls13, .cipher_suites = cipher_suites_list, .sni_hostname = sni_hostname };
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
            // ALPN extension
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
        } else if (ext_type == @intFromEnum(tls.ExtensionType.server_name)) {
            // SNI extension: server_name_list(2) + name_type(1) + name_len(2) + name
            if (off + 5 <= ext_end) {
                const name_list_len = mem.readInt(u16, data[off..][0..2], .big);
                _ = name_list_len;
                const name_type = data[off + 2];
                if (name_type == 0x00) { // host_name
                    const name_len = mem.readInt(u16, data[off + 3 ..][0..2], .big);
                    if (off + 5 + name_len <= ext_end) {
                        sni_hostname = data[off + 5 ..][0..name_len];
                    }
                }
            }
        }
        off += ext_data_len;
    }

    return ClientHelloParsed{ .alpn_protocols = result, .supports_tls13 = supports_tls13, .cipher_suites = cipher_suites_list, .sni_hostname = sni_hostname };
}

fn buildServerHello13(
    out: []u8,
    cipher_suite: tls.CipherSuite,
    server_random: *const [32]u8,
    key_share_group: u16,
    server_key_share: []const u8,
    legacy_session_id: []const u8,
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
    // legacy_session_id_echo (exact echo of the client's value)
    out[off] = @intCast(legacy_session_id.len);
    off += 1;
    @memcpy(out[off..][0..legacy_session_id.len], legacy_session_id);
    off += legacy_session_id.len;
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
    // supported_versions extension (RFC 8446 §4.2.1 ServerHello form:
    // ext_data = selected_version only)
    mem.writeInt(u16, out[off..][0..2], @intFromEnum(tls.ExtensionType.supported_versions), .big);
    off += 2;
    mem.writeInt(u16, out[off..][0..2], 2, .big); // data length = 2
    off += 2;
    mem.writeInt(u16, out[off..][0..2], @intFromEnum(tls.ProtocolVersion.tls_1_3), .big);
    off += 2;
    // key_share extension (RFC 8446 §4.2.8 ServerHello form: single entry,
    // group(2) + key_exchange_length(2) + key_exchange — NO outer list len)
    mem.writeInt(u16, out[off..][0..2], @intFromEnum(tls.ExtensionType.key_share), .big);
    off += 2;
    const ks_len: u16 = @intCast(4 + server_key_share.len); // group + klen + share
    mem.writeInt(u16, out[off..][0..2], ks_len, .big);
    off += 2;
    mem.writeInt(u16, out[off..][0..2], key_share_group, .big);
    off += 2;
    mem.writeInt(u16, out[off..][0..2], @intCast(server_key_share.len), .big);
    off += 2;
    @memcpy(out[off..][0..server_key_share.len], server_key_share);
    off += server_key_share.len;

    // write extensions length
    const ext_data_len: u16 = @intCast(off - ext_start);
    mem.writeInt(u16, out[ext_len_pos..][0..2], ext_data_len, .big);
    const msg_body_len: usize = off - 4;
    const total_len: usize = off;
    mem.writeInt(u24, out[1..][0..3], @intCast(msg_body_len), .big);
    return total_len;
}

fn buildServerHello12(
    out: []u8,
    cipher_suite: tls.CipherSuite,
    server_random: *const [32]u8,
    legacy_session_id: []const u8,
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
    // legacy_session_id_echo (exact echo of the client's value)
    out[off] = @intCast(legacy_session_id.len);
    off += 1;
    @memcpy(out[off..][0..legacy_session_id.len], legacy_session_id);
    off += legacy_session_id.len;
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
    // renegotiation_info (RFC 5746): empty renegotiated_connection.
    // OpenSSL 3.x aborts with "unsafe legacy renegotiation disabled" when the
    // client offered it and the ServerHello omits it.
    mem.writeInt(u16, out[off..][0..2], 0xff01, .big); // extension_type renegotiation_info
    off += 2;
    mem.writeInt(u16, out[off..][0..2], 1, .big); // data length = 1
    off += 2;
    out[off] = 0; // renegotiated_connection length = 0
    off += 1;
    // ec_point_formats (RFC 4492): uncompressed only.
    mem.writeInt(u16, out[off..][0..2], 0x000b, .big);
    off += 2;
    mem.writeInt(u16, out[off..][0..2], 2, .big); // data length = 2
    off += 2;
    out[off] = 1; // formats list length = 1
    off += 1;
    out[off] = 0; // uncompressed
    off += 1;

    const ext_data_len: u16 = @intCast(off - ext_start);
    mem.writeInt(u16, out[ext_len_pos..][0..2], ext_data_len, .big);
    const msg_body_len: usize = off - 4;
    const total_len: usize = off;
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
    out[0] = 12; // handshake_type = server_key_exchange
    var off: usize = 4; // skip 1 type + 3 length (length filled in later)

    // ECDH params: curve_type(1)=named_curve | named_group(2) | pubkey_len(1) | pubkey
    out[off] = 3; // ECCurveType: named_curve
    off += 1;
    mem.writeInt(u16, out[off..][0..2], @intFromEnum(tls.NamedGroup.x25519), .big);
    off += 2;
    out[off] = 32;
    off += 1;
    @memcpy(out[off..][0..32], server_public_key);
    off += 32;

    // Signed params per RFC 5246 §7.4.3 / RFC 4492:
    //   client_random(32) + server_random(32) + curve_type(1) + named_group(2)
    //   + key_size(1) + public_key(32)
    if (ecdsa_keypair) |kp| {
        var sign_msg: [32 + 32 + 1 + 2 + 1 + 32]u8 = undefined;
        @memcpy(sign_msg[0..32], client_random);
        @memcpy(sign_msg[32..][0..32], server_random);
        sign_msg[64] = 3; // curve_type
        mem.writeInt(u16, sign_msg[65..][0..2], @intFromEnum(tls.NamedGroup.x25519), .big);
        sign_msg[67] = 32; // key_size
        @memcpy(sign_msg[68..][0..32], server_public_key);
        const sig = kp.sign(&sign_msg, null) catch return error.TlsHandshakeFailure;
        // TLS 1.2 ECDSA signature encoding (RFC 4492 §5.4 / RFC 8422):
        //   hash_alg(1)=SHA256(4), signature_alg(1)=ECDSA(3),
        //   signature_length(u16), then a DER-encoded ECDSA-Sig-Value
        //   (ANSI X9.62 SEQUENCE{r,s}).  Raw r||s is TLS 1.3 only!
        var der_buf: [crypto.sign.ecdsa.EcdsaP256Sha256.Signature.der_encoded_length_max]u8 = undefined;
        const der_sig = sig.toDer(&der_buf);
        out[off] = 4; // SHA256
        off += 1;
        out[off] = 3; // ECDSA
        off += 1;
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
    // The server signs with its ECDSA (P-256) key, so only ECDHE_ECDSA
    // suites are valid.  Prefer AEAD suites we implement correctly.
    const preferred = [_]tls.CipherSuite{
        .ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
        .ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
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
    server_tls: ?ServerTLSConfig,
) !Connection {
    var conn = Connection{
        .allocator = allocator,
        .socket = socket,
        .is_server = true,
        .connected = true,
    };

    var buf: [4096]u8 = undefined;
    const ch_data = try tls_mod.readTLSRecord(socket, &buf);

    const parsed = parseClientHelloExtensions(ch_data);

    // TLS 1.3 requires a usable key share.  Modern clients (OpenSSL 3.x,
    // curl, browsers) offer the X25519MLKEM768 hybrid (0x4588) — often as
    // their ONLY share — which we support natively via std.crypto ML-KEM.
    // Clients with only unsupported groups fall through to a clean TLS 1.2
    // handshake instead of corrupting the socket.
    var tls13_kex: ?Tls13Kex = null;
    var hybrid_group: u16 = 0;
    var hybrid_share: [1216]u8 = undefined;
    if (parsed.supports_tls13) {
        // Modern clients use codepoint 0x4588 (X25519MLKEM768); OpenSSL 3.x
        // still emits the legacy 0x11ec codepoint but carries the FINAL
        // FIPS-203 ML-KEM-768 contents — identical wire layout.
        if (findClientKeyShare(ch_data, 0x4588, 1216)) |sh| {
            @memcpy(&hybrid_share, sh);
            hybrid_group = 0x4588;
            tls13_kex = .x25519mlkem768;
        } else if (findClientKeyShare(ch_data, 0x11ec, 1216)) |sh| {
            @memcpy(&hybrid_share, sh);
            hybrid_group = 0x11ec;
            tls13_kex = .x25519mlkem768;
        } else if (findX25519ClientKey(ch_data) != null) {
            // Pure X25519.
            tls13_kex = .x25519;
        }
    }

    if (tls13_kex) |kex| {
        return acceptServerTLS13(&conn, socket, ch_data, &parsed, server_alpn, server_tls, &buf, kex, hybrid_group, &hybrid_share) catch |err| {
            return err;
        };
    }

    return try acceptServerTLS12(&conn, socket, ch_data, &parsed, server_alpn, server_tls, &buf);
}

fn acceptServerTLS13(
    conn: *Connection,
    socket: *Socket,
    ch_data: []const u8,
    parsed: *const ClientHelloParsed,
    server_alpn: []const []const u8,
    server_tls: ?ServerTLSConfig,
    buf: *[4096]u8,
    kex: Tls13Kex,
    hybrid_group: u16,
    hybrid_share: *const [1216]u8,
) !Connection {
    var cs_list: [32]tls.CipherSuite = undefined;
    var cs_count: usize = 0;
    for (parsed.cipher_suites.slice()) |cs| {
        if (cs_count < cs_list.len) {
            cs_list[cs_count] = cs;
            cs_count += 1;
        }
    }
    const negotiated_cs = selectCipherSuite13(cs_list[0..cs_count]) orelse {
        return error.TlsHandshakeFailure;
    };

    if (negotiated_cs == .AES_256_GCM_SHA384) {
        return acceptServerTLS13Comptime(conn, socket, ch_data, parsed, server_alpn, server_tls, buf, negotiated_cs, 48, kex, hybrid_group, hybrid_share);
    } else {
        return acceptServerTLS13Comptime(conn, socket, ch_data, parsed, server_alpn, server_tls, buf, negotiated_cs, 32, kex, hybrid_group, hybrid_share);
    }
}

fn acceptServerTLS13Comptime(
    conn: *Connection,
    socket: *Socket,
    ch_data: []const u8,
    parsed: *const ClientHelloParsed,
    server_alpn: []const []const u8,
    server_tls: ?ServerTLSConfig,
    buf: *[4096]u8,
    negotiated_cs: tls.CipherSuite,
    comptime hash_len: usize,
    kex: Tls13Kex,
    hybrid_group: u16,
    hybrid_share: *const [1216]u8,
) !Connection {
    const io = std.Io.Threaded.global_single_threaded.io();

    var client_random: [32]u8 = undefined;
    if (ch_data.len >= 38) {
        @memcpy(&client_random, ch_data[6..38]);
    } else {
        io.random(&client_random);
    }

    var server_random: [32]u8 = undefined;
    io.random(&server_random);

    // ---- Key exchange -------------------------------------------------------
    // shared_secret feeds HKDF-Extract as the ECDHE input (RFC 8446 §7.1).
    // Classic X25519 yields 32 bytes; the X25519MLKEM768 hybrid concatenates
    // x25519_ss(32) || ml_kem_ss(32) = 64 bytes per draft-ietf-tls-ecdhe-mlkem.
    var shared_secret_buf: [64]u8 = undefined;
    var shared_secret_len: usize = 0;
    var server_share_buf: [1152]u8 = undefined; // max hybrid share = ct(1088)+x_pub(32)
    var server_share_len: usize = 0;
    var key_share_group: u16 = @intFromEnum(tls.NamedGroup.x25519);

    switch (kex) {
        .x25519 => {
            const kp = crypto.dh.X25519.KeyPair.generate(io);
            const client_pub = findX25519ClientKey(ch_data) orelse return error.TlsKeyExchangeFailed;
            const ss = crypto.dh.X25519.scalarmult(kp.secret_key, client_pub) catch return error.TlsKeyExchangeFailed;
            @memcpy(shared_secret_buf[0..32], &ss);
            shared_secret_len = 32;
            @memcpy(server_share_buf[0..32], &kp.public_key);
            server_share_len = 32;
        },
        .x25519mlkem768 => {
            server_share_len = try computeHybridKeyShare(crypto.kem.ml_kem.MLKem768, hybrid_share, io, &shared_secret_buf, &server_share_buf);
            shared_secret_len = 64;
            key_share_group = hybrid_group;
        },
    }
    const shared_secret: []const u8 = shared_secret_buf[0..shared_secret_len];

    // BUG 4 fix: transcript must include ClientHello + ServerHello
    var transcript: [12288]u8 = undefined;
    var transcript_len: usize = 0;
    // Add ClientHello to transcript
    @memcpy(transcript[transcript_len..][0..ch_data.len], ch_data);
    transcript_len += ch_data.len;

    // Generate and send ServerHello - echo client's session_id (snapshot:
    // ch_data aliases buf which the builder overwrites)
    var sid_storage13: [32]u8 = undefined;
    var sid_len13: usize = 0;
    if (extractClientSessionId(ch_data)) |sid| {
        @memcpy(sid_storage13[0..sid.len], sid);
        sid_len13 = sid.len;
    } else {
        io.random(&sid_storage13);
        sid_len13 = sid_storage13.len;
    }
    const legacy_session_id: []const u8 = sid_storage13[0..sid_len13];

    const sh_len = buildServerHello13(buf, negotiated_cs, &server_random, key_share_group, server_share_buf[0..server_share_len], legacy_session_id);
    try tls_mod.sendTLSHandshakeRecord(socket, buf[0..sh_len]);
    try tls_mod.sendTLSChangeCipherSpec(socket);

    // Add ServerHello to transcript
    @memcpy(transcript[transcript_len..][0..sh_len], buf[0..sh_len]);
    transcript_len += sh_len;

    const handshake_secret = tls_mod.deriveHandshakeSecret13(shared_secret, hash_len);

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
    try tls_mod.sendTLS13EncryptedHandshake(socket, ee_msg[0..ee_len], tls_mod.trafficKeyFor(negotiated_cs, &hs_keys), &hs_keys.iv, &conn.hs_write_seq, negotiated_cs);

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
    try tls_mod.sendTLS13EncryptedHandshake(socket, cert_msg[0..cert_off], tls_mod.trafficKeyFor(negotiated_cs, &hs_keys), &hs_keys.iv, &conn.hs_write_seq, negotiated_cs);

    @memcpy(transcript[transcript_len..][0..cert_off], cert_msg[0..cert_off]);
    transcript_len += cert_off;

    // BUG 6 fix: CertificateVerify — sign the transcript hash with the server private key
    var cv_msg: [512]u8 = undefined;
    cv_msg[0] = 15;

    // TLS 1.3 CertificateVerify message for ECDSA:
    // " " ** 64 + "TLS 1.3, server CertificateVerify\x00" + Hash(transcript)
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
            // TLS 1.3 ECDSA signatures are DER-encoded Ecdsa-Sig-Value (same
            // encoding as TLS 1.2); only EdDSA uses fixed-width r||s.
            var der_buf2: [crypto.sign.ecdsa.EcdsaP256Sha256.Signature.der_encoded_length_max]u8 = undefined;
            const wire_sig = sig.toDer(&der_buf2);
            mem.writeInt(u16, cv_msg[4..][0..2], @intFromEnum(tls.SignatureScheme.ecdsa_secp256r1_sha256), .big);
            mem.writeInt(u16, cv_msg[6..][0..2], @intCast(wire_sig.len), .big);
            @memcpy(cv_msg[8..][0..wire_sig.len], wire_sig);
            const cv_len: usize = 8 + wire_sig.len;
            mem.writeInt(u24, cv_msg[1..][0..3], @intCast(cv_len - 4), .big);
            try tls_mod.sendTLS13EncryptedHandshake(socket, cv_msg[0..cv_len], tls_mod.trafficKeyFor(negotiated_cs, &hs_keys), &hs_keys.iv, &conn.hs_write_seq, negotiated_cs);
            @memcpy(transcript[transcript_len..][0..cv_len], cv_msg[0..cv_len]);
            transcript_len += cv_len;
        } else {
            // Fallback: no private key available, send empty signature (will fail verification)
            mem.writeInt(u16, cv_msg[4..][0..2], @intFromEnum(tls.SignatureScheme.rsa_pkcs1_sha256), .big);
            mem.writeInt(u16, cv_msg[6..][0..2], 0, .big);
            const cv_len: usize = 8;
            mem.writeInt(u24, cv_msg[1..][0..3], @intCast(cv_len - 4), .big);
            try tls_mod.sendTLS13EncryptedHandshake(socket, cv_msg[0..cv_len], tls_mod.trafficKeyFor(negotiated_cs, &hs_keys), &hs_keys.iv, &conn.hs_write_seq, negotiated_cs);
            @memcpy(transcript[transcript_len..][0..cv_len], cv_msg[0..cv_len]);
            transcript_len += cv_len;
        }
    } else {
        mem.writeInt(u16, cv_msg[4..][0..2], @intFromEnum(tls.SignatureScheme.rsa_pkcs1_sha256), .big);
        mem.writeInt(u16, cv_msg[6..][0..2], 0, .big);
        const cv_len: usize = 8;
        mem.writeInt(u24, cv_msg[1..][0..3], @intCast(cv_len - 4), .big);
        try tls_mod.sendTLS13EncryptedHandshake(socket, cv_msg[0..cv_len], tls_mod.trafficKeyFor(negotiated_cs, &hs_keys), &hs_keys.iv, &conn.hs_write_seq, negotiated_cs);
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
    try tls_mod.sendTLS13EncryptedHandshake(socket, fin_msg[0..fin_len], tls_mod.trafficKeyFor(negotiated_cs, &hs_keys), &hs_keys.iv, &conn.hs_write_seq, negotiated_cs);

    @memcpy(transcript[transcript_len..][0..fin_len], fin_msg[0..fin_len]);
    transcript_len += fin_len;

    // Read and skip client's CCS record before reading client Finished
    {
        const _ccs_record = try tls_mod.readTLSRecord(socket, buf);
        _ = _ccs_record;
    }

    // BUG 10 fix: Read client's Finished message using client handshake traffic keys
    const client_hs_traffic_secret = tls_mod.hkdfExpandLabel(&handshake_secret, "c hs traffic", sh_hash, hash_len);
    const client_hs_keys = tls_mod.deriveTrafficKeys13(&client_hs_traffic_secret);
    var hs_read_seq: u64 = 0;
    const client_fin_data = tls_mod.readTLS13EncryptedHandshake(socket, buf, tls_mod.trafficKeyFor(negotiated_cs, &client_hs_keys), &client_hs_keys.iv, &hs_read_seq, negotiated_cs) catch return error.TlsHandshakeFailure;
    if (client_fin_data.len < 4 + hash_len) {
        return error.TlsHandshakeFailure;
    }
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

    // Store app keys left-aligned in the fixed 32-byte fields; AES-128 uses
    // its dedicated 16-byte expansion, everything else the 32-byte one.
    var skey: [32]u8 = .{0} ** 32;
    var ckey: [32]u8 = .{0} ** 32;
    switch (negotiated_cs) {
        .AES_128_GCM_SHA256 => {
            @memcpy(skey[0..16], &server_app_keys.key16);
            @memcpy(ckey[0..16], &client_app_keys.key16);
        },
        else => {
            skey = server_app_keys.key32;
            ckey = client_app_keys.key32;
        },
    }

    conn.app_write_key = skey;
    conn.app_write_iv = server_app_keys.iv;
    conn.app_read_key = ckey;
    conn.app_read_iv = client_app_keys.iv;
    conn.tls_version = .tls_1_3;
    conn.cipher_suite = negotiated_cs;
    conn.sni_hostname = parsed.sni_hostname;

    if (alpn.serverNegotiate(server_alpn, parsed.alpn_protocols.slice())) |negotiated| {
        conn.negotiated_alpn.set(negotiated);
    }

    return conn.*;
}

fn acceptServerTLS12(
    conn: *Connection,
    socket: *Socket,
    ch_data: []const u8,
    parsed: *const ClientHelloParsed,
    server_alpn: []const []const u8,
    server_tls: ?ServerTLSConfig,
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

    // Echo the client's exact legacy_session_id (any length up to 32);
    // generate one only when the client sent none.  Snapshot into local
    // storage: ch_data aliases `buf`, which buildServerHello12 overwrites.
    var sid_storage: [32]u8 = undefined;
    var sid_len: usize = 0;
    if (extractClientSessionId(ch_data)) |sid| {
        @memcpy(sid_storage[0..sid.len], sid);
        sid_len = sid.len;
    } else {
        std.Io.Threaded.global_single_threaded.io().random(&sid_storage);
        sid_len = sid_storage.len;
    }
    const legacy_session_id: []const u8 = sid_storage[0..sid_len];

    var cs_list: [32]tls.CipherSuite = undefined;
    var cs_count: usize = 0;
    for (parsed.cipher_suites.slice()) |cs| {
        if (cs_count < cs_list.len) {
            cs_list[cs_count] = cs;
            cs_count += 1;
        }
    }
    const negotiated_cs = selectCipherSuite12(cs_list[0..cs_count]) orelse return error.TlsHandshakeFailure;

    // Seed the handshake transcript with the ClientHello BEFORE reusing
    // `buf`: ch_data aliases buf and buildServerHello12 overwrites it.
    // The TLS 1.2 Finished hash covers ALL handshake messages.
    var hs_transcript: [8192]u8 = undefined;
    var hs_transcript_len: usize = 0;
    if (ch_data.len > hs_transcript.len) return error.TlsHandshakeFailure;
    @memcpy(hs_transcript[0..ch_data.len], ch_data);
    hs_transcript_len = ch_data.len;

    const sh_len = buildServerHello12(buf, negotiated_cs, &server_random, legacy_session_id);
    try tls_mod.sendTLSHandshakeRecord(socket, buf[0..sh_len]);

    @memcpy(hs_transcript[hs_transcript_len..][0..sh_len], buf[0..sh_len]);
    hs_transcript_len += sh_len;

    if (server_tls) |tls_cfg| {
        if (tls_cfg.cert_chain_der.len > 0) {
            var cert_msg: [12288]u8 = undefined;
            cert_msg[0] = 11;
            // RFC 5246: body = certificate_list<0..2^24-1> — ONE u24 length
            // covering ALL entries, each entry being u24 len || DER.
            var off: usize = 7; // hdr(4) + body(3, filled later) + list_len(3)
            const list_len_pos: usize = 4;
            var total_cert_body: usize = 0;
            for (tls_cfg.cert_chain_der) |cert| {
                mem.writeInt(u24, cert_msg[off..][0..3], @intCast(cert.len), .big);
                off += 3;
                const copy_len = @min(cert.len, cert_msg.len - off);
                @memcpy(cert_msg[off..][0..copy_len], cert[0..copy_len]);
                off += copy_len;
                total_cert_body += 3 + copy_len;
            }
            mem.writeInt(u24, cert_msg[list_len_pos..][0..3], @intCast(total_cert_body), .big);
            mem.writeInt(u24, cert_msg[1..][0..3], @intCast(off - 4), .big);
            @memcpy(hs_transcript[hs_transcript_len..][0..off], cert_msg[0..off]);
            hs_transcript_len += off;
            try tls_mod.sendTLSHandshakeRecord(socket, cert_msg[0..off]);
        }
    }

    const kp = crypto.dh.X25519.KeyPair.generate(std.Io.Threaded.global_single_threaded.io());

    var ske_out: [1024]u8 = undefined;
    const ske_len = try buildServerKeyExchange12(&ske_out, &kp.public_key, &client_random, &server_random, if (server_tls) |tls_cfg| tls_cfg.ecdsa_keypair else null);
    @memcpy(hs_transcript[hs_transcript_len..][0..ske_len], ske_out[0..ske_len]);
    hs_transcript_len += ske_len;
    try tls_mod.sendTLSHandshakeRecord(socket, ske_out[0..ske_len]);

    var shd_msg: [4]u8 = undefined;
    shd_msg[0] = 14;
    shd_msg[1] = 0;
    shd_msg[2] = 0;
    shd_msg[3] = 0;
    @memcpy(hs_transcript[hs_transcript_len..][0..4], &shd_msg);
    hs_transcript_len += 4;
    try tls_mod.sendTLSHandshakeRecord(socket, &shd_msg);

    const cke_data = try tls_mod.readTLSRecord(socket, buf);
    // ECDHE ClientKeyExchange: header(4) + point_len(1) + X25519 point(32)
    if (cke_data.len < 4 + 1 + 32) return error.TlsHandshakeFailure;
    const client_pub_key: [32]u8 = cke_data[cke_data.len - 32 ..][0..32].*;

    const shared_secret = crypto.dh.X25519.scalarmult(kp.secret_key, client_pub_key) catch return error.TlsKeyExchangeFailed;

    // Store ClientKeyExchange in handshake transcript (including handshake header)
    @memcpy(hs_transcript[hs_transcript_len..][0..cke_data.len], cke_data);
    hs_transcript_len += cke_data.len;

    // Snapshot BEFORE the client Finished: the client computes its
    // verify_data over all handshake messages up to (not including) its own
    // Finished message.
    const transcript_before_client_fin = hs_transcript_len;

    _ = try tls_mod.readTLSRecord(socket, buf); // ChangeCipherSpec (not in handshake hash)

    const use_sha384 = negotiated_cs == .ECDHE_ECDSA_WITH_AES_256_GCM_SHA384;
    const klen: usize = if (use_sha384) 32 else 16;

    var master_secret_256: [48]u8 = undefined;
    var master_secret_384: [48]u8 = undefined;
    if (use_sha384) {
        // RFC 8422: ECDHE premaster = X25519 shared secret (32 bytes);
        // P_hash accepts any secret length.
        master_secret_384 = tls_mod.deriveMasterSecret384(&shared_secret, &client_random, &server_random);
    } else {
        master_secret_256 = tls_mod.deriveMasterSecret256(&shared_secret, &client_random, &server_random);
    }

    // RFC 5246 §6.3 AEAD key block layout:
    //   client_write_key | server_write_key | client_write_IV(4) | server_write_IV(4)
    var key_block_buf: [72]u8 = undefined;
    if (use_sha384) {
        const kb = tls_mod.deriveKeyBlock384(&master_secret_384, &server_random, &client_random, 72);
        @memcpy(&key_block_buf, &kb);
    } else {
        const kb = tls_mod.deriveKeyBlock256(&master_secret_256, &server_random, &client_random, 40);
        @memcpy(key_block_buf[0..40], &kb);
    }
    var client_write_key: [32]u8 = .{0} ** 32;
    var server_write_key: [32]u8 = .{0} ** 32;
    @memcpy(client_write_key[0..klen], key_block_buf[0..klen]);
    @memcpy(server_write_key[0..klen], key_block_buf[klen .. 2 * klen]);
    var client_write_iv: [12]u8 = .{0} ** 12;
    var server_write_iv: [12]u8 = .{0} ** 12;
    @memcpy(client_write_iv[0..4], key_block_buf[2 * klen ..][0..4]);
    @memcpy(server_write_iv[0..4], key_block_buf[2 * klen + 4 ..][0..4]);

    conn.app_write_key = server_write_key;
    conn.app_write_iv = server_write_iv;
    conn.app_read_key = client_write_key;
    conn.app_read_iv = client_write_iv;

    tls_mod.sendTLSChangeCipherSpec(socket) catch return error.WriteFailed;

    // Read and decrypt the client's Finished under the client write keys.
    var client_hs_seq: u64 = 0;
    const cf_plain = tls_mod.readTLS12EncryptedRecord(socket, buf, &client_write_key, &client_write_iv, &client_hs_seq, negotiated_cs) catch |e| {
        return e;
    };
    if (cf_plain.len != 4 + 12 or cf_plain[0] != 20) return error.TlsHandshakeFailure;

    // Verify client verify_data against PRF(master, "client finished",
    // Hash(transcript up to but not including this Finished))[:12].
    var th_before: [48]u8 = undefined;
    if (use_sha384) {
        var h = crypto.hash.sha2.Sha384.init(.{});
        h.update(hs_transcript[0..transcript_before_client_fin]);
        h.final(th_before[0..48]);
    } else {
        var h = crypto.hash.sha2.Sha256.init(.{});
        h.update(hs_transcript[0..transcript_before_client_fin]);
        h.final(th_before[0..32]);
    }
    var expected_fd: [12]u8 = undefined;
    if (use_sha384) {
        tls_mod.hmacSha384Expand(&master_secret_384, "client finished", th_before[0..48], &expected_fd);
    } else {
        tls_mod.hmacSha256Expand(&master_secret_256, "client finished", th_before[0..32], &expected_fd);
    }
    if (!mem.eql(u8, cf_plain[4..16], &expected_fd)) {
        return error.TlsDecryptError;
    }

    // Server Finished covers the transcript INCLUDING the client Finished.
    @memcpy(hs_transcript[hs_transcript_len..][0..cf_plain.len], cf_plain);
    hs_transcript_len += cf_plain.len;

    var verify_data: [12]u8 = undefined;
    var th_full: [48]u8 = undefined;
    if (use_sha384) {
        var h = crypto.hash.sha2.Sha384.init(.{});
        h.update(hs_transcript[0..hs_transcript_len]);
        h.final(th_full[0..48]);
        tls_mod.hmacSha384Expand(&master_secret_384, "server finished", th_full[0..48], &verify_data);
    } else {
        var h = crypto.hash.sha2.Sha256.init(.{});
        h.update(hs_transcript[0..hs_transcript_len]);
        h.final(th_full[0..32]);
        tls_mod.hmacSha256Expand(&master_secret_256, "server finished", th_full[0..32], &verify_data);
    }

    var fin_msg: [17]u8 = undefined;
    fin_msg[0] = 20;
    fin_msg[1] = 0;
    fin_msg[2] = 0;
    fin_msg[3] = 12;
    @memcpy(fin_msg[4..][0..12], &verify_data);
    // TLS 1.2: the server Finished MUST be encrypted under the server write
    // keys (it follows our ChangeCipherSpec).
    try tls_mod.sendTLS12EncryptedHandshake(socket, &fin_msg, &server_write_key, &server_write_iv, &conn.write_seq, negotiated_cs);

    // Sequence sync: the client's ChangeCipherSpec + encrypted Finished
    // consumed record sequence number 0 on its write side; application
    // records continue at 1. conn.write_seq was advanced by our own
    // encrypted Finished above.
    conn.read_seq = 1;

    conn.tls_version = .tls_1_2;
    conn.cipher_suite = negotiated_cs;
    conn.sni_hostname = parsed.sni_hostname;

    if (alpn.serverNegotiate(server_alpn, parsed.alpn_protocols.slice())) |negotiated| {
        conn.negotiated_alpn.set(negotiated);
    }

    return conn.*;
}

test "extractClientSessionId returns null for short data" {
    try std.testing.expect(extractClientSessionId(&[_]u8{0}) == null);
}

test "extractClientSessionId echoes exact length" {
    var buf: [64]u8 = [_]u8{0} ** 64;
    buf[4 + 2 + 32] = 16;
    const sid = extractClientSessionId(&buf);
    try std.testing.expect(sid != null);
    try std.testing.expectEqual(@as(usize, 16), sid.?.len);
}

test "findX25519ClientKey returns null for short data" {
    try std.testing.expect(findX25519ClientKey(&[_]u8{0}) == null);
}

test "parseClientHelloExtensions extracts SNI hostname" {
    var buf: [256]u8 = undefined;
    var off: usize = 0;
    buf[0] = 1;
    off = 4;
    mem.writeInt(u16, buf[off..][0..2], @intFromEnum(tls.ProtocolVersion.tls_1_2), .big);
    off += 2;
    @memset(buf[off..][0..32], 0x42);
    off += 32;
    buf[off] = 0;
    off += 1;
    mem.writeInt(u16, buf[off..][0..2], 0, .big);
    off += 2;
    buf[off] = 1;
    off += 1;
    buf[off] = 0;
    off += 1;
    const ext_len_pos = off;
    off += 2;
    const ext_start = off;
    mem.writeInt(u16, buf[off..][0..2], 0x0000, .big);
    off += 2;
    mem.writeInt(u16, buf[off..][0..2], 14, .big);
    off += 2;
    mem.writeInt(u16, buf[off..][0..2], 12, .big);
    off += 2;
    buf[off] = 0;
    off += 1;
    mem.writeInt(u16, buf[off..][0..2], 9, .big);
    off += 2;
    @memcpy(buf[off..][0..9], "localhost");
    off += 9;
    const ext_data_len: u16 = @intCast(off - ext_start);
    mem.writeInt(u16, buf[ext_len_pos..][0..2], ext_data_len, .big);
    const body_len = off - 4;
    mem.writeInt(u24, buf[1..][0..3], @intCast(body_len), .big);

    const parsed = parseClientHelloExtensions(buf[0..off]);
    try std.testing.expect(parsed.sni_hostname != null);
    try std.testing.expectEqualStrings("localhost", parsed.sni_hostname.?);
}

test "parseClientHelloExtensions extracts ALPN protocols" {
    var buf: [256]u8 = undefined;
    var off: usize = 0;
    buf[0] = 1;
    off = 4;
    mem.writeInt(u16, buf[off..][0..2], @intFromEnum(tls.ProtocolVersion.tls_1_2), .big);
    off += 2;
    @memset(buf[off..][0..32], 0x42);
    off += 32;
    buf[off] = 0;
    off += 1;
    mem.writeInt(u16, buf[off..][0..2], 0, .big);
    off += 2;
    buf[off] = 1;
    off += 1;
    buf[off] = 0;
    off += 1;
    const ext_len_pos = off;
    off += 2;
    const ext_start = off;
    mem.writeInt(u16, buf[off..][0..2], 0x0010, .big);
    off += 2;
    mem.writeInt(u16, buf[off..][0..2], 13, .big);
    off += 2;
    buf[off] = 12;
    off += 1;
    buf[off] = 2;
    off += 1;
    @memcpy(buf[off..][0..2], "h2");
    off += 2;
    buf[off] = 8;
    off += 1;
    @memcpy(buf[off..][0..8], "http/1.1");
    off += 8;
    const ext_data_len: u16 = @intCast(off - ext_start);
    mem.writeInt(u16, buf[ext_len_pos..][0..2], ext_data_len, .big);
    const body_len = off - 4;
    mem.writeInt(u24, buf[1..][0..3], @intCast(body_len), .big);

    const parsed = parseClientHelloExtensions(buf[0..off]);
    try std.testing.expectEqual(@as(usize, 2), parsed.alpn_protocols.len);
    try std.testing.expectEqualStrings("h2", parsed.alpn_protocols.slice()[0]);
    try std.testing.expectEqualStrings("http/1.1", parsed.alpn_protocols.slice()[1]);
}

test "parseClientHelloExtensions detects TLS 1.3 support" {
    var buf: [256]u8 = undefined;
    var off: usize = 0;
    buf[0] = 1;
    off = 4;
    mem.writeInt(u16, buf[off..][0..2], @intFromEnum(tls.ProtocolVersion.tls_1_2), .big);
    off += 2;
    @memset(buf[off..][0..32], 0x42);
    off += 32;
    buf[off] = 0;
    off += 1;
    mem.writeInt(u16, buf[off..][0..2], 0, .big);
    off += 2;
    buf[off] = 1;
    off += 1;
    buf[off] = 0;
    off += 1;
    const ext_len_pos = off;
    off += 2;
    const ext_start = off;
    mem.writeInt(u16, buf[off..][0..2], 0x002B, .big);
    off += 2;
    mem.writeInt(u16, buf[off..][0..2], 3, .big);
    off += 2;
    buf[off] = 2;
    off += 1;
    mem.writeInt(u16, buf[off..][0..2], @intFromEnum(tls.ProtocolVersion.tls_1_3), .big);
    off += 2;
    const ext_data_len: u16 = @intCast(off - ext_start);
    mem.writeInt(u16, buf[ext_len_pos..][0..2], ext_data_len, .big);
    const body_len = off - 4;
    mem.writeInt(u24, buf[1..][0..3], @intCast(body_len), .big);

    const parsed = parseClientHelloExtensions(buf[0..off]);
    try std.testing.expect(parsed.supports_tls13);
}

test "parseClientHelloExtensions returns empty for short data" {
    const parsed = parseClientHelloExtensions(&[_]u8{0});
    try std.testing.expectEqual(@as(usize, 0), parsed.alpn_protocols.len);
    try std.testing.expect(!parsed.supports_tls13);
    try std.testing.expect(parsed.sni_hostname == null);
}

test "selectCipherSuite13 returns null for empty client list" {
    try std.testing.expect(selectCipherSuite13(&[_]tls.CipherSuite{}) == null);
}

test "selectCipherSuite13 prefers CHACHA20" {
    const client_list = [_]tls.CipherSuite{ .AES_128_GCM_SHA256, .CHACHA20_POLY1305_SHA256 };
    const result = selectCipherSuite13(&client_list);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(tls.CipherSuite.CHACHA20_POLY1305_SHA256, result.?);
}

test "selectCipherSuite12 returns null for empty client list" {
    try std.testing.expect(selectCipherSuite12(&[_]tls.CipherSuite{}) == null);
}

test "selectCipherSuite12 prefers ECDHE_ECDSA AES128-GCM" {
    const client_list = [_]tls.CipherSuite{ .ECDHE_ECDSA_WITH_AES_256_GCM_SHA384, .ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 };
    const result = selectCipherSuite12(&client_list);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(tls.CipherSuite.ECDHE_ECDSA_WITH_AES_128_GCM_SHA256, result.?);
}

test "findX25519ClientKey finds pure X25519 key share" {
    var buf: [512]u8 = undefined;
    var off: usize = 0;
    buf[0] = 1; // ClientHello
    off = 4;
    // legacy_version
    mem.writeInt(u16, buf[off..][0..2], @intFromEnum(tls.ProtocolVersion.tls_1_2), .big);
    off += 2;
    // random
    @memset(buf[off..][0..32], 0x42);
    off += 32;
    // session_id_len = 0
    buf[off] = 0;
    off += 1;
    // cipher_suites (empty)
    mem.writeInt(u16, buf[off..][0..2], 0, .big);
    off += 2;
    // compression methods
    buf[off] = 1;
    off += 1;
    buf[off] = 0;
    off += 1;
    // extensions
    const ext_len_pos = off;
    off += 2;
    const ext_start = off;
    // key_share extension type = 0x0033
    mem.writeInt(u16, buf[off..][0..2], 0x0033, .big);
    off += 2;
    // key_share data length: list_len(2) + group(2) + key_len(2) + key(32)
    mem.writeInt(u16, buf[off..][0..2], 2 + 2 + 2 + 32, .big);
    off += 2;
    // client_shares list length
    mem.writeInt(u16, buf[off..][0..2], 2 + 2 + 32, .big);
    off += 2;
    // X25519 group = 0x001d
    mem.writeInt(u16, buf[off..][0..2], 0x001d, .big);
    off += 2;
    // key length = 32
    mem.writeInt(u16, buf[off..][0..2], 32, .big);
    off += 2;
    // 32-byte X25519 public key
    @memset(buf[off..][0..32], 0xAB);
    off += 32;
    // fill in extensions length
    const ext_data_len: u16 = @intCast(off - ext_start);
    mem.writeInt(u16, buf[ext_len_pos..][0..2], ext_data_len, .big);
    // fill in handshake body length
    const body_len = off - 4;
    mem.writeInt(u24, buf[1..][0..3], @intCast(body_len), .big);

    const result = findX25519ClientKey(buf[0..off]);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u8, 0xAB), result.?[0]);
}

test "findX25519ClientKey returns null when only X25519Kyber768 offered" {
    var buf: [1536]u8 = undefined;
    var off: usize = 0;
    buf[0] = 1; // ClientHello
    off = 4;
    mem.writeInt(u16, buf[off..][0..2], @intFromEnum(tls.ProtocolVersion.tls_1_2), .big);
    off += 2;
    @memset(buf[off..][0..32], 0x42);
    off += 32;
    buf[off] = 0;
    off += 1;
    mem.writeInt(u16, buf[off..][0..2], 0, .big);
    off += 2;
    buf[off] = 1;
    off += 1;
    buf[off] = 0;
    off += 1;
    const ext_len_pos = off;
    off += 2;
    const ext_start = off;
    // key_share extension type = 0x0033
    mem.writeInt(u16, buf[off..][0..2], 0x0033, .big);
    off += 2;
    // key_share data length — X25519Kyber768 group 0x11ec with 1120 byte key
    const kyber_key_len: u16 = 1120;
    mem.writeInt(u16, buf[off..][0..2], 2 + 2 + 2 + kyber_key_len, .big);
    off += 2;
    // client_shares list length
    mem.writeInt(u16, buf[off..][0..2], 2 + 2 + kyber_key_len, .big);
    off += 2;
    // X25519Kyber768 group = 0x11ec
    mem.writeInt(u16, buf[off..][0..2], 0x11ec, .big);
    off += 2;
    // key length = 1120
    mem.writeInt(u16, buf[off..][0..2], kyber_key_len, .big);
    off += 2;
    @memset(buf[off..][0..kyber_key_len], 0xCD);
    off += kyber_key_len;
    const ext_data_len: u16 = @intCast(off - ext_start);
    mem.writeInt(u16, buf[ext_len_pos..][0..2], ext_data_len, .big);
    const body_len = off - 4;
    mem.writeInt(u24, buf[1..][0..3], @intCast(body_len), .big);

    const result = findX25519ClientKey(buf[0..off]);
    try std.testing.expect(result == null);
}

test "findX25519ClientKey returns null when no key_share extension present" {
    var buf: [256]u8 = undefined;
    var off: usize = 0;
    buf[0] = 1;
    off = 4;
    mem.writeInt(u16, buf[off..][0..2], @intFromEnum(tls.ProtocolVersion.tls_1_2), .big);
    off += 2;
    @memset(buf[off..][0..32], 0x42);
    off += 32;
    buf[off] = 0;
    off += 1;
    mem.writeInt(u16, buf[off..][0..2], 0, .big);
    off += 2;
    buf[off] = 1;
    off += 1;
    buf[off] = 0;
    off += 1;
    // Empty extensions
    mem.writeInt(u16, buf[off..][0..2], 0, .big);
    off += 2;
    const body_len = off - 4;
    mem.writeInt(u24, buf[1..][0..3], @intCast(body_len), .big);

    const result = findX25519ClientKey(buf[0..off]);
    try std.testing.expect(result == null);
}

test "findX25519ClientKey finds X25519 among multiple key share entries" {
    var buf: [1536]u8 = undefined;
    var off: usize = 0;
    buf[0] = 1;
    off = 4;
    mem.writeInt(u16, buf[off..][0..2], @intFromEnum(tls.ProtocolVersion.tls_1_2), .big);
    off += 2;
    @memset(buf[off..][0..32], 0x42);
    off += 32;
    buf[off] = 0;
    off += 1;
    mem.writeInt(u16, buf[off..][0..2], 0, .big);
    off += 2;
    buf[off] = 1;
    off += 1;
    buf[off] = 0;
    off += 1;
    const ext_len_pos = off;
    off += 2;
    const ext_start = off;
    // key_share extension
    mem.writeInt(u16, buf[off..][0..2], 0x0033, .big);
    off += 2;
    const ks_data_start = off;
    off += 2; // placeholder for key_share data length (list_len + entries)
    const ks_list_len_pos = off;
    off += 2; // placeholder for client_shares list length

    // First entry: X25519Kyber768 (0x11ec)
    const kyber_key_len: u16 = 1120;
    mem.writeInt(u16, buf[off..][0..2], 0x11ec, .big);
    off += 2;
    mem.writeInt(u16, buf[off..][0..2], kyber_key_len, .big);
    off += 2;
    @memset(buf[off..][0..kyber_key_len], 0xCD);
    off += kyber_key_len;

    // Second entry: X25519 (0x001d)
    mem.writeInt(u16, buf[off..][0..2], 0x001d, .big);
    off += 2;
    mem.writeInt(u16, buf[off..][0..2], 32, .big);
    off += 2;
    @memset(buf[off..][0..32], 0xEF);
    off += 32;

    // Fill in list length and total data length
    const ks_list_len: u16 = @intCast(off - ks_list_len_pos - 2);
    mem.writeInt(u16, buf[ks_list_len_pos..][0..2], ks_list_len, .big);
    const ks_data_len: u16 = @intCast(off - ks_data_start - 2);
    mem.writeInt(u16, buf[ks_data_start..][0..2], ks_data_len, .big);

    const ext_data_len: u16 = @intCast(off - ext_start);
    mem.writeInt(u16, buf[ext_len_pos..][0..2], ext_data_len, .big);
    const body_len = off - 4;
    mem.writeInt(u24, buf[1..][0..3], @intCast(body_len), .big);

    const result = findX25519ClientKey(buf[0..off]);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u8, 0xEF), result.?[0]);
}

test "parseClientHelloExtensions with TLS 1.3 and key_share" {
    var buf: [512]u8 = undefined;
    var off: usize = 0;
    buf[0] = 1;
    off = 4;
    mem.writeInt(u16, buf[off..][0..2], @intFromEnum(tls.ProtocolVersion.tls_1_2), .big);
    off += 2;
    @memset(buf[off..][0..32], 0x42);
    off += 32;
    buf[off] = 0;
    off += 1;
    // cipher suites: CHACHA20 + AES_128_GCM
    mem.writeInt(u16, buf[off..][0..2], 4, .big);
    off += 2;
    mem.writeInt(u16, buf[off..][0..2], @intFromEnum(tls.CipherSuite.CHACHA20_POLY1305_SHA256), .big);
    off += 2;
    mem.writeInt(u16, buf[off..][0..2], @intFromEnum(tls.CipherSuite.AES_128_GCM_SHA256), .big);
    off += 2;
    buf[off] = 1;
    off += 1;
    buf[off] = 0;
    off += 1;
    const ext_len_pos = off;
    off += 2;
    const ext_start = off;
    // supported_versions extension (0x002B)
    mem.writeInt(u16, buf[off..][0..2], 0x002B, .big);
    off += 2;
    mem.writeInt(u16, buf[off..][0..2], 3, .big);
    off += 2;
    buf[off] = 2;
    off += 1;
    mem.writeInt(u16, buf[off..][0..2], @intFromEnum(tls.ProtocolVersion.tls_1_3), .big);
    off += 2;
    // key_share extension (0x0033)
    mem.writeInt(u16, buf[off..][0..2], 0x0033, .big);
    off += 2;
    mem.writeInt(u16, buf[off..][0..2], 2 + 2 + 2 + 32, .big); // list_len+grp+klen+key
    off += 2;
    mem.writeInt(u16, buf[off..][0..2], 2 + 2 + 32, .big); // client_shares list length
    off += 2;
    mem.writeInt(u16, buf[off..][0..2], 0x001d, .big); // X25519
    off += 2;
    mem.writeInt(u16, buf[off..][0..2], 32, .big);
    off += 2;
    @memset(buf[off..][0..32], 0xAB);
    off += 32;
    const ext_data_len: u16 = @intCast(off - ext_start);
    mem.writeInt(u16, buf[ext_len_pos..][0..2], ext_data_len, .big);
    const body_len = off - 4;
    mem.writeInt(u24, buf[1..][0..3], @intCast(body_len), .big);

    const parsed = parseClientHelloExtensions(buf[0..off]);
    try std.testing.expect(parsed.supports_tls13);
    try std.testing.expect(parsed.cipher_suites.len >= 2);
    // findX25519ClientKey should also find the key
    const key = findX25519ClientKey(buf[0..off]);
    try std.testing.expect(key != null);
}

test "parseClientHelloExtensions with TLS 1.3 but no X25519 keyshare" {
    var buf: [1536]u8 = undefined;
    var off: usize = 0;
    buf[0] = 1;
    off = 4;
    mem.writeInt(u16, buf[off..][0..2], @intFromEnum(tls.ProtocolVersion.tls_1_2), .big);
    off += 2;
    @memset(buf[off..][0..32], 0x42);
    off += 32;
    buf[off] = 0;
    off += 1;
    mem.writeInt(u16, buf[off..][0..2], 0, .big);
    off += 2;
    buf[off] = 1;
    off += 1;
    buf[off] = 0;
    off += 1;
    const ext_len_pos = off;
    off += 2;
    const ext_start = off;
    // supported_versions: TLS 1.3
    mem.writeInt(u16, buf[off..][0..2], 0x002B, .big);
    off += 2;
    mem.writeInt(u16, buf[off..][0..2], 3, .big);
    off += 2;
    buf[off] = 2;
    off += 1;
    mem.writeInt(u16, buf[off..][0..2], @intFromEnum(tls.ProtocolVersion.tls_1_3), .big);
    off += 2;
    // key_share: only X25519Kyber768
    mem.writeInt(u16, buf[off..][0..2], 0x0033, .big);
    off += 2;
    mem.writeInt(u16, buf[off..][0..2], 2 + 2 + 1120, .big);
    off += 2;
    mem.writeInt(u16, buf[off..][0..2], 0x11ec, .big); // X25519Kyber768
    off += 2;
    mem.writeInt(u16, buf[off..][0..2], 1120, .big);
    off += 2;
    @memset(buf[off..][0..1120], 0xCD);
    off += 1120;
    const ext_data_len: u16 = @intCast(off - ext_start);
    mem.writeInt(u16, buf[ext_len_pos..][0..2], ext_data_len, .big);
    const body_len = off - 4;
    mem.writeInt(u24, buf[1..][0..3], @intCast(body_len), .big);

    const parsed = parseClientHelloExtensions(buf[0..off]);
    try std.testing.expect(parsed.supports_tls13);
    // But findX25519ClientKey should NOT find X25519
    const key = findX25519ClientKey(buf[0..off]);
    try std.testing.expect(key == null);
}
