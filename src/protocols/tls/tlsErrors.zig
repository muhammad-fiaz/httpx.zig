//! Precise TLS error definitions for HTTPX.
//!
//! Categorizes errors across certificate validation, handshake negotiation,
//! cryptographic primitives, identity verification, and mTLS.

pub const TlsError = error{
    /// Peer certificate has passed its NotAfter date.
    CertificateExpired,
    /// Peer certificate has not reached its NotBefore date.
    CertificateNotYetValid,
    /// Peer certificate is not signed by a trusted root CA.
    CertificateUntrusted,
    /// Certificate Subject Alternative Names / Common Name do not match destination host.
    CertificateHostMismatch,
    /// Issuer DN does not match intermediate/root subject DN.
    CertificateIssuerMismatch,
    /// Cryptographic signature on certificate cannot be verified by issuer public key.
    CertificateSignatureInvalid,
    /// Malformed or broken certificate chain (e.g. missing intermediate, loop, or exceeded depth).
    InvalidCertificateChain,
    /// Malformed ASN.1 DER or PEM certificate structure.
    InvalidCertificate,
    /// Hostname verification failed against RFC 6125 rules.
    HostnameMismatch,
    /// TLS protocol version offered/requested is unsupported or disallowed by policy.
    UnsupportedProtocol,
    /// Cipher suite offered/requested is unsupported or disabled by policy.
    UnsupportedCipher,
    /// Failure during TLS handshake negotiation or state machine transition.
    HandshakeFailed,
    /// Application-Layer Protocol Negotiation (ALPN) failed to agree on a mutual protocol.
    AlpnFailed,
    /// Server requires a client certificate (mTLS) but none was provided.
    ClientCertificateRequired,
    /// Client certificate failed validation under trusted client CA bundle.
    ClientCertificateInvalid,
    /// Private key cannot be parsed, has invalid format, or unsupported algorithm.
    PrivateKeyInvalid,
    /// Private key does not correspond to the public key in the configured certificate.
    PrivateKeyMismatch,
    /// Received TLS alert from peer.
    TlsAlert,
    /// Failed to decode TLS record or handshake message payload.
    TlsDecodeError,
    /// System or custom CA trust store is empty or unavailable.
    TlsCaUnavailable,
    /// General initialization failure for TLS context.
    TlsInitializationFailed,
    /// Memory allocation failure.
    OutOfMemory,
    /// Network or underlying socket I/O failure.
    IoError,
};
