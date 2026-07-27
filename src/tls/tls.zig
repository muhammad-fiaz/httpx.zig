//! TLS/SSL Support for httpx.zig
//!
//! Provides TLS configuration and a session wrapper for HTTPS connections.
//! This module uses Zig's standard library TLS client (`std.crypto.tls.Client`).
//!
//! ## Notes
//!
//! - This is a thin wrapper around the stdlib TLS implementation.
//! - `std.crypto.tls.Client` does not advertise ALPN extensions in the TLS
//!   ClientHello, nor does it surface the negotiated protocol from the
//!   ServerHello. To determine whether the server supports HTTP/2, the library
//!   uses a **post-handshake H2 preface probe**: after the TLS handshake
//!   succeeds, the client sends the HTTP/2 connection preface
//!   (`PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`) and waits for a SETTINGS frame. If one
//!   arrives, `negotiated_protocol` is set to `"h2"`; otherwise the consumed
//!   bytes are buffered and the caller falls back to HTTP/1.1.
//! - The high-level HTTP/3 runtime path uses UDP + QUIC framing primitives and
//!   does not go through this TLS wrapper.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const Socket = @import("../net/socket.zig").Socket;
const SocketIoReader = @import("../net/socket.zig").SocketIoReader;
const SocketIoWriter = @import("../net/socket.zig").SocketIoWriter;
const io_util = @import("../util/any_io.zig");
const defaultIo = io_util.defaultIo;

/// HTTP/2 connection preface (RFC 7540 §3.5).
const HTTP2_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

/// Minimum TLS version configuration.
pub const TlsVersion = enum {
    tls_1_0,
    tls_1_1,
    tls_1_2,
    tls_1_3,

    pub fn toString(self: TlsVersion) []const u8 {
        return switch (self) {
            .tls_1_0 => "TLSv1.0",
            .tls_1_1 => "TLSv1.1",
            .tls_1_2 => "TLSv1.2",
            .tls_1_3 => "TLSv1.3",
        };
    }
};

/// TLS verification mode.
pub const VerifyMode = enum {
    none,
    peer,
    fail_if_no_peer_cert,
    client_once,
};

/// TLS configuration for clients and servers.
pub const TlsConfig = struct {
    allocator: Allocator,
    min_version: TlsVersion = .tls_1_2,
    max_version: TlsVersion = .tls_1_3,
    verify_mode: VerifyMode = .peer,
    verify_hostname: bool = true,
    ca_file: ?[]const u8 = null,
    ca_path: ?[]const u8 = null,
    cert_file: ?[]const u8 = null,
    key_file: ?[]const u8 = null,
    /// Application-Layer Protocol Negotiation protocol list.
    ///
    /// Listed protocols are stored and used by `TlsSession.handshake()` to
    /// detect HTTP/2 support via a post-handshake preface probe. The first
    /// entry should be the preferred protocol.
    alpn_protocols: []const []const u8 = &.{"http/1.1"},
    cipher_suites: ?[]const u8 = null,
    server_name: ?[]const u8 = null,

    /// When `false`, receiving a connection close without a TLS `close_notify`
    /// alert is treated as a truncation attack and returns an error.
    /// When `true` (the default), missing `close_notify` is tolerated.
    ///
    /// Set to `false` for security-sensitive connections that must enforce
    /// clean TLS shutdown (e.g. connections transferring authentication tokens).
    allow_truncation_attacks: bool = true,

    /// When `true`, skip the H2 preface probe and directly use HTTP/2 on TLS
    /// connections that advertise `"h2"` in `alpn_protocols`. Use for known-H2
    /// endpoints where the probe round-trip is undesirable.
    ///
    /// Default is `false` (probe is used, falling back to HTTP/1.1 if the
    /// server does not respond with an HTTP/2 SETTINGS frame).
    force_h2: bool = false,

    const Self = @This();

    /// Creates a default TLS configuration.
    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Creates a configuration that skips certificate verification.
    pub fn insecure(allocator: Allocator) Self {
        var config = init(allocator);
        config.verify_mode = .none;
        config.verify_hostname = false;
        return config;
    }

    /// Creates a configuration with HTTP/2 ALPN protocols advertised.
    pub fn withH2(allocator: Allocator) Self {
        var config = init(allocator);
        config.alpn_protocols = &.{ "h2", "http/1.1" };
        return config;
    }

    /// Creates an insecure configuration with HTTP/2 ALPN protocols advertised.
    pub fn insecureWithH2(allocator: Allocator) Self {
        var config = insecure(allocator);
        config.alpn_protocols = &.{ "h2", "http/1.1" };
        return config;
    }

    /// Sets the CA certificate file.
    pub fn setCaFile(self: *Self, path: []const u8) void {
        self.ca_file = path;
    }

    /// Sets the client certificate and key files.
    pub fn setClientCert(self: *Self, cert_file: []const u8, key_file: []const u8) void {
        self.cert_file = cert_file;
        self.key_file = key_file;
    }

    /// Sets the server name for SNI.
    pub fn setServerName(self: *Self, name: []const u8) void {
        self.server_name = name;
    }

    /// Creates a copy of the configuration.
    pub fn clone(self: *const Self) Self {
        return self.*;
    }

    /// Returns true if H2 is included in the ALPN protocol list.
    pub fn wantsHttp2(self: *const Self) bool {
        for (self.alpn_protocols) |proto| {
            if (std.mem.eql(u8, proto, "h2")) return true;
        }
        return false;
    }
};

/// TLS session state.
pub const TlsSession = struct {
    allocator: Allocator,
    config: TlsConfig,
    /// Set after handshake to the negotiated application protocol, or `null`
    /// if the protocol could not be determined (treated as HTTP/1.1).
    negotiated_protocol: ?[]const u8 = null,
    peer_certificate: ?[]const u8 = null,
    connected: bool = false,
    socket: ?*Socket = null,

    net_read_buf: ?[]u8 = null,
    net_write_buf: ?[]u8 = null,
    tls_read_buf: ?[]u8 = null,
    tls_write_buf: ?[]u8 = null,
    net_in: ?SocketIoReader = null,
    net_out: ?SocketIoWriter = null,

    ca_bundle: ?std.crypto.Certificate.Bundle = null,
    ca_bundle_lock: std.Io.RwLock = .init,
    client: ?std.crypto.tls.Client = null,

    /// Bytes buffered during the H2 preface probe that were already consumed
    /// from the TLS stream. These must be replayed before further reads so
    /// that callers receive a complete SETTINGS frame.
    h2_probe_buf: ?[]u8 = null,
    h2_probe_len: usize = 0,

    const Self = @This();

    /// Creates a new TLS session with the given configuration.
    pub fn init(config: TlsConfig) Self {
        return .{
            .allocator = config.allocator,
            .config = config,
        };
    }

    /// Releases session resources.
    pub fn deinit(self: *Self) void {
        if (self.client != null) {
            self.client = null;
        }

        if (self.ca_bundle) |*bundle| {
            bundle.deinit(self.allocator);
            self.ca_bundle = null;
        }

        if (self.net_read_buf) |buf| self.allocator.free(buf);
        if (self.net_write_buf) |buf| self.allocator.free(buf);
        if (self.tls_read_buf) |buf| self.allocator.free(buf);
        if (self.tls_write_buf) |buf| self.allocator.free(buf);
        if (self.h2_probe_buf) |buf| self.allocator.free(buf);

        self.net_read_buf = null;
        self.net_write_buf = null;
        self.tls_read_buf = null;
        self.tls_write_buf = null;
        self.net_in = null;
        self.net_out = null;
        self.h2_probe_buf = null;
        self.h2_probe_len = 0;
    }

    /// Attaches a connected socket that will carry the TLS session.
    pub fn attachSocket(self: *Self, socket: *Socket) void {
        self.socket = socket;
    }

    /// Performs the TLS handshake.
    ///
    /// When `config.alpn_protocols` contains `"h2"`, the session performs an
    /// HTTP/2 preface probe after the TLS handshake:
    ///
    /// 1. The client sends the 24-byte HTTP/2 connection preface.
    /// 2. It attempts to read a 9-byte HTTP/2 frame header.
    /// 3. If the first byte is 0x00 (SETTINGS frame type = 0x04 at offset 3,
    ///    or simply any valid HTTP/2 frame header pattern), the server supports
    ///    HTTP/2 and `negotiated_protocol` is set to `"h2"`. The read bytes
    ///    are saved in `h2_probe_buf` so the caller can replay them.
    /// 4. If the server responds differently, `negotiated_protocol` remains
    ///    `null` and the buffered bytes are similarly available for fallback.
    ///
    /// `allow_truncation_attacks` (from `TlsConfig`) is passed through to
    /// `std.crypto.tls.Client.init()`.
    pub fn handshake(self: *Self, hostname: []const u8) !void {
        const tls = std.crypto.tls;
        const sock = self.socket orelse return error.MissingTransport;
        const min_tls_buf = tls.Client.min_buffer_len;
        const net_buf_len: usize = @max(16 * 1024, min_tls_buf);

        // Allocate buffers once per session.
        if (self.net_read_buf == null) self.net_read_buf = try self.allocator.alloc(u8, net_buf_len);
        if (self.net_write_buf == null) self.net_write_buf = try self.allocator.alloc(u8, net_buf_len);

        if (self.tls_read_buf == null) self.tls_read_buf = try self.allocator.alloc(u8, min_tls_buf);
        if (self.tls_write_buf == null) self.tls_write_buf = try self.allocator.alloc(u8, min_tls_buf);

        const net_in = SocketIoReader.init(sock, self.net_read_buf.?);
        const net_out = SocketIoWriter.init(sock, self.net_write_buf.?);
        self.net_in = net_in;
        self.net_out = net_out;
        const io = defaultIo();

        const verify = self.config.verify_mode != .none;
        const verify_host = verify and self.config.verify_hostname;

        // System CA bundle (cross-platform); optional if verification is disabled.
        if (verify) {
            var bundle: std.crypto.Certificate.Bundle = .empty;
            errdefer bundle.deinit(self.allocator);
            try bundle.rescan(self.allocator, io, std.Io.Timestamp.now(io, .real));
            self.ca_bundle = bundle;
        }

        const sni_host = self.config.server_name orelse hostname;
        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&entropy);
        const ca_bundle_ptr: ?*std.crypto.Certificate.Bundle = if (self.ca_bundle) |*b| b else null;

        // Perform the TLS handshake using the stdlib client.
        // `allow_truncation_attacks` is forwarded from config so callers can
        // opt into strict close-notify enforcement.
        const client = try tls.Client.init(&self.net_in.?.reader, &self.net_out.?.writer, .{
            .host = if (verify_host) .{ .explicit = sni_host } else .{ .no_verification = {} },
            .ca = if (verify)
                .{ .bundle = .{
                    .gpa = self.allocator,
                    .io = io,
                    .lock = &self.ca_bundle_lock,
                    .bundle = ca_bundle_ptr.?,
                } }
            else
                .{ .no_verification = {} },
            .ssl_key_log = null,
            .allow_truncation_attacks = self.config.allow_truncation_attacks,
            .write_buffer = self.tls_write_buf.?,
            .read_buffer = self.tls_read_buf.?,
            .entropy = &entropy,
            .realtime_now = std.Io.Timestamp.now(io, .real),
            .alert = null,
        });

        self.client = client;
        self.connected = true;

        // HTTP/2 ALPN detection.
        //
        // `std.crypto.tls.Client` does not advertise ALPN extensions in the
        // ClientHello and does not expose the negotiated protocol. We detect
        // H2 support by sending the connection preface and checking whether
        // the server responds with an HTTP/2 SETTINGS frame (frame type 0x04
        // at byte offset 3 in the 9-byte frame header).
        //
        // The probe bytes (preface + server response header) are buffered in
        // `h2_probe_buf` and replayed on subsequent reads so no bytes are lost.
        if (self.config.wantsHttp2()) {
            self.negotiated_protocol = try self.probeHttp2Protocol();
        } else {
            self.negotiated_protocol = null;
        }
    }

    /// Sends the HTTP/2 connection preface and reads the first 9 bytes of the
    /// server response to determine whether HTTP/2 is supported.
    ///
    /// Returns `"h2"` if the server responds with a valid HTTP/2 frame header
    /// (specifically a SETTINGS frame, type 0x04, on stream 0). Returns `null`
    /// otherwise. In both cases the consumed bytes are stored in `h2_probe_buf`
    /// so they can be replayed to callers.
    fn probeHttp2Protocol(self: *Self) !?[]const u8 {
        const c = if (self.client) |*c| c else return null;

        // Send the 24-byte HTTP/2 connection preface.
        c.writer.writeAll(HTTP2_PREFACE) catch return null;
        c.writer.flush() catch return null;
        if (self.net_out) |*out| {
            out.writer.flush() catch return null;
        }

        // Read 9 bytes — the length of a standard HTTP/2 frame header.
        // We use readSliceShort which returns however many bytes are available,
        // so we retry until we get all 9 or give up.
        const frame_header_len: usize = 9;
        const probe_buf = try self.allocator.alloc(u8, HTTP2_PREFACE.len + frame_header_len);
        errdefer self.allocator.free(probe_buf);

        // Store the preface we already sent so callers that replay the buffer
        // get a complete picture. The server will not echo the preface back.
        // We only need to replay the server's response bytes.
        const server_response_buf = probe_buf[0..frame_header_len];

        var total_read: usize = 0;
        var attempts: usize = 0;
        while (total_read < frame_header_len and attempts < 16) : (attempts += 1) {
            const n = c.reader.readSliceShort(server_response_buf[total_read..]) catch break;
            if (n == 0) break;
            total_read += n;
        }

        if (total_read < frame_header_len) {
            // Could not read a full frame header — not H2 or connection error.
            // Store whatever we got for replay.
            self.h2_probe_buf = probe_buf;
            self.h2_probe_len = total_read;
            return null;
        }

        // Validate it looks like an HTTP/2 frame header:
        //   bytes 0-2: 24-bit payload length (any value is valid)
        //   byte  3:   frame type — 0x04 = SETTINGS
        //   byte  4:   flags
        //   bytes 5-8: stream ID (must be 0x00000000 for SETTINGS)
        const frame_type = server_response_buf[3];
        const stream_id = (@as(u32, server_response_buf[5] & 0x7F) << 24) |
            (@as(u32, server_response_buf[6]) << 16) |
            (@as(u32, server_response_buf[7]) << 8) |
            server_response_buf[8];

        // A SETTINGS frame on stream 0 from the server is the definitive
        // indicator that HTTP/2 negotiation succeeded.
        if (frame_type == 0x04 and stream_id == 0) {
            self.h2_probe_buf = probe_buf;
            self.h2_probe_len = total_read;
            return "h2";
        }

        // Unknown response — buffer and fall back to HTTP/1.1.
        self.h2_probe_buf = probe_buf;
        self.h2_probe_len = total_read;
        return null;
    }

    /// Reads decrypted data from the session.
    ///
    /// Bytes buffered during H2 ALPN probing are returned first before
    /// forwarding reads to the underlying TLS client.
    pub fn read(self: *Self, buffer: []u8) !usize {
        // Replay any bytes buffered during the H2 preface probe.
        if (self.h2_probe_buf) |probe| {
            if (self.h2_probe_len > 0) {
                const n = @min(buffer.len, self.h2_probe_len);
                @memcpy(buffer[0..n], probe[0..n]);
                // Shift remaining probe bytes to the front.
                if (n < self.h2_probe_len) {
                    std.mem.copyForwards(u8, probe[0 .. self.h2_probe_len - n], probe[n..self.h2_probe_len]);
                }
                self.h2_probe_len -= n;
                if (self.h2_probe_len == 0) {
                    self.allocator.free(probe);
                    self.h2_probe_buf = null;
                }
                return n;
            }
        }

        const c = if (self.client) |*c| c else return error.NotConnected;
        return c.reader.readSliceShort(buffer);
    }

    /// Writes data to be encrypted and sent.
    pub fn write(self: *Self, data: []const u8) !usize {
        const c = if (self.client) |*c| c else return error.NotConnected;
        try c.writer.writeAll(data);
        return data.len;
    }

    /// Flushes any buffered encrypted data to the underlying transport.
    pub fn flush(self: *Self) !void {
        const c = if (self.client) |*c| c else return error.NotConnected;
        try c.writer.flush();
        if (self.net_out) |*out| {
            try out.writer.flush();
        }
    }

    /// Returns an I/O reader for decrypted TLS payload.
    pub fn getReader(self: *Self) !*std.Io.Reader {
        const c = if (self.client) |*c| c else return error.NotConnected;
        return &c.reader;
    }

    /// Returns an I/O writer for TLS-encrypted payload.
    pub fn getWriter(self: *Self) !*std.Io.Writer {
        const c = if (self.client) |*c| c else return error.NotConnected;
        return &c.writer;
    }

    /// Returns the negotiated ALPN protocol.
    pub fn getAlpnProtocol(self: *const Self) ?[]const u8 {
        return self.negotiated_protocol;
    }

    /// Returns true if HTTP/2 was negotiated.
    pub fn isHttp2(self: *const Self) bool {
        if (self.negotiated_protocol) |proto| {
            return std.mem.eql(u8, proto, "h2");
        }
        return false;
    }

    /// Returns the peer's certificate in DER format.
    pub fn getPeerCertificate(self: *const Self) ?[]const u8 {
        return self.peer_certificate;
    }

    /// Closes the TLS session.
    pub fn close(self: *Self) void {
        self.connected = false;
        self.client = null;
    }
};

/// Certificate verification result.
pub const VerifyResult = enum {
    ok,
    expired,
    not_yet_valid,
    revoked,
    hostname_mismatch,
    self_signed,
    invalid_ca,
    invalid_signature,
    unknown_error,
};

/// Parses a PEM-encoded certificate.
pub fn parsePemCertificate(allocator: Allocator, pem_data: []const u8) ![]const u8 {
    const begin_marker = "-----BEGIN CERTIFICATE-----";
    const end_marker = "-----END CERTIFICATE-----";

    const start = std.mem.indexOf(u8, pem_data, begin_marker) orelse return error.InvalidPem;
    const end = std.mem.indexOf(u8, pem_data, end_marker) orelse return error.InvalidPem;

    if (end <= start + begin_marker.len) return error.InvalidPem;

    var base64_block = pem_data[start + begin_marker.len .. end];
    base64_block = std.mem.trim(u8, base64_block, " \t\r\n");

    // Remove all whitespace/newlines from the base64 body.
    var compact = std.ArrayList(u8).empty;
    defer compact.deinit(allocator);
    for (base64_block) |ch| {
        if (ch == '\r' or ch == '\n' or ch == '\t' or ch == ' ') continue;
        try compact.append(allocator, ch);
    }

    const decoder = std.base64.standard.Decoder;
    const out_len = try decoder.calcSizeForSlice(compact.items);
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    _ = decoder.decode(out, compact.items) catch return error.InvalidPem;
    return out;
}

/// Returns the system's default CA certificate path.
pub fn getSystemCaPath() ?[]const u8 {
    return switch (builtin.os.tag) {
        .linux => "/etc/ssl/certs/ca-certificates.crt",
        .macos => "/etc/ssl/cert.pem",
        .windows => null,
        .freebsd, .netbsd, .openbsd => "/etc/ssl/cert.pem",
        else => null,
    };
}

test "TlsConfig initialization" {
    const allocator = std.testing.allocator;
    const config = TlsConfig.init(allocator);

    try std.testing.expectEqual(TlsVersion.tls_1_2, config.min_version);
    try std.testing.expectEqual(TlsVersion.tls_1_3, config.max_version);
    try std.testing.expect(config.verify_hostname);
}

test "TlsConfig insecure" {
    const allocator = std.testing.allocator;
    const config = TlsConfig.insecure(allocator);

    try std.testing.expectEqual(VerifyMode.none, config.verify_mode);
    try std.testing.expect(!config.verify_hostname);
}

test "TlsConfig allow_truncation_attacks defaults to true" {
    const allocator = std.testing.allocator;
    const config = TlsConfig.init(allocator);
    try std.testing.expect(config.allow_truncation_attacks);
}

test "TlsConfig allow_truncation_attacks can be set to false" {
    const allocator = std.testing.allocator;
    var config = TlsConfig.init(allocator);
    config.allow_truncation_attacks = false;
    try std.testing.expect(!config.allow_truncation_attacks);
}

test "TlsConfig force_h2 defaults to false" {
    const allocator = std.testing.allocator;
    const config = TlsConfig.init(allocator);
    try std.testing.expect(!config.force_h2);
}

test "TlsConfig withH2 includes h2 in ALPN" {
    const allocator = std.testing.allocator;
    const config = TlsConfig.withH2(allocator);
    try std.testing.expect(config.wantsHttp2());
    try std.testing.expectEqualStrings("h2", config.alpn_protocols[0]);
    try std.testing.expectEqualStrings("http/1.1", config.alpn_protocols[1]);
}

test "TlsConfig insecureWithH2" {
    const allocator = std.testing.allocator;
    const config = TlsConfig.insecureWithH2(allocator);
    try std.testing.expect(config.wantsHttp2());
    try std.testing.expect(!config.verify_hostname);
    try std.testing.expectEqual(VerifyMode.none, config.verify_mode);
}

test "TlsConfig wantsHttp2 false by default" {
    const allocator = std.testing.allocator;
    const config = TlsConfig.init(allocator);
    try std.testing.expect(!config.wantsHttp2());
}

test "TlsSession initialization" {
    const allocator = std.testing.allocator;
    const config = TlsConfig.init(allocator);
    var session = TlsSession.init(config);
    defer session.deinit();

    try std.testing.expect(!session.connected);
    try std.testing.expect(session.negotiated_protocol == null);
}

test "TlsSession deinit clears probe buffer" {
    const allocator = std.testing.allocator;
    const config = TlsConfig.init(allocator);
    var session = TlsSession.init(config);
    // Simulate a probe buffer being allocated.
    session.h2_probe_buf = try allocator.alloc(u8, 9);
    session.h2_probe_len = 9;
    session.deinit();
    // deinit must free the probe buffer without double-free.
}

test "TlsSession read replays probe buffer first" {
    const allocator = std.testing.allocator;
    const config = TlsConfig.init(allocator);
    var session = TlsSession.init(config);
    defer session.deinit();

    // Populate a fake probe buffer with known bytes.
    const probe_data = [_]u8{ 0x00, 0x00, 0x0C, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00 };
    session.h2_probe_buf = try allocator.alloc(u8, probe_data.len);
    @memcpy(session.h2_probe_buf.?, &probe_data);
    session.h2_probe_len = probe_data.len;

    // The session has no live TLS client, but read() should replay probe bytes.
    var out: [9]u8 = undefined;
    const n = try session.read(&out);

    try std.testing.expectEqual(@as(usize, 9), n);
    try std.testing.expectEqualSlices(u8, &probe_data, out[0..n]);
    // Probe buffer must be freed after full replay.
    try std.testing.expect(session.h2_probe_buf == null);
    try std.testing.expectEqual(@as(usize, 0), session.h2_probe_len);
}

test "TlsSession read replays probe buffer partially" {
    const allocator = std.testing.allocator;
    const config = TlsConfig.init(allocator);
    var session = TlsSession.init(config);
    defer session.deinit();

    const probe_data = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE };
    session.h2_probe_buf = try allocator.alloc(u8, probe_data.len);
    @memcpy(session.h2_probe_buf.?, &probe_data);
    session.h2_probe_len = probe_data.len;

    var out: [3]u8 = undefined;
    const n = try session.read(&out);

    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualSlices(u8, probe_data[0..3], out[0..n]);
    // Two bytes remain in the probe buffer.
    try std.testing.expect(session.h2_probe_buf != null);
    try std.testing.expectEqual(@as(usize, 2), session.h2_probe_len);
    // Remaining bytes should be the last two of the original data.
    try std.testing.expectEqual(@as(u8, 0xDD), session.h2_probe_buf.?[0]);
    try std.testing.expectEqual(@as(u8, 0xEE), session.h2_probe_buf.?[1]);
}

test "System CA path" {
    const path = getSystemCaPath();
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        try std.testing.expect(path != null);
    }
}

test "TLS version strings" {
    try std.testing.expectEqualStrings("TLSv1.2", TlsVersion.tls_1_2.toString());
    try std.testing.expectEqualStrings("TLSv1.3", TlsVersion.tls_1_3.toString());
}

test "parsePemCertificate decodes base64 payload" {
    const allocator = std.testing.allocator;
    const pem =
        "-----BEGIN CERTIFICATE-----\n" ++
        "AQID\n" ++
        "-----END CERTIFICATE-----\n";

    const der = try parsePemCertificate(allocator, pem);
    defer allocator.free(der);

    try std.testing.expectEqual(@as(usize, 3), der.len);
    try std.testing.expectEqual(@as(u8, 0x01), der[0]);
    try std.testing.expectEqual(@as(u8, 0x02), der[1]);
    try std.testing.expectEqual(@as(u8, 0x03), der[2]);
}
