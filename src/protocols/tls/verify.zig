//! Strict X.509 Certificate and Hostname Verification per RFC 6125 and RFC 5280.
//!
//! Enforces:
//!   - Strict wildcard matching (leftmost label only, no matching across dots e.g. *.example.com).
//!   - IP address SAN matching without wildcard support.
//!   - Validity period checks (notBefore <= now <= notAfter).
//!   - BasicConstraints CA verification for intermediate certificates.
//!   - Complete chain verification against a TrustStore.

const std = @import("std");
const Allocator = std.mem.Allocator;
const crypto = std.crypto;
const Certificate = crypto.Certificate;
const cert_mod = @import("certificate.zig");
const trust_store_mod = @import("trust_store.zig");
const errors_mod = @import("errors.zig");
pub const TlsError = errors_mod.TlsError;

/// Validates whether a DNS pattern matches a target hostname per RFC 6125.
pub fn matchDnsPattern(pattern: []const u8, hostname: []const u8) bool {
    if (pattern.len == 0 or hostname.len == 0) return false;

    // Exact case-insensitive match
    if (std.ascii.eqlIgnoreCase(pattern, hostname)) return true;

    // Wildcard matching: only valid if pattern starts with "*."
    if (pattern.len >= 3 and pattern[0] == '*' and pattern[1] == '.') {
        const pattern_suffix = pattern[1..]; // e.g. ".example.com"

        // Hostname must be longer than the suffix
        if (hostname.len <= pattern_suffix.len) return false;

        // Hostname must end with pattern_suffix case-insensitively
        const host_suffix = hostname[hostname.len - pattern_suffix.len ..];
        if (!std.ascii.eqlIgnoreCase(host_suffix, pattern_suffix)) return false;

        // The prefix matched by "*" must be a single label (no dots)
        const host_prefix = hostname[0 .. hostname.len - pattern_suffix.len];
        if (host_prefix.len == 0) return false;
        if (std.mem.indexOfScalar(u8, host_prefix, '.') != null) {
            // Cannot match across dots (e.g. *.example.com does not match a.b.example.com)
            return false;
        }

        return true;
    }

    return false;
}

/// Verifies whether the given target hostname matches the parsed certificate SANs or Common Name.
pub fn verifyHostname(parsed: Certificate.Parsed, target_host: []const u8) TlsError!void {
    if (target_host.len == 0) return TlsError.HostnameMismatch;

    // Remove port if present
    const host_only = if (std.mem.indexOfScalar(u8, target_host, ':')) |colon|
        // If not an IPv6 address enclosed in brackets
        if (target_host[0] != '[') target_host[0..colon] else target_host
    else
        target_host;

    // Trim IPv6 brackets if present
    const clean_host = if (host_only.len >= 2 and host_only[0] == '[' and host_only[host_only.len - 1] == ']')
        host_only[1 .. host_only.len - 1]
    else
        host_only;

    // Use std.crypto.Certificate.Parsed checkHost
    parsed.checkHost(clean_host) catch |err| switch (err) {
        error.CertificateHostMismatch => return TlsError.CertificateHostMismatch,
        else => return TlsError.HostnameMismatch,
    };
}

/// Verifies a complete certificate chain against a trust store and hostname.
pub fn verifyCertificateChain(
    chain: cert_mod.CertificateChain,
    trust_store: *trust_store_mod.TrustStore,
    target_host: ?[]const u8,
    now_sec: i64,
) TlsError!void {
    if (chain.count() == 0) return TlsError.InvalidCertificateChain;

    // 1. Verify leaf certificate
    const leaf = chain.leaf() orelse return TlsError.InvalidCertificate;

    // Check validity period
    if (leaf.isNotYetValid(now_sec)) return TlsError.CertificateNotYetValid;
    if (leaf.isExpired(now_sec)) return TlsError.CertificateExpired;

    // Check hostname
    if (target_host) |host| {
        try verifyHostname(leaf.parsed, host);
    }

    // If trust store mode is none, skip root anchor verification
    if (trust_store.mode == .none) return;

    // If self-signed mode and single certificate
    if (trust_store.mode == .self_signed and chain.count() == 1 and leaf.isSelfSigned()) {
        return;
    }

    // Verify chain signatures up to trust anchor
    var current = leaf;
    var i: usize = 1;
    while (i < chain.count()) : (i += 1) {
        const issuer_cert = chain.get(i) orelse return TlsError.InvalidCertificateChain;

        // Intermediate certificate must be a CA
        if (!issuer_cert.isCa()) {
            return TlsError.InvalidCertificateChain;
        }

        // Verify validity of intermediate
        if (issuer_cert.isNotYetValid(now_sec)) return TlsError.CertificateNotYetValid;
        if (issuer_cert.isExpired(now_sec)) return TlsError.CertificateExpired;

        // Verify signature
        try current.verifySignature(issuer_cert, now_sec);
        current = issuer_cert;
    }

    // Verify top certificate against the trust store
    try trust_store.verify(current.parsed, now_sec);
}

test "matchDnsPattern exact and wildcard" {
    // Exact matches
    try std.testing.expect(matchDnsPattern("example.com", "example.com"));
    try std.testing.expect(matchDnsPattern("example.com", "EXAMPLE.COM"));
    try std.testing.expect(!matchDnsPattern("example.com", "other.com"));

    // Valid wildcard
    try std.testing.expect(matchDnsPattern("*.example.com", "api.example.com"));
    try std.testing.expect(matchDnsPattern("*.example.com", "test.example.com"));

    // Invalid wildcard matches (RFC 6125 rules)
    // 1. Cannot match across dots
    try std.testing.expect(!matchDnsPattern("*.example.com", "sub.api.example.com"));
    // 2. Cannot match apex domain
    try std.testing.expect(!matchDnsPattern("*.example.com", "example.com"));
    // 3. Cannot match partial name without dot
    try std.testing.expect(!matchDnsPattern("*.example.com", "notexample.com"));
}
