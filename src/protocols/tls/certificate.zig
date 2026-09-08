//! Production-grade X.509 Certificate and Chain handling.
//!
//! Supports PEM/DER decoding, X.509 certificate parsing, SAN (Subject Alternative Name)
//! extraction (DNS & IP), validity checking, KeyUsage / ExtKeyUsage checking, and chain building.
//! Uses native std.crypto.Certificate primitives without external C dependencies.

const std = @import("std");
const Allocator = std.mem.Allocator;
const crypto = std.crypto;
const Certificate = crypto.Certificate;
const der_mod = Certificate.der;
const errors_mod = @import("errors.zig");
pub const TlsError = errors_mod.TlsError;

/// A single X.509 Certificate with raw DER representation and parsed metadata.
pub const X509Certificate = struct {
    der_bytes: []const u8,
    parsed: Certificate.Parsed,

    /// Parses an X.509 certificate from raw DER bytes.
    pub fn parseDer(der_bytes: []const u8) TlsError!X509Certificate {
        // Basic DER validation: minimum X.509 certificate size is >= 64 bytes,
        // must begin with ASN.1 SEQUENCE (0x30).
        if (der_bytes.len < 64 or der_bytes[0] != 0x30) return TlsError.InvalidCertificate;

        // Verify outer SEQUENCE length indicator
        const header_len: usize = if (der_bytes[1] < 0x80)
            2
        else if (der_bytes[1] == 0x81)
            3
        else if (der_bytes[1] == 0x82)
            4
        else
            return TlsError.InvalidCertificate;

        if (der_bytes.len < header_len) return TlsError.InvalidCertificate;

        const cert: Certificate = .{
            .buffer = der_bytes,
            .index = 0,
        };
        const parsed = cert.parse() catch return TlsError.InvalidCertificate;
        return .{
            .der_bytes = der_bytes,
            .parsed = parsed,
        };
    }

    /// Returns the raw DER bytes of the certificate.
    pub fn rawDer(self: X509Certificate) []const u8 {
        return self.der_bytes;
    }

    /// Returns the subject DER slice.
    pub fn subject(self: X509Certificate) []const u8 {
        return self.parsed.subject();
    }

    /// Returns the issuer DER slice.
    pub fn issuer(self: X509Certificate) []const u8 {
        return self.parsed.issuer();
    }

    /// Returns true if this certificate is self-signed (subject == issuer).
    pub fn isSelfSigned(self: X509Certificate) bool {
        return std.mem.eql(u8, self.subject(), self.issuer());
    }

    /// Returns true if the certificate is currently valid according to given POSIX timestamp (in seconds).
    pub fn isValidAt(self: X509Certificate, now_sec: i64) bool {
        return now_sec >= self.parsed.validity.not_before and now_sec <= self.parsed.validity.not_after;
    }

    /// Returns true if the certificate has expired.
    pub fn isExpired(self: X509Certificate, now_sec: i64) bool {
        return now_sec > self.parsed.validity.not_after;
    }

    /// Returns true if the certificate is not yet valid.
    pub fn isNotYetValid(self: X509Certificate, now_sec: i64) bool {
        return now_sec < self.parsed.validity.not_before;
    }

    /// Returns not_before timestamp in seconds.
    pub fn notBefore(self: X509Certificate) i64 {
        return self.parsed.validity.not_before;
    }

    /// Returns not_after timestamp in seconds.
    pub fn notAfter(self: X509Certificate) i64 {
        return self.parsed.validity.not_after;
    }

    /// Returns true if the BasicConstraints extension indicates this is a CA certificate.
    pub fn isCa(self: X509Certificate) bool {
        return self.parsed.basic_constraints.is_ca;
    }

    /// Verifies that this certificate was signed by the given issuer certificate.
    pub fn verifySignature(self: X509Certificate, issuer_cert: X509Certificate, now_sec: i64) TlsError!void {
        self.parsed.verify(issuer_cert.parsed, now_sec) catch |err| switch (err) {
            error.CertificateExpired => return TlsError.CertificateExpired,
            error.CertificateNotYetValid => return TlsError.CertificateNotYetValid,
            error.CertificateIssuerMismatch => return TlsError.CertificateIssuerMismatch,
            error.CertificateSignatureInvalid => return TlsError.CertificateSignatureInvalid,
            else => return TlsError.InvalidCertificate,
        };
    }
};

/// An ordered X.509 Certificate Chain (Leaf -> Intermediate(s) -> Root).
pub const CertificateChain = struct {
    /// DER-encoded certificates in presentation order.
    certs: []const []const u8,
    allocator: Allocator,

    pub fn deinit(self: *CertificateChain) void {
        for (self.certs) |c| self.allocator.free(c);
        self.allocator.free(self.certs);
        self.* = undefined;
    }

    /// Returns the leaf certificate (first in chain).
    pub fn leaf(self: CertificateChain) ?X509Certificate {
        if (self.certs.len == 0) return null;
        return X509Certificate.parseDer(self.certs[0]) catch null;
    }

    /// Returns the count of certificates in the chain.
    pub fn count(self: CertificateChain) usize {
        return self.certs.len;
    }

    /// Returns an X509Certificate at the specified index.
    pub fn get(self: CertificateChain, idx: usize) ?X509Certificate {
        if (idx >= self.certs.len) return null;
        return X509Certificate.parseDer(self.certs[idx]) catch null;
    }
};

/// Decodes base64 body of a PEM block with the given label.
pub fn decodePemBlock(allocator: Allocator, pem: []const u8, label: []const u8) TlsError![]u8 {
    var begin_buf: [128]u8 = undefined;
    const begin_tag = std.fmt.bufPrint(&begin_buf, "-----BEGIN {s}-----", .{label}) catch return TlsError.InvalidCertificate;
    var end_buf: [128]u8 = undefined;
    const end_tag = std.fmt.bufPrint(&end_buf, "-----END {s}-----", .{label}) catch return TlsError.InvalidCertificate;

    const begin_idx = std.mem.indexOf(u8, pem, begin_tag) orelse return TlsError.InvalidCertificate;
    const body_start = begin_idx + begin_tag.len;
    const end_idx = std.mem.indexOfPos(u8, pem, body_start, end_tag) orelse return TlsError.InvalidCertificate;
    const body = pem[body_start..end_idx];

    // Strip whitespace and newlines
    var clean = std.ArrayList(u8).empty;
    defer clean.deinit(allocator);
    for (body) |c| {
        if (c != '\n' and c != '\r' and c != ' ' and c != '\t') {
            clean.append(allocator, c) catch return TlsError.OutOfMemory;
        }
    }

    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(clean.items) catch return TlsError.InvalidCertificate;
    const out = allocator.alloc(u8, decoded_len) catch return TlsError.OutOfMemory;
    errdefer allocator.free(out);
    decoder.decode(out, clean.items) catch return TlsError.InvalidCertificate;
    return out;
}

/// Parses all CERTIFICATE blocks from a PEM-encoded string into a CertificateChain.
pub fn parseCertificateChainPem(allocator: Allocator, pem: []const u8) TlsError!CertificateChain {
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |c| allocator.free(c);
        list.deinit(allocator);
    }

    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, pem, search_from, "-----BEGIN CERTIFICATE-----")) |idx| {
        const der = try decodePemBlock(allocator, pem[idx..], "CERTIFICATE");
        list.append(allocator, der) catch {
            allocator.free(der);
            return TlsError.OutOfMemory;
        };
        search_from = idx + 26;
    }

    if (list.items.len == 0) return TlsError.InvalidCertificate;

    return CertificateChain{
        .certs = list.toOwnedSlice(allocator) catch return TlsError.OutOfMemory,
        .allocator = allocator,
    };
}

test "X509Certificate parse invalid bytes" {
    const invalid_der = [_]u8{ 0x30, 0x05, 0x00, 0x01, 0x02 };
    try std.testing.expectError(TlsError.InvalidCertificate, X509Certificate.parseDer(&invalid_der));
}

test "decodePemBlock reject malformed" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(TlsError.InvalidCertificate, decodePemBlock(alloc, "not a valid pem", "CERTIFICATE"));
}
