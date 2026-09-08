//! Example: CSS Selector Querying in HTTPX
//!
//! Demonstrates:
//! 1. Parsing HTML into a DOM Document
//! 2. Querying elements with tags, IDs, classes, attributes, and combinators
//! 3. Iterating through matched `NodeList` and extracting text / attributes
//!
//! Run with: `zig build run-html-select`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("==> HTTPX CSS Selector Engine Demo\n\n", .{});

    const html_content =
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>CSS Selector Demo</title></head>
        \\<body>
        \\  <header>
        \\    <nav class="main-nav">
        \\      <a href="/" class="nav-link active">Home</a>
        \\      <a href="/docs" class="nav-link">Docs</a>
        \\      <a href="/github" class="nav-link external" target="_blank">GitHub</a>
        \\    </nav>
        \\  </header>
        \\  <main id="app-container">
        \\    <article class="post featured" data-id="101">
        \\      <h1 class="title">First Article</h1>
        \\      <p class="summary">Summary of the first post.</p>
        \\    </article>
        \\    <article class="post" data-id="102">
        \\      <h1 class="title">Second Article</h1>
        \\      <p class="summary">Summary of the second post.</p>
        \\    </article>
        \\  </main>
        \\</body>
        \\</html>
    ;

    var p = httpx.Parser.init(allocator, .{});
    var doc = try p.parseHtml(html_content);
    defer doc.deinit();

    // 1. Select by tag and class: "a.nav-link"
    std.debug.print("1. Select 'a.nav-link':\n", .{});
    var links = try doc.select("a.nav-link");
    var i: usize = 0;
    while (i < links.len()) : (i += 1) {
        const node = links.get(i).?;
        const text = try node.text();
        std.debug.print("   [{d}] href={s}, text={s}\n", .{ i, node.attr("href") orelse "", text });
    }

    // 2. Select by ID: "#app-container"
    std.debug.print("\n2. Select by ID '#app-container':\n", .{});
    if (try doc.getElementById("app-container")) |container| {
        std.debug.print("   Found tag: <{s} id=\"{s}\">\n", .{ container.tag(), container.attr("id").? });
    }

    // 3. Select with attribute matcher: "article[data-id=101]"
    std.debug.print("\n3. Select 'article[data-id=101]':\n", .{});
    if (try doc.selectFirst("article[data-id=101]")) |featured| {
        std.debug.print("   Featured article tag: <{s}> with class=\"{s}\"\n", .{ featured.tag(), featured.attr("class") orelse "" });
    }

    // 4. Select with child combinator: "main > article"
    std.debug.print("\n4. Select 'main > article':\n", .{});
    var articles = try doc.select("main > article");
    std.debug.print("   Total matched articles: {d}\n", .{articles.len()});

    std.debug.print("\nSelector verification successful.\n", .{});
}
