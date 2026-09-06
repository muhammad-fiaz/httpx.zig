//! HTTP status codes with reason phrases.
//!
//! Status codes are grouped into five classes per RFC 9110 Section 15.
//! Each code maps to a standard reason phrase used in the HTTP/1.1
//! status line. This module provides both typed constants and a
//! lookup function for reason phrases.
//!
//! References:
//!   - RFC 9110 Section 15 — Response Status Codes
//!   - RFC 9110 Section 15.1 — Overview (1xx Informational … 5xx Server Error)
//!   - RFC 9110 Section 15.2 — 1xx Informational
//!   - RFC 9110 Section 15.3 — 2xx Successful
//!   - RFC 9110 Section 15.4 — 3xx Redirection
//!   - RFC 9110 Section 15.5 — 4xx Client Error
//!   - RFC 9110 Section 15.6 — 5xx Server Error

pub const Status = struct {
    code: u16,
    reason: []const u8,

    pub fn isInformational(self: Status) bool {
        return self.code >= 100 and self.code < 200;
    }
    pub fn isSuccess(self: Status) bool {
        return self.code >= 200 and self.code < 300;
    }
    pub fn isRedirect(self: Status) bool {
        return self.code >= 300 and self.code < 400;
    }
    pub fn isError(self: Status) bool {
        return self.code >= 400;
    }
    pub fn isClientError(self: Status) bool {
        return self.code >= 400 and self.code < 500;
    }
    pub fn isServerError(self: Status) bool {
        return self.code >= 500;
    }
};

pub const OK: u16 = 200;
pub const CREATED: u16 = 201;
pub const ACCEPTED: u16 = 202;
pub const NO_CONTENT: u16 = 204;
pub const MOVED_PERMANENTLY: u16 = 301;
pub const FOUND: u16 = 302;
pub const SEE_OTHER: u16 = 303;
pub const NOT_MODIFIED: u16 = 304;
pub const TEMPORARY_REDIRECT: u16 = 307;
pub const PERMANENT_REDIRECT: u16 = 308;
pub const BAD_REQUEST: u16 = 400;
pub const UNAUTHORIZED: u16 = 401;
pub const FORBIDDEN: u16 = 403;
pub const NOT_FOUND: u16 = 404;
pub const METHOD_NOT_ALLOWED: u16 = 405;
pub const NOT_ACCEPTABLE: u16 = 406;
pub const REQUEST_TIMEOUT: u16 = 408;
pub const CONFLICT: u16 = 409;
pub const PAYLOAD_TOO_LARGE: u16 = 413;
pub const UNSUPPORTED_MEDIA_TYPE: u16 = 415;
pub const UNPROCESSABLE_ENTITY: u16 = 422;
pub const TOO_MANY_REQUESTS: u16 = 429;
pub const INTERNAL_SERVER_ERROR: u16 = 500;
pub const NOT_IMPLEMENTED: u16 = 501;
pub const BAD_GATEWAY: u16 = 502;
pub const SERVICE_UNAVAILABLE: u16 = 503;
pub const GATEWAY_TIMEOUT: u16 = 504;

/// Returns the standard reason phrase for an HTTP status code.
pub fn reasonPhrase(code: u16) []const u8 {
    return switch (code) {
        100 => "Continue",
        101 => "Switching Protocols",
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        303 => "See Other",
        304 => "Not Modified",
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        406 => "Not Acceptable",
        408 => "Request Timeout",
        409 => "Conflict",
        413 => "Payload Too Large",
        415 => "Unsupported Media Type",
        422 => "Unprocessable Entity",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => "Unknown",
    };
}

test "reason phrase lookup" {
    try std.testing.expectEqualStrings("OK", reasonPhrase(200));
    try std.testing.expectEqualStrings("Not Found", reasonPhrase(404));
    try std.testing.expectEqualStrings("Unknown", reasonPhrase(999));
}

const std = @import("std");
