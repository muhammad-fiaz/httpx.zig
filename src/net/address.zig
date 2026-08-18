//! Network Address Utilities for httpx.zig
//!
//! Provides network address handling including:
//!
//! - DNS hostname resolution
//! - IPv4 and IPv6 address parsing
//! - Host:port string parsing
//! - Address formatting

const std = @import("std");
const net = @import("compat.zig");
const Allocator = std.mem.Allocator;

pub const Address = net.Address;
pub const AddressList = net.AddressList;

/// Resolves a hostname to a network address.
pub fn resolve(allocator: Allocator, hostname: []const u8, port: u16) !net.Address {
    if (parseIp4(hostname)) |ip4| {
        return net.Address.initIp4(ip4, port);
    }

    if (parseIp6(hostname)) |ip6| {
        return net.Address.initIp6(ip6, port, 0, 0);
    }

    var list = try net.getAddressList(allocator, hostname, port);
    defer list.deinit();

    if (list.addrs.len == 0) {
        return error.DNSResolutionFailed;
    }

    return list.addrs[0];
}

/// Resolves a hostname to all candidate addresses. Caller must free the returned slice.
pub fn resolveAll(allocator: Allocator, hostname: []const u8, port: u16) ![]net.Address {
    if (parseIp4(hostname)) |ip4| {
        var addrs = try allocator.alloc(net.Address, 1);
        addrs[0] = net.Address.initIp4(ip4, port);
        return addrs;
    }

    if (parseIp6(hostname)) |ip6| {
        var addrs = try allocator.alloc(net.Address, 1);
        addrs[0] = net.Address.initIp6(ip6, port, 0, 0);
        return addrs;
    }

    var list = try net.getAddressList(allocator, hostname, port);
    defer list.deinit();

    if (list.addrs.len == 0) {
        return error.DNSResolutionFailed;
    }

    const addrs = try allocator.alloc(net.Address, list.addrs.len);
    @memcpy(addrs, list.addrs);
    return addrs;
}

/// Parses "host:port" and resolves to a concrete address.
pub fn parseAndResolve(allocator: Allocator, host_port: []const u8, default_port: u16) !net.Address {
    const parsed = try parseHostPort(host_port, default_port);
    return try resolve(allocator, parsed.host, parsed.port);
}

/// Parses an IPv4 address string (e.g., "192.168.1.1").
fn parseIp4(str: []const u8) ?[4]u8 {
    var result: [4]u8 = undefined;
    var octet_idx: usize = 0;
    var current_octet: u16 = 0;
    var digit_count: usize = 0;

    for (str) |c| {
        if (c == '.') {
            if (digit_count == 0 or octet_idx >= 3) return null;
            result[octet_idx] = @intCast(current_octet);
            octet_idx += 1;
            current_octet = 0;
            digit_count = 0;
        } else if (c >= '0' and c <= '9') {
            current_octet = current_octet * 10 + (c - '0');
            if (current_octet > 255) return null;
            digit_count += 1;
        } else {
            return null;
        }
    }

    if (digit_count == 0 or octet_idx != 3) return null;
    result[3] = @intCast(current_octet);
    return result;
}

/// Parses an IPv6 address string.
fn parseIp6(str: []const u8) ?[16]u8 {
    // Minimal IPv6 parser supporting RFC5952-style hex groups with optional "::" abbreviation.
    // Supports IPv4-mapped IPv6 addresses (e.g., ::ffff:192.168.1.1).
    // Zone IDs ("%eth0") are intentionally not supported.
    if (str.len < 2 or str.len > 45) return null;
    if (std.mem.indexOfScalar(u8, str, '%') != null) return null;

    // Address cannot start or end with a single ':'
    if ((str[0] == ':' and str.len > 1 and str[1] != ':') or
        (str.len >= 2 and str[str.len - 2] != ':' and str[str.len - 1] == ':'))
    {
        return null;
    }

    // Check for IPv4-mapped suffix (e.g., ::ffff:192.168.1.1 or 2001:db8::192.168.1.1)
    // Scan backwards for a ':' that is NOT part of '::' and where the rest is a valid IPv4.
    var ipv4_suffix: ?[4]u8 = null;
    var ipv4_start_idx: usize = str.len;
    var ipv4_consumed_abbrev: bool = false;
    var scan: usize = str.len;
    while (scan > 0) {
        scan -= 1;
        if (str[scan] == ':') {
            const is_double = scan > 0 and str[scan - 1] == ':';
            if (is_double) {
                // '::' found. Check if what follows could be an IPv4.
                if (scan + 1 < str.len and str[scan + 1] != ':') {
                    const after_double = str[scan + 1 ..];
                    if (parseIp4(after_double)) |ip4| {
                        ipv4_suffix = ip4;
                        ipv4_start_idx = scan;
                        ipv4_consumed_abbrev = true;
                        break;
                    }
                }
                break; // '::' at start or no IPv4 after it
            }
            const after = str[scan + 1 ..];
            if (parseIp4(after)) |ip4| {
                const before = str[0..scan];
                if (std.mem.indexOfScalar(u8, before, '.') == null) {
                    ipv4_suffix = ip4;
                    ipv4_start_idx = scan;
                    break;
                }
            }
        }
    }

    var groups: [8]u16 = std.mem.zeroes([8]u16);
    var group_count: usize = 0;
    var abbreviated_at: ?usize = null;

    var i: usize = 0;
    const end_idx = ipv4_start_idx;
    while (i < end_idx) {
        if (group_count >= 8) return null;

        // Handle abbreviation
        if (str[i] == ':') {
            if (i + 1 < end_idx and str[i + 1] == ':') {
                if (abbreviated_at != null) return null;
                abbreviated_at = group_count;
                i += 2;
                if (i >= end_idx) break;
                continue;
            }
            // single ':' separator
            i += 1;
            continue;
        }

        // Parse up to 4 hex digits
        var value: u16 = 0;
        var digits: usize = 0;
        while (i < end_idx) : (i += 1) {
            const c = str[i];
            if (c == ':') break;
            const d: u8 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return null,
            };
            value = (value << 4) | d;
            digits += 1;
            if (digits > 4) return null;
        }
        if (digits == 0) return null;

        groups[group_count] = value;
        group_count += 1;

        if (i < end_idx and str[i] == ':') {
            // Loop will handle separator/abbrev
        }
    }

    // If there's an IPv4 suffix, it occupies the last two 16-bit groups
    if (ipv4_suffix) |ip4| {
        if (group_count > 6) return null; // Not enough room for IPv4 suffix

        // If IPv4 detection consumed a '::' abbreviation, record where the abbreviation was
        if (ipv4_consumed_abbrev and abbreviated_at == null) {
            abbreviated_at = group_count;
        }

        groups[group_count] = @as(u16, ip4[0]) << 8 | ip4[1];
        group_count += 1;
        groups[group_count] = @as(u16, ip4[2]) << 8 | ip4[3];
        group_count += 1;
    }

    // Expand abbreviation to 8 groups if present
    if (group_count != 8) {
        const at = abbreviated_at orelse return null;
        const tail = if (group_count > at) group_count - at else 0;

        if (tail > 0) {
            // Move tail groups to the end
            var dst: isize = 7;
            var src: isize = @intCast(group_count - 1);
            var moved: usize = 0;
            while (moved < tail) : (moved += 1) {
                groups[@intCast(dst)] = groups[@intCast(src)];
                dst -= 1;
                src -= 1;
            }
            // Zero fill between at and the start of moved tail
            var z: usize = at;
            while (z <= @as(usize, @intCast(dst))) : (z += 1) {
                groups[z] = 0;
            }
        } else {
            // All zeros (e.g. "::")
            for (&groups) |*g| {
                g.* = 0;
            }
        }
    } else if (abbreviated_at != null) {
        // "::" with exactly 8 groups is not valid
        return null;
    }

    var out: [16]u8 = undefined;
    for (groups, 0..) |g, gi| {
        out[gi * 2] = @intCast(g >> 8);
        out[gi * 2 + 1] = @intCast(g & 0xff);
    }
    return out;
}

/// Parses a host:port string, returning the host and port separately.
pub fn parseHostPort(str: []const u8, default_port: u16) !struct { host: []const u8, port: u16 } {
    if (str.len > 0 and str[0] == '[') {
        if (std.mem.indexOf(u8, str, "]:")) |end| {
            const port_str = str[end + 2 ..];
            const port = try std.fmt.parseInt(u16, port_str, 10);
            return .{ .host = str[1..end], .port = port };
        } else if (str[str.len - 1] == ']') {
            return .{ .host = str[1 .. str.len - 1], .port = default_port };
        }
    }

    if (std.mem.lastIndexOf(u8, str, ":")) |colon| {
        const before_colon = str[0..colon];
        if (std.mem.indexOf(u8, before_colon, ":") != null) {
            return .{ .host = str, .port = default_port };
        }
        const port_str = str[colon + 1 ..];
        const port = try std.fmt.parseInt(u16, port_str, 10);
        return .{ .host = before_colon, .port = port };
    }

    return .{ .host = str, .port = default_port };
}

/// Formats a network address as a string.
pub fn formatAddress(addr: net.Address, allocator: Allocator) ![]u8 {
    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try addr.format(&writer);
    return try allocator.dupe(u8, writer.buffered());
}

/// Returns true if the string looks like an IP address (not a hostname).
pub fn isIpAddress(str: []const u8) bool {
    return parseIp4(str) != null or parseIp6(str) != null;
}

/// Returns true if the string looks like an IPv4 address.
pub fn isIp4Address(str: []const u8) bool {
    return parseIp4(str) != null;
}

/// Returns true if the string looks like an IPv6 address.
pub fn isIp6Address(str: []const u8) bool {
    return parseIp6(str) != null;
}

/// Returns true if the address is the IPv4 or IPv6 loopback (127.0.0.0/8 or ::1).
pub fn isLoopback(addr: net.Address) bool {
    if (addr.any.family == std.posix.AF.INET) {
        const bytes = std.mem.toBytes(addr.in.addr);
        return bytes[0] == 127; // 127.0.0.0/8
    } else if (addr.any.family == std.posix.AF.INET6) {
        // ::1 = all zeros except last byte is 1
        for (addr.in6.addr[0..15]) |b| {
            if (b != 0) return false;
        }
        return addr.in6.addr[15] == 1;
    }
    return false;
}

/// Returns true if the address is unspecified (0.0.0.0 or ::).
pub fn isUnspecified(addr: net.Address) bool {
    if (addr.any.family == std.posix.AF.INET) {
        return addr.in.addr == 0;
    } else if (addr.any.family == std.posix.AF.INET6) {
        for (addr.in6.addr) |b| {
            if (b != 0) return false;
        }
        return true;
    }
    return false;
}

/// Returns true if the address is a private/reserved IPv4 address.
/// Covers 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8.
pub fn isPrivate(addr: net.Address) bool {
    if (addr.any.family == std.posix.AF.INET) {
        const b = std.mem.toBytes(addr.in.addr);
        // 10.0.0.0/8
        if (b[0] == 10) return true;
        // 172.16.0.0/12
        if (b[0] == 172 and b[1] >= 16 and b[1] <= 31) return true;
        // 192.168.0.0/16
        if (b[0] == 192 and b[1] == 168) return true;
        // 127.0.0.0/8 (loopback)
        if (b[0] == 127) return true;
        return false;
    } else if (addr.any.family == std.posix.AF.INET6) {
        // Unique-local fc00::/7
        if ((addr.in6.addr[0] & 0xFE) == 0xFC) return true;
        // Loopback ::1
        if (isLoopback(addr)) return true;
        return false;
    }
    return false;
}

/// Returns true if the address is a link-local address.
/// IPv4: 169.254.0.0/16
/// IPv6: fe80::/10
pub fn isLinkLocal(addr: net.Address) bool {
    if (addr.any.family == std.posix.AF.INET) {
        const b = std.mem.toBytes(addr.in.addr);
        return b[0] == 169 and b[1] == 254;
    } else if (addr.any.family == std.posix.AF.INET6) {
        return addr.in6.addr[0] == 0xFE and (addr.in6.addr[1] & 0xC0) == 0x80;
    }
    return false;
}

/// Returns true if the address is a multicast address.
pub fn isMulticast(addr: net.Address) bool {
    if (addr.any.family == std.posix.AF.INET) {
        const b = std.mem.toBytes(addr.in.addr);
        return (b[0] & 0xF0) == 0xE0; // 224.0.0.0/4
    } else if (addr.any.family == std.posix.AF.INET6) {
        return addr.in6.addr[0] == 0xFF;
    }
    return false;
}

/// Returns true if the IPv4 address is in the 169.254.0.0/16 link-local range.
pub fn isIPv4LinkLocal(addr: net.Address) bool {
    if (addr.any.family == std.posix.AF.INET) {
        const b = std.mem.toBytes(addr.in.addr);
        return b[0] == 169 and b[1] == 254;
    }
    return false;
}

/// Returns true if the IPv6 address is a unique-local address (fc00::/7).
pub fn isUniqueLocal(addr: net.Address) bool {
    if (addr.any.family == std.posix.AF.INET6) {
        return (addr.in6.addr[0] & 0xFE) == 0xFC;
    }
    return false;
}

/// Returns true if the address is an IPv4-mapped IPv6 address (::ffff:x.x.x.x).
pub fn isIPv4Mapped(addr: net.Address) bool {
    if (addr.any.family == std.posix.AF.INET6) {
        for (addr.in6.addr[0..10]) |b| {
            if (b != 0) return false;
        }
        return addr.in6.addr[10] == 0xFF and addr.in6.addr[11] == 0xFF;
    }
    return false;
}

/// Returns true if the address is a public (non-private, non-reserved) IPv4 address.
/// Excludes private, link-local, multicast, loopback, benchmarking, CGNAT, documentation, and class E ranges.
pub fn isPublic(addr: net.Address) bool {
    if (addr.any.family == std.posix.AF.INET) {
        return !isPrivate(addr) and !isLinkLocal(addr) and !isMulticast(addr) and !isReserved(addr);
    } else if (addr.any.family == std.posix.AF.INET6) {
        return !isPrivate(addr) and !isLinkLocal(addr) and !isMulticast(addr) and
            !isIPv4Mapped(addr) and !isDocumentation(addr);
    }
    return false;
}

/// Returns true if the address is in the IPv4 benchmarking range 198.18.0.0/15.
pub fn isBenchmarking(addr: net.Address) bool {
    if (addr.any.family == std.posix.AF.INET) {
        const b = std.mem.toBytes(addr.in.addr);
        return b[0] == 198 and (b[1] == 18 or b[1] == 19);
    }
    return false;
}

/// Returns true if the address is in the IPv4 carrier-grade NAT range 100.64.0.0/10.
pub fn isCarrierGradeNat(addr: net.Address) bool {
    if (addr.any.family == std.posix.AF.INET) {
        const b = std.mem.toBytes(addr.in.addr);
        return b[0] == 100 and (b[1] & 0xC0) == 64;
    }
    return false;
}

/// Returns true if the address is a documentation/test address (RFC 5737 / RFC 3849).
/// IPv4: 192.0.2.0/24 (TEST-NET-1), 198.51.100.0/24 (TEST-NET-2), 203.0.113.0/24 (TEST-NET-3)
/// IPv6: 2001:db8::/32
pub fn isDocumentation(addr: net.Address) bool {
    if (addr.any.family == std.posix.AF.INET) {
        const b = std.mem.toBytes(addr.in.addr);
        // 192.0.2.0/24 (TEST-NET-1)
        if (b[0] == 192 and b[1] == 0 and b[2] == 2) return true;
        // 198.51.100.0/24 (TEST-NET-2)
        if (b[0] == 198 and b[1] == 51 and b[2] == 100) return true;
        // 203.0.113.0/24 (TEST-NET-3)
        if (b[0] == 203 and b[1] == 0 and b[2] == 113) return true;
        return false;
    } else if (addr.any.family == std.posix.AF.INET6) {
        // 2001:db8::/32
        return addr.in6.addr[0] == 0x20 and addr.in6.addr[1] == 0x01 and
            addr.in6.addr[2] == 0xdb and addr.in6.addr[3] == 0x88;
    }
    return false;
}

/// Returns true if the address is reserved (RFC 6890).
/// Covers benchmarking, documentation, carrier-grade NAT, and class-E (240.0.0.0/4).
pub fn isReserved(addr: net.Address) bool {
    if (addr.any.family == std.posix.AF.INET) {
        const b = std.mem.toBytes(addr.in.addr);
        // Class E (240.0.0.0/4) - reserved for future use
        if (b[0] >= 240) return true;
        return isBenchmarking(addr) or isDocumentation(addr) or isCarrierGradeNat(addr);
    } else if (addr.any.family == std.posix.AF.INET6) {
        return isDocumentation(addr);
    }
    return false;
}

test "parseHostPort basic" {
    const result = try parseHostPort("httpbun.com:8080", 80);
    try std.testing.expectEqualStrings("httpbun.com", result.host);
    try std.testing.expectEqual(@as(u16, 8080), result.port);
}

test "parseHostPort default port" {
    const result = try parseHostPort("httpbun.com", 443);
    try std.testing.expectEqualStrings("httpbun.com", result.host);
    try std.testing.expectEqual(@as(u16, 443), result.port);
}

test "parseHostPort IPv6" {
    const result = try parseHostPort("[::1]:8080", 80);
    try std.testing.expectEqualStrings("::1", result.host);
    try std.testing.expectEqual(@as(u16, 8080), result.port);
}

test "parseIp6 basic" {
    const ip = parseIp6("::1");
    try std.testing.expect(ip != null);
    try std.testing.expectEqual(@as(u8, 0), ip.?[0]);
    try std.testing.expectEqual(@as(u8, 1), ip.?[15]);
}

test "parseIp6 full" {
    const ip = parseIp6("2001:0db8:0000:0000:0000:0000:0000:0001");
    try std.testing.expect(ip != null);
    try std.testing.expectEqual(@as(u8, 0x20), ip.?[0]);
    try std.testing.expectEqual(@as(u8, 0x01), ip.?[1]);
    try std.testing.expectEqual(@as(u8, 0x00), ip.?[14]);
    try std.testing.expectEqual(@as(u8, 0x01), ip.?[15]);
}

test "parseIp4 valid" {
    const ip = parseIp4("192.168.1.1");
    try std.testing.expect(ip != null);
    try std.testing.expectEqual(@as(u8, 192), ip.?[0]);
    try std.testing.expectEqual(@as(u8, 168), ip.?[1]);
    try std.testing.expectEqual(@as(u8, 1), ip.?[2]);
    try std.testing.expectEqual(@as(u8, 1), ip.?[3]);
}

test "parseIp4 localhost" {
    const ip = parseIp4("127.0.0.1");
    try std.testing.expect(ip != null);
    try std.testing.expectEqual(@as(u8, 127), ip.?[0]);
}

test "parseIp4 invalid" {
    try std.testing.expect(parseIp4("httpbun.com") == null);
    try std.testing.expect(parseIp4("256.1.1.1") == null);
    try std.testing.expect(parseIp4("1.2.3") == null);
}

test "isIpAddress" {
    try std.testing.expect(isIpAddress("192.168.1.1"));
    try std.testing.expect(!isIpAddress("httpbun.com"));
}

test "parseIp6 ipv4-mapped" {
    const ip = parseIp6("::ffff:192.168.1.1");
    try std.testing.expect(ip != null);
    // ::ffff:192.168.1.1 = 00 00 00 00 00 00 00 00 00 00 ff ff c0 a8 01 01
    try std.testing.expectEqual(@as(u8, 0xff), ip.?[10]);
    try std.testing.expectEqual(@as(u8, 0xff), ip.?[11]);
    try std.testing.expectEqual(@as(u8, 192), ip.?[12]);
    try std.testing.expectEqual(@as(u8, 168), ip.?[13]);
    try std.testing.expectEqual(@as(u8, 1), ip.?[14]);
    try std.testing.expectEqual(@as(u8, 1), ip.?[15]);
}

test "parseIp6 ipv4-compatible" {
    const ip = parseIp6("::192.168.1.1");
    try std.testing.expect(ip != null);
    try std.testing.expectEqual(@as(u8, 192), ip.?[12]);
    try std.testing.expectEqual(@as(u8, 168), ip.?[13]);
}

test "parseIp6 full 8 groups" {
    const ip = parseIp6("0:0:0:0:0:0:0:0");
    try std.testing.expect(ip != null);
    for (ip.?) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }
}

test "parseHostPort unbracketed ipv6" {
    // ::1 without brackets should return whole string as host with default port
    const result = try parseHostPort("::1", 8080);
    try std.testing.expectEqualStrings("::1", result.host);
    try std.testing.expectEqual(@as(u16, 8080), result.port);
}

test "isLoopback" {
    const loopback4 = net.Address.initIp4(.{ 127, 0, 0, 1 }, 80);
    const loopback6 = net.Address.initIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    const not_loopback = net.Address.initIp4(.{ 192, 168, 1, 1 }, 80);
    try std.testing.expect(isLoopback(loopback4));
    try std.testing.expect(isLoopback(loopback6));
    try std.testing.expect(!isLoopback(not_loopback));
}

test "isPrivate" {
    const ten = net.Address.initIp4(.{ 10, 0, 0, 1 }, 80);
    const seventeen = net.Address.initIp4(.{ 172, 16, 0, 1 }, 80);
    const nineteen = net.Address.initIp4(.{ 192, 168, 1, 1 }, 80);
    const public_ip = net.Address.initIp4(.{ 8, 8, 8, 8 }, 80);
    try std.testing.expect(isPrivate(ten));
    try std.testing.expect(isPrivate(seventeen));
    try std.testing.expect(isPrivate(nineteen));
    try std.testing.expect(!isPrivate(public_ip));
}

test "isLinkLocal" {
    const link_local = net.Address.initIp4(.{ 169, 254, 1, 1 }, 80);
    const not_link_local = net.Address.initIp4(.{ 192, 168, 1, 1 }, 80);
    try std.testing.expect(isLinkLocal(link_local));
    try std.testing.expect(!isLinkLocal(not_link_local));
}

test "isMulticast" {
    const multicast = net.Address.initIp4(.{ 224, 0, 0, 1 }, 80);
    const not_multicast = net.Address.initIp4(.{ 192, 168, 1, 1 }, 80);
    try std.testing.expect(isMulticast(multicast));
    try std.testing.expect(!isMulticast(not_multicast));
}

test "isUnspecified" {
    const unspec4 = net.Address.initIp4(.{ 0, 0, 0, 0 }, 80);
    const unspec6 = net.Address.initIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 80, 0, 0);
    const specified = net.Address.initIp4(.{ 127, 0, 0, 1 }, 80);
    try std.testing.expect(isUnspecified(unspec4));
    try std.testing.expect(isUnspecified(unspec6));
    try std.testing.expect(!isUnspecified(specified));
}

test "isPublic" {
    const public_ip = net.Address.initIp4(.{ 8, 8, 8, 8 }, 80);
    const private_ip = net.Address.initIp4(.{ 192, 168, 1, 1 }, 80);
    const loopback_ip = net.Address.initIp4(.{ 127, 0, 0, 1 }, 80);
    try std.testing.expect(isPublic(public_ip));
    try std.testing.expect(!isPublic(private_ip));
    try std.testing.expect(!isPublic(loopback_ip));
}

test "isUniqueLocal" {
    const ula = net.Address.initIp6(.{ 0xFC, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    const global = net.Address.initIp6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    try std.testing.expect(isUniqueLocal(ula));
    try std.testing.expect(!isUniqueLocal(global));
}

test "isIPv4Mapped" {
    const mapped = net.Address.initIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 192, 168, 1, 1 }, 80, 0, 0);
    const global = net.Address.initIp6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    try std.testing.expect(isIPv4Mapped(mapped));
    try std.testing.expect(!isIPv4Mapped(global));
}

test "isCarrierGradeNat" {
    const cgn = net.Address.initIp4(.{ 100, 64, 0, 1 }, 80);
    const not_cgn = net.Address.initIp4(.{ 100, 128, 0, 1 }, 80);
    try std.testing.expect(isCarrierGradeNat(cgn));
    try std.testing.expect(!isCarrierGradeNat(not_cgn));
}

test "isDocumentation" {
    // TEST-NET-1: 192.0.2.0/24
    const test_net1 = net.Address.initIp4(.{ 192, 0, 2, 1 }, 80);
    try std.testing.expect(isDocumentation(test_net1));

    // TEST-NET-2: 198.51.100.0/24
    const test_net2 = net.Address.initIp4(.{ 198, 51, 100, 1 }, 80);
    try std.testing.expect(isDocumentation(test_net2));

    // TEST-NET-3: 203.0.113.0/24
    const test_net3 = net.Address.initIp4(.{ 203, 0, 113, 1 }, 80);
    try std.testing.expect(isDocumentation(test_net3));

    // IPv6 documentation: 2001:db8::/32
    const doc6 = net.Address.initIp6(.{ 0x20, 0x01, 0xdb, 0x88, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    try std.testing.expect(isDocumentation(doc6));

    // Not documentation
    const public_ip = net.Address.initIp4(.{ 8, 8, 8, 8 }, 80);
    try std.testing.expect(!isDocumentation(public_ip));
}

test "isReserved" {
    // Class E: 240.0.0.0/4
    const class_e = net.Address.initIp4(.{ 240, 0, 0, 1 }, 80);
    try std.testing.expect(isReserved(class_e));

    // Benchmarking
    const bench = net.Address.initIp4(.{ 198, 18, 0, 1 }, 80);
    try std.testing.expect(isReserved(bench));

    // Documentation
    const doc = net.Address.initIp4(.{ 192, 0, 2, 1 }, 80);
    try std.testing.expect(isReserved(doc));

    // CGNAT
    const cgn = net.Address.initIp4(.{ 100, 64, 0, 1 }, 80);
    try std.testing.expect(isReserved(cgn));

    // Not reserved
    const public_ip = net.Address.initIp4(.{ 8, 8, 8, 8 }, 80);
    try std.testing.expect(!isReserved(public_ip));
}

test "isPublic excludes benchmarking and CGNAT" {
    // Benchmarking range should NOT be public
    const bench = net.Address.initIp4(.{ 198, 18, 0, 1 }, 80);
    try std.testing.expect(!isPublic(bench));

    // CGNAT range should NOT be public
    const cgn = net.Address.initIp4(.{ 100, 64, 0, 1 }, 80);
    try std.testing.expect(!isPublic(cgn));

    // Documentation should NOT be public
    const doc = net.Address.initIp4(.{ 192, 0, 2, 1 }, 80);
    try std.testing.expect(!isPublic(doc));

    // Class E should NOT be public
    const class_e = net.Address.initIp4(.{ 255, 255, 255, 255 }, 80);
    try std.testing.expect(!isPublic(class_e));

    // Actual public IP should be public
    const public_ip = net.Address.initIp4(.{ 8, 8, 8, 8 }, 80);
    try std.testing.expect(isPublic(public_ip));

    // Cloudflare DNS should be public
    const cf = net.Address.initIp4(.{ 1, 1, 1, 1 }, 80);
    try std.testing.expect(isPublic(cf));
}

test "isLoopback IPv6" {
    const loopback6 = net.Address.initIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    const not_loopback6 = net.Address.initIp6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    try std.testing.expect(isLoopback(loopback6));
    try std.testing.expect(!isLoopback(not_loopback6));
}

test "isLinkLocal IPv6" {
    const link_local6 = net.Address.initIp6(.{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    const not_link_local6 = net.Address.initIp6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    try std.testing.expect(isLinkLocal(link_local6));
    try std.testing.expect(!isLinkLocal(not_link_local6));
}

test "isMulticast IPv6" {
    const multicast6 = net.Address.initIp6(.{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    const not_multicast6 = net.Address.initIp6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    try std.testing.expect(isMulticast(multicast6));
    try std.testing.expect(!isMulticast(not_multicast6));
}

test "isPrivate IPv6" {
    const ula = net.Address.initIp6(.{ 0xfc, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    const loopback6 = net.Address.initIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    const global6 = net.Address.initIp6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    try std.testing.expect(isPrivate(ula));
    try std.testing.expect(isPrivate(loopback6));
    try std.testing.expect(!isPrivate(global6));
}

test "isPublic IPv6" {
    const global6 = net.Address.initIp6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    const ula = net.Address.initIp6(.{ 0xfc, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    const mapped = net.Address.initIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 192, 168, 1, 1 }, 80, 0, 0);
    const doc6 = net.Address.initIp6(.{ 0x20, 0x01, 0xdb, 0x88, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    try std.testing.expect(isPublic(global6));
    try std.testing.expect(!isPublic(ula));
    try std.testing.expect(!isPublic(mapped));
    try std.testing.expect(!isPublic(doc6));
}

test "isIp4Address and isIp6Address" {
    try std.testing.expect(isIp4Address("192.168.1.1"));
    try std.testing.expect(!isIp4Address("::1"));
    try std.testing.expect(!isIp4Address("not-an-ip"));

    try std.testing.expect(isIp6Address("::1"));
    try std.testing.expect(isIp6Address("2001:db8::1"));
    try std.testing.expect(!isIp6Address("192.168.1.1"));
    try std.testing.expect(!isIp6Address("not-an-ip"));
}

test "formatAddress produces valid output" {
    const addr4 = net.Address.initIp4(.{ 192, 168, 1, 1 }, 8080);
    const str4 = try formatAddress(addr4, std.testing.allocator);
    defer std.testing.allocator.free(str4);
    try std.testing.expect(str4.len > 0);
    // Should contain the IP
    try std.testing.expect(str4.len >= 7); // minimum "x.x.x.x"

    const addr6 = net.Address.initIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 8080, 0, 0);
    const str6 = try formatAddress(addr6, std.testing.allocator);
    defer std.testing.allocator.free(str6);
    try std.testing.expect(str6.len > 0);
}

test "parseIp4 edge cases" {
    // Zero address
    const zero = parseIp4("0.0.0.0");
    try std.testing.expect(zero != null);
    try std.testing.expectEqual(@as(u8, 0), zero.?[0]);

    // Max address
    const max = parseIp4("255.255.255.255");
    try std.testing.expect(max != null);
    try std.testing.expectEqual(@as(u8, 255), max.?[3]);

    // Empty string
    try std.testing.expect(parseIp4("") == null);

    // Too many octets
    try std.testing.expect(parseIp4("1.2.3.4.5") == null);

    // Non-numeric
    try std.testing.expect(parseIp4("abc.def.ghi.jkl") == null);
}

test "parseIp6 edge cases" {
    // Double colon alone
    const all_zeros = parseIp6("::");
    try std.testing.expect(all_zeros != null);

    // Trailing double-colon
    const trailing = parseIp6("2001:db8::");
    try std.testing.expect(trailing != null);

    // Triple colon parses as :: followed by :separator (accepted by parser)
    const triple_colon = parseIp6(":::1");
    try std.testing.expect(triple_colon != null);
    // Should be equivalent to ::1 (loopback)
    try std.testing.expectEqual(@as(u8, 0), triple_colon.?[0]);
    try std.testing.expectEqual(@as(u8, 1), triple_colon.?[15]);

    // Too many groups
    try std.testing.expect(parseIp6("1:2:3:4:5:6:7:8:9") == null);

    // fe80::1
    const link_local = parseIp6("fe80::1");
    try std.testing.expect(link_local != null);
    try std.testing.expectEqual(@as(u8, 0xfe), link_local.?[0]);
    try std.testing.expectEqual(@as(u8, 0x80), link_local.?[1]);
}

pub const SsrfPolicy = enum {
    none,
    block_loopback,
    block_private,
    block_all_internal,
    custom,
};

pub const IpRange = struct {
    base: [16]u8,
    prefix_len: u7,
    is_v4: bool,
};

pub const SsrfConfig = struct {
    policy: SsrfPolicy = .none,
    allow_localhost: bool = false,
    allow_private: bool = false,
    allow_link_local: bool = false,
    allow_cloud_metadata: bool = false,
    custom_blocked_ranges: []const IpRange = &.{},
};

pub const AddressClass = struct {
    is_loopback: bool = false,
    is_private: bool = false,
    is_link_local: bool = false,
    is_multicast: bool = false,
    is_unspecified: bool = false,
    is_cloud_metadata: bool = false,
    is_reserved: bool = false,
};

fn isCloudMetadata(addr: net.Address) bool {
    if (addr.any.family == std.posix.AF.INET) {
        const b = std.mem.toBytes(addr.in.addr);
        return b[0] == 169 and b[1] == 254 and b[2] == 169 and b[3] == 254;
    }
    return false;
}

fn ipRangeCovers(addr: net.Address, range: IpRange) bool {
    if (range.is_v4 and addr.any.family == std.posix.AF.INET) {
        const b = std.mem.toBytes(addr.in.addr);
        const prefix_bytes = range.prefix_len / 8;
        const prefix_bits = range.prefix_len % 8;
        var i: usize = 0;
        while (i < prefix_bytes) : (i += 1) {
            if (b[i] != range.base[i]) return false;
        }
        if (prefix_bits > 0 and prefix_bytes < 4) {
            const mask: u8 = @as(u8, 0xFF) << @intCast(8 - prefix_bits);
            if ((b[prefix_bytes] & mask) != (range.base[prefix_bytes] & mask)) return false;
        }
        return true;
    } else if (!range.is_v4 and addr.any.family == std.posix.AF.INET6) {
        const prefix_bytes = range.prefix_len / 8;
        const prefix_bits = range.prefix_len % 8;
        var i: usize = 0;
        while (i < prefix_bytes and i < 16) : (i += 1) {
            if (addr.in6.addr[i] != range.base[i]) return false;
        }
        if (prefix_bits > 0 and prefix_bytes < 16) {
            const mask: u8 = @as(u8, 0xFF) << @intCast(8 - prefix_bits);
            if ((addr.in6.addr[prefix_bytes] & mask) != (range.base[prefix_bytes] & mask)) return false;
        }
        return true;
    }
    return false;
}

pub fn classifyAddress(addr: net.Address) AddressClass {
    return .{
        .is_loopback = isLoopback(addr),
        .is_private = isPrivate(addr),
        .is_link_local = isLinkLocal(addr),
        .is_multicast = isMulticast(addr),
        .is_unspecified = isUnspecified(addr),
        .is_cloud_metadata = isCloudMetadata(addr),
        .is_reserved = isReserved(addr),
    };
}

pub fn isSsrfSafe(addr: Address, config: SsrfConfig) bool {
    const cls = classifyAddress(addr);

    if (config.policy == .none) return true;

    if (cls.is_loopback and !config.allow_localhost) {
        if (config.policy == .block_loopback or
            config.policy == .block_private or
            config.policy == .block_all_internal)
        {
            return false;
        }
    }

    if (cls.is_private and !config.allow_private) {
        if (config.policy == .block_private or config.policy == .block_all_internal) {
            return false;
        }
    }

    if (cls.is_link_local and !config.allow_link_local) {
        if (config.policy == .block_all_internal) return false;
    }

    if (cls.is_cloud_metadata and !config.allow_cloud_metadata) {
        if (config.policy == .block_all_internal) return false;
    }

    if (cls.is_multicast) return false;
    if (cls.is_unspecified) return false;

    if (config.policy == .custom) {
        for (config.custom_blocked_ranges) |range| {
            if (ipRangeCovers(addr, range)) return false;
        }
    }

    return true;
}

test "classifyAddress IPv4" {
    const loopback = net.Address.initIp4(.{ 127, 0, 0, 1 }, 80);
    const cls = classifyAddress(loopback);
    try std.testing.expect(cls.is_loopback);
    try std.testing.expect(cls.is_private);
    try std.testing.expect(!cls.is_link_local);
    try std.testing.expect(!cls.is_multicast);
    try std.testing.expect(!cls.is_unspecified);
    try std.testing.expect(!cls.is_cloud_metadata);
}

test "classifyAddress private" {
    const ten = net.Address.initIp4(.{ 10, 0, 0, 1 }, 80);
    const cls = classifyAddress(ten);
    try std.testing.expect(cls.is_private);
    try std.testing.expect(!cls.is_loopback);
}

test "classifyAddress link-local" {
    const ll = net.Address.initIp4(.{ 169, 254, 1, 1 }, 80);
    const cls = classifyAddress(ll);
    try std.testing.expect(cls.is_link_local);
}

test "classifyAddress multicast" {
    const mc = net.Address.initIp4(.{ 224, 0, 0, 1 }, 80);
    const cls = classifyAddress(mc);
    try std.testing.expect(cls.is_multicast);
}

test "classifyAddress unspecified" {
    const unspec = net.Address.initIp4(.{ 0, 0, 0, 0 }, 80);
    const cls = classifyAddress(unspec);
    try std.testing.expect(cls.is_unspecified);
}

test "classifyAddress cloud metadata" {
    const md = net.Address.initIp4(.{ 169, 254, 169, 254 }, 80);
    const cls = classifyAddress(md);
    try std.testing.expect(cls.is_cloud_metadata);
    try std.testing.expect(cls.is_link_local);
}

test "classifyAddress public" {
    const pub_ip = net.Address.initIp4(.{ 8, 8, 8, 8 }, 80);
    const cls = classifyAddress(pub_ip);
    try std.testing.expect(!cls.is_loopback);
    try std.testing.expect(!cls.is_private);
    try std.testing.expect(!cls.is_link_local);
    try std.testing.expect(!cls.is_multicast);
    try std.testing.expect(!cls.is_unspecified);
    try std.testing.expect(!cls.is_cloud_metadata);
}

test "classifyAddress IPv6 loopback" {
    const loopback6 = net.Address.initIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    const cls = classifyAddress(loopback6);
    try std.testing.expect(cls.is_loopback);
}

test "classifyAddress IPv6 ULA" {
    const ula = net.Address.initIp6(.{ 0xfc, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    const cls = classifyAddress(ula);
    try std.testing.expect(cls.is_private);
}

test "classifyAddress IPv6 link-local" {
    const ll6 = net.Address.initIp6(.{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    const cls = classifyAddress(ll6);
    try std.testing.expect(cls.is_link_local);
}

test "classifyAddress IPv6 multicast" {
    const mc6 = net.Address.initIp6(.{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    const cls = classifyAddress(mc6);
    try std.testing.expect(cls.is_multicast);
}

test "isSsrfSafe none policy allows everything" {
    const config = SsrfConfig{ .policy = .none };
    const loopback = net.Address.initIp4(.{ 127, 0, 0, 1 }, 80);
    try std.testing.expect(isSsrfSafe(loopback, config));
}

test "isSsrfSafe block_loopback" {
    const config = SsrfConfig{ .policy = .block_loopback };
    const loopback = net.Address.initIp4(.{ 127, 0, 0, 1 }, 80);
    const pub_ip = net.Address.initIp4(.{ 8, 8, 8, 8 }, 80);
    try std.testing.expect(!isSsrfSafe(loopback, config));
    try std.testing.expect(isSsrfSafe(pub_ip, config));
}

test "isSsrfSafe block_loopback allows localhost override" {
    const config = SsrfConfig{ .policy = .block_loopback, .allow_localhost = true };
    const loopback = net.Address.initIp4(.{ 127, 0, 0, 1 }, 80);
    try std.testing.expect(isSsrfSafe(loopback, config));
}

test "isSsrfSafe block_private" {
    const config = SsrfConfig{ .policy = .block_private };
    const ten = net.Address.initIp4(.{ 10, 0, 0, 1 }, 80);
    const seventeen = net.Address.initIp4(.{ 172, 16, 0, 1 }, 80);
    const nineteen = net.Address.initIp4(.{ 192, 168, 1, 1 }, 80);
    const pub_ip = net.Address.initIp4(.{ 8, 8, 8, 8 }, 80);
    try std.testing.expect(!isSsrfSafe(ten, config));
    try std.testing.expect(!isSsrfSafe(seventeen, config));
    try std.testing.expect(!isSsrfSafe(nineteen, config));
    try std.testing.expect(isSsrfSafe(pub_ip, config));
}

test "isSsrfSafe block_private allows private override" {
    const config = SsrfConfig{ .policy = .block_private, .allow_private = true };
    const ten = net.Address.initIp4(.{ 10, 0, 0, 1 }, 80);
    try std.testing.expect(isSsrfSafe(ten, config));
}

test "isSsrfSafe block_all_internal" {
    const config = SsrfConfig{ .policy = .block_all_internal };
    const loopback = net.Address.initIp4(.{ 127, 0, 0, 1 }, 80);
    const ten = net.Address.initIp4(.{ 10, 0, 0, 1 }, 80);
    const ll = net.Address.initIp4(.{ 169, 254, 1, 1 }, 80);
    const md = net.Address.initIp4(.{ 169, 254, 169, 254 }, 80);
    const pub_ip = net.Address.initIp4(.{ 8, 8, 8, 8 }, 80);
    try std.testing.expect(!isSsrfSafe(loopback, config));
    try std.testing.expect(!isSsrfSafe(ten, config));
    try std.testing.expect(!isSsrfSafe(ll, config));
    try std.testing.expect(!isSsrfSafe(md, config));
    try std.testing.expect(isSsrfSafe(pub_ip, config));
}

test "isSsrfSafe block_all_internal allows overrides" {
    const config = SsrfConfig{
        .policy = .block_all_internal,
        .allow_localhost = true,
        .allow_private = true,
        .allow_link_local = true,
        .allow_cloud_metadata = true,
    };
    const loopback = net.Address.initIp4(.{ 127, 0, 0, 1 }, 80);
    const ten = net.Address.initIp4(.{ 10, 0, 0, 1 }, 80);
    const ll = net.Address.initIp4(.{ 169, 254, 1, 1 }, 80);
    const md = net.Address.initIp4(.{ 169, 254, 169, 254 }, 80);
    try std.testing.expect(isSsrfSafe(loopback, config));
    try std.testing.expect(isSsrfSafe(ten, config));
    try std.testing.expect(isSsrfSafe(ll, config));
    try std.testing.expect(isSsrfSafe(md, config));
}

test "isSsrfSafe always blocks multicast" {
    const config = SsrfConfig{ .policy = .block_loopback };
    const mc = net.Address.initIp4(.{ 224, 0, 0, 1 }, 80);
    try std.testing.expect(!isSsrfSafe(mc, config));
}

test "isSsrfSafe always blocks unspecified" {
    const config = SsrfConfig{ .policy = .block_loopback };
    const unspec = net.Address.initIp4(.{ 0, 0, 0, 0 }, 80);
    try std.testing.expect(!isSsrfSafe(unspec, config));
}

test "isSsrfSafe custom policy with blocked range" {
    var blocked = [_]IpRange{IpRange{
        .base = .{ 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .prefix_len = 8,
        .is_v4 = true,
    }};
    const config = SsrfConfig{
        .policy = .custom,
        .custom_blocked_ranges = &blocked,
    };
    const ten = net.Address.initIp4(.{ 10, 0, 0, 1 }, 80);
    const pub_ip = net.Address.initIp4(.{ 8, 8, 8, 8 }, 80);
    try std.testing.expect(!isSsrfSafe(ten, config));
    try std.testing.expect(isSsrfSafe(pub_ip, config));
}

test "isSsrfSafe custom policy empty ranges allows everything" {
    const config = SsrfConfig{
        .policy = .custom,
        .custom_blocked_ranges = &.{},
    };
    const ten = net.Address.initIp4(.{ 10, 0, 0, 1 }, 80);
    try std.testing.expect(isSsrfSafe(ten, config));
}

test "isSsrfSafe IPv6 loopback block_loopback" {
    const config = SsrfConfig{ .policy = .block_loopback };
    const loopback6 = net.Address.initIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    const global6 = net.Address.initIp6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    try std.testing.expect(!isSsrfSafe(loopback6, config));
    try std.testing.expect(isSsrfSafe(global6, config));
}

test "isSsrfSafe IPv6 ULA block_private" {
    const config = SsrfConfig{ .policy = .block_private };
    const ula = net.Address.initIp6(.{ 0xfc, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    const global6 = net.Address.initIp6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    try std.testing.expect(!isSsrfSafe(ula, config));
    try std.testing.expect(isSsrfSafe(global6, config));
}

test "isSsrfSafe IPv6 link-local block_all_internal" {
    const config = SsrfConfig{ .policy = .block_all_internal };
    const ll6 = net.Address.initIp6(.{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    const global6 = net.Address.initIp6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    try std.testing.expect(!isSsrfSafe(ll6, config));
    try std.testing.expect(isSsrfSafe(global6, config));
}

test "isSsrfSafe IPv6 multicast always blocked" {
    const config = SsrfConfig{ .policy = .block_loopback };
    const mc6 = net.Address.initIp6(.{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    try std.testing.expect(!isSsrfSafe(mc6, config));
}

test "ipRangeCovers IPv4 exact match" {
    const range = IpRange{
        .base = .{ 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .prefix_len = 8,
        .is_v4 = true,
    };
    const ten = net.Address.initIp4(.{ 10, 0, 0, 1 }, 80);
    const pub_ip = net.Address.initIp4(.{ 8, 8, 8, 8 }, 80);
    try std.testing.expect(ipRangeCovers(ten, range));
    try std.testing.expect(!ipRangeCovers(pub_ip, range));
}

test "ipRangeCovers IPv4 /16" {
    const range = IpRange{
        .base = .{ 192, 168, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .prefix_len = 16,
        .is_v4 = true,
    };
    const in_range = net.Address.initIp4(.{ 192, 168, 1, 1 }, 80);
    const out_range = net.Address.initIp4(.{ 192, 169, 1, 1 }, 80);
    try std.testing.expect(ipRangeCovers(in_range, range));
    try std.testing.expect(!ipRangeCovers(out_range, range));
}

test "ipRangeCovers IPv4 /24" {
    const range = IpRange{
        .base = .{ 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .prefix_len = 24,
        .is_v4 = true,
    };
    const exact = net.Address.initIp4(.{ 10, 0, 0, 255 }, 80);
    const diff_subnet = net.Address.initIp4(.{ 10, 0, 1, 1 }, 80);
    try std.testing.expect(ipRangeCovers(exact, range));
    try std.testing.expect(!ipRangeCovers(diff_subnet, range));
}

test "ipRangeCovers IPv6 /32" {
    const range = IpRange{
        .base = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .prefix_len = 32,
        .is_v4 = false,
    };
    const in_range = net.Address.initIp6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    const out_range = net.Address.initIp6(.{ 0x20, 0x01, 0x0d, 0xb9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    try std.testing.expect(ipRangeCovers(in_range, range));
    try std.testing.expect(!ipRangeCovers(out_range, range));
}

test "ipRangeCovers mismatched family returns false" {
    const ipv4_range = IpRange{
        .base = .{ 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .prefix_len = 8,
        .is_v4 = true,
    };
    const ipv6_addr = net.Address.initIp6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0);
    try std.testing.expect(!ipRangeCovers(ipv6_addr, ipv4_range));
}
