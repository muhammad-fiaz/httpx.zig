//! Route pattern parsing and matching.
//!
//! Canonical syntax (one grammar, no `:id` legacy form):
//!   /users              — exact/static
//!   /users/{id}         — parameter (one segment, any text)
//!   /users/{id:int}     — typed parameter (validated at match time)
//!   /blog/{slug:slug}   — slug parameter
//!   /files/{path:path}  — catch-all (remaining segments, must be last)
//!   /files/*path        — legacy catch-all spelling, same as {path:path}
//!
//! Converters: str|string, int, uint, float, bool, uuid, slug, path.
//! Patterns compile once at registration; matching borrows path slices.

const std = @import("std");

pub const SegmentKind = enum {
    literal,
    parameter,
    wildcard,
};

/// Built-in path parameter converters.
pub const Converter = enum {
    /// Any single non-empty segment (default when no `:type` is given).
    str,
    /// Optional `-` followed by ASCII digits.
    int,
    /// ASCII digits.
    uint,
    /// Anything `std.fmt.parseFloat(f64, …)` accepts.
    float,
    /// Exactly `true` or `false`.
    boolean,
    /// Canonical `8-4-4-4-12` hex form (either case).
    uuid,
    /// Lowercase `[a-z0-9]+(-[a-z0-9]+)*`.
    slug,
    /// Remainder of the path including `/` (catch-all; must be last).
    path,

    /// Maps a `:converter` spelling to a converter. Accepts `str` and
    /// `string` for text. Returns null for unknown spellings.
    pub fn fromName(name: []const u8) ?Converter {
        if (std.mem.eql(u8, name, "str") or std.mem.eql(u8, name, "string")) return .str;
        if (std.mem.eql(u8, name, "int")) return .int;
        if (std.mem.eql(u8, name, "uint")) return .uint;
        if (std.mem.eql(u8, name, "float")) return .float;
        if (std.mem.eql(u8, name, "bool") or std.mem.eql(u8, name, "boolean")) return .boolean;
        if (std.mem.eql(u8, name, "uuid")) return .uuid;
        if (std.mem.eql(u8, name, "slug")) return .slug;
        if (std.mem.eql(u8, name, "path")) return .path;
        return null;
    }

    /// True for converters that only match a single path segment.
    pub fn isSingleSegment(self: Converter) bool {
        return self != .path;
    }

    /// Validates one raw path segment against this converter.
    /// `path` is only meaningful for multi-segment remainders (always true here).
    pub fn matches(self: Converter, value: []const u8) bool {
        if (value.len == 0) return false;
        return switch (self) {
            .str, .path => true,
            .int => isInt(value),
            .uint => isUint(value),
            .float => blk: {
                _ = std.fmt.parseFloat(f64, value) catch break :blk false;
                break :blk true;
            },
            .boolean => std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false"),
            .uuid => isUuid(value),
            .slug => isSlug(value),
        };
    }
};

pub fn isUint(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

pub fn isInt(value: []const u8) bool {
    if (value.len == 0) return false;
    const digits = if (value[0] == '-') value[1..] else value;
    return isUint(digits);
}

pub fn isHexByte(c: u8) bool {
    return std.ascii.isHex(c);
}

pub fn isUuid(value: []const u8) bool {
    // Canonical 8-4-4-4-12 hex groups.
    if (value.len != 36) return false;
    const hexes = [_]bool{
        true,  true, true, true, true,  true,  true, true, false,
        true,  true, true, true, false, true,  true, true, true,
        false, true, true, true, true,  false, true, true, true,
        true,  true, true, true, true,  true,  true, true, true,
    };
    for (hexes, 0..) |want_hex, i| {
        const c = value[i];
        if (want_hex) {
            if (!isHexByte(c)) return false;
        } else if (c != '-') {
            return false;
        }
    }
    return true;
}

pub fn isSlug(value: []const u8) bool {
    // [a-z0-9]+(-[a-z0-9]+)* — lowercase, no leading/trailing/doubled hyphen.
    if (value.len == 0) return false;
    var expect_alnum = true;
    for (value) |c| {
        const alnum = std.ascii.isLower(c) or std.ascii.isDigit(c);
        if (expect_alnum) {
            if (!alnum) return false;
            expect_alnum = false;
        } else if (c == '-') {
            expect_alnum = true;
        } else if (!alnum) {
            return false;
        }
    }
    return !expect_alnum;
}

pub const Segment = struct {
    kind: SegmentKind,
    /// Parameter/wildcard name, or literal text. Borrowed from the
    /// registered (owned) pattern string.
    text: []const u8,
    /// Meaningful for `.parameter` (`.str` when omitted). Wildcards parsed
    /// from either spelling always behave as `.path`.
    converter: Converter = .str,
};

pub const Pattern = struct {
    segments: [32]Segment = undefined,
    count: usize = 0,

    pub fn isWildcard(self: *const Pattern) bool {
        return self.count > 0 and self.segments[self.count - 1].kind == .wildcard;
    }

    /// Normalized shape for duplicate detection. Parameter names are
    /// erased but converters are kept: `/u/{}` vs `/u/{int}` differ,
    /// `/u/{id}` vs `/u/{name}` collide.
    pub fn shape(self: *const Pattern, buf: []u8) ![]const u8 {
        var pos: usize = 0;
        for (self.segments[0..self.count]) |seg| {
            if (pos + 1 >= buf.len) return error.TooManySegments;
            buf[pos] = '/';
            pos += 1;
            if (seg.kind == .literal) {
                if (pos + seg.text.len > buf.len) return error.TooManySegments;
                @memcpy(buf[pos..][0..seg.text.len], seg.text);
                pos += seg.text.len;
            } else if (seg.kind == .wildcard) {
                if (pos + 1 > buf.len) return error.TooManySegments;
                buf[pos] = '*';
                pos += 1;
            } else if (seg.converter == .str) {
                if (pos + 2 > buf.len) return error.TooManySegments;
                buf[pos] = '{';
                buf[pos + 1] = '}';
                pos += 2;
            } else {
                const tag = @tagName(seg.converter);
                if (pos + tag.len + 2 > buf.len) return error.TooManySegments;
                buf[pos] = '{';
                @memcpy(buf[pos + 1 ..][0..tag.len], tag);
                buf[pos + 1 + tag.len] = '}';
                pos += tag.len + 2;
            }
        }
        if (self.count == 0) {
            buf[pos] = '/';
            pos += 1;
        }
        return buf[0..pos];
    }
};

pub const ParseError = error{
    EmptyParameterName,
    InvalidWildcardPlacement,
    UnknownConverter,
    DuplicateParameter,
    TooManySegments,
};

pub fn parsePattern(path: []const u8) ParseError!Pattern {
    var pattern = Pattern{};
    var it = std.mem.splitScalar(u8, path, '/');

    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (pattern.count >= 32) return ParseError.TooManySegments;

        if (seg.len >= 2 and seg[0] == '{' and seg[seg.len - 1] == '}') {
            const inner = seg[1 .. seg.len - 1];
            if (inner.len == 0) return ParseError.EmptyParameterName;
            if (std.mem.indexOfAny(u8, inner, "{}*") != null) return ParseError.EmptyParameterName;
            var name = inner;
            var converter: Converter = .str;
            if (std.mem.indexOfScalar(u8, inner, ':')) |ci| {
                name = inner[0..ci];
                const conv_name = inner[ci + 1 ..];
                if (name.len == 0) return ParseError.EmptyParameterName;
                converter = Converter.fromName(conv_name) orelse return ParseError.UnknownConverter;
            }
            if (hasParam(&pattern, name)) return ParseError.DuplicateParameter;
            if (converter == .path) {
                pattern.segments[pattern.count] = .{ .kind = .wildcard, .text = name, .converter = .path };
            } else {
                pattern.segments[pattern.count] = .{ .kind = .parameter, .text = name, .converter = converter };
            }
            pattern.count += 1;
            continue;
        }

        // Legacy catch-all spelling `*name` — identical to `{name:path}`.
        if (seg[0] == '*') {
            if (seg.len < 2) return ParseError.InvalidWildcardPlacement;
            if (hasParam(&pattern, seg[1..])) return ParseError.DuplicateParameter;
            pattern.segments[pattern.count] = .{ .kind = .wildcard, .text = seg[1..], .converter = .path };
            pattern.count += 1;
            continue;
        }

        pattern.segments[pattern.count] = .{ .kind = .literal, .text = seg };
        pattern.count += 1;
    }

    for (pattern.segments[0..pattern.count], 0..) |seg, i| {
        if (seg.kind == .wildcard and i != pattern.count - 1)
            return ParseError.InvalidWildcardPlacement;
    }

    return pattern;
}

fn hasParam(pattern: *const Pattern, name: []const u8) bool {
    for (pattern.segments[0..pattern.count]) |seg| {
        if ((seg.kind == .parameter or seg.kind == .wildcard) and std.mem.eql(u8, seg.text, name)) return true;
    }
    return false;
}

/// Priority score per segment: literal=5, typed parameter=4, generic
/// parameter=3, wildcard=1. Higher score wins; ties keep the FIRST
/// registered route (documented tie-break — prefer unambiguous patterns).
pub fn priorityScore(p: *const Pattern) u32 {
    var score: u32 = 0;
    for (p.segments[0..p.count]) |seg| {
        switch (seg.kind) {
            .literal => score += 5,
            .parameter => score += if (seg.converter == .str) @as(u32, 3) else 4,
            .wildcard => score += 1,
        }
    }
    return score;
}

test "parse static pattern" {
    const p = try parsePattern("/users/list");
    try std.testing.expectEqual(@as(usize, 2), p.count);
    try std.testing.expectEqual(SegmentKind.literal, p.segments[0].kind);
}

test "parse parameter pattern" {
    const p = try parsePattern("/users/{id}/posts/{post_id}");
    try std.testing.expectEqual(@as(usize, 4), p.count);
    try std.testing.expectEqualStrings("id", p.segments[1].text);
    try std.testing.expectEqual(Converter.str, p.segments[1].converter);
}

test "parse typed parameters" {
    const p = try parsePattern("/users/{id:int}/posts/{slug:slug}/files/{path:path}");
    try std.testing.expectEqual(Converter.int, p.segments[1].converter);
    try std.testing.expectEqualStrings("id", p.segments[1].text);
    try std.testing.expectEqual(Converter.slug, p.segments[3].converter);
    try std.testing.expectEqual(SegmentKind.wildcard, p.segments[5].kind);
    try std.testing.expectEqualStrings("path", p.segments[5].text);
}

test "converter spellings" {
    try std.testing.expectEqual(Converter.str, Converter.fromName("string").?);
    try std.testing.expectEqual(Converter.boolean, Converter.fromName("bool").?);
    try std.testing.expectEqual(Converter.boolean, Converter.fromName("boolean").?);
    try std.testing.expect(null == Converter.fromName("regex"));
    try std.testing.expect(null == Converter.fromName(""));
}

test "unknown converter rejected" {
    try std.testing.expectError(ParseError.UnknownConverter, parsePattern("/users/{id:regex}"));
    try std.testing.expectError(ParseError.UnknownConverter, parsePattern("/users/{id:}"));
    try std.testing.expectError(ParseError.UnknownConverter, parsePattern("/users/{id:int:uint}"));
    try std.testing.expectError(ParseError.EmptyParameterName, parsePattern("/users/{:int}"));
}

test "duplicate parameter rejected" {
    try std.testing.expectError(ParseError.DuplicateParameter, parsePattern("/a/{id}/b/{id}"));
    try std.testing.expectError(ParseError.DuplicateParameter, parsePattern("/a/{id}/b/*id"));
}

test "wildcard must be last" {
    try std.testing.expectError(ParseError.InvalidWildcardPlacement, parsePattern("/*rest/users"));
    try std.testing.expectError(ParseError.InvalidWildcardPlacement, parsePattern("/a/{p:path}/b"));
    _ = try parsePattern("/files/*path");
    _ = try parsePattern("/files/{path:path}");
}

test "bare star is rejected, not a literal" {
    try std.testing.expectError(ParseError.InvalidWildcardPlacement, parsePattern("/files/*"));
    try std.testing.expectError(ParseError.InvalidWildcardPlacement, parsePattern("/*"));
}

test "parameter names reject braces and stars" {
    try std.testing.expectError(ParseError.EmptyParameterName, parsePattern("/users/{a*b}"));
}

test "empty parameter rejected" {
    try std.testing.expectError(ParseError.EmptyParameterName, parsePattern("/users/{}"));
}

test "converters validate values" {
    try std.testing.expect(Converter.int.matches("42"));
    try std.testing.expect(Converter.int.matches("-7"));
    try std.testing.expect(!Converter.int.matches("4.2"));
    try std.testing.expect(!Converter.int.matches("abc"));
    try std.testing.expect(!Converter.int.matches(""));
    try std.testing.expect(Converter.uint.matches("42"));
    try std.testing.expect(!Converter.uint.matches("-7"));
    try std.testing.expect(Converter.float.matches("4.2"));
    try std.testing.expect(Converter.float.matches("-0.5"));
    try std.testing.expect(!Converter.float.matches("abc"));
    try std.testing.expect(Converter.boolean.matches("true"));
    try std.testing.expect(Converter.boolean.matches("false"));
    try std.testing.expect(!Converter.boolean.matches("True"));
    try std.testing.expect(!Converter.boolean.matches("1"));
    try std.testing.expect(Converter.uuid.matches("123e4567-e89b-12d3-a456-426614174000"));
    try std.testing.expect(Converter.uuid.matches("123E4567-E89B-12D3-A456-426614174000"));
    try std.testing.expect(!Converter.uuid.matches("123e4567-e89b-12d3-a456-42661417400"));
    try std.testing.expect(!Converter.uuid.matches("not-a-uuid"));
    try std.testing.expect(Converter.slug.matches("hello-world"));
    try std.testing.expect(Converter.slug.matches("zig-http-framework2"));
    try std.testing.expect(!Converter.slug.matches("Hello-World"));
    try std.testing.expect(!Converter.slug.matches("-lead"));
    try std.testing.expect(!Converter.slug.matches("trail-"));
    try std.testing.expect(!Converter.slug.matches("double--hyphen"));
    try std.testing.expect(!Converter.slug.matches("has space"));
    try std.testing.expect(!Converter.slug.matches("under_score"));
    try std.testing.expect(Converter.str.matches("anything42"));
    try std.testing.expect(!Converter.str.matches(""));
}

test "priority: static beats typed beats generic beats wildcard" {
    const s = try parsePattern("/users/me");
    const t = try parsePattern("/users/{id:int}");
    const g = try parsePattern("/users/{name}");
    const w = try parsePattern("/users/*rest");
    try std.testing.expect(priorityScore(&s) > priorityScore(&t));
    try std.testing.expect(priorityScore(&t) > priorityScore(&g));
    try std.testing.expect(priorityScore(&g) > priorityScore(&w));
}

test "shape erases names but keeps converters" {
    var buf1: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    var buf3: [256]u8 = undefined;
    const p1 = try parsePattern("/users/{id}");
    const p2 = try parsePattern("/users/{user_id}");
    try std.testing.expectEqualStrings(try p1.shape(&buf1), try p2.shape(&buf2));
    const p3 = try parsePattern("/users/{id:int}");
    const s3 = try p3.shape(&buf3);
    try std.testing.expect(!std.mem.eql(u8, try p1.shape(&buf1), s3));
}

test "fuzz: malformed patterns fail safely" {
    const bad = [_][]const u8{
        "{}",    "{{id}}",    "{id",   "id}", "{:",   "{foo:unknown}", "{foo:int:int}",
        "{/}",   "{ }",       "{a b}", "{*}", "{**}", "***",           "///",
        "{id:}", "{id:str:}", "{int}", "{0}", "{-x}", "{UPPER}",
    };
    for (bad) |b| {
        // Must either parse as harmless literals/params or fail cleanly —
        // never panic, never loop, never read out of bounds.
        _ = parsePattern(b) catch |err| {
            try std.testing.expect(err == ParseError.EmptyParameterName or
                err == ParseError.InvalidWildcardPlacement or
                err == ParseError.UnknownConverter or
                err == ParseError.DuplicateParameter or
                err == ParseError.TooManySegments);
            continue;
        };
    }
    // 33 segments exceeds the 32-segment cap.
    var long: [256]u8 = undefined;
    var pos: usize = 0;
    for (0..33) |_| {
        long[pos] = '/';
        long[pos + 1] = 'a';
        pos += 2;
    }
    try std.testing.expectError(ParseError.TooManySegments, parsePattern(long[0..pos]));
}
