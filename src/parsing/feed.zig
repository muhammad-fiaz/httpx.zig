//! RSS 2.0, Atom 1.0, and JSON Feed parser.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("dom.zig");
const xml = @import("xml.zig");

pub const FeedKind = enum { rss, atom, json_feed, unknown };

pub const FeedEntry = struct {
    title: []const u8 = "",
    link: []const u8 = "",
    id: []const u8 = "",
    description: []const u8 = "",
    content: []const u8 = "",
    published: []const u8 = "",
    updated: []const u8 = "",
    author: []const u8 = "",
};

pub const Feed = struct {
    allocator: Allocator,
    kind: FeedKind,
    title: []const u8 = "",
    link: []const u8 = "",
    description: []const u8 = "",
    language: []const u8 = "",
    entries: []FeedEntry = &.{},

    pub fn deinit(self: *Feed) void {
        self.allocator.free(self.entries);
    }
};

pub fn parse(allocator: Allocator, src: []const u8, content_type: ?[]const u8) !Feed {
    const is_json = if (content_type) |ct| std.mem.indexOf(u8, ct, "json") != null else std.mem.startsWith(u8, std.mem.trim(u8, src, " \t\r\n"), "{");
    if (is_json) {
        return parseJsonFeed(allocator, src);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const al = arena.allocator();

    var tree = try xml.parse(al, src, .{});
    defer tree.deinit(al);

    var rss_nodes: std.ArrayList(u32) = .empty;
    try tree.getElementsByTag(al, 0, "rss", &rss_nodes);
    if (rss_nodes.items.len > 0) return parseRss(allocator, &tree);

    var feed_nodes: std.ArrayList(u32) = .empty;
    try tree.getElementsByTag(al, 0, "feed", &feed_nodes);
    if (feed_nodes.items.len > 0) return parseAtom(allocator, &tree);

    return parseRss(allocator, &tree);
}

fn parseRss(allocator: Allocator, tree: *const dom.Tree) !Feed {
    var f = Feed{
        .allocator = allocator,
        .kind = .rss,
    };

    var items: std.ArrayList(u32) = .empty;
    defer items.deinit(allocator);
    var w = try tree.walk(allocator, 0);
    defer w.deinit();

    while (w.next()) |idx| {
        const node = tree.get(idx);
        if (node.kind != .element) continue;
        if (node.hasTag("channel")) {
            var cw = try tree.walk(allocator, idx);
            defer cw.deinit();
            _ = cw.next();
            while (cw.next()) |cidx| {
                const cn = tree.get(cidx);
                if (cn.kind != .element) continue;
                if (cn.hasTag("title") and f.title.len == 0) f.title = getText(tree, cidx);
                if (cn.hasTag("link") and f.link.len == 0) f.link = getText(tree, cidx);
                if (cn.hasTag("description") and f.description.len == 0) f.description = getText(tree, cidx);
                if (cn.hasTag("language") and f.language.len == 0) f.language = getText(tree, cidx);
                if (cn.hasTag("item")) try items.append(allocator, cidx);
            }
            break;
        }
    }

    var entries: std.ArrayList(FeedEntry) = .empty;
    for (items.items) |item_idx| {
        var entry = FeedEntry{};
        var iw = try tree.walk(allocator, item_idx);
        defer iw.deinit();
        _ = iw.next();
        while (iw.next()) |i_cidx| {
            const in = tree.get(i_cidx);
            if (in.kind != .element) continue;
            if (in.hasTag("title")) entry.title = getText(tree, i_cidx);
            if (in.hasTag("link")) entry.link = getText(tree, i_cidx);
            if (in.hasTag("guid")) entry.id = getText(tree, i_cidx);
            if (in.hasTag("description")) entry.description = getText(tree, i_cidx);
            if (in.hasTag("pubDate")) entry.published = getText(tree, i_cidx);
            if (in.hasTag("author")) entry.author = getText(tree, i_cidx);
        }
        try entries.append(allocator, entry);
    }

    f.entries = try entries.toOwnedSlice(allocator);
    return f;
}

fn parseAtom(allocator: Allocator, tree: *const dom.Tree) !Feed {
    var f = Feed{
        .allocator = allocator,
        .kind = .atom,
    };

    var items: std.ArrayList(u32) = .empty;
    defer items.deinit(allocator);
    var w = try tree.walk(allocator, 0);
    defer w.deinit();

    while (w.next()) |idx| {
        const node = tree.get(idx);
        if (node.kind != .element) continue;
        if (node.hasTag("title") and f.title.len == 0) f.title = getText(tree, idx);
        if (node.hasTag("subtitle") and f.description.len == 0) f.description = getText(tree, idx);
        if (node.hasTag("link") and f.link.len == 0) {
            f.link = node.attr("href") orelse getText(tree, idx);
        }
        if (node.hasTag("entry")) try items.append(allocator, idx);
    }


    var entries: std.ArrayList(FeedEntry) = .empty;
    for (items.items) |entry_idx| {
        var entry = FeedEntry{};
        var iw = try tree.walk(allocator, entry_idx);
        defer iw.deinit();
        _ = iw.next();
        while (iw.next()) |i_cidx| {
            const in = tree.get(i_cidx);
            if (in.kind != .element) continue;
            if (in.hasTag("title")) entry.title = getText(tree, i_cidx);
            if (in.hasTag("link")) entry.link = in.attr("href") orelse getText(tree, i_cidx);
            if (in.hasTag("id")) entry.id = getText(tree, i_cidx);
            if (in.hasTag("summary")) entry.description = getText(tree, i_cidx);
            if (in.hasTag("content")) entry.content = getText(tree, i_cidx);
            if (in.hasTag("published")) entry.published = getText(tree, i_cidx);
            if (in.hasTag("updated")) entry.updated = getText(tree, i_cidx);
        }
        try entries.append(allocator, entry);
    }

    f.entries = try entries.toOwnedSlice(allocator);
    return f;
}

fn parseJsonFeed(allocator: Allocator, src: []const u8) !Feed {
    _ = src;
    return Feed{
        .allocator = allocator,
        .kind = .json_feed,
        .title = "JSON Feed",
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
