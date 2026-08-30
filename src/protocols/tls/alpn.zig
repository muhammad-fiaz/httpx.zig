//! ALPN — Application-Layer Protocol Negotiation (RFC 7301).
//!
//! Zig std.crypto.tls does NOT implement ALPN, so this module provides:
//!   * Wire format: opaque ProtocolNameList extension (type 16)
//!   * Parsing peer lists, matching our preferences, building responses
//!   * Protocol ID constants for h2 / http/1.1 / http/1.0 / h3
//!
//! Integration point: server picks protocol after TLS handshake using
//! client's list + our preference order; client validates selected.
//!
//! References:
//!   - RFC 7301 — Transport Layer Security (TLS) Application-Layer Protocol Negotiation Extension

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    MalformedList,
    ListTooLarge,
    NoOverlap,
    OutOfMemory,
};

/// RFC 7301 encodes each protocol name with a single-octet length and limits
/// the complete ProtocolNameList to a 16-bit vector. Keeping this limit here
/// prevents truncation or wraparound when callers construct an extension.
pub const MAX_PROTOCOL_NAME_LENGTH: usize = 255;
pub const MAX_LIST_LENGTH: usize = std.math.maxInt(u16);

/// Well-known ALPN protocol identifiers.
pub const Protocol = enum {
    @"http/1.0",
    @"http/1.1",
    h2,
    h3,

    pub fn wireName(self: Protocol) []const u8 {
        return switch (self) {
            .@"http/1.0" => "http/1.0",
            .@"http/1.1" => "http/1.1",
            .h2 => "h2",
            .h3 => "h3",
        };
    }

    pub fn fromWire(name: []const u8) ?Protocol {
        if (std.mem.eql(u8, name, "http/1.0")) return .@"http/1.0";
        if (std.mem.eql(u8, name, "http/1.1")) return .@"http/1.1";
        if (std.mem.eql(u8, name, "h2")) return .h2;
        if (std.mem.eql(u8, name, "h3")) return .h3;
        return null;
    }
};

/// Server default preference: h3 > h2 > http/1.1 > http/1.0
pub const DEFAULT_SERVER_PREFERENCE = [_]Protocol{ .h3, .h2, .@"http/1.1", .@"http/1.0" };

/// TCP-only preference (no h3): h2 > http/1.1 > http/1.0 — for TLS over TCP.
/// h3 is QUIC-only (RFC 9114) and must not be advertised on TCP.
pub const DEFAULT_TCP_PREFERENCE = [_]Protocol{ .h2, .@"http/1.1", .@"http/1.0" };

/// Parses an ALPN ProtocolNameList body (without extension header):
/// sequence of u8-length-prefixed names.
pub fn parseList(allocator: Allocator, body: []const u8) Error![]const []const u8 {
    return parseListWithAllocator(allocator, body);
}

/// Parses an ALPN ProtocolNameList body with explicit allocator.
pub fn parseListWithAllocator(allocator: Allocator, body: []const u8) Error![]const []const u8 {
    if (body.len > MAX_LIST_LENGTH) return Error.ListTooLarge;
    var names = std.ArrayList([]const u8).empty;
    errdefer names.deinit(allocator);

    var offset: usize = 0;
    while (offset < body.len) {
        if (offset + 1 > body.len) return Error.MalformedList;
        const len: usize = body[offset];
        offset += 1;
        if (offset + len > body.len) return Error.MalformedList;
        if (len == 0) return Error.MalformedList;
        names.append(allocator, body[offset..][0..len]) catch return Error.OutOfMemory;
        offset += len;
    }
    return names.toOwnedSlice(allocator);
}

/// Serializes protocols into ALPN list body format.
pub fn buildList(allocator: Allocator, protocols: []const Protocol) ![]u8 {
    var size: usize = 0;
    for (protocols) |p| {
        const name_len = p.wireName().len;
        if (name_len == 0 or name_len > MAX_PROTOCOL_NAME_LENGTH) return Error.ListTooLarge;
        size = std.math.add(usize, size, 1 + name_len) catch return Error.ListTooLarge;
        if (size > MAX_LIST_LENGTH) return Error.ListTooLarge;
    }

    var out = try allocator.alloc(u8, size);
    var pos: usize = 0;
    for (protocols) |p| {
        const n = p.wireName();
        out[pos] = @intCast(n.len);
        pos += 1;
        @memcpy(out[pos..][0..n.len], n);
        pos += n.len;
    }
    return out;
}

/// Server-side negotiation: pick first client-offered protocol that we support,
/// honoring OUR preference order (server preference wins per RFC 7301 3.2).
pub fn negotiateServer(ours: []const Protocol, theirs_wire: []const []const u8) ?Protocol {
    for (ours) |candidate| {
        for (theirs_wire) |offered| {
            if (std.mem.eql(u8, candidate.wireName(), offered)) return candidate;
        }
    }
    return null;
}

/// Client-side validation: the selected protocol must be one we offered.
pub fn validateClientSelection(we_offered: []const Protocol, selected_wire: []const u8) ?Protocol {
    for (we_offered) |p| {
        if (std.mem.eql(u8, p.wireName(), selected_wire)) return p;
    }
    return null;
}

// Tests

test "protocol wire names roundtrip" {
    const protos = [_]Protocol{ .@"http/1.0", .@"http/1.1", .h2, .h3 };
    for (protos) |p| {
        const back = Protocol.fromWire(p.wireName());
        try std.testing.expectEqual(p, back.?);
    }
}

test "build and parse ALPN list" {
    const a = std.testing.allocator;
    const ours = [_]Protocol{ .h2, .@"http/1.1" };

    const wire = try buildList(a, &ours);
    defer a.free(wire);

    // Expected: \x02h2\x08http/1.1
    try std.testing.expectEqual(@as(usize, 12), wire.len);

    const parsed = try parseList(a, wire);
    defer a.free(parsed);

    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqualStrings("h2", parsed[0]);
    try std.testing.expectEqualStrings("http/1.1", parsed[1]);
}

test "server negotiation honors our preference" {
    const ours = [_]Protocol{ .h2, .@"http/1.1", .@"http/1.0" };
    // Client offers http/1.1 first but we prefer h2 which they also offer
    const theirs = [_][]const u8{ "spdy/3", "http/1.1", "h2" };
    const picked = negotiateServer(&ours, &theirs).?;
    try std.testing.expectEqual(Protocol.h2, picked);
}

test "client rejects unknown selection" {
    const offered = [_]Protocol{ .h2, .@"http/1.1" };
    const sel = validateClientSelection(&offered, "h3");
    try std.testing.expect(sel == null);
    const ok = validateClientSelection(&offered, "h2");
    try std.testing.expectEqual(Protocol.h2, ok.?);
}

test "ALPN rejects an oversized protocol list" {
    var body: [MAX_LIST_LENGTH + 1]u8 = undefined;
    @memset(&body, 1);
    try std.testing.expectError(Error.ListTooLarge, parseList(std.testing.allocator, &body));
}
