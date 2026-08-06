//! ALPN (Application-Layer Protocol Negotiation) Policy  --  RFC 7301
//!
//! Provides:
//! - Client-side: encoding an ordered list of preferred protocols for
//!   inclusion in the TLS ClientHello.
//! - Server-side: selecting one protocol from the server's preference list
//!   that also appears in the client's offered list.
//! - Storage of the negotiated protocol on the connection.

const std = @import("std");
const mem = std.mem;

// Well-known protocol identifiers

/// Well-known ALPN protocol identifier strings.
pub const Protocol = struct {
    pub const HTTP1_0: []const u8 = "http/1.0";
    pub const HTTP1_1: []const u8 = "http/1.1";
    pub const HTTP2: []const u8 = "h2";
    pub const HTTP3: []const u8 = "h3";
    pub const H3_29: []const u8 = "h3-29";
};

// Negotiation logic

/// Selects the first protocol from `server_preference` that also appears
/// in `client_offer`.
///
/// Returns the matched protocol string (a slice into `server_preference`),
/// or `null` if no match was found.
///
/// The selection follows RFC 7301 Section3.2: the server's preference order
/// takes precedence.
pub fn serverNegotiate(
    server_preference: []const []const u8,
    client_offer: []const []const u8,
) ?[]const u8 {
    for (server_preference) |sp| {
        for (client_offer) |co| {
            if (mem.eql(u8, sp, co)) return sp;
        }
    }
    return null;
}

/// Returns true if the negotiated protocol string indicates HTTP/2.
pub fn isHttp2(protocol: ?[]const u8) bool {
    const p = protocol orelse return false;
    return mem.eql(u8, p, Protocol.HTTP2);
}

/// Returns true if the negotiated protocol string indicates HTTP/3
/// (including draft versions like "h3-29").
pub fn isHttp3(protocol: ?[]const u8) bool {
    const p = protocol orelse return false;
    return mem.eql(u8, p, Protocol.HTTP3) or
        mem.startsWith(u8, p, "h3-");
}

/// Returns true if the negotiated protocol string indicates HTTP/1.1 or 1.0.
pub fn isHttp1x(protocol: ?[]const u8) bool {
    const p = protocol orelse return true; // default when ALPN absent
    return mem.eql(u8, p, Protocol.HTTP1_1) or
        mem.eql(u8, p, Protocol.HTTP1_0);
}

// NegotiatedAlpn  --  compact storage for the negotiated protocol

/// Compact inline storage for the negotiated ALPN protocol string.
///
/// A maximum of 64 bytes covers all well-known protocol identifiers with
/// room for future custom protocols.
pub const NegotiatedAlpn = struct {
    buf: [64]u8 = [1]u8{0} ** 64,
    len: usize = 0,

    /// Stores `proto` into this `NegotiatedAlpn`.  Truncates silently if
    /// `proto.len > 64` (protocol IDs longer than 64 bytes are not expected
    /// in practice).
    pub fn set(self: *NegotiatedAlpn, proto: []const u8) void {
        const n = @min(proto.len, self.buf.len);
        @memcpy(self.buf[0..n], proto[0..n]);
        self.len = n;
    }

    /// Returns the negotiated protocol string, or `null` if ALPN was not
    /// negotiated (no extension received from the server).
    pub fn get(self: *const NegotiatedAlpn) ?[]const u8 {
        if (self.len == 0) return null;
        return self.buf[0..self.len];
    }

    pub fn isHttp2Result(self: *const NegotiatedAlpn) bool {
        return isHttp2(self.get());
    }

    pub fn isHttp3Result(self: *const NegotiatedAlpn) bool {
        return isHttp3(self.get());
    }

    pub fn isHttp1xResult(self: *const NegotiatedAlpn) bool {
        return isHttp1x(self.get());
    }
};

// Tests

test "serverNegotiate prefers server order" {
    const t = std.testing;
    const server: []const []const u8 = &.{ Protocol.HTTP2, Protocol.HTTP1_1 };
    const client: []const []const u8 = &.{ Protocol.HTTP1_1, Protocol.HTTP2 };
    // Server prefers h2 -> should select h2 despite client listing http/1.1 first.
    try t.expectEqualStrings(Protocol.HTTP2, serverNegotiate(server, client).?);
}

test "serverNegotiate returns null on no match" {
    const server: []const []const u8 = &.{Protocol.HTTP2};
    const client: []const []const u8 = &.{Protocol.HTTP1_1};
    try std.testing.expect(serverNegotiate(server, client) == null);
}

test "isHttp2 / isHttp3 / isHttp1x" {
    const t = std.testing;
    try t.expect(isHttp2("h2"));
    try t.expect(!isHttp2("http/1.1"));
    try t.expect(isHttp3("h3"));
    try t.expect(isHttp3("h3-29"));
    try t.expect(!isHttp3("h2"));
    try t.expect(isHttp1x("http/1.1"));
    try t.expect(isHttp1x("http/1.0"));
    try t.expect(isHttp1x(null)); // no ALPN -> default to HTTP/1.x
    try t.expect(!isHttp1x("h2"));
}

test "NegotiatedAlpn round-trip" {
    const t = std.testing;
    var n: NegotiatedAlpn = .{};
    try t.expect(n.get() == null);
    n.set(Protocol.HTTP2);
    try t.expectEqualStrings(Protocol.HTTP2, n.get().?);
    try t.expect(n.isHttp2Result());
    try t.expect(!n.isHttp3Result());
    n.set(Protocol.H3_29);
    try t.expect(n.isHttp3Result());
}

test "NegotiatedAlpn set/get multiple protocols" {
    const t = std.testing;
    var n: NegotiatedAlpn = .{};
    n.set("custom-proto");
    try t.expectEqualStrings("custom-proto", n.get().?);
    try t.expect(!n.isHttp2Result());
    try t.expect(!n.isHttp3Result());
    try t.expect(!n.isHttp1xResult());
}

test "NegotiatedAlpn get returns null when empty" {
    var n: NegotiatedAlpn = .{};
    try std.testing.expect(n.get() == null);
}

test "serverNegotiate single match" {
    const server: []const []const u8 = &.{Protocol.HTTP1_1};
    const client: []const []const u8 = &.{Protocol.HTTP1_1};
    const result = serverNegotiate(server, client);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(Protocol.HTTP1_1, result.?);
}

test "serverNegotiate empty server list" {
    const server: []const []const u8 = &.{};
    const client: []const []const u8 = &.{Protocol.HTTP2};
    try std.testing.expect(serverNegotiate(server, client) == null);
}

test "serverNegotiate empty client list" {
    const server: []const []const u8 = &.{Protocol.HTTP2};
    const client: []const []const u8 = &.{};
    try std.testing.expect(serverNegotiate(server, client) == null);
}

test "isHttp3 with h3-30 draft" {
    try std.testing.expect(isHttp3("h3-30"));
}

test "isHttp1x with http/1.0" {
    try std.testing.expect(isHttp1x("http/1.0"));
}

test "isHttp1x with unknown protocol" {
    try std.testing.expect(!isHttp1x("grpc"));
}
