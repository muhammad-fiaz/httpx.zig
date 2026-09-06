//! Route pattern parsing and matching.
//!
//! Supports:
//!   /users              — exact/static
//!   /users/{id}         — parameter
//!   /files/*path        — wildcard (catches remaining segments)

const std = @import("std");

pub const SegmentKind = enum {
    literal,
    parameter,
    wildcard,
};

pub const Segment = struct {
    kind: SegmentKind,
    text: []const u8,
};

pub const Pattern = struct {
    segments: [32]Segment = undefined,
    count: usize = 0,

    pub fn isWildcard(self: *const Pattern) bool {
        return self.count > 0 and self.segments[self.count - 1].kind == .wildcard;
    }

    /// Normalized shape for duplicate detection.
    pub fn shape(self: *const Pattern, buf: []u8) ![]const u8 {
        var pos: usize = 0;
        for (self.segments[0..self.count]) |seg| {
            if (pos + 1 >= buf.len) return error.TooManySegments;
            buf[pos] = '/';
            pos += 1;
            const text: []const u8 = switch (seg.kind) {
                .literal => seg.text,
                .parameter => "{}",
                .wildcard => "*",
            };
            if (pos + text.len > buf.len) return error.TooManySegments;
            @memcpy(buf[pos..][0..text.len], text);
            pos += text.len;
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
    TooManySegments,
};

pub fn parsePattern(path: []const u8) ParseError!Pattern {
    var pattern = Pattern{};
    var it = std.mem.splitScalar(u8, path, '/');

    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (pattern.count >= 32) return ParseError.TooManySegments;

        if (seg.len >= 2 and seg[0] == '{' and seg[seg.len - 1] == '}') {
            const name = seg[1 .. seg.len - 1];
            if (name.len == 0) return ParseError.EmptyParameterName;
            pattern.segments[pattern.count] = .{ .kind = .parameter, .text = name };
            pattern.count += 1;
            continue;
        }

        if (seg.len >= 2 and seg[0] == '*') {
            pattern.segments[pattern.count] = .{ .kind = .wildcard, .text = seg[1..] };
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

/// Priority score: literal=4+1 per segment, param=2+1, wildcard=0+1.
pub fn priorityScore(p: *const Pattern) u32 {
    var score: u32 = 0;
    for (p.segments[0..p.count]) |seg| {
        switch (seg.kind) {
            .literal => score += 5,
            .parameter => score += 3,
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
}

test "wildcard must be last" {
    try std.testing.expectError(ParseError.InvalidWildcardPlacement, parsePattern("/*rest/users"));
    _ = try parsePattern("/files/*path");
}

test "empty parameter rejected" {
    try std.testing.expectError(ParseError.EmptyParameterName, parsePattern("/users/{}"));
}

test "priority: static beats parameter" {
    const static_p = try parsePattern("/users/me");
    const param_p = try parsePattern("/users/{id}");
    try std.testing.expect(priorityScore(&static_p) > priorityScore(&param_p));
}

test "shape normalization detects same-shape routes" {
    var buf1: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    const p1 = try parsePattern("/users/{id}");
    const p2 = try parsePattern("/users/{user_id}");
    const s1 = try p1.shape(&buf1);
    const s2 = try p2.shape(&buf2);
    try std.testing.expectEqualStrings(s1, s2);
}
