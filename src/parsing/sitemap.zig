//! Sitemap XML parser (sitemaps.org protocol 0.9).

const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("dom.zig");
const xml = @import("xml.zig");
const z = @import("zigantic");

pub const ChangeFreq = enum {
    always,
    hourly,
    daily,
    weekly,
    monthly,
    yearly,
    never,
    unknown,
};

const SitemapUrlSchema = z.objectOf(.{
    .loc = z.withDefault(z.string(.{}), ""),
    .lastMod = z.withDefault(z.string(.{}), ""),
    .changeFreq = z.withDefault(z.enumType(ChangeFreq, .{}), .unknown),
    .priority = z.optional(z.float(f32, .{ .min = 0, .max = 1 })),
}, .{});
pub const SitemapUrl = SitemapUrlSchema.Value;

pub const Sitemap = struct {
    allocator: Allocator,
    isIndex: bool = false,
    urls: []SitemapUrl = &.{},
    sitemaps: [][]const u8 = &.{},

    pub fn deinit(self: *Sitemap) void {
        for (self.urls) |url| {
            if (url.loc.len > 0) self.allocator.free(url.loc);
            if (url.lastMod.len > 0) self.allocator.free(url.lastMod);
        }
        self.allocator.free(self.urls);
        for (self.sitemaps) |location| self.allocator.free(location);
        self.allocator.free(self.sitemaps);
    }
};

pub fn parse(allocator: Allocator, src: []const u8) !Sitemap {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const al = arena.allocator();

    var tree = try xml.parse(al, src, .{});
    defer tree.deinit(al);

    var sitemapIndexNodes: std.ArrayList(u32) = .empty;
    try tree.getElementsByTag(al, 0, "sitemapindex", &sitemapIndexNodes);

    if (sitemapIndexNodes.items.len > 0) {
        var smList: std.ArrayList([]const u8) = .empty;
        var sitemaps: std.ArrayList(u32) = .empty;
        try tree.getElementsByTag(al, 0, "sitemap", &sitemaps);
        for (sitemaps.items) |sIdx| {
            var locNodes: std.ArrayList(u32) = .empty;
            try tree.getElementsByTag(al, sIdx, "loc", &locNodes);
            if (locNodes.items.len > 0) {
                const locText = getText(&tree, locNodes.items[0]);
                if (locText.len > 0) try smList.append(allocator, try allocator.dupe(u8, locText));
            }
        }
        errdefer {
            for (smList.items) |location| allocator.free(location);
            smList.deinit(allocator);
        }
        return Sitemap{
            .allocator = allocator,
            .isIndex = true,
            .sitemaps = try smList.toOwnedSlice(allocator),
        };
    }

    var urlNodes: std.ArrayList(u32) = .empty;
    try tree.getElementsByTag(al, 0, "url", &urlNodes);

    var urls: std.ArrayList(SitemapUrl) = .empty;
    errdefer {
        for (urls.items) |url| {
            if (url.loc.len > 0) allocator.free(url.loc);
            if (url.lastMod.len > 0) allocator.free(url.lastMod);
        }
        urls.deinit(allocator);
    }
    for (urlNodes.items) |uIdx| {
        const u = try parseUrl(allocator, al, &tree, uIdx);
        urls.append(allocator, u) catch |err| {
            if (u.loc.len > 0) allocator.free(u.loc);
            if (u.lastMod.len > 0) allocator.free(u.lastMod);
            return err;
        };
    }

    return Sitemap{
        .allocator = allocator,
        .isIndex = false,
        .urls = try urls.toOwnedSlice(allocator),
    };
}

fn parseUrl(allocator: Allocator, arena: Allocator, tree: *const dom.Tree, node: u32) !SitemapUrl {
    var u = SitemapUrl{};
    errdefer {
        if (u.loc.len > 0) allocator.free(u.loc);
        if (u.lastMod.len > 0) allocator.free(u.lastMod);
    }

    var locs: std.ArrayList(u32) = .empty;
    try tree.getElementsByTag(arena, node, "loc", &locs);
    if (locs.items.len > 0) u.loc = try allocator.dupe(u8, getText(tree, locs.items[0]));

    var mods: std.ArrayList(u32) = .empty;
    try tree.getElementsByTag(arena, node, "lastMod", &mods);
    if (mods.items.len > 0) u.lastMod = try allocator.dupe(u8, getText(tree, mods.items[0]));

    var freqs: std.ArrayList(u32) = .empty;
    try tree.getElementsByTag(arena, node, "changeFreq", &freqs);
    if (freqs.items.len > 0) {
        const f = getText(tree, freqs.items[0]);
        if (std.ascii.eqlIgnoreCase(f, "always")) u.changeFreq = .always else if (std.ascii.eqlIgnoreCase(f, "hourly")) u.changeFreq = .hourly else if (std.ascii.eqlIgnoreCase(f, "daily")) u.changeFreq = .daily else if (std.ascii.eqlIgnoreCase(f, "weekly")) u.changeFreq = .weekly else if (std.ascii.eqlIgnoreCase(f, "monthly")) u.changeFreq = .monthly else if (std.ascii.eqlIgnoreCase(f, "yearly")) u.changeFreq = .yearly else if (std.ascii.eqlIgnoreCase(f, "never")) u.changeFreq = .never;
    }

    var priorities: std.ArrayList(u32) = .empty;
    try tree.getElementsByTag(arena, node, "priority", &priorities);
    if (priorities.items.len > 0) {
        const text = getText(tree, priorities.items[0]);
        const value = std.fmt.parseFloat(f32, text) catch return error.InvalidPriority;
        var scratch: [512]u8 = undefined;
        const issue = z.checkFirst(z.float(f32, .{ .min = 0, .max = 1 }), value, &scratch, .{}) catch return error.InvalidPriority;
        if (issue != null) return error.InvalidPriority;
        u.priority = value;
    }
    return u;
}

fn getText(tree: *const dom.Tree, root: u32) []const u8 {
    var c = tree.get(root).firstChild;
    while (c != dom.NO_NODE) {
        const node = tree.get(c);
        if (node.kind == .text or node.kind == .cdata) {
            return std.mem.trim(u8, node.data, " \t\r\n");
        }
        c = node.nextSibling;
    }
    return "";
}

test "sitemap results own their strings after the XML arena is released" {
    const source =
        "<urlset><url><loc>https://example.test/a</loc><lastmod>2026-11-17</lastmod><priority>0.7</priority></url></urlset>";
    var result = try parse(std.testing.allocator, source);
    defer result.deinit();
    try std.testing.expectEqualStrings("https://example.test/a", result.urls[0].loc);
    try std.testing.expectEqualStrings("2026-11-17", result.urls[0].lastMod);
    try std.testing.expectEqual(@as(?f32, 0.7), result.urls[0].priority);
}

test "sitemap priority must be a number in the protocol range" {
    const invalid_values = [_][]const u8{ "nope", "-0.1", "1.1", "nan", "inf" };
    for (invalid_values) |value| {
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "<urlset><url><loc>https://example.test/</loc><priority>{s}</priority></url></urlset>",
            .{value},
        );
        defer std.testing.allocator.free(source);
        try std.testing.expectError(error.InvalidPriority, parse(std.testing.allocator, source));
    }
}
