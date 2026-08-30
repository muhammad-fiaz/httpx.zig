//! robots.txt parsing and path matching (RFC 9309).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Rule = struct {
    path_prefix: []const u8,
    allow: bool,
};

pub const UserAgentGroup = struct {
    user_agent: []const u8,
    rules: []Rule = &.{},
    crawl_delay_s: ?f32 = null,
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

    pub fn isAllowed(self: *const RobotsFile, user_agent: []const u8, path: []const u8) bool {
        var best_group: ?*const UserAgentGroup = null;
        var wildcard_group: ?*const UserAgentGroup = null;

        for (self.groups) |*g| {
            if (std.mem.eql(u8, g.user_agent, "*")) {
                wildcard_group = g;
            } else if (std.ascii.indexOfIgnoreCase(user_agent, g.user_agent) != null) {
                best_group = g;
                break;
            }
        }

        const group = best_group orelse wildcard_group orelse return true;

        var longest_match_len: usize = 0;
        var allowed = true;

        for (group.rules) |r| {
            if (matchPath(r.path_prefix, path)) {
                if (r.path_prefix.len >= longest_match_len) {
                    longest_match_len = r.path_prefix.len;
                    allowed = r.allow;
                }
            }
        }

        return allowed;
    }
};

fn matchPath(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0) return true;
    if (pattern[pattern.len - 1] == '$') {
        const p = pattern[0 .. pattern.len - 1];
        return std.mem.eql(u8, p, path);
    }
    return std.mem.startsWith(u8, path, pattern);
}

pub fn parse(allocator: Allocator, src: []const u8) !RobotsFile {
    var groups: std.ArrayList(UserAgentGroup) = .empty;
    var sitemaps: std.ArrayList([]const u8) = .empty;

    var current_agents: std.ArrayList([]const u8) = .empty;
    defer current_agents.deinit(allocator);
    var current_rules: std.ArrayList(Rule) = .empty;
    defer current_rules.deinit(allocator);
    var current_delay: ?f32 = null;

    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.indexOfScalar(u8, line, '#')) |hash| {
            line = std.mem.trim(u8, line[0..hash], " \t");
        }
        if (line.len == 0) continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(key, "user-agent")) {
            if (current_rules.items.len > 0 and current_agents.items.len > 0) {
                for (current_agents.items) |ua| {
                    try groups.append(allocator, .{
                        .user_agent = ua,
                        .rules = try current_rules.toOwnedSlice(allocator),
                        .crawl_delay_s = current_delay,
                    });
                }
                current_agents.clearRetainingCapacity();
                current_delay = null;
            }
            try current_agents.append(allocator, val);
        } else if (std.ascii.eqlIgnoreCase(key, "disallow")) {
            if (val.len == 0) {
                try current_rules.append(allocator, .{ .path_prefix = "/", .allow = true });
            } else {
                try current_rules.append(allocator, .{ .path_prefix = val, .allow = false });
            }
        } else if (std.ascii.eqlIgnoreCase(key, "allow")) {
            try current_rules.append(allocator, .{ .path_prefix = val, .allow = true });
        } else if (std.ascii.eqlIgnoreCase(key, "crawl-delay")) {
            if (std.fmt.parseFloat(f32, val)) |d| current_delay = d else |_| {}
        } else if (std.ascii.eqlIgnoreCase(key, "sitemap")) {
            try sitemaps.append(allocator, val);
        }
    }

    if (current_agents.items.len > 0) {
        for (current_agents.items) |ua| {
            try groups.append(allocator, .{
                .user_agent = ua,
                .rules = try current_rules.toOwnedSlice(allocator),
                .crawl_delay_s = current_delay,
            });
        }
    }

    return RobotsFile{
        .allocator = allocator,
        .groups = try groups.toOwnedSlice(allocator),
        .sitemaps = try sitemaps.toOwnedSlice(allocator),
    };
}
