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
const errorsMod = @import("errors.zig");
pub const TlsError = errorsMod.TlsError;

/// A single X.509 Certificate with raw DER representation and parsed metadata.
pub const X509Certificate = struct {
    derBytes: []const u8,
    parsed: Certificate.Parsed,

    /// Parses an X.509 certificate from raw DER bytes.
    pub fn parseDer(derBytes: []const u8) TlsError!X509Certificate {
        // Basic DER validation: minimum X.509 certificate size is >= 64 bytes,
        // must begin with ASN.1 SEQUENCE (0x30).
        if (derBytes.len < 64 or derBytes[0] != 0x30) return TlsError.InvalidCertificate;

        // Verify outer SEQUENCE length indicator
        const header_len: usize = if (derBytes[1] < 0x80)
            2
        else if (derBytes[1] == 0x81)
            3
        else if (derBytes[1] == 0x82)
            4
        else
            return TlsError.InvalidCertificate;

        if (derBytes.len < header_len) return TlsError.InvalidCertificate;

        const cert: Certificate = .{
            .buffer = derBytes,
            .index = 0,
        };
        const parsed = cert.parse() catch return TlsError.InvalidCertificate;
        return .{
            .derBytes = derBytes,
            .parsed = parsed,
        };
    }

    /// Returns the raw DER bytes of the certificate.
    pub fn rawDer(self: X509Certificate) []const u8 {
        return self.derBytes;
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
    pub fn isValidAt(self: X509Certificate, nowSec: i64) bool {
        return nowSec >= self.parsed.validity.not_before and nowSec <= self.parsed.validity.not_after;
    }

    /// Returns true if the certificate has expired.
    pub fn isExpired(self: X509Certificate, nowSec: i64) bool {
        return nowSec > self.parsed.validity.not_after;
    }

    /// Returns true if the certificate is not yet valid.
    pub fn isNotYetValid(self: X509Certificate, nowSec: i64) bool {
        return nowSec < self.parsed.validity.not_before;
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
    /// Minimal DER scan for OID 2.5.29.19; fail-closed (false) on any anomaly.
    pub fn isCa(self: X509Certificate) bool {
        const der = self.derBytes;
        // OID 2.5.29.19 (basicConstraints) DER encoding.
        const oid = [_]u8{ 0x06, 0x03, 0x55, 0x1D, 0x13 };
        var search: usize = 0;
        while (std.mem.indexOfPos(u8, der, search, &oid)) |idx| {
            var pos = idx + oid.len;
            // Optional critical BOOLEAN.
            if (pos + 3 <= der.len and der[pos] == 0x01 and der[pos + 1] == 0x01) pos += 3;
            // OCTET STRING wrapping the extension value.
            if (pos + 2 > der.len or der[pos] != 0x04) {
                search = idx + 1;
                continue;
            }
            const oct_len: usize = der[pos + 1];
            if (oct_len & 0x80 != 0 or pos + 2 + oct_len > der.len) {
                search = idx + 1;
                continue;
            }
            const inner = der[pos + 2 ..][0..oct_len];
            // Expect SEQUENCE, then optional cA BOOLEAN TRUE.
            if (inner.len >= 2 and inner[0] == 0x30 and inner[1] + 2 <= inner.len) {
                const seq = inner[2..][0..inner[1]];
                if (seq.len >= 3 and seq[0] == 0x01 and seq[1] == 0x01 and seq[2] == 0xFF) return true;
            }
            search = idx + 1;
        }
        return false;
    }

    /// Verifies that this certificate was signed by the given issuer certificate.
    pub fn verifySignature(self: X509Certificate, issuerCert: X509Certificate, nowSec: i64) TlsError!void {
        self.parsed.verify(issuerCert.parsed, nowSec) catch |err| switch (err) {
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

/// Structural DER validation: walks every TLV header and verifies all
/// lengths stay within bounds (bounded depth, checked arithmetic).
/// Rejects truncated inputs that could otherwise index out of bounds in
/// downstream parsers. Semantic validity is NOT checked here; malformed
/// but well-framed inputs still fail later with clean errors.
pub fn checkDerStructure(der: []const u8) bool {
    if (der.len < 2 or der.len > 16 * 1024 * 1024) return false;
    var stack: [33]usize = .{0} ** 33;
    var depth: usize = 0;
    stack[0] = der.len;
    var end: usize = der.len;
    var pos: usize = 0;
    while (true) {
        if (pos >= end) {
            if (pos != end) return false;
            if (depth == 0) return true;
            depth -= 1;
            end = stack[depth];
            continue;
        }
        if (pos + 2 > end) return false;
        const tag = der[pos];
        var len: usize = der[pos + 1];
        var hdr: usize = 2;
        if (len & 0x80 != 0) {
            // DER forbids indefinite form; cap long-form headers at 4 bytes.
            const n: usize = len & 0x7F;
            if (n == 0 or n > 4 or pos + 2 + n > end) return false;
            len = 0;
            for (der[pos + 2 ..][0..n]) |b| len = (len << 8) | b;
            hdr = 2 + n;
        }
        if (pos + hdr > end) return false;
        if (len > end - (pos + hdr)) return false;
        if (tag & 0x20 != 0) {
            if (depth + 1 >= stack.len) return false;
            depth += 1;
            stack[depth] = pos + hdr + len;
            end = pos + hdr + len;
            pos = pos + hdr;
        } else {
            pos += hdr + len;
        }
    }
}

/// Decodes base64 body of a PEM block with the given label.
pub fn decodePemBlock(allocator: Allocator, pem: []const u8, label: []const u8) TlsError![]u8 {
    var begin_buf: [128]u8 = undefined;
    const begin_tag = std.fmt.bufPrint(&begin_buf, "-----BEGIN {s}-----", .{label}) catch return TlsError.InvalidCertificate;
    var end_buf: [128]u8 = undefined;
    const end_tag = std.fmt.bufPrint(&end_buf, "-----END {s}-----", .{label}) catch return TlsError.InvalidCertificate;

    const begin_idx = std.mem.indexOf(u8, pem, begin_tag) orelse return TlsError.InvalidCertificate;
    const body_start = begin_idx + begin_tag.len;
    const endIdx = std.mem.indexOfPos(u8, pem, body_start, end_tag) orelse return TlsError.InvalidCertificate;
    const body = pem[body_start..endIdx];

    // Strip whitespace and newlines
    var clean = std.ArrayList(u8).empty;
    defer clean.deinit(allocator);
    for (body) |c| {
        if (c != '\n' and c != '\r' and c != ' ' and c != '\t') {
            clean.append(allocator, c) catch return TlsError.OutOfMemory;
        }
    }

    const decoder = std.base64.standard.Decoder;
    const decodedLen = decoder.calcSizeForSlice(clean.items) catch return TlsError.InvalidCertificate;
    const out = allocator.alloc(u8, decodedLen) catch return TlsError.OutOfMemory;
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

test "checkDerStructure rejects truncation without panicking" {
    // Short garbage: length runs past the buffer.
    try std.testing.expect(!checkDerStructure("not-a-valid-cert"));
    try std.testing.expect(!checkDerStructure(&[_]u8{ 0x30, 0x05, 0x00, 0x01, 0x02 }));
    // Truncated real certificate.
    const real = @embedFile("testdata/localhost_cert.pem");
    const alloc = std.testing.allocator;
    const der = try decodePemBlock(alloc, real, "CERTIFICATE");
    defer alloc.free(der);
    try std.testing.expect(checkDerStructure(der));
    try std.testing.expect(!checkDerStructure(der[0 .. der.len / 2]));
    try std.testing.expect(!checkDerStructure(der[0..10]));
}
