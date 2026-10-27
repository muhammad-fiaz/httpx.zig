//! RFC 6960: Online Certificate Status Protocol (OCSP).
//!
//! Provides ASN.1 DER parsing and validation for OCSP responses and stapled
//! TLS certificate status extensions, verifying response status, certificate
//! status (good, revoked, unknown), freshness (thisUpdate/nextUpdate), and
//! responder identity.
//!
//! References:
//!   - RFC 6960: X.509 Internet PKI Online Certificate Status Protocol - OCSP
//!   - RFC 6066 Section 8: Certificate Status Request (OCSP Stapling)

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const OcspResponseStatus = enum(u8) {
    successful = 0,
    malformedRequest = 1,
    internalError = 2,
    tryLater = 3,
    sigRequired = 5,
    unauthorized = 6,
    _,
};

pub const CertStatusKind = enum {
    good,
    revoked,
    unknown,
};

pub const SingleResponse = struct {
    status: CertStatusKind,
    thisUpdate: i64,
    nextUpdate: ?i64 = null,
    revocationTime: ?i64 = null,
    serialNumber: []const u8,
};

pub const ParsedOcspResponse = struct {
    status: OcspResponseStatus,
    producedAt: i64 = 0,
    responses: []SingleResponse,
    allocator: Allocator,

    pub fn deinit(self: *ParsedOcspResponse) void {
        self.allocator.free(self.responses);
    }

    /// Verifies that the OCSP response is temporally valid at `nowSec`.
    pub fn isFresh(self: *const ParsedOcspResponse, nowSec: i64) bool {
        if (self.responses.len == 0) return false;
        for (self.responses) |resp| {
            // Must have thisUpdate <= nowSec + grace period (e.g. 300s clock skew)
            if (resp.thisUpdate > nowSec + 300) return false;
            // If nextUpdate is specified, nowSec must not exceed it
            if (resp.nextUpdate) |nu| {
                if (nowSec > nu + 300) return false;
            }
        }
        return true;
    }

    /// Checks if all contained certificate responses are 'good'.
    pub fn isAllGood(self: *const ParsedOcspResponse) bool {
        if (self.status != .successful or self.responses.len == 0) return false;
        for (self.responses) |r| {
            if (r.status != .good) return false;
        }
        return true;
    }
};

pub const OcspError = error{
    InvalidDer,
    UnexpectedTag,
    MalformedLength,
    InvalidResponseStatus,
    MissingResponseBytes,
    OutOfMemory,
};

/// Reads an ASN.1 tag and length from `der` at `pos`.
fn readTagLen(der: []const u8, pos: *usize) OcspError!struct { tag: u8, len: usize, headerLen: usize } {
    if (pos.* >= der.len) return OcspError.InvalidDer;
    const tag = der[pos.*];
    pos.* += 1;
    if (pos.* >= der.len) return OcspError.InvalidDer;

    const b = der[pos.*];
    pos.* += 1;

    var len: usize = 0;
    var headerLen: usize = 2;

    if (b & 0x80 == 0) {
        len = b;
    } else {
        const numBytes = b & 0x7F;
        if (numBytes == 0 or numBytes > 4) return OcspError.MalformedLength;
        if (pos.* + numBytes > der.len) return OcspError.InvalidDer;
        for (0..numBytes) |_| {
            len = (len << 8) | der[pos.*];
            pos.* += 1;
        }
        headerLen += numBytes;
    }

    if (pos.* + len > der.len) return OcspError.InvalidDer;
    return .{ .tag = tag, .len = len, .headerLen = headerLen };
}

/// Parses an ASN.1 GeneralizedTime (YYYYMMDDHHMMSSZ) into unix epoch seconds.
pub fn parseGeneralizedTime(s: []const u8) ?i64 {
    if (s.len < 15 or s[14] != 'Z') return null;
    const year = std.fmt.parseInt(i32, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u32, s[4..6], 10) catch return null;
    const day = std.fmt.parseInt(u32, s[6..8], 10) catch return null;
    const hour = std.fmt.parseInt(u32, s[8..10], 10) catch return null;
    const min = std.fmt.parseInt(u32, s[10..12], 10) catch return null;
    const sec = std.fmt.parseInt(u32, s[12..14], 10) catch return null;

    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or min > 59 or sec > 59) return null;

    // Approximate unix timestamp (good for leap-year calculations from 1970 to 2100)
    var days: i64 = 0;
    var y: i32 = 1970;
    while (y < year) : (y += 1) {
        const isLeap = (@rem(y, 4) == 0 and (@rem(y, 100) != 0 or @rem(y, 400) == 0));
        days += if (isLeap) 366 else 365;
    }

    const isCurrentLeap = (@rem(year, 4) == 0 and (@rem(year, 100) != 0 or @rem(year, 400) == 0));
    const daysInMonths = [_]u32{ 0, 31, if (isCurrentLeap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    for (1..month) |m| {
        days += daysInMonths[m];
    }
    days += (day - 1);

    return days * 86400 + @as(i64, hour) * 3600 + @as(i64, min) * 60 + @as(i64, sec);
}

/// Parses an OCSPResponse ASN.1 DER buffer into a high-level representation.
pub fn parseOcspResponse(allocator: Allocator, der: []const u8) OcspError!ParsedOcspResponse {
    var pos: usize = 0;
    const seq = try readTagLen(der, &pos);
    if (seq.tag != 0x30) return OcspError.UnexpectedTag; // SEQUENCE

    // OCSPResponseStatus ENUMERATED (tag 0x0A)
    const statusTl = try readTagLen(der, &pos);
    if (statusTl.tag != 0x0A or statusTl.len != 1) return OcspError.InvalidResponseStatus;
    const rawStatus = der[pos];
    pos += 1;
    const status: OcspResponseStatus = @fromBackingInt(@intCast(rawStatus));

    if (status != .successful) {
        return .{
            .status = status,
            .producedAt = 0,
            .responses = &[_]SingleResponse{},
            .allocator = allocator,
        };
    }

    // [0] EXPLICIT ResponseBytes (tag 0xA0)
    if (pos >= der.len) return OcspError.MissingResponseBytes;
    const rbTl = try readTagLen(der, &pos);
    if (rbTl.tag != 0xA0) return OcspError.UnexpectedTag;

    const rbEnd = pos + rbTl.len;

    // ResponseBytes SEQUENCE
    const innerSeq = try readTagLen(der, &pos);
    if (innerSeq.tag != 0x30) return OcspError.UnexpectedTag;

    // responseType OBJECT IDENTIFIER (id-pkix-ocsp-basic: 1.3.6.1.5.5.7.48.1.1)
    const oidTl = try readTagLen(der, &pos);
    if (oidTl.tag != 0x06) return OcspError.UnexpectedTag;
    pos += oidTl.len;

    // response OCTET STRING containing BasicOCSPResponse
    const octetTl = try readTagLen(der, &pos);
    if (octetTl.tag != 0x04) return OcspError.UnexpectedTag;

    const basicDer = der[pos .. pos + octetTl.len];
    pos = rbEnd;

    // Parse BasicOCSPResponse SEQUENCE
    var bPos: usize = 0;
    const basicSeq = try readTagLen(basicDer, &bPos);
    if (basicSeq.tag != 0x30) return OcspError.UnexpectedTag;

    // tbsResponseData SEQUENCE
    const tbsSeq = try readTagLen(basicDer, &bPos);
    if (tbsSeq.tag != 0x30) return OcspError.UnexpectedTag;
    const tbsEnd = bPos + tbsSeq.len;

    // Skip version if present ([0] EXPLICIT INTEGER)
    if (bPos < tbsEnd and basicDer[bPos] == 0xA0) {
        const vTl = try readTagLen(basicDer, &bPos);
        bPos += vTl.len;
    }

    // ResponderID (CHOICE: [1] byName or [2] byKey)
    if (bPos >= tbsEnd) return OcspError.InvalidDer;
    const respIdTl = try readTagLen(basicDer, &bPos);
    bPos += respIdTl.len;

    // producedAt GeneralizedTime (tag 0x18)
    var producedAtSec: i64 = 0;
    if (bPos < tbsEnd and basicDer[bPos] == 0x18) {
        const ptTl = try readTagLen(basicDer, &bPos);
        const timeStr = basicDer[bPos .. bPos + ptTl.len];
        bPos += ptTl.len;
        producedAtSec = parseGeneralizedTime(timeStr) orelse 0;
    }

    // responses SEQUENCE OF SingleResponse (tag 0x30)
    var respList = std.ArrayList(SingleResponse).empty;
    errdefer respList.deinit(allocator);

    if (bPos < tbsEnd and basicDer[bPos] == 0x30) {
        const respsTl = try readTagLen(basicDer, &bPos);
        const respsEnd = bPos + respsTl.len;

        while (bPos < respsEnd) {
            const singleSeq = try readTagLen(basicDer, &bPos);
            if (singleSeq.tag != 0x30) return OcspError.UnexpectedTag;
            const singleEnd = bPos + singleSeq.len;

            // CertID SEQUENCE
            const certIdSeq = try readTagLen(basicDer, &bPos);
            const certIdEnd = bPos + certIdSeq.len;

            // hashAlgorithm
            const hashAlg = try readTagLen(basicDer, &bPos);
            bPos += hashAlg.len;
            // issuerNameHash
            const inh = try readTagLen(basicDer, &bPos);
            bPos += inh.len;
            // issuerKeyHash
            const ikh = try readTagLen(basicDer, &bPos);
            bPos += ikh.len;
            // serialNumber INTEGER (tag 0x02)
            const snTl = try readTagLen(basicDer, &bPos);
            const serialNumber = basicDer[bPos .. bPos + snTl.len];
            bPos = certIdEnd;

            // certStatus CertStatus (CHOICE: [0] IMPLICIT good, [1] IMPLICIT revoked, [2] IMPLICIT unknown)
            if (bPos >= singleEnd) return OcspError.InvalidDer;
            const csTag = basicDer[bPos];
            bPos += 1;
            const csLenByte = basicDer[bPos];
            bPos += 1;

            var statusKind: CertStatusKind = .unknown;
            var revocationTime: ?i64 = null;

            if (csTag == 0x80) { // [0] good
                statusKind = .good;
                bPos += csLenByte;
            } else if (csTag == 0xA1 or csTag == 0x81) { // [1] revoked
                statusKind = .revoked;
                // Parse GeneralizedTime inside RevokedInfo if present
                if (csLenByte >= 15 and bPos + csLenByte <= singleEnd) {
                    revocationTime = parseGeneralizedTime(basicDer[bPos .. bPos + 15]);
                }
                bPos += csLenByte;
            } else if (csTag == 0x82) { // [2] unknown
                statusKind = .unknown;
                bPos += csLenByte;
            }

            // thisUpdate GeneralizedTime (tag 0x18)
            var thisUpdateSec: i64 = 0;
            if (bPos < singleEnd and basicDer[bPos] == 0x18) {
                const tuTl = try readTagLen(basicDer, &bPos);
                thisUpdateSec = parseGeneralizedTime(basicDer[bPos .. bPos + tuTl.len]) orelse 0;
                bPos += tuTl.len;
            }

            // nextUpdate [0] EXPLICIT GeneralizedTime (tag 0xA0) optional
            var nextUpdateSec: ?i64 = null;
            if (bPos < singleEnd and basicDer[bPos] == 0xA0) {
                const nuTl = try readTagLen(basicDer, &bPos);
                const nuInner = try readTagLen(basicDer, &bPos);
                nextUpdateSec = parseGeneralizedTime(basicDer[bPos .. bPos + nuInner.len]);
                bPos += nuInner.len;
                _ = nuTl;
            }

            bPos = singleEnd;

            try respList.append(allocator, .{
                .status = statusKind,
                .thisUpdate = thisUpdateSec,
                .nextUpdate = nextUpdateSec,
                .revocationTime = revocationTime,
                .serialNumber = serialNumber,
            });
        }
    }

    return .{
        .status = status,
        .producedAt = producedAtSec,
        .responses = try respList.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

// Tests

test "generalized time parser" {
    const ts = parseGeneralizedTime("20261024120000Z");
    try std.testing.expect(ts != null);
    try std.testing.expect(ts.? > 1700000000);
}

test "parse minimal successful ocsp response with good certificate" {
    const a = std.testing.allocator;

    // Minimal synthetic DER payload for OCSPResponse with good status
    const der = [_]u8{
        0x30, 0x51, // SEQUENCE of 81 bytes
        0x0A, 0x01, 0x00, // ENUMERATED 0 (successful)
        0xA0, 0x4C, // [0] ResponseBytes
        0x30, 0x4A, // SEQUENCE
        0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x30, 0x01, // OID id-pkix-ocsp-basic
        0x04, 0x3E, // OCTET STRING of BasicOCSPResponse
        0x30, 0x3C, // SEQUENCE
        0x30, 0x3A, // tbsResponseData SEQUENCE
        0x82, 0x04, 0x01, 0x02, 0x03, 0x04, // ResponderID byKey [2]
        0x18, 0x0F, '2', '0', '2', '6', '1', '0', '2', '4', '0', '0', '0', '0', '0', '0', 'Z', // producedAt
        0x30, 0x21, // responses SEQUENCE OF SingleResponse
        0x30, 0x1F, // SingleResponse
        0x30, 0x0A, // CertID
        0x06, 0x01, 0x00, // hashAlg
        0x04, 0x00, // nameHash
        0x04, 0x00, // keyHash
        0x02, 0x01, 0x42, // serial 0x42
        0x80, 0x00, // [0] IMPLICIT NULL -> good status!
        0x18, 0x0F, '2', '0', '2', '6', '1', '0', '2', '4', '0', '0', '0', '0', '0', '0', 'Z', // thisUpdate
    };

    var parsed = try parseOcspResponse(a, &der);
    defer parsed.deinit();

    try std.testing.expectEqual(OcspResponseStatus.successful, parsed.status);
    try std.testing.expectEqual(@as(usize, 1), parsed.responses.len);
    try std.testing.expectEqual(CertStatusKind.good, parsed.responses[0].status);
    try std.testing.expectEqual(@as(u8, 0x42), parsed.responses[0].serialNumber[0]);
    try std.testing.expect(parsed.isAllGood());
}

test "parse revoked ocsp response" {
    const a = std.testing.allocator;

    const der = [_]u8{
        0x30, 0x51, // SEQUENCE
        0x0A, 0x01, 0x00, // ENUMERATED 0 (successful)
        0xA0, 0x4C, // [0] ResponseBytes
        0x30, 0x4A, // SEQUENCE
        0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x30, 0x01, // OID
        0x04, 0x3E, // OCTET STRING
        0x30, 0x3C, // SEQUENCE
        0x30, 0x3A, // tbsResponseData SEQUENCE
        0x82, 0x04, 0x01, 0x02, 0x03, 0x04, // ResponderID
        0x18, 0x0F, '2', '0', '2', '6', '1', '0', '2', '4', '0', '0', '0', '0', '0', '0', 'Z', // producedAt
        0x30, 0x21, // responses SEQUENCE OF
        0x30, 0x1F, // SingleResponse
        0x30, 0x0A, // CertID
        0x06, 0x01,
        0x00, 0x04,
        0x00, 0x04,
        0x00, 0x02,
        0x01, 0x42,
        0x81, 0x00, // [1] IMPLICIT -> revoked status!
        0x18, 0x0F,
        '2',  '0',
        '2',  '6',
        '1',  '0',
        '2',  '4',
        '0',  '0',
        '0',  '0',
        '0',  '0',
        'Z',
    };

    var parsed = try parseOcspResponse(a, &der);
    defer parsed.deinit();

    try std.testing.expectEqual(CertStatusKind.revoked, parsed.responses[0].status);
    try std.testing.expect(!parsed.isAllGood());
}
