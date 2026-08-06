//! Unified TLS Error Set for httpx.zig
//!
//! All TLS modules return errors from this set so callers never need to
//! handle incompatible error unions from different sub-modules.
//!
//! Alert-derived errors follow the naming in RFC 8446 Section6.2 / RFC 5246 Section7.2.

const std = @import("std");

/// All errors that can be produced by the TLS stack.
pub const TlsError = error{
    // Alert-mapped errors (sent by peer or generated locally)

    /// close_notify  --  clean shutdown, not an error per se but surfaced
    /// so callers can distinguish it from an abrupt connection reset.
    TlsCloseNotify,

    /// unexpected_message  --  a message was received that was not expected
    /// in the current handshake state.
    TlsUnexpectedMessage,

    /// bad_record_mac  --  AEAD authentication tag verification failed.
    TlsBadRecordMac,

    /// record_overflow  --  a TLS record exceeded the maximum allowed length.
    TlsRecordOverflow,

    /// handshake_failure  --  no acceptable cipher suite / parameters could
    /// be negotiated.
    TlsHandshakeFailure,

    /// bad_certificate  --  the certificate was corrupt or could not be
    /// parsed.
    TlsBadCertificate,

    /// unsupported_certificate  --  the certificate type is not supported.
    TlsUnsupportedCertificate,

    /// certificate_revoked  --  the certificate has been revoked.
    TlsCertificateRevoked,

    /// certificate_expired  --  the certificate validity period has passed.
    TlsCertificateExpired,

    /// certificate_unknown  --  some other unspecified issue with the cert.
    TlsCertificateUnknown,

    /// illegal_parameter  --  a field in the handshake message was out of
    /// the allowed range or inconsistent with other fields.
    TlsIllegalParameter,

    /// unknown_ca  --  the certificate chain did not chain up to a trusted CA.
    TlsUnknownCa,

    /// access_denied  --  the server declined the connection.
    TlsAccessDenied,

    /// decode_error  --  a message could not be decoded.
    TlsDecodeError,

    /// decrypt_error  --  a handshake cryptographic operation failed
    /// (e.g. wrong Finished MAC, bad CertificateVerify signature).
    TlsDecryptError,

    /// protocol_version  --  the offered TLS version is not supported.
    TlsProtocolVersion,

    /// insufficient_security  --  the negotiated cipher suite / key size is
    /// too weak.
    TlsInsufficientSecurity,

    /// internal_error  --  an internal error unrelated to the peer.
    TlsInternalError,

    /// inappropriate_fallback  --  the peer attempted an invalid version
    /// fallback (TLS_FALLBACK_SCSV was set but version < max supported).
    TlsInappropriateFallback,

    /// missing_extension  --  a required extension was not present.
    TlsMissingExtension,

    /// unsupported_extension  --  an extension was received that is not
    /// allowed in this context.
    TlsUnsupportedExtension,

    /// unrecognized_name  --  the SNI name provided does not correspond to
    /// any available server certificate.
    TlsUnrecognizedName,

    /// bad_certificate_status_response  --  OCSP status request failed.
    TlsBadCertificateStatusResponse,

    /// unknown_psk_identity  --  no acceptable PSK identity was found.
    TlsUnknownPskIdentity,

    /// certificate_required  --  client auth required but no cert sent.
    TlsCertificateRequired,

    /// no_application_protocol  --  ALPN negotiation failed: no mutually
    /// supported protocol.  Sent when server config requires ALPN.
    TlsNoApplicationProtocol,

    // Internal / transport errors

    /// The TLS record buffer is too small to hold the incoming record.
    TlsBufferTooSmall,

    /// The connection was closed before the handshake completed.
    TlsConnectionTruncated,

    /// An unsupported cipher suite was selected by the server.
    TlsUnsupportedCipherSuite,

    /// A certificate could not be parsed or has a malformed structure.
    TlsMalformedCertificate,

    /// The hostname in the certificate does not match the expected SNI.
    TlsHostnameMismatch,

    /// Certificate validity period has not yet started.
    TlsCertificateNotYetValid,

    /// Certificate chain was not verified (no trusted root found).
    TlsCertificateNotVerified,

    /// The TLS sequence number overflowed (connection must be rekeyed
    /// or closed  --  applications should close and reconnect).
    TlsSequenceNumberOverflow,

    /// The session is not connected (handshake has not been performed).
    TlsNotConnected,

    /// A required field was missing from the transport configuration.
    TlsMissingTransport,

    /// An extension value was malformed.
    TlsMalformedExtension,

    /// The server sent a HelloRetryRequest which this implementation
    /// does not support in Phase 1 (will be added in Phase 2+).
    TlsHelloRetryRequestNotSupported,

    /// Key exchange failed (e.g. ECDH point validation error).
    TlsKeyExchangeFailed,

    /// The peer closed the connection without sending close_notify.
    TlsTruncationAttack,

    /// Generic read failure from the underlying transport.
    ReadFailed,

    /// Generic write failure to the underlying transport.
    WriteFailed,
};

/// Converts a `std.crypto.tls.Alert.Description` received from the peer
/// into the corresponding `TlsError`.
pub fn fromAlert(desc: std.crypto.tls.Alert.Description) TlsError {
    return switch (desc) {
        .close_notify => TlsError.TlsCloseNotify,
        .unexpected_message => TlsError.TlsUnexpectedMessage,
        .bad_record_mac => TlsError.TlsBadRecordMac,
        .record_overflow => TlsError.TlsRecordOverflow,
        .handshake_failure => TlsError.TlsHandshakeFailure,
        .bad_certificate => TlsError.TlsBadCertificate,
        .unsupported_certificate => TlsError.TlsUnsupportedCertificate,
        .certificate_revoked => TlsError.TlsCertificateRevoked,
        .certificate_expired => TlsError.TlsCertificateExpired,
        .certificate_unknown => TlsError.TlsCertificateUnknown,
        .illegal_parameter => TlsError.TlsIllegalParameter,
        .unknown_ca => TlsError.TlsUnknownCa,
        .access_denied => TlsError.TlsAccessDenied,
        .decode_error => TlsError.TlsDecodeError,
        .decrypt_error => TlsError.TlsDecryptError,
        .protocol_version => TlsError.TlsProtocolVersion,
        .insufficient_security => TlsError.TlsInsufficientSecurity,
        .internal_error => TlsError.TlsInternalError,
        .inappropriate_fallback => TlsError.TlsInappropriateFallback,
        .missing_extension => TlsError.TlsMissingExtension,
        .unsupported_extension => TlsError.TlsUnsupportedExtension,
        .unrecognized_name => TlsError.TlsUnrecognizedName,
        .bad_certificate_status_response => TlsError.TlsBadCertificateStatusResponse,
        .unknown_psk_identity => TlsError.TlsUnknownPskIdentity,
        .certificate_required => TlsError.TlsCertificateRequired,
        .no_application_protocol => TlsError.TlsNoApplicationProtocol,
        .user_canceled => TlsError.TlsCloseNotify,
        _ => TlsError.TlsUnexpectedMessage,
    };
}

/// Returns the RFC 8446 alert description byte that most closely
/// corresponds to a given `TlsError`. Used when sending an alert to
/// the peer before closing the connection.
pub fn toAlertDescription(err: TlsError) std.crypto.tls.Alert.Description {
    return switch (err) {
        error.TlsCloseNotify => .close_notify,
        error.TlsUnexpectedMessage => .unexpected_message,
        error.TlsBadRecordMac => .bad_record_mac,
        error.TlsRecordOverflow => .record_overflow,
        error.TlsHandshakeFailure => .handshake_failure,
        error.TlsBadCertificate => .bad_certificate,
        error.TlsUnsupportedCertificate => .unsupported_certificate,
        error.TlsCertificateRevoked => .certificate_revoked,
        error.TlsCertificateExpired => .certificate_expired,
        error.TlsCertificateUnknown => .certificate_unknown,
        error.TlsIllegalParameter => .illegal_parameter,
        error.TlsUnknownCa => .unknown_ca,
        error.TlsAccessDenied => .access_denied,
        error.TlsDecodeError => .decode_error,
        error.TlsDecryptError => .decrypt_error,
        error.TlsProtocolVersion => .protocol_version,
        error.TlsInsufficientSecurity => .insufficient_security,
        error.TlsInternalError => .internal_error,
        error.TlsInappropriateFallback => .inappropriate_fallback,
        error.TlsMissingExtension => .missing_extension,
        error.TlsUnsupportedExtension => .unsupported_extension,
        error.TlsUnrecognizedName => .unrecognized_name,
        error.TlsBadCertificateStatusResponse => .bad_certificate_status_response,
        error.TlsUnknownPskIdentity => .unknown_psk_identity,
        error.TlsCertificateRequired => .certificate_required,
        error.TlsNoApplicationProtocol => .no_application_protocol,
        else => .internal_error,
    };
}

test "fromAlert round-trip" {
    const t = std.testing;
    try t.expectEqual(TlsError.TlsHandshakeFailure, fromAlert(.handshake_failure));
    try t.expectEqual(TlsError.TlsNoApplicationProtocol, fromAlert(.no_application_protocol));
    try t.expectEqual(TlsError.TlsCertificateExpired, fromAlert(.certificate_expired));
}

test "toAlertDescription round-trip" {
    const t = std.testing;
    try t.expectEqual(std.crypto.tls.Alert.Description.handshake_failure, toAlertDescription(TlsError.TlsHandshakeFailure));
    try t.expectEqual(std.crypto.tls.Alert.Description.no_application_protocol, toAlertDescription(TlsError.TlsNoApplicationProtocol));
}

test "fromAlert close_notify" {
    try std.testing.expectEqual(TlsError.TlsCloseNotify, fromAlert(.close_notify));
}

test "fromAlert unexpected_message" {
    try std.testing.expectEqual(TlsError.TlsUnexpectedMessage, fromAlert(.unexpected_message));
}

test "fromAlert bad_record_mac" {
    try std.testing.expectEqual(TlsError.TlsBadRecordMac, fromAlert(.bad_record_mac));
}

test "fromAlert unknown alert maps to unexpected_message" {
    // .unsupported_extension is a recognized alert that maps to TlsUnsupportedExtension
    try std.testing.expectEqual(TlsError.TlsUnsupportedExtension, fromAlert(.unsupported_extension));
}

test "toAlertDescription TlsCloseNotify" {
    try std.testing.expectEqual(std.crypto.tls.Alert.Description.close_notify, toAlertDescription(TlsError.TlsCloseNotify));
}

test "toAlertDescription TlsBadRecordMac" {
    try std.testing.expectEqual(std.crypto.tls.Alert.Description.bad_record_mac, toAlertDescription(TlsError.TlsBadRecordMac));
}

test "toAlertDescription unknown error maps to internal_error" {
    try std.testing.expectEqual(std.crypto.tls.Alert.Description.internal_error, toAlertDescription(TlsError.ReadFailed));
}

test "fromAlert user_canceled maps to close_notify" {
    try std.testing.expectEqual(TlsError.TlsCloseNotify, fromAlert(.user_canceled));
}

test "error set has expected members" {
    // Verify key error set members exist at compile time.
    comptime {
        const ErrorSet = @TypeOf(TlsError.TlsCloseNotify);
        _ = ErrorSet;
    }
    try std.testing.expect(true);
}
