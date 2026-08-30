//! Sitemap XML parser (sitemaps.org protocol 0.9).

const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("dom.zig");
const xml = @import("xml.zig");

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

pub const SitemapUrl = struct {
    loc: []const u8 = "",
    lastmod: []const u8 = "",
    changefreq: ChangeFreq = .unknown,
    priority: ?f32 = null,
};

pub const Sitemap = struct {
    allocator: Allocator,
    is_index: bool = false,
    urls: []SitemapUrl = &.{},
    sitemaps: [][]const u8 = &.{},

    pub fn deinit(self: *Sitemap) void {
        self.allocator.free(self.urls);
        self.allocator.free(self.sitemaps);
    }
};

pub fn parse(allocator: Allocator, src: []const u8) !Sitemap {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const al = arena.allocator();

    var tree = try xml.parse(al, src, .{});
    defer tree.deinit(al);

    var sitemap_index_nodes: std.ArrayList(u32) = .empty;
    try tree.getElementsByTag(al, 0, "sitemapindex", &sitemap_index_nodes);

    if (sitemap_index_nodes.items.len > 0) {
        var sm_list: std.ArrayList([]const u8) = .empty;
        var sitemaps: std.ArrayList(u32) = .empty;
        try tree.getElementsByTag(al, 0, "sitemap", &sitemaps);
        for (sitemaps.items) |s_idx| {
            var loc_nodes: std.ArrayList(u32) = .empty;
            try tree.getElementsByTag(al, s_idx, "loc", &loc_nodes);
            if (loc_nodes.items.len > 0) {
                const loc_text = getText(&tree, loc_nodes.items[0]);
                if (loc_text.len > 0) try sm_list.append(allocator, loc_text);
            }
        }
        return Sitemap{
            .allocator = allocator,
            .is_index = true,
            .sitemaps = try sm_list.toOwnedSlice(allocator),
        };
    }

    var url_nodes: std.ArrayList(u32) = .empty;
    try tree.getElementsByTag(al, 0, "url", &url_nodes);

    var urls: std.ArrayList(SitemapUrl) = .empty;
    for (url_nodes.items) |u_idx| {
        var u = SitemapUrl{};
        var locs: std.ArrayList(u32) = .empty;
        try tree.getElementsByTag(al, u_idx, "loc", &locs);
        if (locs.items.len > 0) u.loc = getText(&tree, locs.items[0]);

        var mods: std.ArrayList(u32) = .empty;
        try tree.getElementsByTag(al, u_idx, "lastmod", &mods);
        if (mods.items.len > 0) u.lastmod = getText(&tree, mods.items[0]);

        var freqs: std.ArrayList(u32) = .empty;
        try tree.getElementsByTag(al, u_idx, "changefreq", &freqs);
        if (freqs.items.len > 0) {
            const f = getText(&tree, freqs.items[0]);
            if (std.ascii.eqlIgnoreCase(f, "always")) u.changefreq = .always
            else if (std.ascii.eqlIgnoreCase(f, "hourly")) u.changefreq = .hourly
            else if (std.ascii.eqlIgnoreCase(f, "daily")) u.changefreq = .daily
            else if (std.ascii.eqlIgnoreCase(f, "weekly")) u.changefreq = .weekly
            else if (std.ascii.eqlIgnoreCase(f, "monthly")) u.changefreq = .monthly
            else if (std.ascii.eqlIgnoreCase(f, "yearly")) u.changefreq = .yearly
            else if (std.ascii.eqlIgnoreCase(f, "never")) u.changefreq = .never;
        }

        var prios: std.ArrayList(u32) = .empty;
        try tree.getElementsByTag(al, u_idx, "priority", &prios);
        if (prios.items.len > 0) {
            const p = getText(&tree, prios.items[0]);
            if (std.fmt.parseFloat(f32, p)) |v| u.priority = v else |_| {}
        }

        try urls.append(allocator, u);
    }

    return Sitemap{
        .allocator = allocator,
        .is_index = false,
        .urls = try urls.toOwnedSlice(allocator),
    };
}

fn getText(tree: *const dom.Tree, root: u32) []const u8 {
    var c = tree.get(root).first_child;
    while (c != dom.NO_NODE) {
        const node = tree.get(c);
        if (node.kind == .text or node.kind == .cdata) {
            return std.mem.trim(u8, node.data, " \t\r\n");
        }
        c = node.next_sibling;
    }
    return "";
}
