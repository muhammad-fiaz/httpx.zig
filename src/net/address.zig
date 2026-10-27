//! Unified IP address handling: IPv4 + IPv6.
//!
//! Parsing supports:
//!   * Dotted quad IPv4: "127.0.0.1"
//!   * Full-form IPv6:   "2001:0db8:0000:0000:0000:0000:0000:0001"
//!   * Compressed IPv6:  "2001:db8::1"
//!   * Zone/scoped IPv6: "fe80::1%eth0" (zone parsed, interface resolved lazily)
//!   * v4-mapped:        "::ffff:192.168.1.1"
//! Formatting follows RFC 5952 (longest zero run compressed, lowercase).
//!
//! References:
//!   - RFC 4291 — IP Version 6 Addressing Architecture
//!   - RFC 5952 — A Recommendation for IPv6 Text Representation
//!   - RFC 6874 — IPv6 Zone Identifiers in URIs
//!   - RFC 4007 — IPv6 Scoped Address Architecture

const std = @import("std");
const net = std.Io.net;
const Allocator = std.mem.Allocator;
const parseMod = @import("../common/parse.zig");

pub const Error = error{ InvalidAddress, InvalidPort, BufferTooSmall };

pub const Family = enum { ip4, ip6 };

pub const Address = struct {
    family: Family,
    /// Big-endian address bytes (4 for ip4, 16 for ip6).
    bytes: [16]u8 = (@as([16]u8, @splat(0))),
    port: u16,
    /// IPv6 scope/zone id (interface index); 0 = none.
    zone: u32 = 0,

    pub fn loopback4(port: u16) Address {
        return .{ .family = .ip4, .port = port, .bytes = blk: {
            var b = (@as([16]u8, @splat(0)));
            b[0..4].* = .{ 127, 0, 0, 1 };
            break :blk b;
        } };
    }

    pub fn loopback6(port: u16) Address {
        var a = Address{ .family = .ip6, .bytes = (@as([16]u8, @splat(0))), .port = port };
        a.bytes[15] = 1;
        return a;
    }

    pub fn unspecified4(port: u16) Address {
        return .{ .family = .ip4, .port = port };
    }

    pub fn unspecified6(port: u16) Address {
        return .{ .family = .ip6, .port = port };
    }

    /// True when this is an IPv4-mapped IPv6 address (::ffff:a.b.c.d).
    pub fn isV4Mapped(self: *const Address) bool {
        if (self.family != .ip6) return false;
        const prefix = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
        return std.mem.eql(u8, self.bytes[0..12], prefix[0..]);
    }

    /// Converts v4-mapped IPv6 to plain IPv4 view.
    pub fn toV4MappedView(self: *const Address) ?Address {
        if (!self.isV4Mapped()) return null;
        var a = self.*;
        a.family = .ip4;
        a.bytes[0..4].* = self.bytes[12..16].*;
        a.zone = 0;
        return a;
    }

    /// Parses "host" or "[v6]:port" or "host:port" or bare host.
    /// Bare hosts without an explicit port use `defaultPort`.
    pub fn parse(text: []const u8, defaultPort: u16) Error!struct { addr: []const u8, port: u16 } {
        const auth = parseMod.parseAuthority(text) orelse return Error.InvalidAddress;
        return .{
            .addr = auth.host,
            .port = auth.port orelse defaultPort,
        };
    }

    pub fn parseIp(self: *const Address, text: []const u8) Error!Address {
        _ = self;
        // Try IPv4 first
        if (parseIp4Bytes(text)) |b| {
            var a = Address{ .family = .ip4, .port = 0 };
            a.bytes[0..4].* = b;
            return a;
        }
        return parseIp6Text(text);
    }

    /// Standard Zig format method: enables `{f}` formatting in Zig 0.17.0.
    /// Example: `std.debug.print("{f}\n", .{addr})` or `std.fmt.allocPrint(a, "{f}", .{addr})`.
    pub fn format(self: Address, writer: anytype) !void {
        var buf: [64]u8 = undefined;
        const s = self.formatBuf(&buf);
        try writer.writeAll(s);
    }

    /// Formats into buf per RFC 5952. Returns formatted slice.
    ///
    /// IPv6 text is produced by `std.Io.net.Ip6Address.Unresolved.format`,
    /// which implements the same RFC 5952 rules as the previous hand-rolled
    /// formatter (longest zero run of two or more groups compressed, lowercase
    /// hex, `::ffff:a.b.c.d` for IPv4-mapped addresses).
    pub fn formatBuf(self: *const Address, buf: []u8) []const u8 {
        switch (self.family) {
            .ip4 => return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
                self.bytes[0], self.bytes[1], self.bytes[2], self.bytes[3],
            }) catch buf[0..0],
            .ip6 => {
                var writer = std.Io.Writer.fixed(buf);
                const unresolved = net.Ip6Address.Unresolved{
                    .bytes = self.bytes,
                    .interface_name = null,
                };
                unresolved.format(&writer) catch return buf[0..0];
                return buf[0..writer.end];
            },
        }
    }

    /// Formats the address and port (e.g. "127.0.0.1:80" or "[::1]:443") into buf.
    pub fn formatWithPort(self: *const Address, buf: []u8) []const u8 {
        switch (self.family) {
            .ip4 => {
                var ipBuf: [32]u8 = undefined;
                const ipS = self.formatBuf(&ipBuf);
                return std.fmt.bufPrint(buf, "{s}:{d}", .{ ipS, self.port }) catch buf[0..0];
            },
            .ip6 => {
                var ipBuf: [64]u8 = undefined;
                const ipS = self.formatBuf(&ipBuf);
                return std.fmt.bufPrint(buf, "[{s}]:{d}", .{ ipS, self.port }) catch buf[0..0];
            },
        }
    }

    /// Allocates and formats the address as an owned string.
    pub fn toString(self: Address, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{f}", .{self});
    }

    /// Converts to Zig std IpAddress for socket operations.
    pub fn toStd(self: *const Address, port: ?u16) net.IpAddress {
        const p = port orelse self.port;
        switch (self.family) {
            .ip4 => return .{ .ip4 = .{ .bytes = self.bytes[0..4].*, .port = p } },
            .ip6 => return .{ .ip6 = .{ .bytes = self.bytes, .port = p } },
        }
    }

    pub fn fromStd(a: net.IpAddress) Address {
        return switch (a) {
            .ip4 => |v| blk: {
                var out = Address{ .family = .ip4, .bytes = (@as([16]u8, @splat(0))), .port = v.port };
                out.bytes[0..4].* = v.bytes;
                break :blk out;
            },
            .ip6 => |v| .{ .family = .ip6, .bytes = v.bytes, .port = v.port },
        };
    }
};

/// Returns true when `peer` is covered by an exact address or CIDR rule.
/// IPv4-mapped IPv6 peers are normalized so `::ffff:127.0.0.1` matches
/// `127.0.0.1` and IPv4 prefixes. Invalid rules never match.
pub fn matchesCidr(peer: []const u8, rule: []const u8) bool {
    const trimmed = std.mem.trim(u8, rule, " \t");
    if (trimmed.len == 0) return false;

    const slash = std.mem.indexOfScalar(u8, trimmed, '/');
    const host = if (slash) |i| trimmed[0..i] else trimmed;

    var dummy = Address{ .family = .ip4, .port = 0 };
    var peerAddr = dummy.parseIp(std.mem.trim(u8, peer, " \t")) catch
        return std.ascii.eqlIgnoreCase(peer, trimmed);
    var ruleAddr = dummy.parseIp(host) catch
        return std.ascii.eqlIgnoreCase(peer, trimmed);

    if (peerAddr.toV4MappedView()) |v| peerAddr = v;
    if (ruleAddr.toV4MappedView()) |v| ruleAddr = v;
    if (peerAddr.family != ruleAddr.family) return false;

    const maxBits: u8 = if (peerAddr.family == .ip4) 32 else 128;
    const bits: u8 = if (slash) |i|
        std.fmt.parseInt(u8, trimmed[i + 1 ..], 10) catch return false
    else
        maxBits;
    if (bits > maxBits) return false;

    var i: usize = 0;
    while (i < bits / 8) : (i += 1) {
        if (peerAddr.bytes[i] != ruleAddr.bytes[i]) return false;
    }
    const rem = bits % 8;
    if (rem != 0) {
        const mask: u8 = @truncate(@as(u16, 0xff00) >> @as(u4, @intCast(rem)));
        if ((peerAddr.bytes[i] & mask) != (ruleAddr.bytes[i] & mask)) return false;
    }
    return true;
}

test "CIDR rules match addresses and normalize v4-mapped peers" {
    try std.testing.expect(matchesCidr("127.0.0.1", "127.0.0.1"));
    try std.testing.expect(matchesCidr("127.0.0.1", "127.0.0.0/8"));
    try std.testing.expect(!matchesCidr("127.0.0.1", "10.0.0.0/8"));
    try std.testing.expect(matchesCidr("192.168.1.5", "192.168.1.0/24"));
    try std.testing.expect(!matchesCidr("192.168.2.5", "192.168.1.0/24"));
    try std.testing.expect(matchesCidr("::ffff:127.0.0.1", "127.0.0.1"));
    try std.testing.expect(matchesCidr("2001:db8::1", "2001:db8::/32"));
    try std.testing.expect(!matchesCidr("2001:db9::1", "2001:db8::/32"));
    try std.testing.expect(matchesCidr("10.1.2.3", "0.0.0.0/0"));
    try std.testing.expect(!matchesCidr("10.1.2.3", "10.1.2.3/33"));
    try std.testing.expect(!matchesCidr("10.1.2.3", "not-an-address"));
}

/// Parses dotted-quad IPv4 into 4 bytes.
///
/// Delegates to `std.Io.net.Ip4Address.parse`, which rejects empty
/// octets, values above 255, leading zeros, and trailing junk.
pub fn parseIp4Bytes(text: []const u8) ?[4]u8 {
    const parsed = net.Ip4Address.parse(text, 0) catch return null;
    return parsed.bytes;
}

/// Parses dotted-quad IPv4 into the big-endian `u32` used by SOCKS.
pub fn parseIp4U32(text: []const u8) ?u32 {
    const bytes = parseIp4Bytes(text) orelse return null;
    return std.mem.readInt(u32, &bytes, .big);
}

/// Parses a full or compressed IPv6 literal with an optional `%zone`
/// suffix. Numeric zones are stored in `Address.zone`; named zones are
/// accepted and left for the socket layer to resolve.
///
/// Validation and byte assembly are delegated to the standard library.
/// Only the RFC 4291 embedded-IPv4 tail is translated to two hexadecimal
/// groups first because `std.Io.net.Ip6Address.parse` handles that form
/// only for the `::ffff:` prefix.
fn parseIp6Text(textIn: []const u8) Error!Address {
    var text = textIn;

    var zone: u32 = 0;
    if (std.mem.indexOfScalar(u8, text, '%')) |zidx| {
        const zname = text[zidx + 1 ..];
        text = text[0..zidx];
        if (zname.len == 0) return Error.InvalidAddress;
        // Numeric interface index; non-numeric names resolve at the socket layer.
        zone = std.fmt.parseInt(u32, zname, 10) catch 0;
    }
    if (std.mem.indexOfScalar(u8, text, '%') != null) return Error.InvalidAddress;

    var converted: [64]u8 = undefined;
    if (std.mem.lastIndexOfScalar(u8, text, ':')) |lastColon| {
        const tail = text[lastColon + 1 ..];
        // `std.Io.net` understands `::ffff:a.b.c.d` directly but not other
        // IPv4-embedded forms, so translate those to hex groups.
        if (std.mem.indexOfScalar(u8, tail, '.') != null and
            !std.ascii.startsWithIgnoreCase(text, "::ffff:"))
        {
            const v4 = parseIp4Bytes(tail) orelse return Error.InvalidAddress;
            const prefix = text[0 .. lastColon + 1];
            if (prefix.len + 20 > converted.len) return Error.InvalidAddress;
            @memcpy(converted[0..prefix.len], prefix);
            const suffix = std.fmt.bufPrint(converted[prefix.len..], "{x}:{x}", .{
                (@as(u16, v4[0]) << 8) | v4[1],
                (@as(u16, v4[2]) << 8) | v4[3],
            }) catch return Error.InvalidAddress;
            text = converted[0 .. prefix.len + suffix.len];
        }
    }

    const parsed = net.Ip6Address.parse(text, 0) catch return Error.InvalidAddress;
    return .{ .family = .ip6, .bytes = parsed.bytes, .port = 0, .zone = zone };
}

// Tests

var addrAny = Address{ .family = .ip4, .port = 0 };

test "parse ipv4 dotted quad" {
    var buf: [64]u8 = undefined;
    const a = addrAny.parseIp("192.168.1.100") catch unreachable;
    try std.testing.expectEqual(Family.ip4, a.family);
    try std.testing.expectEqualSlices(u8, &.{ 192, 168, 1, 100 }, a.bytes[0..4]);
    try std.testing.expectEqualStrings("192.168.1.100", a.formatBuf(&buf));

    // Test native std.fmt printing
    const str = try a.toString(std.testing.allocator);
    defer std.testing.allocator.free(str);
    try std.testing.expectEqualStrings("192.168.1.100", str);
}

test "reject malformed ipv4" {
    const a = Address{ .family = .ip4, .port = 0 };
    try std.testing.expectError(Error.InvalidAddress, a.parseIp("256.1.1.1"));
    try std.testing.expectError(Error.InvalidAddress, a.parseIp("1.2.3"));
    try std.testing.expectError(Error.InvalidAddress, a.parseIp("1.2.3.4.5"));
    try std.testing.expectError(Error.InvalidAddress, a.parseIp("a.b.c.d"));
    try std.testing.expectError(Error.InvalidAddress, a.parseIp(""));
}

test "parse ipv4 into network-order u32" {
    try std.testing.expectEqual(@as(?u32, 0x7F000001), parseIp4U32("127.0.0.1"));
    try std.testing.expectEqual(@as(?u32, 0x08080808), parseIp4U32("8.8.8.8"));
    try std.testing.expectEqual(@as(?u32, null), parseIp4U32("example.com"));
    try std.testing.expectEqual(@as(?u32, null), parseIp4U32("999.1.1.1"));
    try std.testing.expectEqual(@as(?u32, null), parseIp4U32("01.2.3.4"));
    try std.testing.expectEqual(@as(?u32, null), parseIp4U32("1.2.3.4.5"));
}

test "reject non-canonical and malformed ip literals" {
    const a = Address{ .family = .ip4, .port = 0 };
    try std.testing.expectError(Error.InvalidAddress, a.parseIp("01.2.3.4"));
    try std.testing.expectError(Error.InvalidAddress, a.parseIp("1.2.3.4 "));
    try std.testing.expectError(Error.InvalidAddress, a.parseIp("999.1.1.1"));

    // Inputs that previously underflowed the compression-width calculation.
    try std.testing.expectError(Error.InvalidAddress, a.parseIp("1:2:3:4:5:6:7:8:9::"));
    try std.testing.expectError(Error.InvalidAddress, a.parseIp("1:2:3:4:5:6:7:8::"));
    try std.testing.expectError(Error.InvalidAddress, a.parseIp("1::2::3"));
    try std.testing.expectError(Error.InvalidAddress, a.parseIp("1:::2"));
    try std.testing.expectError(Error.InvalidAddress, a.parseIp("fe80::1%"));
}

test "parse embedded ipv4 ipv6 tails" {
    var buf: [64]u8 = undefined;
    const m = try addrAny.parseIp("::ffff:192.168.1.1");
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 168, 1, 1 }, &m.bytes);
    try std.testing.expectEqualStrings("::ffff:192.168.1.1", m.formatBuf(&buf));

    const plain = try addrAny.parseIp("::192.168.1.1");
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 192, 168, 1, 1 }, &plain.bytes);

    const full = try addrAny.parseIp("1:2:3:4:5:6:7.8.9.10");
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 10 }, &full.bytes);
}

test "parse full-form ipv6" {
    var buf: [64]u8 = undefined;
    const a = addrAny.parseIp("2001:0db8:0000:0000:0000:0000:0000:0001") catch unreachable;
    try std.testing.expectEqual(Family.ip6, a.family);
    try std.testing.expectEqualStrings("2001:db8::1", a.formatBuf(&buf));

    const str = try a.toString(std.testing.allocator);
    defer std.testing.allocator.free(str);
    try std.testing.expectEqualStrings("2001:db8::1", str);
}

test "parse compressed ipv6" {
    var buf: [64]u8 = undefined;
    const cases = [_][]const u8{
        "::",           "2001:db8::1",     "::1",
        "fe80::a%eth0", "1:2:3:4:5:6:7:8",
    };
    for (cases) |c| {
        const a = try addrAny.parseIp(c);
        try std.testing.expectEqual(Family.ip6, a.family);
        _ = a.formatBuf(&buf);
    }
}

test "ipv6 loopback roundtrip" {
    var buf: [64]u8 = undefined;
    const a = Address.loopback6(443);
    try std.testing.expectEqualStrings("::1", a.formatBuf(&buf));

    var portBuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("[::1]:443", a.formatWithPort(&portBuf));
}

test "v4 mapped ipv6" {
    var buf: [64]u8 = undefined;
    const a = addrAny.parseIp("::ffff:192.168.1.1") catch unreachable;
    try std.testing.expect(a.isV4Mapped());
    try std.testing.expectEqualStrings("::ffff:192.168.1.1", a.formatBuf(&buf));

    const asV4 = a.toV4MappedView().?;
    try std.testing.expectEqual(Family.ip4, asV4.family);
    try std.testing.expectEqualStrings("192.168.1.1", asV4.formatBuf(&buf));
}

test "ipv6 text follows RFC 5952 through the standard formatter" {
    var buf: [64]u8 = undefined;
    const cases = [_]struct { text: []const u8, want: []const u8 }{
        // Longest zero run is compressed.
        .{ .text = "2001:db8:0:0:0:0:0:1", .want = "2001:db8::1" },
        .{ .text = "2001:0db8:0000:0000:0000:0000:0000:0001", .want = "2001:db8::1" },
        // A single zero group is never compressed (RFC 5952 Section 4.2.2).
        .{ .text = "1:0:2:3:4:5:6:7", .want = "1:0:2:3:4:5:6:7" },
        // All-zero address.
        .{ .text = "::", .want = "::" },
        .{ .text = "0:0:0:0:0:0:0:0", .want = "::" },
        // Trailing zero run.
        .{ .text = "1:2:3:4:5:6:7:0", .want = "1:2:3:4:5:6:7:0" },
        // Lowercase hex output.
        .{ .text = "2001:DB8:ABCD:EF01:2345:6789:ABCD:EF01", .want = "2001:db8:abcd:ef01:2345:6789:abcd:ef01" },
    };
    for (cases) |c| {
        const a = try addrAny.parseIp(c.text);
        try std.testing.expectEqualStrings(c.want, a.formatBuf(&buf));
    }
}

test "host:port splitting" {
    const r1 = try Address.parse("127.0.0.1:8080", 80);
    try std.testing.expectEqualStrings("127.0.0.1", r1.addr);
    try std.testing.expectEqual(@as(u16, 8080), r1.port);

    const r2 = try Address.parse("[::1]:9000", 80);
    try std.testing.expectEqualStrings("::1", r2.addr);
    try std.testing.expectEqual(@as(u16, 9000), r2.port);

    const r3 = try Address.parse("example.com", 80);
    try std.testing.expectEqualStrings("example.com", r3.addr);
    try std.testing.expectEqual(@as(u16, 80), r3.port);

    const r4 = try Address.parse("[::1]", 443);
    try std.testing.expectEqualStrings("::1", r4.addr);
    try std.testing.expectEqual(@as(u16, 443), r4.port);
}
