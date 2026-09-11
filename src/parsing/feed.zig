//! RSS 2.0, Atom 1.0, and JSON Feed parser.
//!
//! XML feeds use the native DOM engine. JSON Feed documents are parsed
//! through the internal Tree-sitter JSON grammar (syntax tree, error
//! recovery surface); feed semantics (field mapping) stay in HTTPX.
//! Tree-sitter never leaks through this API.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("dom.zig");
const xml = @import("xml.zig");
const ts = @import("treesitter");

fn parseJsonTree(allocator: Allocator, src: []const u8) !ts.Tree {
    var parser = ts.Parser.init(allocator);
    defer parser.deinit();
    parser.setLanguage(ts.json_language) catch return error.InvalidFeed;
    return parser.parseString(src) catch return error.InvalidFeed;
}

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
    const is_json = if (contentType) |ct| std.mem.indexOf(u8, ct, "json") != null else std.mem.startsWith(u8, std.mem.trim(u8, src, " \t\r\n"), "{");
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
    for (items.items) |entryIdx| {
        var entry = FeedEntry{};
        var iw = try tree.walk(allocator, entryIdx);
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
    // Syntax layer: Tree-sitter JSON grammar via the internal adapter.
    // Malformed documents fail here with a clean error instead of
    // partial garbage. std.json is NOT used here: the syntax tree gives
    // structural positions + error recovery surface for feed validation.
    var tree = parseJsonTree(allocator, src) catch return error.InvalidFeed;
    defer tree.deinit();
    if (tree.hasError()) return error.InvalidFeed;

    const root = unwrapValue(tree.rootNode()) orelse return error.InvalidFeed;
    if (!std.mem.eql(u8, root.nodeType(), "object")) return error.InvalidFeed;

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
    if (try objField(allocator, &owned, root, "items")) |items_val| {
        const arr = unwrapValue(items_val) orelse return error.InvalidFeed;
        if (!std.mem.eql(u8, arr.nodeType(), "array")) return error.InvalidFeed;
        // Collect element objects, descending through `elements`/`value`
        // wrappers. Non-object elements are ignored, not fatal.
        var work = std.ArrayList(ts.Node).empty;
        defer work.deinit(allocator);
        try work.append(allocator, arr);
        while (work.pop()) |cur| {
            const t = cur.nodeType();
            if (std.mem.eql(u8, t, "object")) {
                try appendJsonEntry(allocator, &owned, &entries, cur);
                continue;
            }
            if (std.mem.eql(u8, t, "value") or std.mem.eql(u8, t, "elements") or std.mem.eql(u8, t, "array")) {
                // Push reversed so pops come out in document order.
                var i: u32 = cur.namedChildCount();
                while (i > 0) {
                    i -= 1;
                    const c = cur.namedChild(i) orelse continue;
                    try work.append(allocator, c);
                }
            }
        }
    }

    f.entries = try entries.toOwnedSlice(allocator);
    f.owned = try owned.toOwnedSlice(allocator);
    return f;
}

/// Maps one JSON Feed item object onto a FeedEntry.
fn appendJsonEntry(allocator: Allocator, owned: *std.ArrayList([]const u8), entries: *std.ArrayList(FeedEntry), obj: ts.Node) !void {
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
    if (try objField(allocator, owned, obj, "author")) |author_val| {
        if (try authorName(allocator, owned, author_val)) |v| entry.author = v;
    }
    try entries.append(allocator, entry);
}

/// Descends through single-child wrapper nodes (`value`, `program`) to
/// the significant node. Concrete nodes (object, array, string, number,
/// literals) are returned as-is, so this is safe whether or not the
/// grammar elides unit productions.
fn unwrapValue(n: ts.Node) ?ts.Node {
    var cur = n;
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        const t = cur.nodeType();
        if (std.mem.eql(u8, t, "value") or std.mem.eql(u8, t, "program")) {
            if (cur.namedChildCount() != 1) return null;
            cur = cur.namedChild(0) orelse return null;
            continue;
        }
        return cur;
    }
    return null;
}

/// Finds the value node for `name` among the DIRECT pairs of a JSON
/// object. Descends through `members` wrapper nodes only — never into
/// nested values — so an item field can never shadow a top-level field.
/// Heap-allocated work stack: no depth limit on legitimate documents.
fn objField(allocator: Allocator, owned: *std.ArrayList([]const u8), obj: ts.Node, name: []const u8) !?ts.Node {
    if (!std.mem.eql(u8, obj.nodeType(), "object")) return null;
    var stack = std.ArrayList(ts.Node).empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, obj);
    while (stack.pop()) |cur| {
        // Named children pushed reversed so matches resolve in document
        // order (first occurrence wins, like the RSS/Atom paths).
        var i: u32 = cur.namedChildCount();
        while (i > 0) {
            i -= 1;
            const c = cur.namedChild(i) orelse continue;
            const t = c.nodeType();
            if (std.mem.eql(u8, t, "pair")) {
                // Pairs are leaves for this search; check immediately.
                if (try pairKeyMatches(allocator, owned, c, name)) {
                    return pairValue(c);
                }
            } else if (std.mem.eql(u8, t, "members")) {
                try stack.append(allocator, c);
            }
        }
    }
    return null;
}

/// Key comparison: raw inner text, falling back to unescaped comparison
/// for keys containing escapes (temporary buffer, freed immediately).
fn pairKeyMatches(allocator: Allocator, owned: *std.ArrayList([]const u8), pair: ts.Node, name: []const u8) !bool {
    const k = pair.childByFieldName("key") orelse return false;
    const kt = k.text();
    if (kt.len < 2 or kt[0] != '"' or kt[kt.len - 1] != '"') return false;
    const inner = kt[1 .. kt.len - 1];
    if (std.mem.indexOfScalar(u8, inner, '\\') == null) return std.mem.eql(u8, inner, name);
    const un = try unescapeJsonString(allocator, inner);
    defer allocator.free(un);
    _ = owned;
    return std.mem.eql(u8, un, name);
}

/// Pair value: field API first, positional fallback.
fn pairValue(pair: ts.Node) ?ts.Node {
    if (pair.childByFieldName("value")) |v| return v;
    if (pair.namedChildCount() >= 2) return pair.namedChild(1);
    return null;
}

/// Reads an object string field. Returns null when absent or not a string.
/// Every value is allocator-owned (tracked in `owned`) because node text
/// borrows tree memory that dies with the tree.
fn objString(allocator: Allocator, owned: *std.ArrayList([]const u8), obj: ts.Node, name: []const u8) !?[]const u8 {
    const v = (try objField(allocator, owned, obj, name)) orelse return null;
    const val = unwrapValue(v) orelse return null;
    if (!std.mem.eql(u8, val.nodeType(), "string")) return null;
    return try jsonString(allocator, owned, val);
}

/// Extracts author name from an object (`{"name": ...}`) or the first
/// element of an author array (JSON Feed 1.1).
fn authorName(allocator: Allocator, owned: *std.ArrayList([]const u8), v: ts.Node) !?[]const u8 {
    const val = unwrapValue(v) orelse return null;
    if (std.mem.eql(u8, val.nodeType(), "object")) {
        return objString(allocator, owned, val, "name");
    }
    if (std.mem.eql(u8, val.nodeType(), "array")) {
        // First element object, descending through `elements` wrappers.
        var work = std.ArrayList(ts.Node).empty;
        defer work.deinit(allocator);
        try work.append(allocator, val);
        while (work.pop()) |cur| {
            const t = cur.nodeType();
            if (std.mem.eql(u8, t, "object")) {
                if (try objString(allocator, owned, cur, "name")) |got| return got;
                continue;
            }
            if (std.mem.eql(u8, t, "value") or std.mem.eql(u8, t, "elements") or std.mem.eql(u8, t, "array")) {
                var i: u32 = cur.namedChildCount();
                while (i > 0) {
                    i -= 1;
                    const c = cur.namedChild(i) orelse continue;
                    try work.append(allocator, c);
                }
            }
        }
        return null;
    }
    return null;
}

/// JSON string value: strips quotes, unescapes when needed.
/// The syntax tree owns a private copy of the source that dies with the
/// tree, so every extracted string is duped here (tracked in `owned`).
fn jsonString(allocator: Allocator, owned: *std.ArrayList([]const u8), node: ts.Node) ![]const u8 {
    const t = node.text();
    if (t.len < 2 or t[0] != '"' or t[t.len - 1] != '"') return error.InvalidFeed;
    const inner = t[1 .. t.len - 1];
    const out = if (std.mem.indexOfScalar(u8, inner, '\\') == null)
        try allocator.dupe(u8, inner)
    else
        try unescapeJsonString(allocator, inner);
    errdefer allocator.free(out);
    try owned.append(allocator, out);
    return out;
}

/// JSON string unescaping (RFC 8259 Section 7), including surrogate pairs.
fn unescapeJsonString(allocator: Allocator, inner: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < inner.len) {
        const c = inner[i];
        if (c != '\\') {
            if (c < 0x20) return error.InvalidFeed; // raw control characters
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= inner.len) return error.InvalidFeed;
        switch (inner[i]) {
            '"' => try out.append(allocator, '"'),
            '\\' => try out.append(allocator, '\\'),
            '/' => try out.append(allocator, '/'),
            'b' => try out.append(allocator, 0x08),
            'f' => try out.append(allocator, 0x0C),
            'n' => try out.append(allocator, '\n'),
            'r' => try out.append(allocator, '\r'),
            't' => try out.append(allocator, '\t'),
            'u' => {
                if (i + 4 >= inner.len) return error.InvalidFeed;
                const hi = hex4(inner[i + 1 ..][0..4]) orelse return error.InvalidFeed;
                i += 4;
                var cp: u21 = hi;
                if (hi >= 0xD800 and hi <= 0xDBFF) {
                    // High surrogate: expect a low surrogate escape.
                    // Next escape occupies inner[i+1..i+7]; require it fully.
                    if (i + 6 >= inner.len or inner[i + 1] != '\\' or inner[i + 2] != 'u') {
                        cp = 0xFFFD;
                    } else {
                        const lo = hex4(inner[i + 3 ..][0..4]) orelse return error.InvalidFeed;
                        if (lo < 0xDC00 or lo > 0xDFFF) return error.InvalidFeed;
                        cp = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
                        i += 6; // land on the last low-surrogate digit; loop steps past it
                    }
                } else if (hi >= 0xDC00 and hi <= 0xDFFF) {
                    cp = 0xFFFD;
                }
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch {
                    const rp = std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
                    try out.appendSlice(allocator, buf[0..rp]);
                    i += 1;
                    continue;
                };
                try out.appendSlice(allocator, buf[0..n]);
            },
            else => return error.InvalidFeed,
        }
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn hex4(digits: []const u8) ?u21 {
    var v: u21 = 0;
    for (digits) |c| {
        v = (v << 4) | switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
    }
    return v;
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

test "json feed parses title, link, and items via tree-sitter" {
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
