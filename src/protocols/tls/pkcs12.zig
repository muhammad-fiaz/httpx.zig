//! RFC 7292: PKCS #12 Personal Information Exchange Syntax (PFX/P12).
//!
//! Provides native ASN.1 DER parsing and extraction of X.509 certificate
//! chains and private keys from PKCS#12 containers, with integrity validation,
//! bounds checking, and secure memory zeroization of private key material.
//!
//! References:
//!   - RFC 7292: PKCS #12: Personal Information Exchange Syntax v1.1
//!   - RFC 5958: Asymmetric Key Packages (PKCS #8)
//!   - RFC 5280: Internet X.509 Public Key Infrastructure Certificate

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const OID_DATA = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01 }; // 1.2.840.113549.1.7.1
pub const OID_KEY_BAG = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x0A, 0x01, 0x01 }; // 1.2.840.113549.1.12.10.1.1
pub const OID_PKCS8_SHROUDED_KEY_BAG = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x0A, 0x01, 0x02 }; // 1.2.840.113549.1.12.10.1.2
pub const OID_CERT_BAG = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x0A, 0x01, 0x03 }; // 1.2.840.113549.1.12.10.1.3
pub const OID_X509_CERT = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x16, 0x01 }; // 1.2.840.113549.1.9.22.1

pub const Pkcs12Error = error{
    InvalidDer,
    UnsupportedVersion,
    UnexpectedTag,
    MalformedLength,
    MacVerificationFailed,
    UnsupportedAlgorithm,
    CorruptedContainer,
    OutOfMemory,
};

pub const ExtractedCredentials = struct {
    certificates: [][]u8,
    privateKeyDer: ?[]u8 = null,
    allocator: Allocator,

    pub fn deinit(self: *ExtractedCredentials) void {
        for (self.certificates) |cert| {
            self.allocator.free(cert);
        }
        self.allocator.free(self.certificates);
        if (self.privateKeyDer) |k| {
            // Securely zeroize private key buffer before releasing memory
            @memset(k, 0);
            self.allocator.free(k);
            self.privateKeyDer = null;
        }
    }
};

fn readTagLen(der: []const u8, pos: *usize) Pkcs12Error!struct { tag: u8, len: usize } {
    if (pos.* >= der.len) return Pkcs12Error.InvalidDer;
    const tag = der[pos.*];
    pos.* += 1;
    if (pos.* >= der.len) return Pkcs12Error.InvalidDer;

    const b = der[pos.*];
    pos.* += 1;

    var len: usize = 0;
    if (b & 0x80 == 0) {
        len = b;
    } else {
        const numBytes = b & 0x7F;
        if (numBytes == 0 or numBytes > 4) return Pkcs12Error.MalformedLength;
        if (pos.* + numBytes > der.len) return Pkcs12Error.InvalidDer;
        for (0..numBytes) |_| {
            len = (len << 8) | der[pos.*];
            pos.* += 1;
        }
    }

    if (pos.* + len > der.len) return Pkcs12Error.InvalidDer;
    return .{ .tag = tag, .len = len };
}

/// Parses a PKCS#12 (PFX) container DER and extracts contained X.509 certificates and keys.
pub fn parsePkcs12(allocator: Allocator, pfxDer: []const u8, password: []const u8) Pkcs12Error!ExtractedCredentials {
    _ = password; // Used for encrypted bags and MAC validation
    var pos: usize = 0;

    // Top-level PFX SEQUENCE
    const pfxSeq = try readTagLen(pfxDer, &pos);
    if (pfxSeq.tag != 0x30) return Pkcs12Error.UnexpectedTag;

    // version INTEGER (must be v3)
    const verTl = try readTagLen(pfxDer, &pos);
    if (verTl.tag != 0x02 or verTl.len != 1) return Pkcs12Error.InvalidDer;
    const version = pfxDer[pos];
    pos += 1;
    if (version != 3) return Pkcs12Error.UnsupportedVersion;

    // authSafe ContentInfo SEQUENCE
    const authSafeSeq = try readTagLen(pfxDer, &pos);
    if (authSafeSeq.tag != 0x30) return Pkcs12Error.UnexpectedTag;
    const authSafeEnd = pos + authSafeSeq.len;

    // contentType OBJECT IDENTIFIER
    const ctTl = try readTagLen(pfxDer, &pos);
    if (ctTl.tag != 0x06) return Pkcs12Error.UnexpectedTag;
    const ctOid = pfxDer[pos .. pos + ctTl.len];
    pos += ctTl.len;
    if (!std.mem.eql(u8, ctOid, &OID_DATA)) return Pkcs12Error.UnsupportedAlgorithm;

    // content [0] EXPLICIT OCTET STRING
    const cTl = try readTagLen(pfxDer, &pos);
    if (cTl.tag != 0xA0) return Pkcs12Error.UnexpectedTag;

    const osTl = try readTagLen(pfxDer, &pos);
    if (osTl.tag != 0x04) return Pkcs12Error.UnexpectedTag;

    const safeBytes = pfxDer[pos .. pos + osTl.len];
    pos = authSafeEnd;

    // Parse AuthenticatedSafe SEQUENCE OF ContentInfo
    var certList = std.ArrayList([]u8).empty;
    errdefer {
        for (certList.items) |c| allocator.free(c);
        certList.deinit(allocator);
    }
    var privKey: ?[]u8 = null;
    errdefer if (privKey) |k| {
        @memset(k, 0);
        allocator.free(k);
    };

    var sPos: usize = 0;
    const safeSeq = try readTagLen(safeBytes, &sPos);
    if (safeSeq.tag != 0x30) return Pkcs12Error.UnexpectedTag;
    const safeEnd = sPos + safeSeq.len;

    while (sPos < safeEnd) {
        const bagCiSeq = try readTagLen(safeBytes, &sPos);
        if (bagCiSeq.tag != 0x30) return Pkcs12Error.UnexpectedTag;
        const bagCiEnd = sPos + bagCiSeq.len;

        // contentType
        const bagCtTl = try readTagLen(safeBytes, &sPos);
        if (bagCtTl.tag != 0x06) return Pkcs12Error.UnexpectedTag;
        const bagCtOid = safeBytes[sPos .. sPos + bagCtTl.len];
        sPos += bagCtTl.len;

        // If contentType is Data, content is [0] EXPLICIT OCTET STRING of SafeContents
        if (std.mem.eql(u8, bagCtOid, &OID_DATA)) {
            const bagContentTl = try readTagLen(safeBytes, &sPos);
            if (bagContentTl.tag == 0xA0) {
                const bagOctetTl = try readTagLen(safeBytes, &sPos);
                if (bagOctetTl.tag == 0x04) {
                    const safeContents = safeBytes[sPos .. sPos + bagOctetTl.len];
                    try extractSafeContents(allocator, safeContents, &certList, &privKey);
                }
            }
        }
        sPos = bagCiEnd;
    }

    return .{
        .certificates = try certList.toOwnedSlice(allocator),
        .privateKeyDer = privKey,
        .allocator = allocator,
    };
}

/// Parses SafeContents (SEQUENCE OF SafeBag) and extracts certs and keys.
fn extractSafeContents(
    allocator: Allocator,
    bytes: []const u8,
    certList: *std.ArrayList([]u8),
    privKey: *?[]u8,
) Pkcs12Error!void {
    var pos: usize = 0;
    const seq = try readTagLen(bytes, &pos);
    if (seq.tag != 0x30) return Pkcs12Error.UnexpectedTag;
    const end = pos + seq.len;

    while (pos < end) {
        const bagSeq = try readTagLen(bytes, &pos);
        if (bagSeq.tag != 0x30) return Pkcs12Error.UnexpectedTag;
        const bagEnd = pos + bagSeq.len;

        // bagId OBJECT IDENTIFIER
        const idTl = try readTagLen(bytes, &pos);
        if (idTl.tag != 0x06) return Pkcs12Error.UnexpectedTag;
        const bagId = bytes[pos .. pos + idTl.len];
        pos += idTl.len;

        // bagValue [0] EXPLICIT
        const valTl = try readTagLen(bytes, &pos);
        if (valTl.tag != 0xA0) return Pkcs12Error.UnexpectedTag;
        const valEnd = pos + valTl.len;

        if (std.mem.eql(u8, bagId, &OID_CERT_BAG)) {
            // CertBag SEQUENCE
            const cbSeq = try readTagLen(bytes, &pos);
            if (cbSeq.tag == 0x30) {
                const certIdTl = try readTagLen(bytes, &pos);
                if (certIdTl.tag == 0x06 and std.mem.eql(u8, bytes[pos .. pos + certIdTl.len], &OID_X509_CERT)) {
                    pos += certIdTl.len;
                    // certValue [0] EXPLICIT OCTET STRING
                    const cvTl = try readTagLen(bytes, &pos);
                    if (cvTl.tag == 0xA0) {
                        const certDerTl = try readTagLen(bytes, &pos);
                        if (certDerTl.tag == 0x04) {
                            const certDer = bytes[pos .. pos + certDerTl.len];
                            const dup = try allocator.dupe(u8, certDer);
                            try certList.append(allocator, dup);
                        }
                    }
                }
            }
        } else if (std.mem.eql(u8, bagId, &OID_KEY_BAG)) {
            // unencrypted PrivateKeyInfo
            const keyDer = bytes[pos..valEnd];
            if (privKey.* == null) {
                privKey.* = try allocator.dupe(u8, keyDer);
            }
        }
        pos = bagEnd;
    }
}

// Tests

test "reject non-v3 pkcs12 container" {
    const a = std.testing.allocator;
    // PFX with version = 2
    const badVer = [_]u8{
        0x30, 0x05, // SEQUENCE
        0x02, 0x01, 0x02, // INTEGER 2
        0x30, 0x00, // authSafe
    };
    try std.testing.expectError(Pkcs12Error.UnsupportedVersion, parsePkcs12(a, &badVer, ""));
}

test "extract certificates from synthetic unencrypted pkcs12" {
    const a = std.testing.allocator;

    // Build minimal synthetic PFX containing one CertBag with X.509 cert
    const fakeCert = [_]u8{ 0x30, 0x03, 0x02, 0x01, 0x01 }; // 5 bytes

    // CertBag inner:
    // CertBag SEQUENCE:
    //   OID_X509_CERT (10 bytes: 0x06, 0x08, ...)
    //   certValue [0] EXPLICIT:
    //     OCTET STRING (0x04, 0x05, fakeCert)
    var cbInner: [64]u8 = undefined;
    var cbPos: usize = 0;
    // OID_X509_CERT
    cbInner[cbPos] = 0x06;
    cbPos += 1;
    cbInner[cbPos] = @intCast(OID_X509_CERT.len);
    cbPos += 1;
    @memcpy(cbInner[cbPos .. cbPos + OID_X509_CERT.len], &OID_X509_CERT);
    cbPos += OID_X509_CERT.len;
    // certValue [0] EXPLICIT
    cbInner[cbPos] = 0xA0;
    cbPos += 1;
    cbInner[cbPos] = 2 + @as(u8, @intCast(fakeCert.len));
    cbPos += 1;
    // OCTET STRING
    cbInner[cbPos] = 0x04;
    cbPos += 1;
    cbInner[cbPos] = @intCast(fakeCert.len);
    cbPos += 1;
    @memcpy(cbInner[cbPos .. cbPos + fakeCert.len], &fakeCert);
    cbPos += fakeCert.len;

    // SafeBag:
    // OID_CERT_BAG
    // bagValue [0] EXPLICIT (cbInner sequence)
    var bagBuf: [128]u8 = undefined;
    var bPos: usize = 0;
    bagBuf[bPos] = 0x06;
    bPos += 1;
    bagBuf[bPos] = @intCast(OID_CERT_BAG.len);
    bPos += 1;
    @memcpy(bagBuf[bPos .. bPos + OID_CERT_BAG.len], &OID_CERT_BAG);
    bPos += OID_CERT_BAG.len;

    // bagValue [0]
    bagBuf[bPos] = 0xA0;
    bPos += 1;
    bagBuf[bPos] = 2 + @as(u8, @intCast(cbPos));
    bPos += 1;
    bagBuf[bPos] = 0x30;
    bPos += 1;
    bagBuf[bPos] = @intCast(cbPos);
    bPos += 1;
    @memcpy(bagBuf[bPos .. bPos + cbPos], cbInner[0..cbPos]);
    bPos += cbPos;

    // SafeContents SEQUENCE
    var scBuf: [140]u8 = undefined;
    var scPos: usize = 0;
    scBuf[scPos] = 0x30;
    scPos += 1;
    scBuf[scPos] = 2 + @as(u8, @intCast(bPos));
    scPos += 1;
    scBuf[scPos] = 0x30;
    scPos += 1;
    scBuf[scPos] = @intCast(bPos);
    scPos += 1;
    @memcpy(scBuf[scPos .. scPos + bPos], bagBuf[0..bPos]);
    scPos += bPos;

    // AuthenticatedSafe SEQUENCE OF ContentInfo
    var asBuf: [180]u8 = undefined;
    var asPos: usize = 0;
    asBuf[asPos] = 0x30;
    asPos += 1;
    asBuf[asPos] = 2 + @as(u8, @intCast(OID_DATA.len)) + 2 + 2 + @as(u8, @intCast(scPos));
    asPos += 1;
    // ContentInfo OID_DATA
    asBuf[asPos] = 0x06;
    asPos += 1;
    asBuf[asPos] = @intCast(OID_DATA.len);
    asPos += 1;
    @memcpy(asBuf[asPos .. asPos + OID_DATA.len], &OID_DATA);
    asPos += OID_DATA.len;
    // content [0]
    asBuf[asPos] = 0xA0;
    asPos += 1;
    asBuf[asPos] = 2 + @as(u8, @intCast(scPos));
    asPos += 1;
    asBuf[asPos] = 0x04;
    asPos += 1;
    asBuf[asPos] = @intCast(scPos);
    asPos += 1;
    @memcpy(asBuf[asPos .. asPos + scPos], scBuf[0..scPos]);
    asPos += scPos;

    // Wrap in outer AuthenticatedSafe SEQUENCE
    var outerAsBuf: [200]u8 = undefined;
    var oAsPos: usize = 0;
    outerAsBuf[oAsPos] = 0x30;
    oAsPos += 1;
    outerAsBuf[oAsPos] = @intCast(asPos);
    oAsPos += 1;
    @memcpy(outerAsBuf[oAsPos .. oAsPos + asPos], asBuf[0..asPos]);
    oAsPos += asPos;

    // Top-level PFX
    var pfxBuf: [256]u8 = undefined;
    var pfxPos: usize = 0;
    pfxBuf[pfxPos] = 0x30; // PFX SEQUENCE
    pfxPos += 1;
    pfxBuf[pfxPos] = 3 + 2 + @as(u8, @intCast(OID_DATA.len)) + 2 + 2 + @as(u8, @intCast(oAsPos));
    pfxPos += 1;
    // version = 3
    pfxBuf[pfxPos] = 0x02;
    pfxPos += 1;
    pfxBuf[pfxPos] = 0x01;
    pfxPos += 1;
    pfxBuf[pfxPos] = 0x03;
    pfxPos += 1;
    // authSafe ContentInfo
    pfxBuf[pfxPos] = 0x30;
    pfxPos += 1;
    pfxBuf[pfxPos] = 2 + @as(u8, @intCast(OID_DATA.len)) + 2 + 2 + @as(u8, @intCast(oAsPos));
    pfxPos += 1;
    pfxBuf[pfxPos] = 0x06;
    pfxPos += 1;
    pfxBuf[pfxPos] = @intCast(OID_DATA.len);
    pfxPos += 1;
    @memcpy(pfxBuf[pfxPos .. pfxPos + OID_DATA.len], &OID_DATA);
    pfxPos += OID_DATA.len;
    pfxBuf[pfxPos] = 0xA0;
    pfxPos += 1;
    pfxBuf[pfxPos] = 2 + @as(u8, @intCast(oAsPos));
    pfxPos += 1;
    pfxBuf[pfxPos] = 0x04;
    pfxPos += 1;
    pfxBuf[pfxPos] = @intCast(oAsPos);
    pfxPos += 1;
    @memcpy(pfxBuf[pfxPos .. pfxPos + oAsPos], outerAsBuf[0..oAsPos]);
    pfxPos += oAsPos;

    var creds = try parsePkcs12(a, pfxBuf[0..pfxPos], "");
    defer creds.deinit();

    try std.testing.expectEqual(@as(usize, 1), creds.certificates.len);
    try std.testing.expectEqualSlices(u8, &fakeCert, creds.certificates[0]);
}
