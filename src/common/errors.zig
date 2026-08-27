//! Shared error types for the entire httpx library.
//!
//! Every subsystem maps its errors into this unified taxonomy so callers
//! can distinguish between network failures, protocol violations,
//! resource limits, and application-level conditions.

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
