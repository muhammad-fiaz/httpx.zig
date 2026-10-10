//! Authoritative shared parsing primitives for httpx.zig.
//!
//! Provides zero-copy bounded byte cursors, text scanners, fast numeric parsers,
//! case-insensitive ASCII routines, RFC-compliant URI/header token validators,
//! percent-decoding, authority/host parsing, parameter iterators, and HTTP date parsing.
//!
//! Designed for zero unnecessary allocations, bounded memory safety, and branch-minimized
//! hot paths targeting Zig 0.17.0.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// 1. ASCII & Character Classification Tables (Comptime O(1))
// ============================================================================

/// Lookup table for RFC 7230 / 9110 token characters:
/// tchar = "!" / "#" / "$" / "%" / "&" / "'" / "*" / "+" / "-" / "." /
///         "^" / "_" / "`" / "|" / "~" / DIGIT / ALPHA
pub const TOKEN_CHARS: [256]bool = blk: {
    var table: [256]bool = undefined;
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        const isAlpha = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
        const isDigit = (c >= '0' and c <= '9');
        const isSpecial = switch (c) {
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
            else => false,
        };
        table[i] = isAlpha or isDigit or isSpecial;
    }
    break :blk table;
};

/// Lookup table for RFC 3986 unreserved characters:
/// unreserved = ALPHA / DIGIT / "-" / "." / "_" / "~"
pub const UNRESERVED_CHARS: [256]bool = blk: {
    var table: [256]bool = undefined;
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        const isAlpha = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
        const isDigit = (c >= '0' and c <= '9');
        const isPunct = (c == '-' or c == '.' or c == '_' or c == '~');
        table[i] = isAlpha or isDigit or isPunct;
    }
    break :blk table;
};

/// Lookup table for hexadecimal nibble values.
/// Returns 0..15 for valid hex, or 0xFF for invalid.
pub const HEX_VALUES: [256]u8 = blk: {
    var table: [256]u8 = @splat(0xFF);
    for ('0'..('9' + 1)) |i| table[i] = @intCast(i - '0');
    for ('a'..('f' + 1)) |i| table[i] = @intCast(i - 'a' + 10);
    for ('A'..('F' + 1)) |i| table[i] = @intCast(i - 'A' + 10);
    break :blk table;
};

/// True if `c` is a valid RFC 7230/9110 token character.
pub inline fn isTokenChar(c: u8) bool {
    return TOKEN_CHARS[c];
}

/// True if `c` is an RFC 3986 unreserved character.
pub inline fn isUnreservedChar(c: u8) bool {
    return UNRESERVED_CHARS[c];
}

/// True if `c` is a control character (0x00..0x1F or 0x7F).
pub inline fn isCtl(c: u8) bool {
    return c <= 0x1F or c == 0x7F;
}

/// True if `c` is an HTTP space or horizontal tab (OWS).
pub inline fn isSpaceOrTab(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// True if `c` is a CR or LF line terminator.
pub inline fn isEol(c: u8) bool {
    return c == '\r' or c == '\n';
}

/// Converts a hex character to its 4-bit nibble value (0..15), or null if invalid.
pub inline fn hexNibble(c: u8) ?u4 {
    const val = HEX_VALUES[c];
    if (val <= 15) return @intCast(val);
    return null;
}

/// Fast case-insensitive equality check.
pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Fast case-insensitive prefix check.
pub fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(haystack, prefix);
}

/// Trims leading and trailing HTTP whitespace (spaces and tabs).
pub inline fn trimOws(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}

// ============================================================================
// 2. Numeric Parsing Primitives
// ============================================================================

/// Parses an unsigned integer from ASCII decimal digits without intermediate allocations
/// or error-handling overhead in the fast path.
pub fn parseUint(comptime T: type, s: []const u8) ?T {
    if (s.len == 0) return null;
    var result: T = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        const digit: T = @intCast(c - '0');
        result = std.math.mul(T, result, 10) catch return null;
        result = std.math.add(T, result, digit) catch return null;
    }
    return result;
}

/// Fast branchless parsing of an exact 3-digit ASCII HTTP status code (e.g. "200").
pub inline fn parse3DigitStatus(s: []const u8) ?u16 {
    if (s.len != 3) return null;
    const d0 = s[0];
    const d1 = s[1];
    const d2 = s[2];
    if (d0 < '1' or d0 > '9' or d1 < '0' or d1 > '9' or d2 < '0' or d2 > '9') return null;
    return (@as(u16, d0 - '0') * 100) + (@as(u16, d1 - '0') * 10) + @as(u16, d2 - '0');
}

/// Parses a port number (1..65535).
pub fn parsePort(s: []const u8) ?u16 {
    const p = parseUint(u32, s) orelse return null;
    if (p == 0 or p > 65535) return null;
    return @intCast(p);
}

/// Parses an unsigned integer from ASCII hexadecimal digits (e.g. HTTP chunk sizes).
pub fn parseHexUint(comptime T: type, s: []const u8) ?T {
    if (s.len == 0) return null;
    var result: T = 0;
    for (s) |c| {
        const nibble = hexNibble(c) orelse return null;
        result = std.math.mul(T, result, 16) catch return null;
        result = std.math.add(T, result, @as(T, nibble)) catch return null;
    }
    return result;
}

// ============================================================================
// 3. Fast Method Parsing
// ============================================================================

const Method = @import("method.zig").Method;

/// Fast, branch-minimized HTTP method lookup from wire/slice string.
pub const parseMethod = Method.fromString;

// ============================================================================
// 4. Authority / Host / Port Parser (Single Authoritative Implementation)
// ============================================================================

pub const ParsedAuthority = struct {
    /// Hostname, IPv4 string, or inner unbracketed IPv6 literal.
    host: []const u8,
    /// Explicit port if specified in the authority string.
    port: ?u16 = null,
    /// True when the host was wrapped in IPv6 brackets `[...]`.
    isIpv6: bool = false,
};

/// Parses an authority string ("host", "host:port", "[::1]", "[::1]:port").
/// Returns null if the syntax is malformed (unmatched brackets, invalid port digits, etc.).
pub fn parseAuthority(input: []const u8) ?ParsedAuthority {
    if (input.len == 0) return null;

    if (input[0] == '[') {
        const close = std.mem.indexOfScalar(u8, input, ']') orelse return null;
        if (close < 2) return null; // "[]" minimum invalid
        const inner = input[1..close];
        const after = input[close + 1 ..];
        if (after.len == 0) {
            return .{ .host = inner, .port = null, .isIpv6 = true };
        }
        if (after[0] != ':') return null;
        const portVal = parsePort(after[1..]) orelse return null;
        return .{ .host = inner, .port = portVal, .isIpv6 = true };
    }

    // Bare host or host:port
    if (std.mem.lastIndexOfScalar(u8, input, ':')) |colon| {
        // If there are multiple colons without brackets, this is an unbracketed IPv6 literal
        if (std.mem.indexOfScalar(u8, input[0..colon], ':') != null) {
            return .{ .host = input, .port = null, .isIpv6 = true };
        }
        const portVal = parsePort(input[colon + 1 ..]) orelse return null;
        return .{ .host = input[0..colon], .port = portVal, .isIpv6 = false };
    }

    return .{ .host = input, .port = null, .isIpv6 = false };
}

// ============================================================================
// 5. Zero-Copy Bounded Byte Cursor
// ============================================================================

pub const ByteCursor = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) ByteCursor {
        return .{ .data = data, .pos = 0 };
    }

    pub inline fn remaining(self: *const ByteCursor) usize {
        return self.data.len - self.pos;
    }

    pub inline fn isEof(self: *const ByteCursor) bool {
        return self.pos >= self.data.len;
    }

    pub inline fn peekByte(self: *const ByteCursor) ?u8 {
        if (self.pos >= self.data.len) return null;
        return self.data[self.pos];
    }

    pub inline fn readByte(self: *ByteCursor) ?u8 {
        if (self.pos >= self.data.len) return null;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    pub fn readBytes(self: *ByteCursor, n: usize) ?[]const u8 {
        if (self.pos + n > self.data.len) return null;
        const slice = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return slice;
    }

    pub fn readInt(self: *ByteCursor, comptime T: type, endian: std.builtin.Endian) ?T {
        const size = @sizeOf(T);
        const bytes = self.readBytes(size) orelse return null;
        return std.mem.readInt(T, bytes[0..size], endian);
    }

    pub fn readU24Big(self: *ByteCursor) ?u24 {
        const bytes = self.readBytes(3) orelse return null;
        return (@as(u24, bytes[0]) << 16) | (@as(u24, bytes[1]) << 8) | bytes[2];
    }

    pub fn skip(self: *ByteCursor, n: usize) bool {
        if (self.pos + n > self.data.len) return false;
        self.pos += n;
        return true;
    }

    pub fn seek(self: *ByteCursor, pos: usize) bool {
        if (pos > self.data.len) return false;
        self.pos = pos;
        return true;
    }

    pub fn sliceFrom(self: *const ByteCursor, start: usize) []const u8 {
        const end = @min(self.pos, self.data.len);
        if (start >= end) return "";
        return self.data[start..end];
    }
};

// ============================================================================
// 6. Delimited Token & Parameter Iterators
// ============================================================================

/// Iterates over comma-separated values in HTTP headers (RFC 9110 Section 5.6.1).
/// Strips leading and trailing OWS and skips empty entries.
pub const TokenListIterator = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) TokenListIterator {
        return .{ .data = data, .pos = 0 };
    }

    pub fn next(self: *TokenListIterator) ?[]const u8 {
        while (self.pos < self.data.len) {
            const start = self.pos;
            if (std.mem.indexOfScalarPos(u8, self.data, start, ',')) |comma| {
                self.pos = comma + 1;
                const token = trimOws(self.data[start..comma]);
                if (token.len > 0) return token;
            } else {
                self.pos = self.data.len;
                const token = trimOws(self.data[start..]);
                if (token.len > 0) return token;
            }
        }
        return null;
    }
};

/// Checks if a comma-separated header value contains a specific token case-insensitively.
pub fn hasToken(headerVal: []const u8, wanted: []const u8) bool {
    var it = TokenListIterator.init(headerVal);
    while (it.next()) |tok| {
        if (eqlIgnoreCase(tok, wanted)) return true;
    }
    return false;
}

/// A parsed parameter key/value pair.
pub const Param = struct {
    key: []const u8,
    value: []const u8,
};

/// Iterates over semicolon-separated parameters (e.g. `Cookie`, `Set-Cookie`,
/// `Content-Type`, `Content-Disposition`). Unquotes quoted values automatically.
pub const ParamIterator = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) ParamIterator {
        return .{ .data = data, .pos = 0 };
    }

    pub fn next(self: *ParamIterator) ?Param {
        while (self.pos < self.data.len) {
            const start = self.pos;
            var end = self.data.len;
            var inQuotes = false;

            var i = start;
            while (i < self.data.len) : (i += 1) {
                const c = self.data[i];
                if (c == '"') {
                    inQuotes = !inQuotes;
                } else if (c == ';' and !inQuotes) {
                    end = i;
                    break;
                }
            }

            self.pos = if (end < self.data.len) end + 1 else self.data.len;
            const part = trimOws(self.data[start..end]);
            if (part.len == 0) continue;

            if (std.mem.indexOfScalar(u8, part, '=')) |eq| {
                const k = trimOws(part[0..eq]);
                var v = trimOws(part[eq + 1 ..]);
                if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') {
                    v = v[1 .. v.len - 1];
                }
                return .{ .key = k, .value = v };
            } else {
                return .{ .key = part, .value = "" };
            }
        }
        return null;
    }
};

/// Iterates over `&`-separated query string key/value pairs.
pub const QueryIterator = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) QueryIterator {
        return .{ .data = data, .pos = 0 };
    }

    pub fn next(self: *QueryIterator) ?Param {
        while (self.pos < self.data.len) {
            const start = self.pos;
            const end = if (std.mem.indexOfScalarPos(u8, self.data, start, '&')) |amp| blk: {
                self.pos = amp + 1;
                break :blk amp;
            } else blk: {
                self.pos = self.data.len;
                break :blk self.data.len;
            };

            const part = self.data[start..end];
            if (part.len == 0) continue;

            if (std.mem.indexOfScalar(u8, part, '=')) |eq| {
                return .{ .key = part[0..eq], .value = part[eq + 1 ..] };
            } else {
                return .{ .key = part, .value = "" };
            }
        }
        return null;
    }
};

/// Looks up a query parameter by key in a raw query string without allocations.
pub fn lookupQuery(query: []const u8, name: []const u8) ?[]const u8 {
    var it = QueryIterator.init(query);
    while (it.next()) |p| {
        if (std.mem.eql(u8, p.key, name)) return p.value;
    }
    return null;
}

// ============================================================================
// 7. High-Performance Percent-Encoding and Percent-Decoding
// ============================================================================

pub const DecodeError = error{
    BufferTooSmall,
    InvalidEncoding,
};

/// Percent-decodes `input` into `buf`. Decoded length is always <= `input.len`.
/// Returns the decoded slice within `buf`.
pub fn percentDecode(buf: []u8, input: []const u8) DecodeError![]const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (out >= buf.len) return error.BufferTooSmall;
        const c = input[i];
        if (c == '%') {
            if (i + 2 >= input.len) {
                // Trailing incomplete '%' copied verbatim per lenient browser specs
                buf[out] = c;
                out += 1;
                i += 1;
                continue;
            }
            const hi = hexNibble(input[i + 1]);
            const lo = hexNibble(input[i + 2]);
            if (hi != null and lo != null) {
                buf[out] = (@as(u8, hi.?) << 4) | @as(u8, lo.?);
                out += 1;
                i += 3;
            } else {
                buf[out] = c;
                out += 1;
                i += 1;
            }
        } else {
            buf[out] = c;
            out += 1;
            i += 1;
        }
    }
    return buf[0..out];
}

/// Percent-decodes `buf` in-place without heap allocation.
pub fn percentDecodeInPlace(buf: []u8) []u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < buf.len) {
        const c = buf[i];
        if (c == '%' and i + 2 < buf.len) {
            const hi = hexNibble(buf[i + 1]);
            const lo = hexNibble(buf[i + 2]);
            if (hi != null and lo != null) {
                buf[out] = (@as(u8, hi.?) << 4) | @as(u8, lo.?);
                out += 1;
                i += 3;
                continue;
            }
        }
        buf[out] = c;
        out += 1;
        i += 1;
    }
    return buf[0..out];
}

/// Percent-encodes `input` into `buf` (keeps RFC 3986 unreserved characters).
pub fn percentEncode(buf: []u8, input: []const u8) error{BufferTooSmall}![]const u8 {
    const hexd = "0123456789ABCDEF";
    var out: usize = 0;
    for (input) |c| {
        if (isUnreservedChar(c)) {
            if (out >= buf.len) return error.BufferTooSmall;
            buf[out] = c;
            out += 1;
        } else {
            if (out + 3 > buf.len) return error.BufferTooSmall;
            buf[out] = '%';
            buf[out + 1] = hexd[c >> 4];
            buf[out + 2] = hexd[c & 0x0F];
            out += 3;
        }
    }
    return buf[0..out];
}

/// Calculates exact required encoded byte count for `input`.
pub fn encodedLength(input: []const u8) usize {
    var len: usize = 0;
    for (input) |c| {
        len += if (isUnreservedChar(c)) 1 else 3;
    }
    return len;
}

/// Percent-encodes `input` into an allocated slice in a single pass without redundant copies.
pub fn percentEncodeAlloc(allocator: Allocator, input: []const u8) Allocator.Error![]u8 {
    const totalLen = encodedLength(input);
    const out = try allocator.alloc(u8, totalLen);
    errdefer allocator.free(out);
    _ = percentEncode(out, input) catch unreachable;
    return out;
}

// ============================================================================
// 8. HTTP Date Parser (IMF-fixdate, RFC 9110 Section 5.6.7)
// ============================================================================

const monthNames = [_][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};

/// Parses an IMF-fixdate string (e.g. "Sun, 06 Nov 1994 08:49:37 GMT") to epoch seconds.
/// Returns null on invalid or malformed format.
pub fn parseHttpDate(s: []const u8) ?i64 {
    var it = std.mem.tokenizeAny(u8, s, " ,");
    _ = it.next() orelse return null; // Day of week
    const dayS = it.next() orelse return null;
    const monS = it.next() orelse return null;
    const yearS = it.next() orelse return null;
    const timeS = it.next() orelse return null;

    const day = parseUint(u16, dayS) orelse return null;
    var month: ?u4 = null;
    for (monthNames, 0..) |m, i| {
        if (startsWithIgnoreCase(monS, m)) {
            month = @intCast(i + 1);
            break;
        }
    }
    const mon = month orelse return null;
    const year = parseUint(i32, yearS) orelse return null;

    var tit = std.mem.splitScalar(u8, timeS, ':');
    const hh = parseUint(u8, tit.next() orelse return null) orelse return null;
    const mm = parseUint(u8, tit.next() orelse return null) orelse return null;
    const ss = parseUint(u8, tit.next() orelse return null) orelse return null;

    if (hh >= 24 or mm >= 60 or ss > 60 or day == 0 or day > daysInMonth(year, mon)) return null;

    const days = daysFromCivil(year, mon, day);
    return days * 86400 + @as(i64, hh) * 3600 + @as(i64, mm) * 60 + ss;
}

fn daysInMonth(year: i32, month: u4) u16 {
    return switch (month) {
        2 => if (@mod(year, 400) == 0 or (@mod(year, 4) == 0 and @mod(year, 100) != 0)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

fn daysFromCivil(yIn: i32, m: u4, d: u16) i64 {
    const y: i64 = if (m <= 2) yIn - 1 else yIn;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = @mod(@as(i64, m) + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

// ============================================================================
// Unit Tests for Parsing Primitives
// ============================================================================

test "isTokenChar matches RFC 7230" {
    try std.testing.expect(isTokenChar('a'));
    try std.testing.expect(isTokenChar('Z'));
    try std.testing.expect(isTokenChar('0'));
    try std.testing.expect(isTokenChar('-'));
    try std.testing.expect(isTokenChar('_'));
    try std.testing.expect(!isTokenChar(' '));
    try std.testing.expect(!isTokenChar(':'));
    try std.testing.expect(!isTokenChar('('));
    try std.testing.expect(!isTokenChar('\r'));
    try std.testing.expect(!isTokenChar(0));
}

test "parseUint and parse3DigitStatus" {
    try std.testing.expectEqual(@as(?u16, 200), parse3DigitStatus("200"));
    try std.testing.expectEqual(@as(?u16, 404), parse3DigitStatus("404"));
    try std.testing.expectEqual(@as(?u16, null), parse3DigitStatus("20a"));
    try std.testing.expectEqual(@as(?u16, null), parse3DigitStatus("20"));
    try std.testing.expectEqual(@as(?u32, 12345), parseUint(u32, "12345"));
    try std.testing.expectEqual(@as(?u16, 8080), parsePort("8080"));
    try std.testing.expectEqual(@as(?u16, null), parsePort("70000"));
    try std.testing.expectEqual(@as(?u64, 0x1A2B), parseHexUint(u64, "1A2B"));
}

test "parseMethod fast lookup" {
    try std.testing.expectEqual(Method.GET, parseMethod("GET").?);
    try std.testing.expectEqual(Method.POST, parseMethod("POST").?);
    try std.testing.expectEqual(Method.PUT, parseMethod("PUT").?);
    try std.testing.expectEqual(Method.DELETE, parseMethod("DELETE").?);
    try std.testing.expectEqual(Method.HEAD, parseMethod("HEAD").?);
    try std.testing.expectEqual(Method.PATCH, parseMethod("PATCH").?);
    try std.testing.expectEqual(Method.OPTIONS, parseMethod("OPTIONS").?);
    try std.testing.expectEqual(Method.CONNECT, parseMethod("CONNECT").?);
    try std.testing.expectEqual(Method.TRACE, parseMethod("TRACE").?);
    try std.testing.expectEqual(Method.GET, parseMethod("get").?);
    try std.testing.expect(parseMethod("INVALID") == null);
}

test "parseAuthority variations" {
    const a1 = parseAuthority("localhost").?;
    try std.testing.expectEqualStrings("localhost", a1.host);
    try std.testing.expect(a1.port == null);
    try std.testing.expect(!a1.isIpv6);

    const a2 = parseAuthority("example.com:8080").?;
    try std.testing.expectEqualStrings("example.com", a2.host);
    try std.testing.expectEqual(@as(?u16, 8080), a2.port);
    try std.testing.expect(!a2.isIpv6);

    const a3 = parseAuthority("[::1]:8443").?;
    try std.testing.expectEqualStrings("::1", a3.host);
    try std.testing.expectEqual(@as(?u16, 8443), a3.port);
    try std.testing.expect(a3.isIpv6);

    const a4 = parseAuthority("[fe80::1]").?;
    try std.testing.expectEqualStrings("fe80::1", a4.host);
    try std.testing.expect(a4.port == null);
    try std.testing.expect(a4.isIpv6);

    try std.testing.expect(parseAuthority("[::1:bad") == null);
    try std.testing.expect(parseAuthority("host:99999") == null);
}

test "ByteCursor reading" {
    const raw = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07 };
    var cursor = ByteCursor.init(&raw);
    try std.testing.expectEqual(@as(usize, 7), cursor.remaining());
    try std.testing.expectEqual(@as(u8, 0x01), cursor.readByte().?);
    try std.testing.expectEqual(@as(u16, 0x0203), cursor.readInt(u16, .big).?);
    try std.testing.expectEqual(@as(u24, 0x040506), cursor.readU24Big().?);
    try std.testing.expectEqual(@as(u8, 0x07), cursor.readByte().?);
    try std.testing.expect(cursor.isEof());
    try std.testing.expect(cursor.readByte() == null);
}

test "TokenListIterator and hasToken" {
    const list = "gzip, deflate, br;q=1.0, zstd";
    var it = TokenListIterator.init(list);
    try std.testing.expectEqualStrings("gzip", it.next().?);
    try std.testing.expectEqualStrings("deflate", it.next().?);
    try std.testing.expectEqualStrings("br;q=1.0", it.next().?);
    try std.testing.expectEqualStrings("zstd", it.next().?);
    try std.testing.expect(it.next() == null);

    try std.testing.expect(hasToken(list, "gzip"));
    try std.testing.expect(hasToken(list, "DEFLATE"));
    try std.testing.expect(hasToken(list, "zstd"));
    try std.testing.expect(!hasToken(list, "compress"));
}

test "ParamIterator semicolon parameters" {
    const cookie = "sessionId=abc123xyz; Path=/api; Secure; HttpOnly; SameSite=Strict";
    var it = ParamIterator.init(cookie);
    const p1 = it.next().?;
    try std.testing.expectEqualStrings("sessionId", p1.key);
    try std.testing.expectEqualStrings("abc123xyz", p1.value);

    const p2 = it.next().?;
    try std.testing.expectEqualStrings("Path", p2.key);
    try std.testing.expectEqualStrings("/api", p2.value);

    const p3 = it.next().?;
    try std.testing.expectEqualStrings("Secure", p3.key);
    try std.testing.expectEqualStrings("", p3.value);

    const p4 = it.next().?;
    try std.testing.expectEqualStrings("HttpOnly", p4.key);
    try std.testing.expectEqualStrings("", p4.value);

    const p5 = it.next().?;
    try std.testing.expectEqualStrings("SameSite", p5.key);
    try std.testing.expectEqualStrings("Strict", p5.value);
    try std.testing.expect(it.next() == null);
}

test "percentDecode and percentEncode" {
    var decBuf: [64]u8 = undefined;
    const decoded = try percentDecode(&decBuf, "Hello%20World%21%2F");
    try std.testing.expectEqualStrings("Hello World!/", decoded);

    var encBuf: [64]u8 = undefined;
    const encoded = try percentEncode(&encBuf, "Hello World!/");
    try std.testing.expectEqualStrings("Hello%20World%21%2F", encoded);

    var inPlace: [16]u8 = undefined;
    @memcpy(inPlace[0..13], "Hello%20World");
    const ipDecoded = percentDecodeInPlace(inPlace[0..13]);
    try std.testing.expectEqualStrings("Hello World", ipDecoded);
}

test "parseHttpDate IMF-fixdate" {
    const s = "Sun, 06 Nov 1994 08:49:37 GMT";
    const ts = parseHttpDate(s);
    try std.testing.expect(ts != null);
    try std.testing.expectEqual(@as(i64, 784111777), ts.?);
    try std.testing.expect(parseHttpDate("invalid date") == null);
}
