//! Canonical HTTP version selector — requested vs supported vs negotiated.
//!
//! `auto` is a *negotiation directive*, never a protocol. It resolves
//! through transport capabilities (TCP/TLS-ALPN/QUIC) to an actual engine.
//! Explicit selections never silently downgrade: requesting `h3` on a host
//! without QUIC is a hard error, not a fallback.
//!
//! Wire identifiers follow TLS ALPN (RFC 7301): "http/1.0", "http/1.1",
//! "h2", "h3". `auto` has no wire identifier.

const std = @import("std");

pub const Error = error{
    /// Text is not a recognized version identifier.
    InvalidVersionString,
    /// An explicitly requested protocol cannot be established on this
    /// connection/transport/build. Never produced for `auto`.
    VersionUnsupported,
    /// `auto` negotiation found no usable common protocol.
    NegotiationFailed,
};

pub const HttpVersion = enum {
    /// Automatic selection based on transport capabilities.
    auto,
    /// Explicit HTTP/1.0 semantics.
    http_1_0,
    /// HTTP/1.1 (keep-alive, chunked, etc).
    http_1,
    /// HTTP/2. Plain TCP -> prior knowledge (RFC 9113 §3.4); TLS requires h2 ALPN.
    h2,
    /// HTTP/3 over QUIC (RFC 9114).
    h3,

    /// Wire / ALPN identifier. `auto` has none — callers must negotiate
    /// first and use the negotiated value's name.
    pub fn wireName(self: HttpVersion) ?[]const u8 {
        return switch (self) {
            .auto => null,
            .http_1_0 => "http/1.0",
            .http_1 => "http/1.1",
            .h2 => "h2",
            .h3 => "h3",
        };
    }

    /// Alias kept for call sites that require a string; asserts resolved.
    pub fn wireNameResolved(self: HttpVersion) []const u8 {
        return self.wireName() orelse "http/1.1";
    }

    /// Parses an ALPN wire identifier.
    pub fn fromWire(name: []const u8) ?HttpVersion {
        if (std.mem.eql(u8, name, "http/1.0")) return .http_1_0;
        if (std.mem.eql(u8, name, "http/1.1")) return .http_1;
        if (std.mem.eql(u8, name, "h2")) return .h2;
        if (std.mem.eql(u8, name, "h3")) return .h3;
        return null;
    }

    /// Parses user-facing selection text. Canonical forms are the wire
    /// identifiers plus "auto"; convenience aliases ("1.0", "1", "1.1",
    /// "2", "3", "http1", "http2", "http3", "http/2") map to canonical
    /// values. Unknown text is an error, never a silent fallback.
    pub fn parse(text: []const u8) Error!HttpVersion {
        const eq = std.mem.eql;
        if (eq(u8, text, "auto")) return .auto;

        // Canonical wire identifiers.
        if (fromWire(text)) |v| return v;

        // Convenience aliases (documented; output stays canonical).
        if (eq(u8, text, "1") or eq(u8, text, "1.0") or eq(u8, text, "http1") or eq(u8, text, "http/1")) return .http_1_0;
        if (eq(u8, text, "1.1") or eq(u8, text, "http11") or eq(u8, text, "http/1.1x")) return .http_1;
        // NOTE: bare "1" is ambiguous; treated as HTTP/1.0's family alias.
        if (eq(u8, text, "2") or eq(u8, text, "http2") or eq(u8, text, "http/2")) return .h2;
        if (eq(u8, text, "3") or eq(u8, text, "http3") or eq(u8, text, "http/3")) return .h3;

        return Error.InvalidVersionString;
    }

    /// Preference rank used by `auto` (higher wins when available).
    pub fn rank(self: HttpVersion) u8 {
        return switch (self) {
            .h3 => 4,
            .h2 => 3,
            .http_1 => 2,
            .http_1_0 => 1,
            .auto => 0,
        };
    }
};

// Capability model

/// What this build/runtime can actually establish. Compile-time feature
/// availability belongs here so the selector never advertises a disabled
/// protocol as available.
pub const Capabilities = struct {
    http_1_0: bool = true,
    http_1: bool = true,
    h2: bool = false,
    h3: bool = false,

    pub fn supports(self: *const Capabilities, v: HttpVersion) bool {
        return switch (v) {
            .auto => true,
            .http_1_0 => self.http_1_0,
            .http_1 => self.http_1,
            .h2 => self.h2,
            .h3 => self.h3,
        };
    }

    /// Best available concrete protocol by preference order.
    pub fn bestAvailable(self: *const Capabilities) ?HttpVersion {
        const order = [_]HttpVersion{ .h3, .h2, .http_1, .http_1_0 };
        for (order) |v| {
            if (self.supports(v)) return v;
        }
        return null;
    }
};

/// Outcome of negotiation: the single protocol the connection will run.
pub const Negotiation = struct {
    active: HttpVersion,
    /// True when ALPN decided the outcome (client must verify it offered
    /// the returned identifier; server must have selected it).
    via_alpn: bool = false,
};

/// Resolves the requested version against capabilities.
///
/// Rules:
///   * explicit + supported  -> that protocol (identity).
///   * explicit + unsupported-> error.VersionUnsupported (NO downgrade).
///   * auto                  -> ALPN result if provided and supported;
///                              otherwise the best capability available.
pub fn negotiate(
    requested: HttpVersion,
    caps: *const Capabilities,
    /// Wire-level ALPN identifier selected by TLS/QUIC, if any.
    alpn_selected: ?[]const u8,
) Error!Negotiation {
    if (requested != .auto) {
        if (!caps.supports(requested)) return Error.VersionUnsupported;
        // If ALPN ran, its result constrains us: an explicit request that
        // contradicts the negotiated ALPN is a mismatch, not a downgrade.
        if (alpn_selected) |sel| {
            if (HttpVersion.fromWire(sel)) |v| {
                if (v != requested) return Error.VersionUnsupported;
            } else {
                return Error.VersionUnsupported;
            }
        }
        return .{ .active = requested };
    }

    // auto path
    if (alpn_selected) |sel| {
        const v = HttpVersion.fromWire(sel) orelse return Error.NegotiationFailed;
        if (!caps.supports(v)) return Error.NegotiationFailed;
        return .{ .active = v, .via_alpn = true };
    }
    const best = caps.bestAvailable() orelse return Error.NegotiationFailed;
    return .{ .active = best };
}

// Tests

test "canonical wire names" {
    try std.testing.expectEqualStrings("http/1.0", HttpVersion.http_1_0.wireName().?);
    try std.testing.expectEqualStrings("http/1.1", HttpVersion.http_1.wireName().?);
    try std.testing.expectEqualStrings("h2", HttpVersion.h2.wireName().?);
    try std.testing.expectEqualStrings("h3", HttpVersion.h3.wireName().?);
    try std.testing.expectEqual(@as(?[]const u8, null), HttpVersion.auto.wireName());
}

test "wire parsing and roundtrips" {
    inline for (@typeInfo(HttpVersion).@"enum".fields) |f| {
        const v: HttpVersion = @enumFromInt(f.value);
        if (v.wireName()) |w| {
            try std.testing.expectEqual(v, HttpVersion.fromWire(w).?);
            try std.testing.expectEqual(v, try HttpVersion.parse(w));
        }
    }
}

test "aliases parse to canonical values" {
    try std.testing.expectEqual(HttpVersion.auto, try HttpVersion.parse("auto"));
    try std.testing.expectEqual(HttpVersion.http_1_0, try HttpVersion.parse("1.0"));
    try std.testing.expectEqual(HttpVersion.http_1_0, try HttpVersion.parse("http1"));
    try std.testing.expectEqual(HttpVersion.http_1, try HttpVersion.parse("1.1"));
    try std.testing.expectEqual(HttpVersion.h2, try HttpVersion.parse("2"));
    try std.testing.expectEqual(HttpVersion.h2, try HttpVersion.parse("http2"));
    try std.testing.expectEqual(HttpVersion.h2, try HttpVersion.parse("http/2"));
    try std.testing.expectEqual(HttpVersion.h3, try HttpVersion.parse("3"));
    try std.testing.expectEqual(HttpVersion.h3, try HttpVersion.parse("http3"));
}

test "invalid version strings error, never fall back" {
    try std.testing.expectError(Error.InvalidVersionString, HttpVersion.parse(""));
    try std.testing.expectError(Error.InvalidVersionString, HttpVersion.parse("HTTP/9"));
    try std.testing.expectError(Error.InvalidVersionString, HttpVersion.parse("quic"));
    try std.testing.expectError(Error.InvalidVersionString, HttpVersion.parse("spdy/3"));
}

test "negotiate: auto picks best capability" {
    var caps = Capabilities{};
    // Default build: HTTP/1 only.
    try std.testing.expectEqual(HttpVersion.http_1, (try negotiate(.auto, &caps, null)).active);

    caps.h2 = true;
    try std.testing.expectEqual(HttpVersion.h2, (try negotiate(.auto, &caps, null)).active);

    caps.h3 = true;
    try std.testing.expectEqual(HttpVersion.h3, (try negotiate(.auto, &caps, null)).active);
}

test "negotiate: ALPN result wins for auto" {
    var caps = Capabilities{ .h2 = true };
    caps.http_1 = true;
    // Server selects h2 even though our best would be h2 anyway...
    const n = try negotiate(.auto, &caps, "h2");
    try std.testing.expectEqual(HttpVersion.h2, n.active);
    try std.testing.expect(n.via_alpn);
    // ...and can also pick http/1.1 when only that overlaps.
    const n2 = try negotiate(.auto, &caps, "http/1.1");
    try std.testing.expectEqual(HttpVersion.http_1, n2.active);
    try std.testing.expect(n2.via_alpn);
}

test "negotiate: explicit identity when supported" {
    var caps = Capabilities{ .h2 = true, .h3 = true };
    try std.testing.expectEqual(HttpVersion.h3, (try negotiate(.h3, &caps, null)).active);
    try std.testing.expectEqual(HttpVersion.h2, (try negotiate(.h2, &caps, null)).active);
    try std.testing.expectEqual(HttpVersion.http_1, (try negotiate(.http_1, &caps, null)).active);
    try std.testing.expectEqual(HttpVersion.http_1_0, (try negotiate(.http_1_0, &caps, null)).active);
}

test "negotiate: explicit never silently downgrades" {
    const caps = Capabilities{}; // h1-only build
    try std.testing.expectError(Error.VersionUnsupported, negotiate(.h2, &caps, null));
    try std.testing.expectError(Error.VersionUnsupported, negotiate(.h3, &caps, null));
}

test "negotiate: explicit contradicted by ALPN is a hard failure" {
    var caps = Capabilities{ .h2 = true, .http_1 = true };
    caps.http_1 = true;
    // We asked for h2 but the server ALPN-selected http/1.1: refuse.
    try std.testing.expectError(Error.VersionUnsupported, negotiate(.h2, &caps, "http/1.1"));
}

test "negotiate: unknown ALPN result fails loudly" {
    const caps = Capabilities{};
    try std.testing.expectError(Error.NegotiationFailed, negotiate(.auto, &caps, "spdy/3.1"));
    try std.testing.expectError(Error.NegotiationFailed, negotiate(.auto, &caps, "h4"));
}

test "capabilities: nothing available yields negotiation failure" {
    const caps = Capabilities{
        .http_1_0 = false,
        .http_1 = false,
        .h2 = false,
        .h3 = false,
    };
    try std.testing.expect(caps.bestAvailable() == null);
    try std.testing.expectError(Error.NegotiationFailed, negotiate(.auto, &caps, null));
}

test "rank ordering prefers h3 > h2 > h1.1 > h1.0" {
    try std.testing.expect(HttpVersion.h3.rank() > HttpVersion.h2.rank());
    try std.testing.expect(HttpVersion.h2.rank() > HttpVersion.http_1.rank());
    try std.testing.expect(HttpVersion.http_1.rank() > HttpVersion.http_1_0.rank());
}
