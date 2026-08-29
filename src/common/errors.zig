//! Unified error taxonomy for the entire httpx library.
//!
//! Every subsystem maps its errors into this shared enum so callers can
//! distinguish between network failures, protocol violations, resource
//! limits, and application-level conditions. Error categories are derived
//! from the IANA HTTP Status Code Registry (RFC 9110 Section 15) and
//! common network failure modes defined in RFC 5424 (Syslog) severity
//! mappings.
//!
//! References:
//!   - RFC 9110 — HTTP Semantics (status code semantics)
//!   - RFC 9112 — HTTP/1.1 Message Syntax (malformed request/response)
//!   - RFC 7231 — HTTP/1.1 Content Semantics (auth errors)
//!   - RFC 9113 — HTTP/2 (protocol-level errors)

pub const Error = error{
    // DNS
    DnsFailure,
    DnsTimeout,
    HostNotFound,

    // Connection
    ConnectionRefused,
    ConnectionReset,
    ConnectionClosed,
    ConnectTimeout,
    ConnectionFailed,

    // TLS
    TlsHandshakeFailed,
    CertificateInvalid,
    CertificateExpired,
    HostnameMismatch,
    TlsProtocolError,

    // HTTP protocol
    MalformedRequest,
    MalformedResponse,
    InvalidHeader,
    InvalidContentLength,
    InvalidTransferEncoding,
    UnsupportedHttpVersion,
    BodyTooLarge,
    HeaderTooLarge,

    // Routing
    RouteNotFound,
    MethodNotAllowed,
    DuplicateRoute,
    InvalidRoutePattern,

    // Validation
    ValidationFailed,

    // Auth
    Unauthorized,
    Forbidden,

    // Resources
    OutOfMemory,
    ResourceLimitExceeded,
    QueueFull,
    PoolExhausted,

    // Timeouts / lifecycle
    Timeout,
    DeadlineExceeded,
    Cancelled,
    ShutdownInProgress,

    // I/O
    ReadFailed,
    WriteFailed,
    FileNotFound,
    PermissionDenied,

    // Parsing
    InvalidJson,
    InvalidMultipart,
    InvalidUri,
    InvalidUtf8,

    // Generic
    InternalError,
    NotImplemented,
};
