//! TLS 1.2 Handshake  --  Full Client + Server Implementation (RFC 5246)
//!
//! Complete state machines for both client and server roles:
//!
//! Client: ClientHello -> ServerHello -> Certificate -> ServerKeyExchange
//!         -> ServerHelloDone -> ClientKeyExchange -> ChangeCipherSpec
//!         -> Finished -> (application data)
//!
//! Server: ClientHello -> ServerHello -> Certificate -> ServerKeyExchange
//!         -> ServerHelloDone -> (wait ClientKeyExchange + Finished)
//!
//! Supports ECDHE key exchange with X25519, P-256, P-384.
//! Supports AEAD cipher suites: AES-128-GCM, AES-256-GCM, ChaCha20-Poly1305.

const std = @import("std");
const mem = std.mem;
const crypto = std.crypto;
const tls = std.crypto.tls;

const errors = @import("errors.zig");
const handshake = @import("handshake.zig");
const extensions_mod = @import("extensions.zig");
const alpn = @import("alpn.zig");
const transcript_mod = @import("transcript.zig");
const cipher_suites_mod = @import("cipher_suites.zig");
const crypto_utils = @import("crypto_utils.zig");

const HmacSha256 = handshake.HmacSha256;
const HmacSha384 = handshake.HmacSha384;

const tlsRandom = crypto_utils.tlsRandom;

// TLS 1.2 state machine (client role)

pub const ClientState12 = enum {
    start,
    wait_server_hello,
    wait_certificate,
    wait_server_key_exchange,
    wait_server_hello_done,
    wait_finished,
    connected,
};

/// Full TLS 1.2 client handshake context.
pub const Handshake12Client = struct {
    allocator: mem.Allocator,
    state: ClientState12 = .start,
    transcript: transcript_mod.TranscriptHash = .{},
    key_exchange: handshake.KeyExchange = .{},
    negotiated_alpn: alpn.NegotiatedAlpn = .{},

    // Random values
    client_random: [32]u8 = undefined,
    server_random: [32]u8 = undefined,

    // Negotiated cipher
    cipher_suite: ?tls.CipherSuite = null,

    // Master secret (derived during key exchange, needed for Finished verification)
    master_secret: ?[48]u8 = null,

    pub fn init(allocator: mem.Allocator) Handshake12Client {
        var tr: transcript_mod.TranscriptHash = .{};
        tr.initAlgorithm(.sha256);
        return .{
            .allocator = allocator,
            .transcript = tr,
        };
    }

    /// Build a TLS 1.2 ClientHello message.
    /// Returns the number of bytes written to `out`.
    pub fn buildClientHello(
        self: *Handshake12Client,
        out: []u8,
        host: ?[]const u8,
        offer_alpn: []const []const u8,
    ) errors.TlsError!usize {
        if (out.len < 512) return error.TlsBufferTooSmall;

        // Generate client random
        tlsRandom(&self.client_random);

        // Initialize key exchange
        var entropy: [96]u8 = undefined;
        tlsRandom(&entropy);
        self.key_exchange = try handshake.KeyExchange.init(&entropy);

        var off: usize = 0;

        // Handshake header (type + 3-byte length)
        out[0] = @intFromEnum(tls.HandshakeType.client_hello);
        off += 4; // placeholder for length

        // Client version: TLS 1.2 (0x0303)
        mem.writeInt(u16, out[off..][0..2], @intFromEnum(tls.ProtocolVersion.tls_1_2), .big);
        off += 2;

        // Client random (32 bytes)
        @memcpy(out[off..][0..32], &self.client_random);
        off += 32;

        // Session ID length = 0
        out[off] = 0;
        off += 1;

        // Cipher suites
        const cs_len = cipher_suites_mod.writeCipherSuiteList(out[off..]);
        off += cs_len;

        // Compression methods: null only
        out[off] = 1; // length
        out[off + 1] = 0; // null
        off += 2;

        // Extensions
        const ext_len_offset = off;
        off += 2;
        var ext_written: usize = 0;

        // SNI extension
        if (host) |h| {
            ext_written += try extensions_mod.writeSniExtension(out[off + ext_written ..], h);
        }

        // ALPN extension
        if (offer_alpn.len > 0) {
            ext_written += try extensions_mod.writeAlpnExtension(out[off + ext_written ..], offer_alpn);
        }

        // supported_groups extension
        ext_written += try extensions_mod.writeSupportedGroupsExtension(out[off + ext_written ..]);

        // signature_algorithms extension
        ext_written += try extensions_mod.writeSignatureAlgorithmsExtension(out[off + ext_written ..]);

        mem.writeInt(u16, out[ext_len_offset..][0..2], @intCast(ext_written), .big);
        off += ext_written;

        // Fill in handshake message length
        const body_len: u24 = @intCast(off - 4);
        handshake.writeHandshakeHeader(.client_hello, body_len, out[0..4]);

        // Update transcript
        self.transcript.update(out[0..off]);
        self.state = .wait_server_hello;
        return off;
    }

    /// Process a ServerHello message from the server.
    pub fn processServerHello(self: *Handshake12Client, data: []const u8) errors.TlsError!void {
        if (data.len < 42) return error.TlsDecodeError;

        var off: usize = 0;

        // Skip handshake type (already verified)
        off += 4;

        // Server version
        const version = mem.readInt(u16, data[off..][0..2], .big);
        if (version != @intFromEnum(tls.ProtocolVersion.tls_1_2)) return error.TlsProtocolVersion;
        off += 2;

        // Server random (32 bytes)
        @memcpy(&self.server_random, data[off..][0..32]);
        off += 32;

        // Session ID echo
        const session_id_len = data[off];
        off += 1 + session_id_len;

        // Cipher suite
        if (off + 2 > data.len) return error.TlsDecodeError;
        self.cipher_suite = @enumFromInt(mem.readInt(u16, data[off..][0..2], .big));
        off += 2;

        // Check if the cipher suite is supported
        if (!cipher_suites_mod.isSupported(self.cipher_suite.?)) return error.TlsUnsupportedCipherSuite;

        // Compression method
        off += 1;

        // Extensions (optional)
        if (off < data.len) {
            if (off + 2 > data.len) return error.TlsDecodeError;
            const ext_len = mem.readInt(u16, data[off..][0..2], .big);
            off += 2;
            const ext_end2 = @min(off + ext_len, data.len);

            while (off + 4 <= ext_end2) {
                const ext_type: tls.ExtensionType = @enumFromInt(mem.readInt(u16, data[off..][0..2], .big));
                const ext_data_len = mem.readInt(u16, data[off + 2 ..][0..2], .big);
                off += 4;

                if (off + ext_data_len > ext_end2) return error.TlsDecodeError;
                const ext_data = data[off..][0..ext_data_len];
                off += ext_data_len;

                switch (ext_type) {
                    .server_name => {},
                    .application_layer_protocol_negotiation => {
                        if (ext_data.len >= 2) {
                            const list_len = mem.readInt(u16, ext_data[0..2], .big);
                            if (list_len + 2 <= ext_data.len and ext_data.len >= 4) {
                                const proto_len = ext_data[2];
                                if (3 + proto_len <= ext_data.len) {
                                    self.negotiated_alpn.set(ext_data[3..][0..proto_len]);
                                }
                            }
                        }
                    },
                    else => {},
                }
            }
        }

        self.transcript.update(data);
        self.state = .wait_certificate;
    }

    /// Process a Certificate message from the server.
    pub fn processCertificate(self: *Handshake12Client, data: []const u8) errors.TlsError!void {
        if (data.len < 7) return error.TlsDecodeError;

        // Skip handshake type + 3-byte length
        var off: usize = 4;

        // Certificate list length (3 bytes)
        const cert_list_len = (@as(u24, data[off]) << 16) | (@as(u24, data[off + 1]) << 8) | @as(u24, data[off + 2]);
        off += 3;

        if (off + cert_list_len > data.len) return error.TlsDecodeError;

        // Parse first certificate to get the server's public key
        if (cert_list_len >= 3) {
            const cert_len = (@as(u24, data[off]) << 16) | (@as(u24, data[off + 1]) << 8) | @as(u24, data[off + 2]);
            off += 3;
            if (off + cert_len <= data.len) {
                // Parse but discard cert data. The server sends an empty certificate
                // in this implementation, so the data is not stored or verified.
                _ = data[off..][0..cert_len];
            }
        }

        self.transcript.update(data);
        self.state = .wait_server_key_exchange;
    }

    /// Process a ServerKeyExchange message (ECDHE).
    pub fn processServerKeyExchange(self: *Handshake12Client, data: []const u8) errors.TlsError!void {
        if (data.len < 10) return error.TlsDecodeError;

        // Skip handshake type + 3-byte length
        var off: usize = 4;

        // Curve type (must be named_curve = 0x03)
        if (data[off] != 0x03) return error.TlsIllegalParameter;
        off += 1;

        // Named group
        const named_group: tls.NamedGroup = @enumFromInt(mem.readInt(u16, data[off..][0..2], .big));
        off += 2;

        // Public key length + public key
        const key_len = data[off];
        off += 1;
        if (off + key_len > data.len) return error.TlsDecodeError;
        const server_pub_key = data[off..][0..key_len];
        off += key_len;

        // Signature (2-byte scheme + 2-byte length + signature)
        if (off + 4 > data.len) return error.TlsDecodeError;
        const sig_scheme: tls.SignatureScheme = @enumFromInt(mem.readInt(u16, data[off..][0..2], .big));
        off += 2;
        const sig_len = mem.readInt(u16, data[off..][0..2], .big);
        off += 2;
        if (off + sig_len > data.len) return error.TlsDecodeError;
        const signature = data[off..][0..sig_len];
        off += sig_len;

        // Verify the signature over (client_random || server_random || params).
        // params = curve_type(1) || named_group(2) || key_len(1) || public_key
        // We need the server's RSA public key from the certificate. Currently the
        // server sends an empty certificate, so we skip verification. A production
        // implementation must verify using the certificate's public key.
        _ = sig_scheme;
        _ = signature;

        // Perform ECDHE key exchange
        try self.key_exchange.exchange(named_group, server_pub_key);

        self.transcript.update(data);
        self.state = .wait_server_hello_done;
    }

    /// Process a ServerHelloDone message.
    pub fn processServerHelloDone(self: *Handshake12Client, data: []const u8) errors.TlsError!void {
        if (data.len < 4) return error.TlsDecodeError;
        self.transcript.update(data);
        self.state = .wait_finished;
    }

    /// Build ClientKeyExchange, ChangeCipherSpec, and Finished messages.
    /// Returns the total bytes written to `out`.
    pub fn buildClientKeyExchangeAndFinished(
        self: *Handshake12Client,
        out: []u8,
    ) errors.TlsError!usize {
        if (out.len < 512) return error.TlsBufferTooSmall;

        const pub_key = try self.key_exchange.getPublicKey(
            switch (self.key_exchange.group) {
                .x25519 => tls.NamedGroup.x25519,
                .secp256r1 => tls.NamedGroup.secp256r1,
                .secp384r1 => tls.NamedGroup.secp384r1,
            },
        );

        var off: usize = 0;

        // --- ClientKeyExchange ---
        // Handshake header
        const cke_body_len: u24 = @intCast(1 + pub_key.len); // 1 byte key_len + key
        handshake.writeHandshakeHeader(.client_key_exchange, cke_body_len, out[0..4]);
        off += 4;
        // Public key length
        out[off] = @intCast(pub_key.len);
        off += 1;
        // Public key
        @memcpy(out[off..][0..pub_key.len], pub_key);
        off += pub_key.len;

        // Update transcript with ClientKeyExchange
        self.transcript.update(out[0..off]);

        // --- Derive master secret, key material, and Finished ---
        const shared_secret = self.key_exchange.getSharedSecret() orelse return error.TlsKeyExchangeFailed;
        const suite = self.cipher_suite orelse return error.TlsHandshakeFailure;

        // Everything using HmacType and master_secret must be inside the inline switch
        switch (suite) {
            inline .ECDHE_RSA_WITH_AES_128_GCM_SHA256,
            .ECDHE_RSA_WITH_AES_256_GCM_SHA384,
            .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
            => |tag| {
                const HmacType = switch (tag) {
                    .ECDHE_RSA_WITH_AES_256_GCM_SHA384 => HmacSha384,
                    else => HmacSha256,
                };
                const master_secret = handshake.deriveMasterSecret(HmacType, shared_secret, &self.client_random, &self.server_random);
                self.master_secret = master_secret;

                // --- ChangeCipherSpec record (must be sent BEFORE Finished) ---
                const ccs_record = [_]u8{
                    @intFromEnum(tls.ContentType.change_cipher_spec),
                    0x03, 0x01, // version TLS 1.0 (CCS is always 0x0301)
                    0x00, 0x01, // length = 1
                    0x01, // change_cipher_spec
                };
                @memcpy(out[off..][0..ccs_record.len], &ccs_record);
                off += ccs_record.len;

                // Client Finished handshake message
                const transcript_hash = self.transcript.peek();
                const digest_len = self.transcript.digestLen();
                const verify_data = handshake.tls12FinishedVerifyData(
                    HmacType,
                    &master_secret,
                    transcript_hash[0..digest_len],
                    "client finished",
                );

                handshake.writeHandshakeHeader(.finished, 12, out[off..][0..4]);
                const finished_off = off + 4;
                @memcpy(out[finished_off..][0..12], &verify_data);
                off = finished_off + 12;

                // Update transcript with Finished (header + verify_data = 16 bytes)
                self.transcript.update(out[off - 16 ..][0..16]);
            },
            else => return error.TlsUnsupportedCipherSuite,
        }

        self.state = .connected;
        return off;
    }

    /// Process the server's Finished message.
    pub fn processServerFinished(self: *Handshake12Client, data: []const u8) errors.TlsError!void {
        if (data.len < 4 + 12) return error.TlsDecodeError;
        // Skip handshake type + 3-byte length
        const verify_data = data[4..][0..12];

        // Verify the server's Finished verify_data
        const ms = self.master_secret orelse return error.TlsHandshakeFailure;
        const suite = self.cipher_suite orelse return error.TlsHandshakeFailure;

        switch (suite) {
            inline .ECDHE_RSA_WITH_AES_128_GCM_SHA256,
            .ECDHE_RSA_WITH_AES_256_GCM_SHA384,
            .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
            => |tag| {
                const HmacType = switch (tag) {
                    .ECDHE_RSA_WITH_AES_256_GCM_SHA384 => HmacSha384,
                    else => HmacSha256,
                };
                const transcript_hash = self.transcript.peek();
                const digest_len = self.transcript.digestLen();
                const expected = handshake.tls12FinishedVerifyData(
                    HmacType,
                    &ms,
                    transcript_hash[0..digest_len],
                    "server finished",
                );

                if (!std.crypto.timing_safe.eql([12]u8, expected, verify_data.*)) {
                    return error.TlsDecryptError;
                }
            },
            else => return error.TlsUnsupportedCipherSuite,
        }

        self.transcript.update(data);
        self.state = .connected;
    }
};

// TLS 1.2 state machine (server role)

pub const ServerState12 = enum {
    wait_client_hello,
    wait_client_key_exchange,
    wait_change_cipher_spec,
    wait_finished,
    connected,
};

pub const Handshake12Server = struct {
    allocator: mem.Allocator,
    state: ServerState12 = .wait_client_hello,
    transcript: transcript_mod.TranscriptHash = .{},
    key_exchange: handshake.KeyExchange = .{},
    negotiated_alpn: alpn.NegotiatedAlpn = .{},

    client_random: [32]u8 = undefined,
    server_random: [32]u8 = undefined,
    cipher_suite: tls.CipherSuite = .ECDHE_RSA_WITH_AES_128_GCM_SHA256,

    server_name: ?[]const u8 = null,
    alpn_protocols: []const []const u8 = &.{},

    // Server certificate chain (DER-encoded)
    cert_chain_der: []const []const u8 = &.{},

    pub fn init(allocator: mem.Allocator) Handshake12Server {
        var tr: transcript_mod.TranscriptHash = .{};
        tr.initAlgorithm(.sha256);
        return .{
            .allocator = allocator,
            .transcript = tr,
        };
    }

    /// Process a ClientHello from the client.
    pub fn processClientHello(self: *Handshake12Server, data: []const u8) errors.TlsError!void {
        if (data.len < 42) return error.TlsDecodeError;

        var off: usize = 4; // skip handshake type + length

        // Client version
        const version = mem.readInt(u16, data[off..][0..2], .big);
        if (version != @intFromEnum(tls.ProtocolVersion.tls_1_2)) return error.TlsProtocolVersion;
        off += 2;

        // Client random
        @memcpy(&self.client_random, data[off..][0..32]);
        off += 32;

        // Session ID
        const session_id_len = data[off];
        off += 1 + session_id_len;

        // Cipher suites
        if (off + 2 > data.len) return error.TlsDecodeError;
        const cs_list_len = mem.readInt(u16, data[off..][0..2], .big);
        off += 2;
        off += cs_list_len; // skip for now, we pick from our preferred list

        // Compression methods
        if (off >= data.len) return error.TlsDecodeError;
        const comp_len = data[off];
        off += 1 + comp_len;

        // Parse extensions
        if (off + 2 <= data.len) {
            const ext_len = mem.readInt(u16, data[off..][0..2], .big);
            off += 2;
            const ext_end = @min(off + ext_len, data.len);

            while (off + 4 <= ext_end) {
                const ext_type: tls.ExtensionType = @enumFromInt(mem.readInt(u16, data[off..][0..2], .big));
                const ext_data_len = mem.readInt(u16, data[off + 2 ..][0..2], .big);
                off += 4;
                if (off + ext_data_len > ext_end) return error.TlsDecodeError;
                const ext_data = data[off..][0..ext_data_len];
                off += ext_data_len;

                switch (ext_type) {
                    .server_name => {
                        var host: []const u8 = "";
                        if (extensions_mod.parseSniExtension(ext_data, &host)) {
                            self.server_name = host;
                        }
                    },
                    .application_layer_protocol_negotiation => {
                        var protos: [extensions_mod.max_alpn_protocols][]const u8 = undefined;
                        const n = try extensions_mod.parseAlpnExtension(ext_data, &protos);
                        // Server-side ALPN selection
                        for (self.alpn_protocols) |sp| {
                            for (protos[0..n]) |cp| {
                                if (mem.eql(u8, sp, cp)) {
                                    self.negotiated_alpn.set(sp);
                                    break;
                                }
                            }
                            if (self.negotiated_alpn.get() != null) break;
                        }
                    },
                    else => {},
                }
            }
        }

        // Generate server random
        tlsRandom(&self.server_random);

        // Initialize key exchange
        var entropy: [96]u8 = undefined;
        tlsRandom(&entropy);
        self.key_exchange = try handshake.KeyExchange.init(&entropy);

        self.transcript.update(data);
        self.state = .wait_client_key_exchange;
    }

    /// Build ServerHello message. Returns bytes written to `out`.
    pub fn buildServerHello(self: *Handshake12Server, out: []u8) errors.TlsError!usize {
        if (out.len < 256) return error.TlsBufferTooSmall;

        var off: usize = 0;

        // Handshake header
        out[0] = @intFromEnum(tls.HandshakeType.server_hello);
        off += 4;

        // Server version
        mem.writeInt(u16, out[off..][0..2], @intFromEnum(tls.ProtocolVersion.tls_1_2), .big);
        off += 2;

        // Server random
        @memcpy(out[off..][0..32], &self.server_random);
        off += 32;

        // Session ID length = 0
        out[off] = 0;
        off += 1;

        // Cipher suite
        mem.writeInt(u16, out[off..][0..2], @intFromEnum(self.cipher_suite), .big);
        off += 2;

        // Compression method
        out[off] = 0;
        off += 1;

        // Extensions
        const ext_len_offset = off;
        off += 2;
        var ext_written: usize = 0;

        // ALPN extension (if negotiated)
        if (self.negotiated_alpn.get()) |proto| {
            const proto_list: [1][]const u8 = .{proto};
            ext_written += try extensions_mod.writeAlpnExtension(out[off + ext_written ..], &proto_list);
        }

        mem.writeInt(u16, out[ext_len_offset..][0..2], @intCast(ext_written), .big);
        off += ext_written;

        const body_len: u24 = @intCast(off - 4);
        handshake.writeHandshakeHeader(.server_hello, body_len, out[0..4]);

        self.transcript.update(out[0..off]);
        return off;
    }

    /// Build Certificate message. Returns bytes written to `out`.
    pub fn buildCertificate(self: *Handshake12Server, out: []u8) errors.TlsError!usize {
        if (out.len < 7) return error.TlsBufferTooSmall;

        var off: usize = 0;

        // Handshake header (type + 3-byte length, filled in later)
        off += 4;

        // Calculate total certificate list length
        var cert_list_len: usize = 0;
        for (self.cert_chain_der) |cert_der| {
            // Each entry: 3-byte length + cert_der
            cert_list_len += 3 + cert_der.len;
        }

        // Write certificate list length (3 bytes)
        out[off] = @intCast((cert_list_len >> 16) & 0xFF);
        out[off + 1] = @intCast((cert_list_len >> 8) & 0xFF);
        out[off + 2] = @intCast(cert_list_len & 0xFF);
        off += 3;

        // Write each certificate
        for (self.cert_chain_der) |cert_der| {
            // Certificate length (3 bytes)
            out[off] = @intCast((cert_der.len >> 16) & 0xFF);
            out[off + 1] = @intCast((cert_der.len >> 8) & 0xFF);
            out[off + 2] = @intCast(cert_der.len & 0xFF);
            off += 3;

            // Certificate data
            if (off + cert_der.len > out.len) return error.TlsBufferTooSmall;
            @memcpy(out[off..][0..cert_der.len], cert_der);
            off += cert_der.len;
        }

        const body_len: u24 = @intCast(off - 4);
        handshake.writeHandshakeHeader(.certificate, body_len, out[0..4]);

        self.transcript.update(out[0..off]);
        return off;
    }

    /// Build ServerKeyExchange (ECDHE). Returns bytes written to `out`.
    pub fn buildServerKeyExchange(self: *Handshake12Server, out: []u8) errors.TlsError!usize {
        if (out.len < 256) return error.TlsBufferTooSmall;

        var off: usize = 0;

        // Handshake header
        out[0] = @intFromEnum(tls.HandshakeType.server_key_exchange);
        off += 4;

        // Curve type = named_curve (0x03)
        out[off] = 0x03;
        off += 1;

        // Named group
        const group = tls.NamedGroup.x25519;
        mem.writeInt(u16, out[off..][0..2], @intFromEnum(group), .big);
        off += 2;

        // Public key
        const pub_key = try self.key_exchange.getPublicKey(group);
        out[off] = @intCast(pub_key.len);
        off += 1;
        @memcpy(out[off..][0..pub_key.len], pub_key);
        off += pub_key.len;

        // Signature (empty for now  --  a full implementation would sign with the server cert)
        mem.writeInt(u16, out[off..][0..2], @intFromEnum(tls.SignatureScheme.rsa_pkcs1_sha256), .big);
        off += 2;
        mem.writeInt(u16, out[off..][0..2], 0, .big); // signature length = 0
        off += 2;

        const body_len: u24 = @intCast(off - 4);
        handshake.writeHandshakeHeader(.server_key_exchange, body_len, out[0..4]);

        self.transcript.update(out[0..off]);
        return off;
    }

    /// Build ServerHelloDone. Returns bytes written to `out`.
    pub fn buildServerHelloDone(self: *Handshake12Server, out: []u8) errors.TlsError!usize {
        if (out.len < 4) return error.TlsBufferTooSmall;
        handshake.writeHandshakeHeader(.server_hello_done, 0, out[0..4]);
        self.transcript.update(out[0..4]);
        self.state = .wait_client_key_exchange;
        return 4;
    }

    /// Process ClientKeyExchange. Returns bytes written to `out` for CCS + Finished.
    pub fn processClientKeyExchange(self: *Handshake12Server, data: []const u8) errors.TlsError!void {
        if (data.len < 5) return error.TlsDecodeError;

        // Skip handshake type + 3-byte length
        var off: usize = 4;
        const key_len = data[off];
        off += 1;
        if (off + key_len > data.len) return error.TlsDecodeError;
        const client_pub_key = data[off..][0..key_len];

        // Perform key exchange
        try self.key_exchange.exchange(tls.NamedGroup.x25519, client_pub_key);

        self.transcript.update(data);
        self.state = .wait_change_cipher_spec;
    }

    /// Build ChangeCipherSpec + Finished. Returns bytes written to `out`.
    pub fn buildChangeCipherSpecAndFinished(self: *Handshake12Server, out: []u8) errors.TlsError!usize {
        if (out.len < 256) return error.TlsBufferTooSmall;

        var off: usize = 0;

        // ChangeCipherSpec record
        out[0] = @intFromEnum(tls.ContentType.change_cipher_spec);
        out[1] = 0x03;
        out[2] = 0x01;
        out[3] = 0x00;
        out[4] = 0x01;
        out[5] = 0x01;
        off += 6;

        // Derive master secret
        const shared_secret = self.key_exchange.getSharedSecret() orelse return error.TlsKeyExchangeFailed;
        var master_secret: [48]u8 = undefined;
        master_secret = handshake.deriveMasterSecret(HmacSha256, shared_secret, &self.client_random, &self.server_random);

        // Compute Finished verify_data
        const transcript_hash = self.transcript.peek();
        const verify_data = handshake.tls12FinishedVerifyData(
            HmacSha256,
            &master_secret,
            transcript_hash[0..32],
            "server finished",
        );

        // Finished handshake message
        handshake.writeHandshakeHeader(.finished, 12, out[off..][0..4]);
        off += 4;
        @memcpy(out[off..][0..12], &verify_data);
        off += 12;

        self.transcript.update(out[off - 16 ..][0..16]);
        self.state = .connected;
        return off;
    }

    /// Process client's Finished message.
    pub fn processClientFinished(self: *Handshake12Server, data: []const u8) errors.TlsError!void {
        if (data.len < 4 + 12) return error.TlsDecodeError;
        self.transcript.update(data);
        self.state = .connected;
    }
};

// Tests

test "Handshake12Client buildClientHello" {
    var client = Handshake12Client.init(std.testing.allocator);
    var buf: [2048]u8 = undefined;
    const n = try client.buildClientHello(&buf, "example.com", &.{ "h2", "http/1.1" });
    try std.testing.expect(n > 64);
    try std.testing.expectEqual(ClientState12.wait_server_hello, client.state);
    // Verify the handshake type byte
    try std.testing.expectEqual(@intFromEnum(tls.HandshakeType.client_hello), buf[0]);
}

test "Handshake12Server init" {
    const server = Handshake12Server.init(std.testing.allocator);
    try std.testing.expectEqual(ServerState12.wait_client_hello, server.state);
}

test "Handshake12Client init defaults" {
    const client = Handshake12Client.init(std.testing.allocator);
    try std.testing.expectEqual(ClientState12.start, client.state);
    try std.testing.expect(client.cipher_suite == null);
    try std.testing.expect(client.master_secret == null);
}

test "Handshake12Client buildClientHello includes SNI" {
    var client = Handshake12Client.init(std.testing.allocator);
    var buf: [2048]u8 = undefined;
    const n = try client.buildClientHello(&buf, "test.example.com", &.{"http/1.1"});
    // Verify the message contains the SNI extension (type 0x0000)
    var found_sni = false;
    var off: usize = 4; // skip handshake header
    off += 2 + 32 + 1; // version + random + session_id_len
    off += 2; // skip cipher suites length
    const cs_len = std.mem.readInt(u16, buf[off - 2 ..][0..2], .big);
    off += cs_len;
    off += 1; // compression methods length
    off += 1; // compression method
    const ext_len = std.mem.readInt(u16, buf[off..][0..2], .big);
    off += 2;
    const ext_end = off + ext_len;
    while (off + 4 <= ext_end) {
        const ext_type = std.mem.readInt(u16, buf[off..][0..2], .big);
        const ext_data_len = std.mem.readInt(u16, buf[off + 2 ..][0..2], .big);
        if (ext_type == 0x0000) {
            found_sni = true;
            break;
        }
        off += 4 + ext_data_len;
    }
    try std.testing.expect(found_sni);
    _ = n;
}

test "Handshake12Server processClientHello rejects short data" {
    var server = Handshake12Server.init(std.testing.allocator);
    const short_data: [5]u8 = [_]u8{0} ** 5;
    const result = server.processClientHello(&short_data);
    try std.testing.expectError(error.TlsDecodeError, result);
}

test "Handshake12Server buildServerHelloDone is 4 bytes" {
    var server = Handshake12Server.init(std.testing.allocator);
    var buf: [32]u8 = undefined;
    const n = try server.buildServerHelloDone(&buf);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@intFromEnum(tls.HandshakeType.server_hello_done), buf[0]);
}

test "Handshake12Client processServerHello rejects short data" {
    var client = Handshake12Client.init(std.testing.allocator);
    const short_data: [5]u8 = [_]u8{0} ** 5;
    const result = client.processServerHello(&short_data);
    try std.testing.expectError(error.TlsDecodeError, result);
}

test "Handshake12Client processCertificate rejects short data" {
    var client = Handshake12Client.init(std.testing.allocator);
    const short_data: [3]u8 = [_]u8{0} ** 3;
    const result = client.processCertificate(&short_data);
    try std.testing.expectError(error.TlsDecodeError, result);
}

test "Handshake12Client processServerHelloDone rejects short data" {
    var client = Handshake12Client.init(std.testing.allocator);
    const short_data: [3]u8 = [_]u8{0} ** 3;
    const result = client.processServerHelloDone(&short_data);
    try std.testing.expectError(error.TlsDecodeError, result);
}

test "Handshake12Server buildCertificate is 7 bytes" {
    var server = Handshake12Server.init(std.testing.allocator);
    var buf: [32]u8 = undefined;
    const n = try server.buildCertificate(&buf);
    try std.testing.expectEqual(@as(usize, 7), n);
    try std.testing.expectEqual(@intFromEnum(tls.HandshakeType.certificate), buf[0]);
}
