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

pub const Error = error{ InvalidAddress, InvalidPort, BufferTooSmall };

pub const Family = enum { ip4, ip6 };

pub const Address = struct {
    family: Family,
    /// Big-endian address bytes (4 for ip4, 16 for ip6).
    bytes: [16]u8 = [_]u8{0} ** 16,
    port: u16,
    /// IPv6 scope/zone id (interface index); 0 = none.
    zone: u32 = 0,

    pub fn loopback4(port: u16) Address {
        return .{ .family = .ip4, .port = port, .bytes = blk: {
            var b = [_]u8{0} ** 16;
            b[0..4].* = .{ 127, 0, 0, 1 };
            break :blk b;
        } };
    }

    pub fn loopback6(port: u16) Address {
        var a = Address{ .family = .ip6, .bytes = [_]u8{0} ** 16, .port = port };
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
    pub fn parse(text: []const u8, default_port: u16) Error!struct { addr: []const u8, port: u16 } {
        _ = default_port;
        // Bracketed IPv6 [::1]:8080
        if (text.len > 0 and text[0] == '[') {
            const close = std.mem.indexOfScalar(u8, text, ']') orelse return Error.InvalidAddress;
            const rest = text[close + 1 ..];
            if (rest.len == 0) {
                return .{ .addr = text[1..close], .port = 0 };
            }
            if (rest[0] != ':') return Error.InvalidAddress;
            const p = std.fmt.parseInt(u16, rest[1..], 10) catch return Error.InvalidPort;
            return .{ .addr = text[1..close], .port = p };
        }
        // Bare IPv4 host:port - count colons; >1 colon without brackets means raw v6
        var colons: usize = 0;
        for (text) |c| {
            if (c == ':') colons += 1;
        }
        if (colons == 1) {
            const colon = std.mem.indexOfScalar(u8, text, ':').?;
            const p = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return Error.InvalidPort;
            return .{ .addr = text[0..colon], .port = p };
        }
        // Raw host or unbracketed IPv6 without port
        return .{ .addr = text, .port = 0 };
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

    /// Formats into buf per RFC 5952. Returns formatted slice.
    pub fn format(self: *const Address, buf: []u8) []const u8 {
        switch (self.family) {
            .ip4 => return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
                self.bytes[0], self.bytes[1], self.bytes[2], self.bytes[3],
            }) catch buf[0..0],
            .ip6 => {
                // v4-mapped has its own canonical form
                if (self.isV4Mapped()) {
                    return std.fmt.bufPrint(buf, "::ffff:{d}.{d}.{d}.{d}", .{
                        self.bytes[12], self.bytes[13], self.bytes[14], self.bytes[15],
                    }) catch buf[0..0];
                }
                var groups: [8]u16 = undefined;
                for (0..8) |g| {
                    groups[g] = (@as(u16, self.bytes[g * 2]) << 8) | self.bytes[g * 2 + 1];
                }
                // Longest zero run >= 2 gets compressed (RFC 5952)
                var best_start: usize = 8;
                var best_len: usize = 0;
                var i: usize = 0;
                while (i < 8) {
                    if (groups[i] == 0) {
                        var j = i;
                        while (j < 8 and groups[j] == 0) j += 1;
                        if (j - i > best_len) {
                            best_len = j - i;
                            best_start = i;
                        }
                        i = j;
                    } else i += 1;
                }
                if (best_len < 2) best_start = 8;

                var pos: usize = 0;
                var gi: usize = 0;
                while (gi < 8) {
                    if (gi == best_start) {
                        if (pos < buf.len) { buf[pos] = ':'; pos += 1; }
                        if (pos < buf.len) { buf[pos] = ':'; pos += 1; }
                        gi += best_len;
                        continue;
                    }
                    if (std.fmt.bufPrint(buf[pos..], "{x}", .{groups[gi]})) |str| {
                        pos += str.len;
                    } else |_| break;
                    if (gi < 7 and gi + 1 != best_start) {
                        if (pos < buf.len) { buf[pos] = ':'; pos += 1; }
                    }
                    gi += 1;
                }
                return buf[0..pos];
            },
        }
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
                var out = Address{ .family = .ip4, .bytes = [_]u8{0} ** 16, .port = v.port };
                out.bytes[0..4].* = v.bytes;
                break :blk out;
            },
            .ip6 => |v| .{ .family = .ip6, .bytes = v.bytes, .port = v.port },
        };
    }
};

/// Parses dotted-quad IPv4 into 4 bytes.
pub fn parseIp4Bytes(text: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, text, '.');
    var i: usize = 0;
    while (it.next()) |part| {
        if (i >= 4) return null;
        if (part.len == 0 or part.len > 3) return null;
        var value: u16 = 0;
        for (part) |c| {
            if (c < '0' or c > '9') return null;
            value = value * 10 + (c - '0');
        }
        if (value > 255) return null;
        out[i] = @intCast(value);
        i += 1;
    }
    if (i != 4) return null;
    return out;
}

/// Parses full/compressed IPv6 with optional %zone suffix.
fn parseIp6Text(text_in: []const u8) Error!Address {
    var text = text_in;

    // Extract zone
    var zone: u32 = 0;
    if (std.mem.indexOfScalar(u8, text, '%')) |zidx| {
        const zname = text[zidx + 1 ..];
        text = text[0..zidx];
        // Numeric interface index or name (names resolve at socket layer)
        zone = std.fmt.parseInt(u32, zname, 10) catch 0;
    }

    // Handle embedded IPv4 tail "::ffff:1.2.3.4"
    var tail_v4: ?[4]u8 = null;
    if (std.mem.lastIndexOfScalar(u8, text, ':')) |last_colon| {
        const tail = text[last_colon + 1 ..];
        if (std.mem.indexOfScalar(u8, tail, '.') != null) {
            tail_v4 = parseIp4Bytes(tail) orelse return Error.InvalidAddress;
            text = text[0 .. last_colon + 1]; // keep trailing colon for compression math
        }
    }

    // Find "::" compression point
    const double_colon = std.mem.indexOf(u8, text, "::");
    var head_groups: [8]u16 = [_]u16{0} ** 8;
    var head_count: usize = 0;
    var tail_groups: [8]u16 = [_]u16{0} ** 8;
    var tail_count: usize = 0;

    var head_part: []const u8 = "";
    var tail_part: []const u8 = "";
    if (double_colon) |dc| {
        head_part = text[0..dc];
        tail_part = text[dc + 2 ..];
    } else {
        head_part = text;
    }

    var fit = std.mem.splitScalar(u8, head_part, ':');
    while (fit.next()) |g| {
        if (g.len == 0) continue;
        if (head_count >= 8) return Error.InvalidAddress;
        head_groups[head_count] = std.fmt.parseInt(u16, g, 16) catch return Error.InvalidAddress;
        head_count += 1;
    }

    if (double_colon != null) {
        var tit = std.mem.splitScalar(u8, tail_part, ':');
        while (tit.next()) |g| {
            if (g.len == 0) continue;
            if (tail_count >= 8) return Error.InvalidAddress;
            tail_groups[tail_count] = std.fmt.parseInt(u16, g, 16) catch return Error.InvalidAddress;
            tail_count += 1;
        }
    } else {
        // No compression: must have exactly 8 groups (or 6 + v4 tail)
        if (head_count != 8 and !(tail_v4 != null and head_count == 6)) return Error.InvalidAddress;
    }

    var out = Address{ .family = .ip6, .port = 0 };
    const total_from_text = head_count + tail_count;
    const v4_extra: usize = if (tail_v4 != null) 2 else 0;
    const zeros = 8 - total_from_text - v4_extra;
    if (zeros < 0 or total_from_text + v4_extra > 8) return Error.InvalidAddress;

    var pos: usize = 0;
    for (head_groups[0..head_count]) |g| {
        out.bytes[pos * 2] = @intCast(g >> 8);
        out.bytes[pos * 2 + 1] = @intCast(g & 0xFF);
        pos += 1;
    }
    for (0..@intCast(zeros)) |_| {
        pos += 1;
    }
    for (tail_groups[0..tail_count]) |g| {
        out.bytes[pos * 2] = @intCast(g >> 8);
        out.bytes[pos * 2 + 1] = @intCast(g & 0xFF);
        pos += 1;
    }
    if (tail_v4) |v4| {
        out.bytes[pos * 2] = v4[0];
        out.bytes[pos * 2 + 1] = v4[1];
        out.bytes[pos * 2 + 2] = v4[2];
        out.bytes[pos * 2 + 3] = v4[3];
    }
    out.zone = zone;
    return out;
}

// Tests

var addrAny = Address{ .family = .ip4, .port = 0 };

test "parse ipv4 dotted quad" {
    var buf: [64]u8 = undefined;
    const a = addrAny.parseIp("192.168.1.100") catch unreachable;
    try std.testing.expectEqual(Family.ip4, a.family);
    try std.testing.expectEqualSlices(u8, &.{ 192, 168, 1, 100 }, a.bytes[0..4]);
    try std.testing.expectEqualStrings("192.168.1.100", a.format(&buf));
}

test "reject malformed ipv4" {
    const a = Address{ .family = .ip4, .port = 0 };
    try std.testing.expectError(Error.InvalidAddress, a.parseIp("256.1.1.1"));
    try std.testing.expectError(Error.InvalidAddress, a.parseIp("1.2.3"));
    try std.testing.expectError(Error.InvalidAddress, a.parseIp("1.2.3.4.5"));
    try std.testing.expectError(Error.InvalidAddress, a.parseIp("a.b.c.d"));
    try std.testing.expectError(Error.InvalidAddress, a.parseIp(""));
}

test "parse full-form ipv6" {
    var buf: [64]u8 = undefined;
    const a = addrAny.parseIp("2001:0db8:0000:0000:0000:0000:0000:0001") catch unreachable;
    try std.testing.expectEqual(Family.ip6, a.family);
    try std.testing.expectEqualStrings("2001:db8::1", a.format(&buf));
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
        _ = a.format(&buf);
    }
}

test "ipv6 loopback roundtrip" {
    var buf: [64]u8 = undefined;
    const a = Address.loopback6(443);
    try std.testing.expectEqualStrings("::1", a.format(&buf));
}

test "v4 mapped ipv6" {
    var buf: [64]u8 = undefined;
    const a = addrAny.parseIp("::ffff:192.168.1.1") catch unreachable;
    try std.testing.expect(a.isV4Mapped());
    try std.testing.expectEqualStrings("::ffff:192.168.1.1", a.format(&buf));

    const as_v4 = a.toV4MappedView().?;
    try std.testing.expectEqual(Family.ip4, as_v4.family);
    try std.testing.expectEqualStrings("192.168.1.1", as_v4.format(&buf));
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
}
