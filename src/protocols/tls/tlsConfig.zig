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
    tls12,
    tls13,
    both,
};

pub const ClientAuthMode = enum {
    disabled,
    optional,
    required,
};

test "TLS version and client-auth enums" {
    try std.testing.expect(TlsVersion.tls12 != TlsVersion.tls13);
    try std.testing.expect(ClientAuthMode.disabled != ClientAuthMode.required);
}
