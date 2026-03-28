//! TLS/SSL Support for httpx.zig
//!
//! Provides TLS configuration and a session wrapper for HTTPS connections.
//! This module uses Zig's standard library TLS client (`std.crypto.tls.Client`).
//!
//! ## Notes
//!
//! - This is a thin wrapper around the stdlib TLS implementation.
//! - ALPN negotiation is not currently surfaced by `std.crypto.tls.Client` in a
//!   way this library uses for strict HTTP/2 protocol selection.
//! - The higher-level HTTP client supports HTTP/1.1 and an HTTP/2 runtime path
//!   over TLS, but strict ALPN-dependent server negotiation is not yet exposed.
//! - The high-level HTTP/3 runtime path uses UDP + QUIC framing primitives and
//!   does not go through this TLS wrapper.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const Socket = @import("../net/socket.zig").Socket;
const SocketIoReader = @import("../net/socket.zig").SocketIoReader;
const SocketIoWriter = @import("../net/socket.zig").SocketIoWriter;

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
    // Reserved for future protocol negotiation plumbing.
    alpn_protocols: []const []const u8 = &.{"http/1.1"},
    cipher_suites: ?[]const u8 = null,
    server_name: ?[]const u8 = null,

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
};

/// TLS session state.
pub const TlsSession = struct {
    allocator: Allocator,
    config: TlsConfig,
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
    client: ?std.crypto.tls.Client = null,

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

        self.net_read_buf = null;
        self.net_write_buf = null;
        self.tls_read_buf = null;
        self.tls_write_buf = null;
        self.net_in = null;
        self.net_out = null;
    }

    /// Attaches a connected socket that will carry the TLS session.
    pub fn attachSocket(self: *Self, socket: *Socket) void {
        self.socket = socket;
    }

    /// Performs the TLS handshake.
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

        const verify = self.config.verify_mode != .none;
        const verify_host = verify and self.config.verify_hostname;

        // System CA bundle (cross-platform); optional if verification is disabled.
        if (verify) {
            var bundle: std.crypto.Certificate.Bundle = .{};
            errdefer bundle.deinit(self.allocator);
            try bundle.rescan(self.allocator);
            self.ca_bundle = bundle;
        }

        const sni_host = self.config.server_name orelse hostname;

        const client = try tls.Client.init(&self.net_in.?.reader, &self.net_out.?.writer, .{
            .host = if (verify_host) .{ .explicit = sni_host } else .{ .no_verification = {} },
            .ca = if (verify) .{ .bundle = self.ca_bundle.? } else .{ .no_verification = {} },
            .ssl_key_log = null,
            .allow_truncation_attacks = false,
            .write_buffer = self.tls_write_buf.?,
            .read_buffer = self.tls_read_buf.?,
            .alert = null,
        });

        self.client = client;
        self.connected = true;
        self.negotiated_protocol = null;
    }

    /// Reads decrypted data from the session.
    pub fn read(self: *Self, buffer: []u8) !usize {
        const c = if (self.client) |*c| c else return error.NotConnected;
        var iov = [_][]u8{buffer};
        return c.reader.readVec(&iov) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => err,
        };
    }

    /// Writes data to be encrypted and sent.
    pub fn write(self: *Self, data: []const u8) !usize {
        const c = if (self.client) |*c| c else return error.NotConnected;
        try c.writer.writeAll(data);
        return data.len;
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

test "TlsSession initialization" {
    const allocator = std.testing.allocator;
    const config = TlsConfig.init(allocator);
    var session = TlsSession.init(config);
    defer session.deinit();

    try std.testing.expect(!session.connected);
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
