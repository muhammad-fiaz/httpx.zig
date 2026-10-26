//! RFC 6962: Certificate Transparency (Signed Certificate Timestamp - SCT).
//!
//! Provides binary decoding and validation for Signed Certificate Timestamps
//! (SCTs) received via TLS extensions (SignedCertificateTimestampList),
//! OCSP stapling, or embedded X.509 extensions.
//!
//! References:
//!   - RFC 6962: Certificate Transparency
//!   - RFC 5246 Section 4.7: DigitallySigned

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SctVersion = enum(u8) {
    v1 = 0,
    _,
};

pub const HashAlgorithm = enum(u8) {
    sha256 = 4,
    _,
};

pub const SignatureAlgorithm = enum(u8) {
    anonymous = 0,
    rsa = 1,
    dsa = 2,
    ecdsa = 3,
    _,
};

pub const SctError = error{
    InvalidVersion,
    TruncatedData,
    MalformedLength,
    InvalidSignature,
    OutOfMemory,
};

pub const SignedCertificateTimestamp = struct {
    version: SctVersion,
    logId: [32]u8,
    timestampMs: u64,
    extensions: []const u8,
    hashAlgo: HashAlgorithm,
    sigAlgo: SignatureAlgorithm,
    signature: []const u8,

    /// Returns true if this SCT's log ID matches any of the provided trusted log IDs.
    pub fn isTrustedLog(self: *const SignedCertificateTimestamp, trustedLogs: []const [32]u8) bool {
        for (trustedLogs) |tLog| {
            if (std.mem.eql(u8, &self.logId, &tLog)) return true;
        }
        return false;
    }
};

/// Parses a single RFC 6962 SignedCertificateTimestamp binary structure.
pub fn parseSct(bytes: []const u8) SctError!SignedCertificateTimestamp {
    // Minimum SCT size:
    // 1 (version) + 32 (logId) + 8 (timestamp) + 2 (extensions length) + 2 (hash+sig algo) + 2 (sig length) = 47 bytes
    if (bytes.len < 47) return SctError.TruncatedData;

    var pos: usize = 0;
    const rawVersion = bytes[pos];
    pos += 1;
    if (rawVersion != 0) return SctError.InvalidVersion; // only v1 supported per RFC 6962

    var logId: [32]u8 = undefined;
    @memcpy(&logId, bytes[pos .. pos + 32]);
    pos += 32;

    const timestampMs = std.mem.readInt(u64, bytes[pos..][0..8], .big);
    pos += 8;

    const extLen = std.mem.readInt(u16, bytes[pos..][0..2], .big);
    pos += 2;
    if (pos + extLen > bytes.len) return SctError.TruncatedData;
    const extensions = bytes[pos .. pos + extLen];
    pos += extLen;

    if (pos + 4 > bytes.len) return SctError.TruncatedData;
    const hashAlgo: HashAlgorithm = @fromBackingInt(@intCast(bytes[pos]));
    pos += 1;
    const sigAlgo: SignatureAlgorithm = @fromBackingInt(@intCast(bytes[pos]));
    pos += 1;

    const sigLen = std.mem.readInt(u16, bytes[pos..][0..2], .big);
    pos += 2;
    if (pos + sigLen > bytes.len) return SctError.TruncatedData;
    const signature = bytes[pos .. pos + sigLen];

    return .{
        .version = .v1,
        .logId = logId,
        .timestampMs = timestampMs,
        .extensions = extensions,
        .hashAlgo = hashAlgo,
        .sigAlgo = sigAlgo,
        .signature = signature,
    };
}

/// Parses an RFC 6962 SignedCertificateTimestampList (2-byte total length
/// followed by 2-byte length-prefixed serialized SCTs).
pub fn parseSctList(allocator: Allocator, bytes: []const u8) SctError![]SignedCertificateTimestamp {
    if (bytes.len < 2) return SctError.TruncatedData;

    const listLen = std.mem.readInt(u16, bytes[0..2], .big);
    if (2 + listLen > bytes.len) return SctError.TruncatedData;

    var list = std.ArrayList(SignedCertificateTimestamp).empty;
    errdefer list.deinit(allocator);

    var pos: usize = 2;
    const end = 2 + listLen;

    while (pos < end) {
        if (pos + 2 > end) return SctError.TruncatedData;
        const sctLen = std.mem.readInt(u16, bytes[pos..][0..2], .big);
        pos += 2;
        if (pos + sctLen > end) return SctError.TruncatedData;

        const sct = try parseSct(bytes[pos .. pos + sctLen]);
        try list.append(allocator, sct);
        pos += sctLen;
    }

    return list.toOwnedSlice(allocator) catch return SctError.OutOfMemory;
}

// Tests

test "parse valid rfc 6962 sct" {
    var raw: [64]u8 = undefined;
    var pos: usize = 0;

    raw[pos] = 0; // v1
    pos += 1;

    // log id: 32 bytes of 0xAA
    @memset(raw[pos .. pos + 32], 0xAA);
    pos += 32;

    // timestamp: 1700000000000 ms
    std.mem.writeInt(u64, raw[pos..][0..8], 1700000000000, .big);
    pos += 8;

    // ext length: 0
    std.mem.writeInt(u16, raw[pos..][0..2], 0, .big);
    pos += 2;

    // hash + sig algo: SHA256 (4), ECDSA (3)
    raw[pos] = 4;
    pos += 1;
    raw[pos] = 3;
    pos += 1;

    // sig length: 4
    std.mem.writeInt(u16, raw[pos..][0..2], 4, .big);
    pos += 2;
    @memcpy(raw[pos..][0..4], &[_]u8{ 1, 2, 3, 4 });
    pos += 4;

    const sct = try parseSct(raw[0..pos]);
    try std.testing.expectEqual(SctVersion.v1, sct.version);
    try std.testing.expectEqual(@as(u64, 1700000000000), sct.timestampMs);
    try std.testing.expectEqual(HashAlgorithm.sha256, sct.hashAlgo);
    try std.testing.expectEqual(SignatureAlgorithm.ecdsa, sct.sigAlgo);
    try std.testing.expectEqual(@as(usize, 4), sct.signature.len);

    const trusted = [_][32]u8{@splat(0xAA)};
    try std.testing.expect(sct.isTrustedLog(&trusted));

    const untrusted = [_][32]u8{@splat(0xBB)};
    try std.testing.expect(!sct.isTrustedLog(&untrusted));
}

test "parse sct list" {
    const a = std.testing.allocator;

    var sctBuf: [64]u8 = undefined;
    var pos: usize = 0;
    sctBuf[pos] = 0;
    pos += 1;
    @memset(sctBuf[pos .. pos + 32], 0x42);
    pos += 32;
    std.mem.writeInt(u64, sctBuf[pos..][0..8], 123456789, .big);
    pos += 8;
    std.mem.writeInt(u16, sctBuf[pos..][0..2], 0, .big);
    pos += 2;
    sctBuf[pos] = 4; // sha256
    pos += 1;
    sctBuf[pos] = 1; // rsa
    pos += 1;
    std.mem.writeInt(u16, sctBuf[pos..][0..2], 2, .big);
    pos += 2;
    sctBuf[pos] = 0xDE;
    pos += 1;
    sctBuf[pos] = 0xAD;
    pos += 1;
    const sctBytes = sctBuf[0..pos];

    var listBuf: [128]u8 = undefined;
    var lPos: usize = 0;
    // total length placeholder
    lPos += 2;
    // sct length
    std.mem.writeInt(u16, listBuf[lPos..][0..2], @intCast(sctBytes.len), .big);
    lPos += 2;
    @memcpy(listBuf[lPos .. lPos + sctBytes.len], sctBytes);
    lPos += sctBytes.len;

    // write total length
    std.mem.writeInt(u16, listBuf[0..2], @intCast(lPos - 2), .big);

    const parsedList = try parseSctList(a, listBuf[0..lPos]);
    defer a.free(parsedList);

    try std.testing.expectEqual(@as(usize, 1), parsedList.len);
    try std.testing.expectEqual(@as(u64, 123456789), parsedList[0].timestampMs);
    try std.testing.expectEqual(SignatureAlgorithm.rsa, parsedList[0].sigAlgo);
}
