// TLS configuration and handshake management.
//
// Zig 0.16 std.crypto.tls provides the record/handshake engine but lacks:
//   * Certificate loading from PEM/DER files (we parse DER here)
//   * ALPN extension negotiation (see alpn.zig)
//   * SNI
// This module composes those pieces into a usable server/client config.

const std = @import("std");
const Allocator = std.mem.Allocator;
pub const alpn = @import("alpn.zig");

pub const Error = error{
    InvalidPem,
    InvalidDer,
    OutOfMemory,
    CertificateExpired,
};

// DER / PEM certificate parsing

/// Decodes base64 body of a PEM block.
fn decodePemBody(allocator: Allocator, pem: []const u8, label: []const u8) ![]u8 {
    // Find -----BEGIN <label>----- ... -----END <label>-----
    var begin_buf: [128]u8 = undefined;
    const begin_tag = try std.fmt.bufPrint(&begin_buf, "-----BEGIN {s}-----", .{label});
    var end_buf: [128]u8 = undefined;
    const end_tag = try std.fmt.bufPrint(&end_buf, "-----END {s}-----", .{label});

    const begin_idx = std.mem.indexOf(u8, pem, begin_tag) orelse return Error.InvalidPem;
    const body_start = begin_idx + begin_tag.len;
    const end_idx = std.mem.indexOfPos(u8, pem, body_start, end_tag) orelse return Error.InvalidPem;
    const body = pem[body_start..end_idx];

    // Strip whitespace/newlines
    var clean = std.ArrayList(u8).empty;
    defer clean.deinit(allocator);
    for (body) |c| {
        if (c != '\n' and c != '\r' and c != ' ' and c != '\t') {
            clean.append(allocator, c) catch return Error.OutOfMemory;
        }
    }

    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(clean.items) catch return Error.InvalidPem;
    const out = allocator.alloc(u8, decoded_len) catch return Error.OutOfMemory;
    errdefer allocator.free(out);
    decoder.decode(out, clean.items) catch return Error.InvalidPem;
    return out;
}

pub const CertificateChain = struct {
    /// DER-encoded leaf first, then intermediates.
    certs: []const []const u8,
    allocator: Allocator,

    pub fn deinit(self: *CertificateChain) void {
        for (self.certs) |c| self.allocator.free(c);
        self.allocator.free(self.certs);
    }
};

/// Parses a PEM file containing one or more CERTIFICATE blocks.
pub fn parseCertificatePem(allocator: Allocator, pem: []const u8) !CertificateChain {
    var list = std.ArrayList([]const u8).empty;
    errdefer list.deinit(allocator);

    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, pem, search_from, "-----BEGIN CERTIFICATE-----")) |idx| {
        const der = try decodePemBody(allocator, pem[idx..], "CERTIFICATE");
        list.append(allocator, der) catch {
            allocator.free(der);
            return Error.OutOfMemory;
        };
        search_from = idx + 26;
    }

    if (list.items.len == 0) return Error.InvalidPem;

    return .{
        .certs = try list.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Parses a PEM PRIVATE KEY block to raw DER (PKCS#8 or SEC1).
pub fn parsePrivateKeyPem(allocator: Allocator, pem: []const u8) ![]u8 {
    inline for (.{ "PRIVATE KEY", "EC PRIVATE KEY", "RSA PRIVATE KEY" }) |label| {
        if (std.mem.indexOf(u8, pem, label) != null) {
            return decodePemBody(allocator, pem, label);
        }
    }
    return Error.InvalidPem;
}

// Server TLS configuration

pub const TlsVersion = enum { tls_1_2, tls_1_3, both };

pub const ServerConfig = struct {
    allocator: Allocator,

    cert_chain: ?CertificateChain = null,
    private_key_der: ?[]u8 = null,

    min_version: TlsVersion = .tls_1_2,
    /// Preference order for ALPN; empty means no ALPN.
    alpn_protocols: []const alpn.Protocol = &.{},

    pub fn init(allocator: Allocator) ServerConfig {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ServerConfig) void {
        if (self.cert_chain) |*c| c.deinit();
        if (self.private_key_der) |k| self.allocator.free(k);
    }

    pub fn loadCertificates(self: *ServerConfig, cert_pem: []const u8, key_pem: []const u8) !void {
        self.cert_chain = try parseCertificatePem(self.allocator, cert_pem);
        self.private_key_der = try parsePrivateKeyPem(self.allocator, key_pem);
    }

    pub fn hasIdentity(self: *const ServerConfig) bool {
        return self.cert_chain != null and self.private_key_der != null;
    }
};

pub const ClientConfig = struct {
    /// Protocols to offer in ALPN; order is our preference.
    alpn_protocols: []const alpn.Protocol = &.{ .h2, .@"http/1.1" },
    verify_certificates: bool = true,
};

// Tests

test "parse single certificate PEM" {
    const a = std.testing.allocator;
    const pem =
        \\-----BEGIN CERTIFICATE-----
        \\MIIBszCCAVmgAwIB
        \\abcdefghIJKLmnop
        \\-----END CERTIFICATE-----
    ;
    var chain = try parseCertificatePem(a, pem);
    defer chain.deinit();
    try std.testing.expectEqual(@as(usize, 1), chain.certs.len);
    // Decoded content should be non-empty DER bytes
    try std.testing.expect(chain.certs[0].len > 0);
}

test "reject garbage pem" {
    const a = std.testing.allocator;
    try std.testing.expectError(Error.InvalidPem, parseCertificatePem(a, "not a pem"));
}

test "server config identity flow" {
    const a = std.testing.allocator;
    var cfg = ServerConfig.init(a);
    defer cfg.deinit();

    try std.testing.expect(!cfg.hasIdentity());

    const cert_pem =
        \\-----BEGIN CERTIFICATE-----
        \\AAAA
        \\-----END CERTIFICATE-----
    ;
    const key_pem =
        \\-----BEGIN PRIVATE KEY-----
        \\BBBB
        \\-----END PRIVATE KEY-----
    ;
    try cfg.loadCertificates(cert_pem, key_pem);
    try std.testing.expect(cfg.hasIdentity());
}
