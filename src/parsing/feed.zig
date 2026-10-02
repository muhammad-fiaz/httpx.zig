//! RSS 2.0, Atom 1.0, and JSON Feed parser.
//!
//! XML feeds use the native DOM engine. JSON Feed documents are parsed
//! with `std.json`; feed semantics (field mapping) stay in HTTPX.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("dom.zig");
const xml = @import("xml.zig");

pub const FeedKind = enum { rss, atom, jsonFeed, unknown };

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
    /// Owned strings (JSON field values are duped because syntax-tree text
    /// borrows tree memory that dies with the tree; RSS/Atom field slices
    /// borrow the caller's source buffer instead).
    owned: [][]const u8 = &.{},

    pub fn deinit(self: *Feed) void {
        for (self.owned) |s| self.allocator.free(s);
        if (self.owned.len > 0) self.allocator.free(self.owned);
        self.allocator.free(self.entries);
    }
};

pub fn parse(allocator: Allocator, src: []const u8, contentType: ?[]const u8) !Feed {
    const isJson = if (contentType) |ct| std.mem.indexOf(u8, ct, "json") != null else std.mem.startsWith(u8, std.mem.trim(u8, src, " \t\r\n"), "{");
    if (isJson) {
        return parseJsonFeed(allocator, src);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const al = arena.allocator();

    var tree = try xml.parse(al, src, .{});
    defer tree.deinit(al);

    var rssNodes: std.ArrayList(u32) = .empty;
    try tree.getElementsByTag(al, 0, "rss", &rssNodes);
    if (rssNodes.items.len > 0) return parseRss(allocator, &tree);

    var feedNodes: std.ArrayList(u32) = .empty;
    try tree.getElementsByTag(al, 0, "feed", &feedNodes);
    if (feedNodes.items.len > 0) return parseAtom(allocator, &tree);

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
    for (items.items) |itemIdx| {
        var entry = FeedEntry{};
        var iw = try tree.walk(allocator, itemIdx);
        defer iw.deinit();
        _ = iw.next();
        while (iw.next()) |iCidx| {
            const in = tree.get(iCidx);
            if (in.kind != .element) continue;
            if (in.hasTag("title")) entry.title = getText(tree, iCidx);
            if (in.hasTag("link")) entry.link = getText(tree, iCidx);
            if (in.hasTag("guid")) entry.id = getText(tree, iCidx);
            if (in.hasTag("description")) entry.description = getText(tree, iCidx);
            if (in.hasTag("pubDate")) entry.published = getText(tree, iCidx);
            if (in.hasTag("author")) entry.author = getText(tree, iCidx);
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
    for (items.items) |entryIdx| {
        var entry = FeedEntry{};
        var iw = try tree.walk(allocator, entryIdx);
        defer iw.deinit();
        _ = iw.next();
        while (iw.next()) |iCidx| {
            const in = tree.get(iCidx);
            if (in.kind != .element) continue;
            if (in.hasTag("title")) entry.title = getText(tree, iCidx);
            if (in.hasTag("link")) entry.link = in.attr("href") orelse getText(tree, iCidx);
            if (in.hasTag("id")) entry.id = getText(tree, iCidx);
            if (in.hasTag("summary")) entry.description = getText(tree, iCidx);
            if (in.hasTag("content")) entry.content = getText(tree, iCidx);
            if (in.hasTag("published")) entry.published = getText(tree, iCidx);
            if (in.hasTag("updated")) entry.updated = getText(tree, iCidx);
        }
        try entries.append(allocator, entry);
    }

    f.entries = try entries.toOwnedSlice(allocator);
    return f;
}

fn parseJsonFeed(allocator: Allocator, src: []const u8) !Feed {
    // std.json rejects a malformed document outright, which is what a feed
    // consumer wants: no partial garbage from a broken document.
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, src, .{}) catch return error.InvalidFeed;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidFeed;

    var owned = std.ArrayList([]const u8).empty;
    errdefer {
        for (owned.items) |s| allocator.free(s);
        owned.deinit(allocator);
    }

    var f = Feed{ .allocator = allocator, .kind = .jsonFeed };
    if (try objString(allocator, &owned, root, "title")) |v| f.title = v;
    if (try objString(allocator, &owned, root, "description")) |v| f.description = v;
    if (try objString(allocator, &owned, root, "language")) |v| f.language = v;
    if (try objString(allocator, &owned, root, "home_page_url")) |v| {
        f.link = v;
    } else if (try objString(allocator, &owned, root, "feed_url")) |v| {
        f.link = v;
    }

    var entries = std.ArrayList(FeedEntry).empty;
    errdefer entries.deinit(allocator);
    if (objField(root, "items")) |itemsVal| {
        // Non-array items are ignored, not fatal, matching the XML paths.
        if (itemsVal == .array) {
            for (itemsVal.array.items) |item| {
                if (item == .object) try appendJsonEntry(allocator, &owned, &entries, item);
            }
        }
    }

    f.entries = try entries.toOwnedSlice(allocator);
    f.owned = try owned.toOwnedSlice(allocator);
    return f;
}

/// Maps one JSON Feed item object onto a FeedEntry.
fn appendJsonEntry(allocator: Allocator, owned: *std.ArrayList([]const u8), entries: *std.ArrayList(FeedEntry), obj: std.json.Value) !void {
    var entry = FeedEntry{};
    if (try objString(allocator, owned, obj, "title")) |v| entry.title = v;
    if (try objString(allocator, owned, obj, "url")) |v| entry.link = v;
    if (try objString(allocator, owned, obj, "id")) |v| entry.id = v;
    if (try objString(allocator, owned, obj, "summary")) |v| entry.description = v;
    if (try objString(allocator, owned, obj, "content_text")) |v| {
        entry.content = v;
    } else if (try objString(allocator, owned, obj, "content_html")) |v| {
        entry.content = v;
    }
    if (try objString(allocator, owned, obj, "date_published")) |v| entry.published = v;
    if (try objString(allocator, owned, obj, "date_modified")) |v| entry.updated = v;
    if (objField(obj, "author")) |authorVal| {
        if (try authorName(allocator, owned, authorVal)) |v| entry.author = v;
    }
    try entries.append(allocator, entry);
}

/// The value for `name` among the DIRECT keys of a JSON object, so an item
/// field can never shadow a top-level field. First occurrence wins.
fn objField(obj: std.json.Value, name: []const u8) ?std.json.Value {
    const o = switch (obj) {
        .object => |o| o,
        else => return null,
    };
    return o.get(name);
}

/// JSON Feed `author` is an object with `name`, a bare string, or - per the
/// spec's "one or more authors" wording - an array of either. The first
/// author that yields a name wins.
fn authorName(allocator: Allocator, owned: *std.ArrayList([]const u8), v: std.json.Value) !?[]const u8 {
    switch (v) {
        .string => |s| return try keep(allocator, owned, s),
        .object => return objString(allocator, owned, v, "name"),
        .array => |arr| {
            for (arr.items) |item| {
                if (try authorName(allocator, owned, item)) |name| return name;
            }
            return null;
        },
        else => return null,
    }
}

fn objString(allocator: Allocator, owned: *std.ArrayList([]const u8), obj: std.json.Value, name: []const u8) !?[]const u8 {
    const v = objField(obj, name) orelse return null;
    return switch (v) {
        .string => |s| try keep(allocator, owned, s),
        else => null,
    };
}

/// Copies `s` into the feed's owned buffer so the parsed document can be
/// freed while the feed stays valid.
fn keep(allocator: Allocator, owned: *std.ArrayList([]const u8), s: []const u8) ![]const u8 {
    const copy = try allocator.dupe(u8, s);
    errdefer allocator.free(copy);
    try owned.append(allocator, copy);
    return copy;
}

/// First text or CDATA child of an element, trimmed. Used by the XML paths.
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

test "json feed parses title, link, and items" {
    const a = std.testing.allocator;
    const src =
        \\{
        \\  "version": "https://jsonfeed.org/version/1.1",
        \\  "title": "Caf\u00e9 \"News\"",
        \\  "home_page_url": "https://example.com/",
        \\  "feed_url": "https://example.com/feed.json",
        \\  "description": "A demo feed",
        \\  "language": "en",
        \\  "items": [
        \\    {
        \\      "id": "1",
        \\      "url": "https://example.com/1",
        \\      "title": "First",
        \\      "summary": "Summary one",
        \\      "content_text": "Body one",
        \\      "date_published": "2026-09-01T00:00:00Z",
        \\      "date_modified": "2026-09-02T00:00:00Z",
        \\      "author": { "name": "Ada" }
        \\    },
        \\    {
        \\      "id": "2",
        \\      "title": "Second",
        \\      "content_html": "<p>Body two</p>",
        \\      "author": [{ "name": "Grace" }, { "name": "Alan" }]
        \\    }
        \\  ]
        \\}
    ;
    var f = try parse(a, src, "application/feed+json");
    defer f.deinit();
    try std.testing.expectEqual(FeedKind.jsonFeed, f.kind);
    try std.testing.expectEqualStrings("Café \"News\"", f.title);
    try std.testing.expectEqualStrings("https://example.com/", f.link);
    try std.testing.expectEqualStrings("A demo feed", f.description);
    try std.testing.expectEqualStrings("en", f.language);
    try std.testing.expectEqual(@as(usize, 2), f.entries.len);
    try std.testing.expectEqualStrings("First", f.entries[0].title);
    try std.testing.expectEqualStrings("https://example.com/1", f.entries[0].link);
    try std.testing.expectEqualStrings("1", f.entries[0].id);
    try std.testing.expectEqualStrings("Summary one", f.entries[0].description);
    try std.testing.expectEqualStrings("Body one", f.entries[0].content);
    try std.testing.expectEqualStrings("2026-09-01T00:00:00Z", f.entries[0].published);
    try std.testing.expectEqualStrings("2026-09-02T00:00:00Z", f.entries[0].updated);
    try std.testing.expectEqualStrings("Ada", f.entries[0].author);
    try std.testing.expectEqualStrings("Second", f.entries[1].title);
    try std.testing.expectEqualStrings("<p>Body two</p>", f.entries[1].content);
    try std.testing.expectEqualStrings("Grace", f.entries[1].author);
    try std.testing.expectEqualStrings("", f.entries[1].link);
}

test "json feed tolerates missing fields and empty items" {
    const a = std.testing.allocator;
    var f = try parse(a, "{}", "application/json");
    defer f.deinit();
    try std.testing.expectEqual(FeedKind.jsonFeed, f.kind);
    try std.testing.expectEqualStrings("", f.title);
    try std.testing.expectEqual(@as(usize, 0), f.entries.len);

    var g = try parse(a, "{\"title\": \"T\", \"items\": []}", null);
    defer g.deinit();
    try std.testing.expectEqualStrings("T", g.title);
    try std.testing.expectEqual(@as(usize, 0), g.entries.len);
}

test "json feed rejects malformed input" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidFeed, parse(a, "{bad", "application/json"));
    try std.testing.expectError(error.InvalidFeed, parse(a, "[1, 2]", "application/json"));
    try std.testing.expectError(error.InvalidFeed, parse(a, "{\"a\": }", "application/json"));
}

test "json feed surrogate pairs decode to astral characters" {
    const a = std.testing.allocator;
    var f = try parse(a, "{\"title\": \"\\uD83D\\uDE00\", \"items\": []}", "application/json");
    defer f.deinit();
    try std.testing.expectEqualStrings("😀", f.title);
}

test "json feed tolerates numbers, null, booleans, and nested structures" {
    const a = std.testing.allocator;
    const src =
        \\{
        \\  "version": "https://jsonfeed.org/version/1.1",
        \\  "title": "Numbers",
        \\  "items": [
        \\    { "id": "n1", "title": "Has number", "x": 42, "y": 3.14, "z": null, "w": true, "v": false },
        \\    { "id": "n2", "title": "Nested", "author": { "name": "N", "extra": { "deep": [1, 2, {"x": 1}] } } },
        \\    "not-an-object",
        \\    42,
        \\    null
        \\  ]
        \\}
    ;
    var f = try parse(a, src, "application/json");
    defer f.deinit();
    // Only object elements become entries; scalars are ignored, not fatal.
    try std.testing.expectEqual(@as(usize, 2), f.entries.len);
    try std.testing.expectEqualStrings("Has number", f.entries[0].title);
    try std.testing.expectEqualStrings("n1", f.entries[0].id);
    try std.testing.expectEqualStrings("Nested", f.entries[1].title);
    try std.testing.expectEqualStrings("N", f.entries[1].author);
}
