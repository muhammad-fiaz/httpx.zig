//! robots.txt parsing and path matching (RFC 9309).
//!
//! Deliberately native (no Tree-sitter): robots.txt is a line-oriented
//! `field: value` format with group scoping, not a nested syntax tree.
//! A grammar would add table overhead for zero structural benefit.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Rule = struct {
    pathPrefix: []const u8,
    allow: bool,
};

pub const UserAgentGroup = struct {
    userAgent: []const u8,
    rules: []Rule = &.{},
    crawlDelay: ?f32 = null,
};

pub const RobotsFile = struct {
    allocator: Allocator,
    groups: []UserAgentGroup = &.{},
    sitemaps: [][]const u8 = &.{},

    pub fn deinit(self: *RobotsFile) void {
        for (self.groups) |g| {
            self.allocator.free(g.rules);
        }
        self.allocator.free(self.groups);
        self.allocator.free(self.sitemaps);
    }

    pub fn isAllowed(self: *const RobotsFile, userAgent: []const u8, path: []const u8) bool {
        var bestGroup: ?*const UserAgentGroup = null;
        var wildcardGroup: ?*const UserAgentGroup = null;

        for (self.groups) |*g| {
            if (std.mem.eql(u8, g.userAgent, "*")) {
                wildcardGroup = g;
            } else if (std.ascii.findIgnoreCase(userAgent, g.userAgent) != null) {
                bestGroup = g;
                break;
            }
        }

        const group = bestGroup orelse wildcardGroup orelse return true;

        var longestMatchLen: usize = 0;
        var allowed = true;

        for (group.rules) |r| {
            if (matchPath(self.allocator, r.pathPrefix, path)) {
                if (r.pathPrefix.len >= longestMatchLen) {
                    longestMatchLen = r.pathPrefix.len;
                    allowed = r.allow;
                }
            }
        }

        return allowed;
    }
};

const regexMod = @import("regex");

fn matchPath(allocator: Allocator, pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0) return true;

    // Fast-path for simple prefix matches without wildcard or end-anchor
    const hasWildcard = std.mem.indexOfScalar(u8, pattern, '*') != null;
    const hasAnchor = pattern[pattern.len - 1] == '$';

    if (!hasWildcard and !hasAnchor) {
        return std.mem.startsWith(u8, path, pattern);
    }
    if (!hasWildcard and hasAnchor) {
        return std.mem.eql(u8, pattern[0 .. pattern.len - 1], path);
    }

    // RFC 9309 Section 2.2.2 pattern matching with '*' and '$':
    // A '$' at the end of the pattern anchors to the end of the URL.
    // Without '$', it is a prefix pattern (anchored only at start).
    const isEndAnchored = pattern[pattern.len - 1] == '$';
    const effectivePattern = if (isEndAnchored) pattern[0 .. pattern.len - 1] else pattern;

    const reStr = buildRobotsRegex(allocator, effectivePattern, isEndAnchored) catch {
        return std.mem.startsWith(u8, path, pattern);
    };
    defer allocator.free(reStr);

    var re = regexMod.compile(allocator, reStr, .{}) catch {
        return std.mem.startsWith(u8, path, pattern);
    };
    defer re.deinit();

    return re.isMatch(path, .{});
}

fn buildRobotsRegex(allocator: Allocator, pattern: []const u8, isEndAnchored: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '^');
    for (pattern) |c| {
        if (c == '*') {
            try out.appendSlice(allocator, ".*");
        } else {
            switch (c) {
                '.', '+', '?', '(', ')', '[', ']', '{', '}', '^', '$', '|', '\\' => {
                    try out.append(allocator, '\\');
                    try out.append(allocator, c);
                },
                else => try out.append(allocator, c),
            }
        }
    }
    if (isEndAnchored) {
        try out.append(allocator, '$');
    }
    return out.toOwnedSlice(allocator);
}

pub fn parse(allocator: Allocator, src: []const u8) !RobotsFile {
    var groups: std.ArrayList(UserAgentGroup) = .empty;
    var sitemaps: std.ArrayList([]const u8) = .empty;

    var currentAgents: std.ArrayList([]const u8) = .empty;
    defer currentAgents.deinit(allocator);
    var currentRules: std.ArrayList(Rule) = .empty;
    defer currentRules.deinit(allocator);
    var currentDelay: ?f32 = null;

    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |rawLine| {
        var line = std.mem.trim(u8, rawLine, " \t\r");
        if (std.mem.indexOfScalar(u8, line, '#')) |hash| {
            line = std.mem.trim(u8, line[0..hash], " \t");
        }
        if (line.len == 0) continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(key, "user-agent")) {
            if (currentRules.items.len > 0 and currentAgents.items.len > 0) {
                for (currentAgents.items) |ua| {
                    try groups.append(allocator, .{
                        .userAgent = ua,
                        .rules = try currentRules.toOwnedSlice(allocator),
                        .crawlDelay = currentDelay,
                    });
                }
                currentAgents.clearRetainingCapacity();
                currentDelay = null;
            }
            try currentAgents.append(allocator, val);
        } else if (std.ascii.eqlIgnoreCase(key, "disallow")) {
            if (val.len == 0) {
                try currentRules.append(allocator, .{ .pathPrefix = "/", .allow = true });
            } else {
                try currentRules.append(allocator, .{ .pathPrefix = val, .allow = false });
            }
        } else if (std.ascii.eqlIgnoreCase(key, "allow")) {
            try currentRules.append(allocator, .{ .pathPrefix = val, .allow = true });
        } else if (std.ascii.eqlIgnoreCase(key, "crawl-delay")) {
            if (std.fmt.parseFloat(f32, val)) |d| currentDelay = d else |_| {}
        } else if (std.ascii.eqlIgnoreCase(key, "sitemap")) {
            try sitemaps.append(allocator, val);
        }
    }

    if (currentAgents.items.len > 0) {
        for (currentAgents.items) |ua| {
            try groups.append(allocator, .{
                .userAgent = ua,
                .rules = try currentRules.toOwnedSlice(allocator),
                .crawlDelay = currentDelay,
            });
        }
    }

    return RobotsFile{
        .allocator = allocator,
        .groups = try groups.toOwnedSlice(allocator),
        .sitemaps = try sitemaps.toOwnedSlice(allocator),
    };
}

// Tests

test "robots.txt parsing with user agents, disallows, allows, and sitemaps" {
    const a = std.testing.allocator;
    const robotsTxt =
        \\User-agent: Googlebot
        \\Disallow: /private/
        \\Allow: /private/public.html
        \\Crawl-delay: 2.5
        \\
        \\User-agent: *
        \\Disallow: /admin/
        \\Disallow: /*.gif$
        \\Allow: /
        \\Sitemap: https://example.com/sitemap.xml
    ;

    var rf = try parse(a, robotsTxt);
    defer rf.deinit();

    try std.testing.expectEqual(@as(usize, 2), rf.groups.len);
    try std.testing.expectEqual(@as(usize, 1), rf.sitemaps.len);
    try std.testing.expectEqualStrings("https://example.com/sitemap.xml", rf.sitemaps[0]);

    // Googlebot group matches
    try std.testing.expect(!rf.isAllowed("Googlebot/2.1", "/private/secret.html"));
    try std.testing.expect(rf.isAllowed("Googlebot/2.1", "/private/public.html"));

    // Default wildcard agent group matches
    try std.testing.expect(!rf.isAllowed("OtherBot", "/admin/settings"));
    try std.testing.expect(!rf.isAllowed("OtherBot", "/images/pic.gif"));
    try std.testing.expect(rf.isAllowed("OtherBot", "/images/pic.gif.html"));
    try std.testing.expect(rf.isAllowed("OtherBot", "/blog/post-1"));
}

test "robots wildcard and anchor matching" {
    const a = std.testing.allocator;
    try std.testing.expect(matchPath(a, "/fish*", "/fish"));
    try std.testing.expect(matchPath(a, "/fish*", "/fish.html"));
    try std.testing.expect(matchPath(a, "/fish*", "/fish/salmon.html"));
    try std.testing.expect(!matchPath(a, "/fish*", "/other/fish.html"));

    try std.testing.expect(matchPath(a, "/*.php$", "/index.php"));
    try std.testing.expect(!matchPath(a, "/*.php$", "/index.php?query=1"));
    try std.testing.expect(!matchPath(a, "/*.php$", "/index.phps"));
}
