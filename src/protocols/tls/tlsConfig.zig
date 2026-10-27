//! Production-grade TLS configuration for Client and Server (RFC 8446, RFC 6066, RFC 7301).
//!
//! Safe defaults by construction:
//!   - TLS 1.3 preferred, TLS 1.2 supported
//!   - Peer certificate verification enabled by default
//!   - Hostname verification enabled by default
//!   - System trust store enabled by default
//!   - ALPN negotiation: h2, http/1.1

const std = @import("std");
const Allocator = std.mem.Allocator;
pub const alpn = @import("alpn.zig");
pub const certMod = @import("certificate.zig");
pub const keyMod = @import("tlsKey.zig");
pub const trustMod = @import("trustStore.zig");
pub const errorsMod = @import("tlsErrors.zig");
pub const sessionMod = @import("tlsSession.zig");

pub const CertificateChain = certMod.CertificateChain;
pub const X509Certificate = certMod.X509Certificate;
pub const PrivateKey = keyMod.PrivateKey;
pub const TrustStore = trustMod.TrustStore;
pub const TrustMode = trustMod.TrustMode;
pub const TlsError = errorsMod.TlsError;

const fsMod = @import("../../utils/fs.zig");

pub const TlsVersion = enum {
    /// Deprecated legacy TLS 1.1 (RFC 4346) compatibility mode.
    /// Insecure and prohibited by RFC 8996; disabled by default.
    /// Explicit opt-in only. Must NEVER be negotiated for HTTP/2 (RFC 9113) or HTTP/3 (RFC 9114).
    legacyTls11,
    tls12,
    tls13,
    both,

    /// Returns true if this configuration uses modern secure protocols (TLS 1.2+).
    pub fn isModern(self: TlsVersion) bool {
        return self != .legacyTls11;
    }

    /// Whether this version allows HTTP/2 or HTTP/3 negotiation (RFC 9113 section 9.2).
    pub fn allowsAlpnH2(self: TlsVersion) bool {
        return self != .legacyTls11;
    }
};

pub const ClientAuthMode = enum {
    disabled,
    optional,
    required,
};

test "TLS version and client-auth enums" {
    try std.testing.expect(TlsVersion.tls12 != TlsVersion.tls13);
    try std.testing.expect(TlsVersion.legacyTls11 != TlsVersion.tls13);
    try std.testing.expect(!TlsVersion.legacyTls11.isModern());
    try std.testing.expect(!TlsVersion.legacyTls11.allowsAlpnH2());
    try std.testing.expect(TlsVersion.tls13.allowsAlpnH2());
    try std.testing.expect(ClientAuthMode.disabled != ClientAuthMode.required);
}
