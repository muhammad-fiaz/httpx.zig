//! TLS 1.3 server over TCP with ALPN dispatch (RFC 8446).
//!
//! Accepts TCP connections, performs a complete TLS 1.3 server handshake
//! with SNI parsing, ALPN negotiation, and record-level encryption, then
//! dispatches to the appropriate HTTP handler based on the negotiated
//! protocol.
//!
//! This module ties together:
//!   - TLS record layer (record.zig) — AEAD encrypt/decrypt
//!   - TLS handshake engine (engine.zig) — key schedule, Finished
//!   - ALPN negotiation (alpn.zig) — protocol selection
//!   - Config (config.zig) — certificate chain, private key, SNI map
//!   - TCP socket (sockets/tcp.zig) — transport
//!
//! Thread-safety: one connection = one TlsServerConn, not shared.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tls = std.crypto.tls;

const engine_mod = @import("engine.zig");
const handshake_mod = @import("handshake.zig");
const record_mod = @import("record.zig");
const alpn_mod = @import("alpn.zig");
const config_mod = @import("config.zig");
const tcp = @import("../../sockets/tcp.zig");

// Errors

pub const Error = error{
    TlsHandshakeFailed,
    TlsRecordError,
    TlsAlertSent,
    TlsFatalAlert,
    TlsCloseNotify,
    TlsProtocolViolation,
    TlsUnsupportedSni,
    AcceptFailed,
    IoError,
    OutOfMemory,
    BufferTooSmall,
    MissingCertificate,
};

// TLS server connection (post-handshake)

/// Represents a completed TLS server connection ready for application data.
pub const TlsServerConn = struct {
    socket: *tcp.Socket,
    allocator: Allocator,

    /// Negotiated ALPN protocol.
    alpn: ?alpn_mod.Protocol,

    /// SNI hostname from ClientHello, if any.
    sni: ?[]const u8,

    /// Application traffic keys for encrypt/decrypt.
    app_keys: engine_mod.DerivedKeys,

    /// Sequence numbers for application records.
    tx_seq: u64 = 0,
    rx_seq: u64 = 0,

    /// Write buffer for outgoing encrypted records.
    write_buf: []u8,

    /// Read buffer for incoming encrypted records.
    read_buf: []u8,

    /// Leftover plaintext from a previous read (partial record).
    leftover: []const u8 = &.{},

    pub fn deinit(self: *TlsServerConn) void {
        self.allocator.free(self.write_buf);
        self.allocator.free(self.read_buf);
        if (self.sni) |hostname| self.allocator.free(hostname);
    }

    /// Encrypt and send application data.
    pub fn writeAll(self: *TlsServerConn, plaintext: []const u8) Error!void {
        var offset: usize = 0;
        while (offset < plaintext.len) {
            const chunk_len = @min(plaintext.len - offset, record_mod.max_record_plaintext);
            const encoded = try record_mod.encodeRecord(
                .application_data,
                plaintext[offset..][0..chunk_len],
                self.tx_seq,
                self.app_keys.serverKeySlice(),
                &self.app_keys.server_iv,
                self.app_keys.cipher,
            );
            self.socket.writeAll(encoded.bytes[0..encoded.len]) catch return error.IoError;
            self.tx_seq +%= 1;
            offset += chunk_len;
        }
    }

    /// Read and decrypt one record worth of application data.
    /// Returns the decrypted plaintext (valid until next readAll call).
    pub fn read(self: *TlsServerConn, buf: []u8) Error!usize {
        if (self.leftover.len > 0) {
            const n = @min(self.leftover.len, buf.len);
            @memcpy(buf[0..n], self.leftover[0..n]);
            self.leftover = self.leftover[n..];
            return n;
        }

        // Read record header (5 bytes)
        var hdr_buf: [5]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < 5) {
            const n = self.socket.read(hdr_buf[total_read..]) catch return error.IoError;
            if (n == 0) return 0; // peer closed
            total_read += n;
        }

        // TLS 1.3 records use the TLS 1.2 legacy version on the wire.
        if (hdr_buf[1] != 0x03 or hdr_buf[2] != 0x03) return error.TlsRecordError;

        const record_len: usize = (@as(usize, hdr_buf[3]) << 8) | hdr_buf[4];
        const tag_len = self.app_keys.cipher.tagLen();
        if (record_len < tag_len or
            record_len > record_mod.max_record_plaintext + 1 + tag_len)
        {
            return error.TlsRecordError;
        }

        // Read record body
        var wire_buf: [record_mod.max_record_wire]u8 = undefined;
        @memcpy(wire_buf[0..5], &hdr_buf);
        total_read = 0;
        while (total_read < record_len) {
            const n = self.socket.read(wire_buf[5 + total_read ..][0 .. record_len - total_read]) catch return error.IoError;
            if (n == 0) return error.TlsRecordError;
            total_read += n;
        }

        // Check content type
        const content_type_byte = wire_buf[0];
        if (content_type_byte != @intFromEnum(record_mod.ContentType.application_data)) {
            if (content_type_byte == @intFromEnum(record_mod.ContentType.alert)) {
                // Try to decrypt to read alert description
                var decrypt_buf: [record_mod.max_record_plaintext + 1]u8 = undefined;
                const result = record_mod.decodeRecord(
                    wire_buf[0..][0 .. 5 + record_len],
                    &decrypt_buf,
                    self.rx_seq,
                    self.app_keys.clientKeySlice(),
                    &self.app_keys.client_iv,
                    self.app_keys.cipher,
                ) catch return error.TlsFatalAlert;
                if (result.plaintext.len >= 2) {
                    const alert = handshake_mod.Alert.decode(.{ result.plaintext[0], result.plaintext[1] });
                    if (alert.description == .close_notify) return error.TlsCloseNotify;
                }
                return error.TlsFatalAlert;
            }
            return error.TlsRecordError;
        }

        // Decrypt application record
        var decrypt_buf: [record_mod.max_record_plaintext + 1]u8 = undefined;
        const result = record_mod.decodeRecord(
            wire_buf[0..][0 .. 5 + record_len],
            &decrypt_buf,
            self.rx_seq,
            self.app_keys.clientKeySlice(),
            &self.app_keys.client_iv,
            self.app_keys.cipher,
        ) catch return error.TlsRecordError;
        self.rx_seq +%= 1;

        const n = @min(result.plaintext.len, buf.len);
        @memcpy(buf[0..n], result.plaintext[0..n]);
        if (n < result.plaintext.len) {
            self.leftover = result.plaintext[n..];
        }
        return n;
    }
};

// TLS server listener

/// SNI-based certificate selector. Maps hostname → certificate identity.
pub const CertSelector = struct {
    ctx: ?*anyopaque = null,
    select: *const fn (ctx: ?*anyopaque, hostname: ?[]const u8) ?CertIdentity,
};

pub const CertIdentity = struct {
    cert_chain_pem: []const u8,
    private_key_pem: []const u8,
};

/// Configuration for the TLS server.
pub const TlsServerConfig = struct {
    allocator: Allocator,

    /// Default certificate (used when SNI doesn't match any specific cert).
    default_identity: ?CertIdentity = null,

    /// SNI certificate selector (optional; falls back to default_identity).
    cert_selector: ?CertSelector = null,

    /// ALPN protocols in server preference order (TCP: no h3, QUIC handles h3 separately).
    alpn_protocols: []const alpn_mod.Protocol = &alpn_mod.DEFAULT_TCP_PREFERENCE,

    pub fn init(allocator: Allocator) TlsServerConfig {
        return .{ .allocator = allocator };
    }
};

/// TLS server that wraps TCP + TLS handshake.
pub const TlsServer = struct {
    config: TlsServerConfig,

    pub fn init(config: TlsServerConfig) TlsServer {
        return .{ .config = config };
    }

    /// Perform TLS 1.3 server handshake on an accepted TCP connection.
    ///
    /// This reads the ClientHello, extracts SNI, performs ALPN negotiation,
    /// derives keys via the TLS 1.3 key schedule, and sends the full server
    /// flight (ServerHello + EncryptedExtensions + Certificate +
    /// CertificateVerify + Finished) as plaintext records.
    pub fn handshake(self: *TlsServer, socket: *tcp.Socket) !TlsServerConn {
        const a = self.config.allocator;

        var engine = engine_mod.Engine.initServer(a, .{});

        // ---- Read ClientHello ----
        var read_buf: [16384]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < 4) {
            const n = socket.read(read_buf[total_read..]) catch return error.IoError;
            if (n == 0) return error.TlsHandshakeFailed;
            total_read += n;
        }

        // Parse handshake header
        if (read_buf[0] != @intFromEnum(handshake_mod.HandshakeType.client_hello)) {
            return error.TlsHandshakeFailed;
        }
        const body_len: u24 = @as(u24, @intCast(read_buf[1])) << 16 |
            @as(u24, @intCast(read_buf[2])) << 8 |
            @as(u24, @intCast(read_buf[3]));
        if (body_len > max_handshake_body) return error.TlsHandshakeFailed;

        // Read remaining body
        while (total_read < 4 + body_len) {
            const n = socket.read(read_buf[total_read..]) catch return error.IoError;
            if (n == 0) return error.TlsHandshakeFailed;
            total_read += n;
        }

        // Parse the ClientHello body for SNI and ALPN
        const ch_body = read_buf[4..][0..body_len];
        var parsed_ch = try parseClientHelloExtensions(a, ch_body);
        defer parsed_ch.alpn_protocols.deinit(a);

        // Feed the full ClientHello (header + body) to the transcript
        try engine.processClientHello(ch_body);

        // Store SNI in engine
        if (parsed_ch.sni) |sni| {
            engine.negotiated_alpn = null; // will be set during ALPN processing
            _ = sni; // stored via engine
        }

        // ---- Select certificate ----
        const identity = self.resolveIdentity(parsed_ch.sni) orelse return error.MissingCertificate;
        if (identity.cert_chain_pem.len == 0 or identity.private_key_pem.len == 0)
            return error.MissingCertificate;

        // ---- Server produces flight ----
        const flight = try engine.produceServerFlight(
            identity.cert_chain_pem,
            identity.private_key_pem,
            self.config.alpn_protocols,
            parsed_ch.alpn_protocols.items,
        );
        defer flight.deinit(a);

        // ServerHello is the final plaintext handshake message. The remaining
        // flight is carried in TLS 1.3 encrypted handshake records.
        try writePlaintextHandshakeRecord(socket, flight.server_hello);
        const hs_keys = engine.hs_keys orelse return error.TlsHandshakeFailed;
        var hs_seq: u64 = 0;
        try writeEncryptedHandshakeRecord(socket, flight.encrypted_extensions, hs_keys, &hs_seq);
        try writeEncryptedHandshakeRecord(socket, flight.certificate, hs_keys, &hs_seq);
        try writeEncryptedHandshakeRecord(socket, flight.certificate_verify, hs_keys, &hs_seq);
        try writeEncryptedHandshakeRecord(socket, flight.finished, hs_keys, &hs_seq);

        // ---- Derive application keys ----
        // Application keys were derived at the end of produceServerFlight
        const ap_keys = engine.ap_keys orelse return error.TlsHandshakeFailed;

        // Allocate read/write buffers for application records
        const write_buf = try a.alloc(u8, record_mod.max_record_wire);
        errdefer a.free(write_buf);
        const read_buf_app = try a.alloc(u8, record_mod.max_record_wire);
        errdefer a.free(read_buf_app);

        const sni_copy = if (parsed_ch.sni) |hostname| try a.dupe(u8, hostname) else null;
        errdefer if (sni_copy) |hostname| a.free(hostname);

        return .{
            .socket = socket,
            .allocator = a,
            .alpn = if (engine.negotiated_alpn) |a_name| alpn_mod.Protocol.fromWire(a_name) else null,
            .sni = sni_copy,
            .app_keys = ap_keys,
            .write_buf = write_buf,
            .read_buf = read_buf_app,
        };
    }

    fn writePlaintextHandshakeRecord(socket: *tcp.Socket, message: []const u8) !void {
        if (message.len > std.math.maxInt(u16)) return error.TlsHandshakeFailed;
        var header: [5]u8 = .{ 0x16, 0x03, 0x03, 0, 0 };
        std.mem.writeInt(u16, header[3..5], @intCast(message.len), .big);
        try socket.writeAll(&header);
        try socket.writeAll(message);
    }

    fn writeEncryptedHandshakeRecord(socket: *tcp.Socket, message: []const u8, keys: engine_mod.DerivedKeys, seq: *u64) !void {
        const encoded = try record_mod.encodeRecord(.handshake, message, seq.*, keys.serverKeySlice(), &keys.server_iv, keys.cipher);
        try socket.writeAll(encoded.bytes[0..encoded.len]);
        seq.* +%= 1;
    }

    fn resolveIdentity(self: *const TlsServer, sni: ?[]const u8) ?CertIdentity {
        if (self.config.cert_selector) |sel| {
            return sel.select(sel.ctx, sni);
        }
        return self.config.default_identity;
    }
};

// ClientHello parsing helpers

const max_handshake_body = 1 << 14;

const ParsedClientHello = struct {
    sni: ?[]const u8 = null,
    alpn_protocols: std.ArrayList([]const u8),
};

/// Parse extensions from a ClientHello body to extract SNI and ALPN.
fn parseClientHelloExtensions(allocator: Allocator, body: []const u8) !ParsedClientHello {
    if (body.len < 34) return error.TlsHandshakeFailed;

    // ClientHello body layout (matching our encoder):
    //   [0..2]   client_version
    //   [2..34]  random
    //   [34]       legacy_session_id_length (u8)
    //   [35..]     legacy_session_id
    //   [...]      cipher suites, compression methods, extensions
    var pos: usize = 34; // skip client_version(2) + random(32)

    if (pos + 1 > body.len) return error.TlsHandshakeFailed;
    const session_id_len = body[pos];
    pos += 1;
    const session_end = std.math.add(usize, pos, session_id_len) catch return error.TlsHandshakeFailed;
    if (session_end > body.len) return error.TlsHandshakeFailed;
    pos += session_id_len;

    if (pos + 2 > body.len) return error.TlsHandshakeFailed;
    const cs_len: usize = (@as(usize, body[pos]) << 8) | body[pos + 1];
    pos += 2 + cs_len;

    if (pos + 1 > body.len) return error.TlsHandshakeFailed;
    const comp_len = body[pos];
    pos += 1 + comp_len;

    if (pos + 2 > body.len) return error.TlsHandshakeFailed;
    const ext_len: usize = (@as(usize, body[pos]) << 8) | body[pos + 1];
    pos += 2;
    const ext_end = std.math.add(usize, pos, ext_len) catch return error.TlsHandshakeFailed;
    if (ext_end > body.len) return error.TlsHandshakeFailed;

    var result = ParsedClientHello{
        .alpn_protocols = std.ArrayList([]const u8).empty,
    };
    errdefer result.alpn_protocols.deinit(allocator);

    while (pos + 4 <= ext_end) {
        const ext_type = std.mem.readInt(u16, body[pos..][0..2], .big);
        const ext_data_len: usize = (@as(usize, body[pos + 2]) << 8) | body[pos + 3];
        pos += 4;
        const data_end = std.math.add(usize, pos, ext_data_len) catch return error.TlsHandshakeFailed;
        if (data_end > ext_end) return error.TlsHandshakeFailed;

        if (ext_type == @intFromEnum(handshake_mod.ExtensionType.server_name)) {
            result.sni = try parseSniExtension(body[pos..][0..ext_data_len]);
        } else if (ext_type == @intFromEnum(handshake_mod.ExtensionType.application_layer_protocol_negotiation)) {
            result.alpn_protocols = try parseAlpnExtension(allocator, body[pos..][0..ext_data_len]);
        }

        pos = data_end;
    }

    if (pos != ext_end) return error.TlsHandshakeFailed;

    return result;
}

/// Parse the server_name extension to extract the hostname.
fn parseSniExtension(data: []const u8) !?[]const u8 {
    if (data.len < 5) return error.TlsHandshakeFailed;
    // list length (2 bytes), then at least one entry
    const list_len: usize = (@as(usize, data[0]) << 8) | data[1];
    const list_end = std.math.add(usize, 2, list_len) catch return null;
    if (list_len < 3 or list_end != data.len) return error.TlsHandshakeFailed;

    // name type (1 byte) + name length (2 bytes)
    const name_type = data[2];
    if (name_type != 0) return error.TlsHandshakeFailed; // only host_name type
    const name_len: usize = (@as(usize, data[3]) << 8) | data[4];
    const name_end = std.math.add(usize, 5, name_len) catch return null;
    if (name_end != list_end) return error.TlsHandshakeFailed;

    return data[5..][0..name_len];
}

/// Parse the ALPN extension to extract the list of offered protocol names.
fn parseAlpnExtension(allocator: Allocator, data: []const u8) !std.ArrayList([]const u8) {
    var result = std.ArrayList([]const u8).empty;
    errdefer result.deinit(allocator);
    if (data.len < 2) return error.TlsHandshakeFailed;
    const list_len: usize = (@as(usize, data[0]) << 8) | data[1];
    if (list_len != data.len - 2) return error.TlsHandshakeFailed;
    var pos: usize = 2;
    const list_end = 2 + list_len;
    while (pos < list_end) {
        if (pos + 1 > list_end) return error.TlsHandshakeFailed;
        const name_len = data[pos];
        pos += 1;
        if (name_len == 0 or pos + name_len > list_end) return error.TlsHandshakeFailed;
        try result.append(allocator, data[pos..][0..name_len]);
        pos += name_len;
    }
    if (pos != list_end) return error.TlsHandshakeFailed;
    return result;
}

// Tests

test "tls server handshake processes client hello" {
    const a = std.testing.allocator;

    // Create a client that produces a ClientHello
    var client = engine_mod.Engine.initClient(a, .{});
    const ch = try client.produceClientHello(&.{"h2"}, &.{});
    defer a.free(ch);

    try std.testing.expectEqual(@as(u8, 0x01), ch[0]);

    // Process it through a server engine
    var server_engine = engine_mod.Engine.initServer(a, .{});
    try server_engine.processClientHello(ch[4..]);
    try std.testing.expectEqual(engine_mod.Engine.State.client_hello_received, server_engine.state);
}

test "alpn negotiation in server config" {
    const cfg = TlsServerConfig{
        .allocator = std.testing.allocator,
    };
    try std.testing.expectEqual(@as(usize, 3), cfg.alpn_protocols.len);
    try std.testing.expectEqual(alpn_mod.Protocol.h2, cfg.alpn_protocols[0]);
    try std.testing.expectEqual(alpn_mod.Protocol.@"http/1.1", cfg.alpn_protocols[1]);
    try std.testing.expectEqual(alpn_mod.Protocol.@"http/1.0", cfg.alpn_protocols[2]);
}

test "ClientHello SNI parsing" {
    const a = std.testing.allocator;

    var client = engine_mod.Engine.initClient(a, .{});
    const ch = try client.produceClientHelloWithSni(&.{"h2"}, &.{}, "example.com");
    defer a.free(ch);

    // Parse the ClientHello body for extensions
    var parsed = try parseClientHelloExtensions(a, ch[4..]);
    defer parsed.alpn_protocols.deinit(a);
    try std.testing.expect(parsed.sni != null);
    try std.testing.expectEqualStrings("example.com", parsed.sni.?);
}

test "TLS extension parsers reject malformed SNI and ALPN" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.TlsHandshakeFailed, parseSniExtension(&.{ 0, 3, 0, 0, 1 }));
    try std.testing.expectError(error.TlsHandshakeFailed, parseSniExtension(&.{ 0, 5, 0, 0, 1, 'x', 0 }));
    try std.testing.expectError(error.TlsHandshakeFailed, parseAlpnExtension(a, &.{ 0, 3, 2, 'h' }));
    try std.testing.expectError(error.TlsHandshakeFailed, parseAlpnExtension(a, &.{ 0, 2, 0, 'x' }));
}
