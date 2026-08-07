//! High-level TLS Connection & Server Accept engine
//!
//! Public API for httpx.zig TLS support:
//!
//! - `TlsConfig`  --  configuration (ALPN, verification, etc.)
//! - `Connection`  --  established TLS session with read/write
//! - `connectClient()`  --  perform a full TLS 1.2/1.3 client handshake
//! - `acceptServer()`  --  perform a full TLS 1.2/1.3 server accept
//! - `TlsSession`  --  lightweight session wrapper (backward-compatible)

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const crypto = std.crypto;
const tls = std.crypto.tls;

const Socket = @import("../net/socket.zig").Socket;

const alpn = @import("alpn.zig");
const errors = @import("errors.zig");
const record = @import("record.zig");
const handshake_12 = @import("handshake_12.zig");
const handshake_13 = @import("handshake_13.zig");
const cipher_suites = @import("cipher_suites.zig");
const crypto_utils = @import("crypto_utils.zig");
const any_io = @import("../util/any_io.zig");

// Server TLS configuration — holds loaded cert chain and private key

pub const ServerTlsConfig = struct {
    cert_chain_der: []const []const u8 = &.{},
    key_der: ?[]const u8 = null,
    allocator: ?Allocator = null,

    pub fn deinit(self: *ServerTlsConfig) void {
        if (self.allocator) |a| {
            for (self.cert_chain_der) |cert| a.free(cert);
            a.free(self.cert_chain_der);
            if (self.key_der) |k| a.free(k);
        }
    }
};

/// PEM decode: strip headers and base64-decode the content.
/// Returns allocated DER bytes.
fn pemDecode(allocator: Allocator, pem: []const u8) ![]const u8 {
    // Find the base64 content between headers
    const begin_marker = "-----BEGIN ";
    var start: usize = 0;
    var found_start = false;
    var i: usize = 0;
    while (i < pem.len) : (i += 1) {
        if (pem[i] == '-' and i + begin_marker.len <= pem.len) {
            if (std.mem.startsWith(u8, pem[i..], begin_marker)) {
                // Skip to end of this line
                while (i < pem.len and pem[i] != '\n') : (i += 1) {}
                i += 1;
                start = i;
                found_start = true;
                break;
            }
        }
    }
    if (!found_start) return error.TlsInvalidPem;

    // Find end marker
    var end: usize = pem.len;
    i = start;
    while (i < pem.len) : (i += 1) {
        if (pem[i] == '-' and i + 5 <= pem.len) {
            if (std.mem.startsWith(u8, pem[i..], "-----END ")) {
                end = i;
                break;
            }
        }
    }

    // Strip whitespace from base64 content
    var b64_len: usize = 0;
    for (pem[start..end]) |c| {
        if (c != '\n' and c != '\r' and c != ' ' and c != '\t') {
            b64_len += 1;
        }
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

/// Load a PEM certificate chain file. Returns a list of DER-encoded certificates.
pub fn loadCertChain(allocator: Allocator, path: []const u8) ![]const []const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = std.Io.Dir.cwd();
    const pem = try dir.readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(pem);

    // Count certificates in the chain
    var count: usize = 0;
    var search_pos: usize = 0;
    while (search_pos < pem.len) {
        if (std.mem.indexOf(u8, pem[search_pos..], "-----BEGIN CERTIFICATE-----")) |_| {
            count += 1;
            // Skip past this cert's end marker
            if (std.mem.indexOf(u8, pem[search_pos..], "-----END CERTIFICATE-----")) |end_pos| {
                search_pos += end_pos + 25; // len("-----END CERTIFICATE-----")
            } else {
                break;
            }
        } else {
            break;
        }
    }

    if (count == 0) return error.TlsNoCertificates;

    var certs = try allocator.alloc([]const u8, count);
    var cert_idx: usize = 0;
    search_pos = 0;
    while (cert_idx < count) {
        const begin_pos = std.mem.indexOf(u8, pem[search_pos..], "-----BEGIN CERTIFICATE-----") orelse break;
        const cert_start = search_pos + begin_pos;
        const end_pos = std.mem.indexOf(u8, pem[cert_start..], "-----END CERTIFICATE-----") orelse break;
        const cert_end = cert_start + end_pos + 25;
        certs[cert_idx] = try pemDecode(allocator, pem[cert_start..cert_end]);
        search_pos = cert_end;
        cert_idx += 1;
    }

    return certs;
}

/// Load a PEM private key file. Returns DER-encoded PKCS#1 or PKCS#8 key bytes.
pub fn loadPrivateKey(allocator: Allocator, path: []const u8) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = std.Io.Dir.cwd();
    const pem = try dir.readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(pem);

    // Find the private key section
    const begin = "-----BEGIN RSA PRIVATE KEY-----";
    const begin2 = "-----BEGIN PRIVATE KEY-----";
    const search_start: usize = 0;

    const pkcs1_start = std.mem.indexOf(u8, pem[search_start..], begin);
    const pkcs8_start = std.mem.indexOf(u8, pem[search_start..], begin2);

    const key_start = if (pkcs1_start) |s| search_start + s else null;
    const is_pkcs1 = pkcs1_start != null;

    const key_start2 = if (pkcs8_start) |s| search_start + s else null;
    const final_start = if (key_start) |s| s else key_start2 orelse return error.TlsInvalidPrivateKey;

    const end_marker = if (is_pkcs1) "-----END RSA PRIVATE KEY-----" else "-----END PRIVATE KEY-----";
    const end_pos = std.mem.indexOf(u8, pem[final_start..], end_marker) orelse return error.TlsInvalidPrivateKey;
    const key_end = final_start + end_pos + end_marker.len;

    return pemDecode(allocator, pem[final_start..key_end]);
}

/// Load server TLS configuration from PEM files.
pub fn loadServerTlsConfig(allocator: Allocator, cert_path: []const u8, key_path: []const u8) !ServerTlsConfig {
    const cert_chain = try loadCertChain(allocator, cert_path);
    const key_der = try loadPrivateKey(allocator, key_path);

    return .{
        .cert_chain_der = cert_chain,
        .key_der = key_der,
        .allocator = allocator,
    };
}

// Connection  --  represents an established TLS session

pub const Connection = struct {
    allocator: Allocator,
    socket: *Socket,
    negotiated_alpn: alpn.NegotiatedAlpn = .{},
    tls_version: tls.ProtocolVersion = .tls_1_2,
    is_server: bool = false,
    connected: bool = false,

    // Cipher state for application data
    app_write_key: ?[32]u8 = null,
    app_write_iv: ?[12]u8 = null,
    app_read_key: ?[32]u8 = null,
    app_read_iv: ?[12]u8 = null,

    // Sequence numbers
    write_seq: u64 = 0,
    read_seq: u64 = 0,

    // Handshake traffic sequence numbers (TLS 1.3)
    hs_write_seq: u64 = 0,
    hs_read_seq: u64 = 0,

    cipher_suite: ?tls.CipherSuite = null,
    read_buf: [record.max_record_len]u8 = undefined,
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

    /// Send an alert and close the connection.
    pub fn sendAlert(self: *Connection, level: tls.Alert.Level, desc: tls.Alert.Description) void {
        var buf: [7]u8 = undefined;
        buf[0] = @intFromEnum(tls.ContentType.alert);
        buf[1] = 0x03;
        buf[2] = 0x03;
        buf[3] = 0;
        buf[4] = 2;
        buf[5] = @intFromEnum(level);
        buf[6] = @intFromEnum(desc);
        _ = self.socket.send(buf[0..7]) catch {};
    }

    /// Send close_notify alert.
    pub fn closeNotify(self: *Connection) void {
        self.sendAlert(.warning, .close_notify);
    }

    /// Returns a reader interface for reading from the TLS connection.
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

    /// Returns a writer interface for writing to the TLS connection.
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

    /// Write application data over the TLS connection.
    pub fn write(self: *Connection, data: []const u8) !usize {
        const socket = self.socket;
        const version = self.tls_version;
        const key = self.app_write_key orelse return error.TlsHandshakeNotComplete;
        const iv = self.app_write_iv orelse return error.TlsHandshakeNotComplete;
        const cs = self.cipher_suite orelse return error.TlsHandshakeNotComplete;

        switch (version) {
            .tls_1_3 => {
                var hdr: [record.record_header_len]u8 = undefined;
                const hdr_val = record.RecordHeader{
                    .content_type = .application_data,
                    .version = .tls_1_2,
                    .length = @intCast(data.len + 16),
                };
                hdr_val.format(&hdr);

                const nonce = record.nonceTls13(&iv, self.write_seq);

                var out_buf: [record.record_header_len + record.max_plaintext_len + 256]u8 = undefined;
                @memcpy(out_buf[0..record.record_header_len], &hdr);

                const enc_len = switch (cs) {
                    .AES_128_GCM_SHA256 => blk: {
                        var k: [16]u8 = undefined;
                        @memcpy(&k, key[0..16]);
                        const enc = try record.encryptTls13(crypto.aead.aes_gcm.Aes128Gcm, out_buf[record.record_header_len..], data, &hdr, &nonce, &k);
                        break :blk enc.len;
                    },
                    .AES_256_GCM_SHA384 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        const enc = try record.encryptTls13(crypto.aead.aes_gcm.Aes256Gcm, out_buf[record.record_header_len..], data, &hdr, &nonce, &k);
                        break :blk enc.len;
                    },
                    .CHACHA20_POLY1305_SHA256 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        const enc = try record.encryptTls13(crypto.aead.chacha_poly.ChaCha20Poly1305, out_buf[record.record_header_len..], data, &hdr, &nonce, &k);
                        break :blk enc.len;
                    },
                    else => return error.TlsUnsupportedCipherSuite,
                };

                const total = record.record_header_len + enc_len;
                _ = socket.send(out_buf[0..total]) catch return error.WriteFailed;
                self.write_seq += 1;
                return data.len;
            },
            .tls_1_2 => {
                var hdr: [record.record_header_len]u8 = undefined;
                const hdr_val = record.RecordHeader{
                    .content_type = .application_data,
                    .version = .tls_1_2,
                    .length = @intCast(12 + data.len + 16),
                };
                hdr_val.format(&hdr);

                var out_buf: [record.record_header_len + 32 + record.max_plaintext_len + 256]u8 = undefined;
                @memcpy(out_buf[0..record.record_header_len], &hdr);

                const enc_len = switch (cs) {
                    .ECDHE_RSA_WITH_AES_128_GCM_SHA256 => blk: {
                        var k: [16]u8 = undefined;
                        @memcpy(&k, key[0..16]);
                        const enc = try record.encryptTls12(crypto.aead.aes_gcm.Aes128Gcm, out_buf[record.record_header_len..], data, &hdr, self.write_seq, &iv, &k);
                        break :blk enc.len;
                    },
                    .ECDHE_RSA_WITH_AES_256_GCM_SHA384 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        const enc = try record.encryptTls12(crypto.aead.aes_gcm.Aes256Gcm, out_buf[record.record_header_len..], data, &hdr, self.write_seq, &iv, &k);
                        break :blk enc.len;
                    },
                    .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        const enc = try record.encryptTls12(crypto.aead.chacha_poly.ChaCha20Poly1305, out_buf[record.record_header_len..], data, &hdr, self.write_seq, &iv, &k);
                        break :blk enc.len;
                    },
                    else => return error.TlsUnsupportedCipherSuite,
                };

                const total = record.record_header_len + enc_len;
                _ = socket.send(out_buf[0..total]) catch return error.WriteFailed;
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

    /// Read application data from the TLS connection.
    pub fn read(self: *Connection, buf: []u8) !usize {
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
            const n = socket.recv(self.read_buf[total..5]) catch return error.ReadFailed;
            if (n == 0) return error.TlsConnectionTruncated;
            total += n;
        }

        const length = mem.readInt(u16, self.read_buf[3..5], .big);
        if (length > record.max_ciphertext_len) return error.TlsRecordOverflow;

        while (total < 5 + length) {
            const n = socket.recv(self.read_buf[total..][0 .. 5 + length - total]) catch return error.ReadFailed;
            if (n == 0) return error.TlsConnectionTruncated;
            total += n;
        }

        const record_body = self.read_buf[5..][0..length];

        switch (version) {
            .tls_1_3 => {
                const nonce = record.nonceTls13(&iv, self.read_seq);

                const plaintext = switch (cs) {
                    .AES_128_GCM_SHA256 => blk: {
                        var k: [16]u8 = undefined;
                        @memcpy(&k, key[0..16]);
                        break :blk try record.decryptTls13(crypto.aead.aes_gcm.Aes128Gcm, record_body, self.read_buf[0..5], &nonce, &k);
                    },
                    .AES_256_GCM_SHA384 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        break :blk try record.decryptTls13(crypto.aead.aes_gcm.Aes256Gcm, record_body, self.read_buf[0..5], &nonce, &k);
                    },
                    .CHACHA20_POLY1305_SHA256 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        break :blk try record.decryptTls13(crypto.aead.chacha_poly.ChaCha20Poly1305, record_body, self.read_buf[0..5], &nonce, &k);
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
                        break :blk try record.decryptTls12(crypto.aead.aes_gcm.Aes128Gcm, record_body, self.read_buf[0..5], self.read_seq, &iv, &k);
                    },
                    .ECDHE_RSA_WITH_AES_256_GCM_SHA384 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        break :blk try record.decryptTls12(crypto.aead.aes_gcm.Aes256Gcm, record_body, self.read_buf[0..5], self.read_seq, &iv, &k);
                    },
                    .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        break :blk try record.decryptTls12(crypto.aead.chacha_poly.ChaCha20Poly1305, record_body, self.read_buf[0..5], self.read_seq, &iv, &k);
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

// TlsConfig  --  TLS connection configuration

pub const TlsConfig = struct {
    allocator: Allocator,
    alpn_protocols: []const []const u8 = &.{"http/1.1"},
    verify_server: bool = true,
    ca_bundle_path: ?[]const u8 = null,

    pub fn init(allocator: Allocator) TlsConfig {
        return .{ .allocator = allocator };
    }

    pub fn insecure(allocator: Allocator) TlsConfig {
        return .{
            .allocator = allocator,
            .verify_server = false,
        };
    }

    pub fn withH2(allocator: Allocator) TlsConfig {
        return .{
            .allocator = allocator,
            .alpn_protocols = &.{ "h2", "http/1.1" },
        };
    }

    pub fn insecureWithH2(allocator: Allocator) TlsConfig {
        return .{
            .allocator = allocator,
            .alpn_protocols = &.{ "h2", "http/1.1" },
            .verify_server = false,
        };
    }

    pub fn withH3(allocator: Allocator) TlsConfig {
        return .{
            .allocator = allocator,
            .alpn_protocols = &.{ "h3", "h2", "http/1.1" },
        };
    }

    pub fn insecureWithH3(allocator: Allocator) TlsConfig {
        return .{
            .allocator = allocator,
            .alpn_protocols = &.{ "h3", "h2", "http/1.1" },
            .verify_server = false,
        };
    }

    pub fn wantsHttp2(self: TlsConfig) bool {
        for (self.alpn_protocols) |proto| {
            if (std.mem.eql(u8, proto, "h2")) return true;
        }
        return false;
    }
};

// TlsSession  --  lightweight session wrapper (backward-compatible)

pub const TlsSession = struct {
    config: TlsConfig,
    negotiated_alpn: alpn.NegotiatedAlpn = .{},
    tls_version: ?tls.ProtocolVersion = null,
    socket: ?*Socket = null,
    cipher_suite: ?tls.CipherSuite = null,

    // Handshake traffic keys for TLS 1.3 encrypted handshake messages
    hs_write_key: ?[32]u8 = null,
    hs_write_iv: ?[12]u8 = null,
    hs_write_seq: u64 = 0,
    hs_read_key: ?[32]u8 = null,
    hs_read_iv: ?[12]u8 = null,
    hs_read_seq: u64 = 0,

    // Application traffic keys for encrypted data exchange
    app_write_key: ?[32]u8 = null,
    app_write_iv: ?[12]u8 = null,
    app_read_key: ?[32]u8 = null,
    app_read_iv: ?[12]u8 = null,
    write_seq: u64 = 0,
    read_seq: u64 = 0,

    // Internal read buffer for TLS record reassembly
    read_buf: [record.max_record_len]u8 = undefined,
    read_buf_len: usize = 0,
    read_buf_pos: usize = 0,

    /// Legacy accessor: returns negotiated protocol string or null.
    pub fn negotiatedProtocol(self: *const TlsSession) ?[]const u8 {
        return self.negotiated_alpn.get();
    }

    pub fn init(config: TlsConfig) TlsSession {
        return .{ .config = config };
    }

    pub fn deinit(self: *TlsSession) void {
        // Zero out key material to prevent leaking secrets
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

    /// Perform the TLS handshake with the server.
    pub fn handshake(self: *TlsSession, host: []const u8) !void {
        const socket = self.socket orelse return error.TlsMissingTransport;

        // Try TLS 1.3 first, then fall back to TLS 1.2
        self.handshakeTls13(socket, host) catch |err| switch (err) {
            error.TlsProtocolVersion, error.TlsIllegalParameter, error.TlsUnsupportedCipherSuite => {
                // Server doesn't support TLS 1.3, try TLS 1.2
                try self.handshakeTls12(socket, host);
            },
            else => return err,
        };
    }

    fn handshakeTls13(self: *TlsSession, socket: *Socket, host: []const u8) !void {
        var client = handshake_13.Handshake13Client.init(self.config.allocator, host);

        // Build and send ClientHello wrapped in a TLS record
        var buf: [4096]u8 = undefined;
        const ch_len = try client.buildClientHello(&buf, self.config.alpn_protocols);

        // Wrap in TLS record: content_type(1) + version(2) + length(2) + body
        var record_buf: [4096]u8 = undefined;
        record_buf[0] = @intFromEnum(tls.ContentType.handshake);
        record_buf[1] = 0x03; // legacy version major
        record_buf[2] = 0x03; // legacy version minor
        mem.writeInt(u16, record_buf[3..5], @intCast(ch_len), .big);
        @memcpy(record_buf[5..][0..ch_len], buf[0..ch_len]);
        _ = socket.send(record_buf[0 .. 5 + ch_len]) catch return error.WriteFailed;

        // Read ServerHello (unencrypted)
        const sh_data = try readTlsRecord(socket, &buf);
        try client.processServerHello(sh_data);

        // Derive handshake keys for decrypting server messages
        const server_hs_key = client.getServerHsKey() orelse return error.TlsKeyExchangeFailed;
        const server_hs_iv = client.getServerHsIv() orelse return error.TlsKeyExchangeFailed;

        // Read EncryptedExtensions (encrypted with server handshake key)
        var ee_buf: [4096]u8 = undefined;
        const ee_data = try readTls13EncryptedHandshake(socket, &ee_buf, &server_hs_key, &server_hs_iv, &self.hs_read_seq, client.cipher_suite orelse .AES_128_GCM_SHA256);
        try client.processEncryptedExtensions(ee_data);

        // Read Certificate (encrypted)
        var cert_buf: [4096]u8 = undefined;
        const cert_data = try readTls13EncryptedHandshake(socket, &cert_buf, &server_hs_key, &server_hs_iv, &self.hs_read_seq, client.cipher_suite orelse .AES_128_GCM_SHA256);
        try client.processCertificate(cert_data);

        // Read CertificateVerify (encrypted)
        var cv_buf: [4096]u8 = undefined;
        const cv_data = try readTls13EncryptedHandshake(socket, &cv_buf, &server_hs_key, &server_hs_iv, &self.hs_read_seq, client.cipher_suite orelse .AES_128_GCM_SHA256);
        try client.processCertificateVerify(cv_data);

        // Read server Finished (encrypted)
        var sf_buf: [4096]u8 = undefined;
        const sf_data = try readTls13EncryptedHandshake(socket, &sf_buf, &server_hs_key, &server_hs_iv, &self.hs_read_seq, client.cipher_suite orelse .AES_128_GCM_SHA256);

        // Build our Finished (encrypt with client handshake key)
        var fin_buf: [256]u8 = undefined;
        const fin_len = try client.processServerFinishedAndBuildClientFinished(sf_data, &fin_buf);

        // Derive client handshake key/IV for encrypting our Finished
        const client_hs_key = client.getClientHsKey() orelse return error.TlsKeyExchangeFailed;
        const client_hs_iv = client.getClientHsIv() orelse return error.TlsKeyExchangeFailed;

        // Send ChangeCipherSpec (for middlebox compatibility, unencrypted)
        const ccs = [_]u8{
            @intFromEnum(tls.ContentType.change_cipher_spec),
            0x03,
            0x01,
            0x00,
            0x01,
            0x01,
        };
        _ = socket.send(&ccs) catch return error.WriteFailed;

        // Send Finished (encrypted with client handshake key)
        try sendTls13EncryptedHandshake(socket, fin_buf[0..fin_len], &client_hs_key, &client_hs_iv, &self.hs_write_seq, client.cipher_suite orelse .AES_128_GCM_SHA256);

        // Extract application traffic keys
        self.app_write_key = client.getClientAppKey();
        self.app_write_iv = client.getClientAppIv();
        self.app_read_key = client.getServerAppKey();
        self.app_read_iv = client.getServerAppIv();
        self.tls_version = .tls_1_3;
        self.cipher_suite = client.cipher_suite;
        self.negotiated_alpn = client.negotiated_alpn;
    }

    fn handshakeTls12(self: *TlsSession, socket: *Socket, host: []const u8) !void {
        var client = handshake_12.Handshake12Client.init(self.config.allocator);

        // Build and send ClientHello wrapped in a TLS record
        var buf: [4096]u8 = undefined;
        const ch_len = try client.buildClientHello(&buf, host, self.config.alpn_protocols);

        // Wrap in TLS record: content_type(1) + version(2) + length(2) + body
        var record_buf: [4096]u8 = undefined;
        record_buf[0] = @intFromEnum(tls.ContentType.handshake);
        record_buf[1] = 0x03;
        record_buf[2] = 0x03;
        mem.writeInt(u16, record_buf[3..5], @intCast(ch_len), .big);
        @memcpy(record_buf[5..][0..ch_len], buf[0..ch_len]);
        _ = socket.send(record_buf[0 .. 5 + ch_len]) catch return error.WriteFailed;

        // Read ServerHello
        const sh_data = try readTlsRecord(socket, &buf);
        try client.processServerHello(sh_data);

        // Read Certificate
        const cert_data = try readTlsRecord(socket, &buf);
        try client.processCertificate(cert_data);

        // Read ServerKeyExchange
        const ske_data = try readTlsRecord(socket, &buf);
        try client.processServerKeyExchange(ske_data);

        // Read ServerHelloDone
        const shd_data = try readTlsRecord(socket, &buf);
        try client.processServerHelloDone(shd_data);

        // Build and send ClientKeyExchange + ChangeCipherSpec + Finished
        var out_buf: [4096]u8 = undefined;
        _ = try client.buildClientKeyExchangeAndFinished(&out_buf);

        // Parse the output: CKE handshake msg, then CCS record (6 bytes), then Finished handshake msg
        // CKE: type(1) + len(3) + body
        const cke_msg_len: usize = 4 + @as(usize, (@as(u24, @intCast(out_buf[1])) << 16) | (@as(u24, @intCast(out_buf[2])) << 8) | @as(u24, @intCast(out_buf[3])));
        // CCS record is always 6 bytes starting at cke_msg_len
        const ccs_offset = cke_msg_len;
        // Finished starts at ccs_offset + 6
        const fin_offset = ccs_offset + 6;
        const fin_msg_len: usize = 4 + @as(usize, (@as(u24, @intCast(out_buf[fin_offset + 1])) << 16) | (@as(u24, @intCast(out_buf[fin_offset + 2])) << 8) | @as(u24, @intCast(out_buf[fin_offset + 3])));

        // Send CKE wrapped in TLS record
        var rec: [4096]u8 = undefined;
        rec[0] = @intFromEnum(tls.ContentType.handshake);
        rec[1] = 0x03;
        rec[2] = 0x03;
        mem.writeInt(u16, rec[3..5], @intCast(cke_msg_len), .big);
        @memcpy(rec[5..][0..cke_msg_len], out_buf[0..cke_msg_len]);
        _ = socket.send(rec[0 .. 5 + cke_msg_len]) catch return error.WriteFailed;

        // Send CCS record (already properly framed)
        _ = socket.send(out_buf[ccs_offset..][0..6]) catch return error.WriteFailed;

        // Send Finished wrapped in TLS record
        rec[0] = @intFromEnum(tls.ContentType.handshake);
        rec[1] = 0x03;
        rec[2] = 0x03;
        mem.writeInt(u16, rec[3..5], @intCast(fin_msg_len), .big);
        @memcpy(rec[5..][0..fin_msg_len], out_buf[fin_offset..][0..fin_msg_len]);
        _ = socket.send(rec[0 .. 5 + fin_msg_len]) catch return error.WriteFailed;

        // Read server ChangeCipherSpec + Finished
        const sfin_data = try readTlsRecord(socket, &buf);
        try client.processServerFinished(sfin_data);

        self.tls_version = .tls_1_2;
        self.cipher_suite = client.cipher_suite;
        self.negotiated_alpn = client.negotiated_alpn;

        // Derive application traffic keys for TLS 1.2
        if (client.cipher_suite) |cs| {
            const shared_secret = client.key_exchange.getSharedSecret() orelse return error.TlsKeyExchangeFailed;
            if (cs == .ECDHE_RSA_WITH_AES_256_GCM_SHA384) {
                const HmacType = @import("handshake.zig").HmacSha384;
                const master_secret = @import("handshake.zig").deriveMasterSecret(HmacType, shared_secret, &client.client_random, &client.server_random);
                const key_block = @import("handshake.zig").deriveKeyBlock(HmacType, &master_secret, &client.server_random, &client.client_random, 2 * 16 + 2 * 4);
                var wk: [32]u8 = [_]u8{0} ** 32;
                var rk: [32]u8 = [_]u8{0} ** 32;
                @memcpy(wk[0..16], key_block[0..16]);
                @memcpy(rk[0..16], key_block[16..32]);
                self.app_write_key = wk;
                self.app_read_key = rk;
                self.app_write_iv = key_block[32..36].* ++ [_]u8{0} ** 8;
                self.app_read_iv = key_block[36..40].* ++ [_]u8{0} ** 8;
            } else {
                const HmacType = @import("handshake.zig").HmacSha256;
                const master_secret = @import("handshake.zig").deriveMasterSecret(HmacType, shared_secret, &client.client_random, &client.server_random);
                const key_block = @import("handshake.zig").deriveKeyBlock(HmacType, &master_secret, &client.server_random, &client.client_random, 2 * 16 + 2 * 4);
                var wk: [32]u8 = [_]u8{0} ** 32;
                var rk: [32]u8 = [_]u8{0} ** 32;
                @memcpy(wk[0..16], key_block[0..16]);
                @memcpy(rk[0..16], key_block[16..32]);
                self.app_write_key = wk;
                self.app_read_key = rk;
                self.app_write_iv = key_block[32..36].* ++ [_]u8{0} ** 8;
                self.app_read_iv = key_block[36..40].* ++ [_]u8{0} ** 8;
            }
        }
    }

    pub fn isHttp2(self: *const TlsSession) bool {
        return self.negotiated_alpn.isHttp2Result();
    }

    pub fn isHttp3(self: *const TlsSession) bool {
        return self.negotiated_alpn.isHttp3Result();
    }

    /// Write application data over the TLS connection.
    /// After the handshake completes, encrypts the data using the
    /// negotiated AEAD cipher and sends it as a TLS record.
    pub fn write(self: *TlsSession, data: []const u8) !usize {
        const socket = self.socket orelse return 0;
        const version = self.tls_version orelse return error.TlsHandshakeNotComplete;
        const key = self.app_write_key orelse return error.TlsHandshakeNotComplete;
        const iv = self.app_write_iv orelse return error.TlsHandshakeNotComplete;
        const cs = self.cipher_suite orelse return error.TlsHandshakeNotComplete;

        switch (version) {
            .tls_1_3 => {
                // Build record header for AAD
                var hdr: [record.record_header_len]u8 = undefined;
                const hdr_val = record.RecordHeader{
                    .content_type = .application_data,
                    .version = .tls_1_2,
                    .length = @intCast(data.len + 16), // 16 = AES-GCM/ChaCha20 tag length
                };
                hdr_val.format(&hdr);

                const nonce = record.nonceTls13(&iv, self.write_seq);

                // Encrypt using the negotiated cipher
                var out_buf: [record.record_header_len + record.max_plaintext_len + 256]u8 = undefined;
                @memcpy(out_buf[0..record.record_header_len], &hdr);

                const enc_len = switch (cs) {
                    .AES_128_GCM_SHA256 => blk: {
                        var k: [16]u8 = undefined;
                        @memcpy(&k, key[0..16]);
                        const enc = try record.encryptTls13(crypto.aead.aes_gcm.Aes128Gcm, out_buf[record.record_header_len..], data, &hdr, &nonce, &k);
                        break :blk enc.len;
                    },
                    .AES_256_GCM_SHA384 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        const enc = try record.encryptTls13(crypto.aead.aes_gcm.Aes256Gcm, out_buf[record.record_header_len..], data, &hdr, &nonce, &k);
                        break :blk enc.len;
                    },
                    .CHACHA20_POLY1305_SHA256 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        const enc = try record.encryptTls13(crypto.aead.chacha_poly.ChaCha20Poly1305, out_buf[record.record_header_len..], data, &hdr, &nonce, &k);
                        break :blk enc.len;
                    },
                    else => return error.TlsUnsupportedCipherSuite,
                };

                const total = record.record_header_len + enc_len;
                _ = socket.send(out_buf[0..total]) catch return error.WriteFailed;
                self.write_seq += 1;
                return data.len;
            },
            .tls_1_2 => {
                // TLS 1.2: explicit IV prepended to ciphertext
                var hdr: [record.record_header_len]u8 = undefined;
                const hdr_val = record.RecordHeader{
                    .content_type = .application_data,
                    .version = .tls_1_2,
                    .length = @intCast(12 + data.len + 16), // explicit_iv + plaintext + tag
                };
                hdr_val.format(&hdr);

                var out_buf: [record.record_header_len + 32 + record.max_plaintext_len + 256]u8 = undefined;
                @memcpy(out_buf[0..record.record_header_len], &hdr);

                const enc_len = switch (cs) {
                    .ECDHE_RSA_WITH_AES_128_GCM_SHA256 => blk: {
                        var k: [16]u8 = undefined;
                        @memcpy(&k, key[0..16]);
                        const enc = try record.encryptTls12(crypto.aead.aes_gcm.Aes128Gcm, out_buf[record.record_header_len..], data, &hdr, self.write_seq, &iv, &k);
                        break :blk enc.len;
                    },
                    .ECDHE_RSA_WITH_AES_256_GCM_SHA384 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        const enc = try record.encryptTls12(crypto.aead.aes_gcm.Aes256Gcm, out_buf[record.record_header_len..], data, &hdr, self.write_seq, &iv, &k);
                        break :blk enc.len;
                    },
                    .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        const enc = try record.encryptTls12(crypto.aead.chacha_poly.ChaCha20Poly1305, out_buf[record.record_header_len..], data, &hdr, self.write_seq, &iv, &k);
                        break :blk enc.len;
                    },
                    else => return error.TlsUnsupportedCipherSuite,
                };

                const total = record.record_header_len + enc_len;
                _ = socket.send(out_buf[0..total]) catch return error.WriteFailed;
                self.write_seq += 1;
                return data.len;
            },
            else => return error.TlsUnsupportedCipherSuite,
        }
    }

    pub fn flush(_: *TlsSession) !void {
        // No-op: socket sends are immediate
    }

    pub fn writeAll(self: *TlsSession, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            const n = try self.write(data[written..]);
            if (n == 0) return error.WriteFailed;
            written += n;
        }
    }

    /// Read application data from the TLS connection.
    /// Reads a TLS record from the socket, decrypts it, and copies
    /// the plaintext into `buf`. Returns the number of bytes read.
    pub fn read(self: *TlsSession, buf: []u8) !usize {
        const socket = self.socket orelse return 0;
        const version = self.tls_version orelse return error.TlsHandshakeNotComplete;
        const key = self.app_read_key orelse return error.TlsHandshakeNotComplete;
        const iv = self.app_read_iv orelse return error.TlsHandshakeNotComplete;
        const cs = self.cipher_suite orelse return error.TlsHandshakeNotComplete;

        // Return buffered data if available
        if (self.read_buf_pos < self.read_buf_len) {
            const available = self.read_buf_len - self.read_buf_pos;
            const to_copy = @min(available, buf.len);
            @memcpy(buf[0..to_copy], self.read_buf[self.read_buf_pos..][0..to_copy]);
            self.read_buf_pos += to_copy;
            return to_copy;
        }

        // Read a complete TLS record
        // Read 5-byte record header
        var total: usize = 0;
        while (total < 5) {
            const n = socket.recv(self.read_buf[total..5]) catch return error.ReadFailed;
            if (n == 0) return error.TlsConnectionTruncated;
            total += n;
        }

        const length = mem.readInt(u16, self.read_buf[3..5], .big);
        if (length > record.max_ciphertext_len) return error.TlsRecordOverflow;

        // Read record body
        while (total < 5 + length) {
            const n = socket.recv(self.read_buf[total..][0 .. 5 + length - total]) catch return error.ReadFailed;
            if (n == 0) return error.TlsConnectionTruncated;
            total += n;
        }

        const record_body = self.read_buf[5..][0..length];

        // Decrypt based on TLS version
        switch (version) {
            .tls_1_3 => {
                // For TLS 1.3, the content type is inside the encrypted payload
                const nonce = record.nonceTls13(&iv, self.read_seq);

                const plaintext = switch (cs) {
                    .AES_128_GCM_SHA256 => blk: {
                        var k: [16]u8 = undefined;
                        @memcpy(&k, key[0..16]);
                        break :blk try record.decryptTls13(crypto.aead.aes_gcm.Aes128Gcm, record_body, self.read_buf[0..5], &nonce, &k);
                    },
                    .AES_256_GCM_SHA384 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        break :blk try record.decryptTls13(crypto.aead.aes_gcm.Aes256Gcm, record_body, self.read_buf[0..5], &nonce, &k);
                    },
                    .CHACHA20_POLY1305_SHA256 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        break :blk try record.decryptTls13(crypto.aead.chacha_poly.ChaCha20Poly1305, record_body, self.read_buf[0..5], &nonce, &k);
                    },
                    else => return error.TlsUnsupportedCipherSuite,
                };

                self.read_seq += 1;

                // TLS 1.3: last byte of plaintext is the real content type
                // For application_data, we just return the data before the content type byte
                if (plaintext.len == 0) return 0;
                const data_len = plaintext.len - 1;
                const to_copy = @min(data_len, buf.len);
                @memcpy(buf[0..to_copy], plaintext[0..to_copy]);
                return to_copy;
            },
            .tls_1_2 => {
                // For TLS 1.2, the record body is: explicit_iv || ciphertext || tag
                const plaintext = switch (cs) {
                    .ECDHE_RSA_WITH_AES_128_GCM_SHA256 => blk: {
                        var k: [16]u8 = undefined;
                        @memcpy(&k, key[0..16]);
                        break :blk try record.decryptTls12(crypto.aead.aes_gcm.Aes128Gcm, record_body, self.read_buf[0..5], self.read_seq, &iv, &k);
                    },
                    .ECDHE_RSA_WITH_AES_256_GCM_SHA384 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        break :blk try record.decryptTls12(crypto.aead.aes_gcm.Aes256Gcm, record_body, self.read_buf[0..5], self.read_seq, &iv, &k);
                    },
                    .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256 => blk: {
                        var k: [32]u8 = undefined;
                        @memcpy(&k, key[0..32]);
                        break :blk try record.decryptTls12(crypto.aead.chacha_poly.ChaCha20Poly1305, record_body, self.read_buf[0..5], self.read_seq, &iv, &k);
                    },
                    else => return error.TlsUnsupportedCipherSuite,
                };

                self.read_seq += 1;
                const to_copy = @min(plaintext.len, buf.len);
                @memcpy(buf[0..to_copy], plaintext[0..to_copy]);

                // Buffer any remaining data
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

// Server-side accept

/// Wrap a handshake message in a TLS record and send it.
fn sendTlsHandshakeRecord(socket: *Socket, msg: []const u8) !void {
    var buf: [5 + record.max_plaintext_len]u8 = undefined;
    buf[0] = @intFromEnum(tls.ContentType.handshake);
    buf[1] = 0x03; // legacy version major
    buf[2] = 0x03; // legacy version minor
    mem.writeInt(u16, buf[3..5], @intCast(msg.len), .big);
    @memcpy(buf[5..][0..msg.len], msg);
    _ = socket.send(buf[0 .. 5 + msg.len]) catch return error.WriteFailed;
}

/// Send a ChangeCipherSpec record (unencrypted, always 1 byte).
fn sendTlsChangeCipherSpec(socket: *Socket) !void {
    const ccs = [_]u8{
        @intFromEnum(tls.ContentType.change_cipher_spec),
        0x03,
        0x01,
        0x00,
        0x01,
        0x01,
    };
    _ = socket.send(&ccs) catch return error.WriteFailed;
}

/// Send a TLS 1.3 encrypted handshake record.
/// Encrypts `msg` using the handshake key and sends it as a TLS record
/// with content_type=application_data (outer) and handshake (inner).
fn sendTls13EncryptedHandshake(
    socket: *Socket,
    msg: []const u8,
    key: []const u8,
    iv: []const u8,
    seq: *u64,
    cs: tls.CipherSuite,
) !void {
    // Inner plaintext: message || content_type (0x16 = handshake)
    var inner_buf: [record.max_plaintext_len + 1]u8 = undefined;
    @memcpy(inner_buf[0..msg.len], msg);
    inner_buf[msg.len] = @intFromEnum(tls.ContentType.handshake);
    const inner_len = msg.len + 1;

    // Build record header for AAD
    var hdr_buf: [record.record_header_len]u8 = undefined;
    const hdr_val = record.RecordHeader{
        .content_type = .application_data,
        .version = .tls_1_2,
        .length = @intCast(inner_len + 16), // ciphertext + tag
    };
    hdr_val.format(&hdr_buf);

    // Encrypt
    const nonce = record.nonceTls13(iv, seq.*);
    var out_buf: [record.record_header_len + record.max_plaintext_len + 256]u8 = undefined;
    @memcpy(out_buf[0..record.record_header_len], &hdr_buf);

    const enc_len = switch (cs) {
        .AES_128_GCM_SHA256 => blk: {
            var k: [16]u8 = undefined;
            @memcpy(&k, key[0..16]);
            const enc = try record.encryptTls13(crypto.aead.aes_gcm.Aes128Gcm, out_buf[record.record_header_len..], inner_buf[0..inner_len], &hdr_buf, &nonce, &k);
            break :blk enc.len;
        },
        .AES_256_GCM_SHA384 => blk: {
            var k: [32]u8 = undefined;
            @memcpy(&k, key[0..32]);
            const enc = try record.encryptTls13(crypto.aead.aes_gcm.Aes256Gcm, out_buf[record.record_header_len..], inner_buf[0..inner_len], &hdr_buf, &nonce, &k);
            break :blk enc.len;
        },
        .CHACHA20_POLY1305_SHA256 => blk: {
            var k: [32]u8 = undefined;
            @memcpy(&k, key[0..32]);
            const enc = try record.encryptTls13(crypto.aead.chacha_poly.ChaCha20Poly1305, out_buf[record.record_header_len..], inner_buf[0..inner_len], &hdr_buf, &nonce, &k);
            break :blk enc.len;
        },
        else => return error.TlsUnsupportedCipherSuite,
    };

    const total = record.record_header_len + enc_len;
    _ = socket.send(out_buf[0..total]) catch return error.WriteFailed;

    seq.* += 1;
}

/// Read and decrypt a TLS 1.3 encrypted handshake record.
/// Reads a TLS record, decrypts it, and returns the inner plaintext
/// (message || content_type).
fn readTls13EncryptedHandshake(
    socket: *Socket,
    buf: *[4096]u8,
    key: []const u8,
    iv: []const u8,
    seq: *u64,
    cs: tls.CipherSuite,
) ![]const u8 {
    // Read the outer TLS record
    const record_data = try readTlsRecord(socket, buf);

    // Build AAD from the record header (5 bytes before record_data)
    const hdr_ptr: *const [record.record_header_len]u8 = buf[0..record.record_header_len];

    // Decrypt
    const nonce = record.nonceTls13(iv, seq.*);

    const decrypted = switch (cs) {
        .AES_128_GCM_SHA256 => blk: {
            var k: [16]u8 = undefined;
            @memcpy(&k, key[0..16]);
            const plaintext = try record.decryptTls13(crypto.aead.aes_gcm.Aes128Gcm, @constCast(record_data), hdr_ptr, &nonce, &k);
            break :blk plaintext;
        },
        .AES_256_GCM_SHA384 => blk: {
            var k: [32]u8 = undefined;
            @memcpy(&k, key[0..32]);
            const plaintext = try record.decryptTls13(crypto.aead.aes_gcm.Aes256Gcm, @constCast(record_data), hdr_ptr, &nonce, &k);
            break :blk plaintext;
        },
        .CHACHA20_POLY1305_SHA256 => blk: {
            var k: [32]u8 = undefined;
            @memcpy(&k, key[0..32]);
            const plaintext = try record.decryptTls13(crypto.aead.chacha_poly.ChaCha20Poly1305, @constCast(record_data), hdr_ptr, &nonce, &k);
            break :blk plaintext;
        },
        else => return error.TlsUnsupportedCipherSuite,
    };

    seq.* += 1;
    // Last byte is the real content type
    if (decrypted.len == 0) return error.TlsDecryptError;
    return decrypted[0 .. decrypted.len - 1];
}

fn acceptServerTls12(
    conn: *Connection,
    socket: *Socket,
    server: *handshake_12.Handshake12Server,
    buf: *[4096]u8,
) !void {
    // Build and send ServerHello
    var out_buf: [4096]u8 = undefined;
    const sh_len = try server.buildServerHello(&out_buf);
    try sendTlsHandshakeRecord(socket, out_buf[0..sh_len]);

    // Build and send Certificate
    const cert_len = try server.buildCertificate(&out_buf);
    try sendTlsHandshakeRecord(socket, out_buf[0..cert_len]);

    // Build and send ServerKeyExchange
    const ske_len = try server.buildServerKeyExchange(&out_buf);
    try sendTlsHandshakeRecord(socket, out_buf[0..ske_len]);

    // Build and send ServerHelloDone
    const shd_len = try server.buildServerHelloDone(&out_buf);
    try sendTlsHandshakeRecord(socket, out_buf[0..shd_len]);

    // Read ClientKeyExchange
    const cke_data = try readTlsRecord(socket, buf);
    try server.processClientKeyExchange(cke_data);

    // Read ChangeCipherSpec
    _ = try readTlsRecord(socket, buf);

    // Read client Finished
    const cf_data = try readTlsRecord(socket, buf);
    try server.processClientFinished(cf_data);

    // Build and send ChangeCipherSpec + Finished
    var fin_buf: [1024]u8 = undefined;
    const fin_len = try server.buildChangeCipherSpecAndFinished(&fin_buf);

    // CCS record is 6 bytes, Finished starts at offset 6
    // Send CCS record (already properly framed)
    _ = socket.send(fin_buf[0..6]) catch return error.WriteFailed;

    // Send Finished wrapped in TLS record
    const fin_msg_len: usize = fin_len - 6;
    var rec: [4096]u8 = undefined;
    rec[0] = @intFromEnum(tls.ContentType.handshake);
    rec[1] = 0x03;
    rec[2] = 0x03;
    mem.writeInt(u16, rec[3..5], @intCast(fin_msg_len), .big);
    @memcpy(rec[5..][0..fin_msg_len], fin_buf[6..][0..fin_msg_len]);
    _ = socket.send(rec[0 .. 5 + fin_msg_len]) catch return error.WriteFailed;

    conn.tls_version = .tls_1_2;
    conn.cipher_suite = server.cipher_suite;
    conn.negotiated_alpn = server.negotiated_alpn;

    // Derive application traffic keys for TLS 1.2 server role
    const cs = server.cipher_suite;
    {
        const shared_secret2 = server.key_exchange.getSharedSecret() orelse return error.TlsKeyExchangeFailed;
        if (cs == .ECDHE_RSA_WITH_AES_256_GCM_SHA384) {
            const HmacType = @import("handshake.zig").HmacSha384;
            const master_secret = @import("handshake.zig").deriveMasterSecret(HmacType, shared_secret2, &server.client_random, &server.server_random);
            // AES-256-GCM: key=32 bytes, IV=4 bytes (implicit), total=2*32+2*4=72
            const key_block = @import("handshake.zig").deriveKeyBlock(HmacType, &master_secret, &server.server_random, &server.client_random, 2 * 32 + 2 * 4);
            var wk: [32]u8 = [_]u8{0} ** 32;
            var rk: [32]u8 = [_]u8{0} ** 32;
            @memcpy(rk[0..32], key_block[0..32]);
            @memcpy(wk[0..32], key_block[32..64]);
            conn.app_write_key = wk;
            conn.app_read_key = rk;
            conn.app_write_iv = key_block[64..68].* ++ [_]u8{0} ** 8;
            conn.app_read_iv = key_block[68..72].* ++ [_]u8{0} ** 8;
        } else {
            const HmacType = @import("handshake.zig").HmacSha256;
            const master_secret = @import("handshake.zig").deriveMasterSecret(HmacType, shared_secret2, &server.client_random, &server.server_random);
            const key_block = @import("handshake.zig").deriveKeyBlock(HmacType, &master_secret, &server.server_random, &server.client_random, 2 * 16 + 2 * 4);
            var wk: [32]u8 = [_]u8{0} ** 32;
            var rk: [32]u8 = [_]u8{0} ** 32;
            @memcpy(rk[0..16], key_block[0..16]);
            @memcpy(wk[0..16], key_block[16..32]);
            conn.app_write_key = wk;
            conn.app_read_key = rk;
            conn.app_write_iv = key_block[32..36].* ++ [_]u8{0} ** 8;
            conn.app_read_iv = key_block[36..40].* ++ [_]u8{0} ** 8;
        }
    }
}

pub fn acceptServer(
    allocator: Allocator,
    socket: *Socket,
    server_alpn: []const []const u8,
    server_tls: ?ServerTlsConfig,
) !Connection {
    var conn = Connection{
        .allocator = allocator,
        .socket = socket,
        .is_server = true,
        .connected = true,
    };

    // Perform TLS accept
    var buf: [4096]u8 = undefined;

    // Read ClientHello
    const ch_data = try readTlsRecord(socket, &buf);

    // Determine if TLS 1.3 or 1.2 based on supported_versions extension
    const is_tls13 = detectTls13(ch_data);

    if (is_tls13) {
        var server = handshake_13.Handshake13Server.init(allocator);
        server.alpn_protocols = server_alpn;
        if (server_tls) |*tls_cfg| {
            server.cert_chain_der = tls_cfg.cert_chain_der;
        }

        // Try TLS 1.3 handshake
        server.processClientHello(ch_data) catch {
            // Send TLS alert to inform client of failure
            const alert = [_]u8{
                @intFromEnum(tls.ContentType.alert),
                0x03,
                0x03,
                0x00,
                0x02,
                @intFromEnum(tls.Alert.Description.illegal_parameter),
            };
            _ = socket.send(&alert) catch {};
            return error.TlsIllegalParameter;
        };

        // Initialize key schedule before building ServerHello
        server.initKeySchedule();

        var out_buf: [4096]u8 = undefined;

        // Build ServerHello (sent unencrypted)
        const sh_len = try server.buildServerHello(&out_buf);
        try sendTlsHandshakeRecord(socket, out_buf[0..sh_len]);

        // Derive handshake secrets after ServerHello is sent
        const shared_secret = server.key_exchange.getSharedSecret() orelse return error.TlsKeyExchangeFailed;
        if (server.hash_is_384) {
            const hello_hash = server.transcript.peek()[0..48];
            server.ks384.deriveHandshakeSecret(shared_secret);
            server.ks384.deriveHandshakeTrafficSecrets(hello_hash);
        } else {
            const hello_hash = server.transcript.peek()[0..32];
            server.ks256.deriveHandshakeSecret(shared_secret);
            server.ks256.deriveHandshakeTrafficSecrets(hello_hash);
        }

        // Derive server handshake write key/IV for encrypting subsequent messages
        const server_hs_key = server.getServerHsKey() orelse return error.TlsKeyExchangeFailed;
        const server_hs_iv = server.getServerHsIv() orelse return error.TlsKeyExchangeFailed;

        // Build EncryptedExtensions (encrypted with handshake key)
        const ee_len = try server.buildEncryptedExtensions(&out_buf);
        try sendTls13EncryptedHandshake(socket, out_buf[0..ee_len], &server_hs_key, &server_hs_iv, &conn.hs_write_seq, server.cipher_suite);

        // Build Certificate (encrypted)
        const cert_len = try server.buildCertificate(&out_buf);
        try sendTls13EncryptedHandshake(socket, out_buf[0..cert_len], &server_hs_key, &server_hs_iv, &conn.hs_write_seq, server.cipher_suite);

        // Build CertificateVerify (encrypted)
        const cv_len = try server.buildCertificateVerify(&out_buf);
        try sendTls13EncryptedHandshake(socket, out_buf[0..cv_len], &server_hs_key, &server_hs_iv, &conn.hs_write_seq, server.cipher_suite);

        // Build Finished (encrypted)
        const fin_len = try server.buildFinished(&out_buf);
        try sendTls13EncryptedHandshake(socket, out_buf[0..fin_len], &server_hs_key, &server_hs_iv, &conn.hs_write_seq, server.cipher_suite);

        // Derive master secret and application traffic secrets BEFORE reading client Finished.
        // Per RFC 8446 §7.1, app traffic secrets use Hash(ClientHello...ServerFinished),
        // which does NOT include the client's Finished.
        if (server.hash_is_384) {
            const sf_hash = server.transcript.peek()[0..48];
            server.ks384.deriveMasterSecret();
            server.ks384.deriveApplicationTrafficSecrets(sf_hash);
        } else {
            const sf_hash = server.transcript.peek()[0..32];
            server.ks256.deriveMasterSecret();
            server.ks256.deriveApplicationTrafficSecrets(sf_hash);
        }

        conn.app_write_key = server.getServerAppKey();
        conn.app_write_iv = server.getServerAppIv();
        conn.app_read_key = server.getClientAppKey();
        conn.app_read_iv = server.getClientAppIv();

        // Read client ChangeCipherSpec (unencrypted)
        _ = try readTlsRecord(socket, &buf);

        // Read client Finished (encrypted with client handshake key)
        const client_hs_key = server.getClientHsKey() orelse return error.TlsKeyExchangeFailed;
        const client_hs_iv = server.getClientHsIv() orelse return error.TlsKeyExchangeFailed;
        const cf_data = try readTls13EncryptedHandshake(socket, &buf, &client_hs_key, &client_hs_iv, &conn.hs_read_seq, server.cipher_suite);
        try server.processClientFinished(cf_data);

        conn.tls_version = .tls_1_3;
        conn.cipher_suite = server.cipher_suite;
        conn.negotiated_alpn = server.negotiated_alpn;
    } else {
        var server = handshake_12.Handshake12Server.init(allocator);
        server.alpn_protocols = server_alpn;
        if (server_tls) |*tls_cfg| {
            server.cert_chain_der = tls_cfg.cert_chain_der;
        }
        try server.processClientHello(ch_data);
        try acceptServerTls12(&conn, socket, &server, &buf);
        return conn;
    }

    return conn;
}

// Client-side connect

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

    // Copy negotiated ALPN
    conn.negotiated_alpn = session.negotiated_alpn;

    return conn;
}

// Internal helpers

/// Read a complete TLS record from the socket and return the record body.
fn readTlsRecord(socket: *Socket, buf: *[4096]u8) ![]const u8 {
    // Read 5-byte record header
    var total: usize = 0;
    while (total < 5) {
        const n = socket.recv(buf[total..5]) catch return error.ReadFailed;
        if (n == 0) return error.TlsConnectionTruncated;
        total += n;
    }

    const length = mem.readInt(u16, buf[3..5], .big);
    if (length > record.max_ciphertext_len) return error.TlsRecordOverflow;

    // Read record body
    while (total < 5 + length) {
        const n = socket.recv(buf[total..][0 .. 5 + length - total]) catch return error.ReadFailed;
        if (n == 0) return error.TlsConnectionTruncated;
        total += n;
    }

    return buf[5..][0..length];
}

/// Detect if a ClientHello indicates TLS 1.3 by checking the supported_versions extension.
fn detectTls13(client_hello: []const u8) bool {
    // Simple heuristic: look for the supported_versions extension with 0x0304
    if (client_hello.len < 42) return false;
    var off: usize = 4 + 2 + 32; // skip type + len + version + random
    if (off >= client_hello.len) return false;
    const session_id_len = client_hello[off];
    off += 1 + session_id_len;

    // Skip cipher suites
    if (off + 2 > client_hello.len) return false;
    const cs_len = mem.readInt(u16, client_hello[off..][0..2], .big);
    off += 2 + cs_len;

    // Skip compression
    if (off >= client_hello.len) return false;
    const comp_len = client_hello[off];
    off += 1 + comp_len;

    // Parse extensions
    if (off + 2 > client_hello.len) return false;
    const ext_len = mem.readInt(u16, client_hello[off..][0..2], .big);
    off += 2;
    const ext_end = @min(off + ext_len, client_hello.len);

    while (off + 4 <= ext_end) {
        const ext_type = mem.readInt(u16, client_hello[off..][0..2], .big);
        const ext_data_len = mem.readInt(u16, client_hello[off + 2 ..][0..2], .big);
        off += 4;
        if (ext_type == @intFromEnum(tls.ExtensionType.supported_versions)) {
            // Check if TLS 1.3 is listed
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

// Tests

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

test "Connection struct field defaults" {
    // Verify Connection struct default values at compile time.
    const defaults = Connection{
        .allocator = undefined,
        .socket = undefined,
    };
    try std.testing.expect(!defaults.is_server);
    try std.testing.expect(!defaults.connected);
    try std.testing.expect(defaults.tls_version == .tls_1_2);
    try std.testing.expect(defaults.negotiated_alpn.get() == null);
}

test "TlsSession deinit zeros key material" {
    var session = TlsSession.init(TlsConfig.init(std.testing.allocator));
    session.app_write_key = [_]u8{0xAB} ** 32;
    session.app_read_key = [_]u8{0xCD} ** 32;
    session.deinit();
    // deinit zeros the key material, but the optional fields remain set
    if (session.app_write_key) |k| {
        for (k) |b| try std.testing.expectEqual(@as(u8, 0), b);
    }
    if (session.app_read_key) |k| {
        for (k) |b| try std.testing.expectEqual(@as(u8, 0), b);
    }
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

test "detectTls13 returns false for short data" {
    try std.testing.expect(!detectTls13(&[_]u8{0}));
}

test "detectTls13 returns false for no supported_versions extension" {
    // Minimal ClientHello that won't have supported_versions
    var buf: [50]u8 = [_]u8{0} ** 50;
    buf[0] = 1; // session_id_len = 1
    buf[1] = 0x33; // random placeholder byte
    try std.testing.expect(!detectTls13(&buf));
}
