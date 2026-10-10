# Example: Parse Html

Demonstrates parseHtml.zig using the canonical HTTPX API.

## Complete Example

```zig
//! Example: HTML/XML/Feed/Robots/Sitemap parsing with httpx.zig
//!
//! Demonstrates the full parsing API:
//!   * Unified `httpx.Parser.init(allocator, .{})` instance
//!   * Parser `parseHtml`, `parseXml`, `parseFeed`, `parseRobots`, `parseSitemap`
//!   * Direct dot-notation access on parsed elements and collections
//!   * Clean lifecycle: `doc.deinit()` frees all extracted structures and nodes
//!
//! Run with:
//!   zig build run-parse-html

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n==> httpx.zig Unified Parsing & Inspection Subsystem Demo\n\n", .{});

    // 1. Initialize the unified Parser instance with the allocator once
    var p = httpx.Parser.init(allocator, .{});

    // 1. HTML Parsing & DOM Inspection
    std.debug.print("1. HTML Parsing & DOM Inspection\n", .{});

    const htmlSrc =
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <title>httpx Parsing Demo</title>
        \\  <meta name="description" content="A demo of httpx parsing">
        \\  <meta property="og:title" content="httpx Demo">
        \\  <meta property="og:image" content="https://example.com/img.png">
        \\  <link rel="canonical" href="https://example.com/demo">
        \\  <link rel="stylesheet" href="/styles.css">
        \\  <link rel="stylesheet" href="/extra.css" media="print">
        \\</head>
        \\<body>
        \\  <header>
        \\    <nav>
        \\      <a href="/" title="Home">Home</a>
        \\      <a href="/about">About</a>
        \\      <a href="/blog" rel="nofollow">Blog</a>
        \\    </nav>
        \\  </header>
        \\  <main id="content">
        \\    <h1 class="hero-title">Welcome to httpx</h1>
        \\    <p class="lead">The batteries-included Zig networking library.</p>
        \\    <p>Version <strong>0.2.0</strong> is out now!</p>
        \\    <img src="logo.png" alt="httpx logo" width="200" height="100">
        \\    <img src="banner.jpg" alt="Banner">
        \\    <form action="/search" method="get">
        \\      <input type="text" name="q" placeholder="Search...">
        \\      <select name="category">
        \\        <option value="all">All</option>
        \\        <option value="docs">Docs</option>
        \\      </select>
        \\      <button type="submit" name="go">Search</button>
        \\    </form>
        \\  </main>
        \\  <script src="/app.js" defer></script>
        \\  <script src="/analytics.js" async></script>
        \\</body>
        \\</html>
    ;

    var doc = try p.parseHtml(htmlSrc);
    defer doc.deinit();

    // Title
    const title = try doc.title();
    std.debug.print("  Title: {s}\n", .{title});

    // Metadata
    const meta = try doc.metadata();
    std.debug.print("  Description: {s}\n", .{meta.description});
    std.debug.print("  OG title: {s}\n", .{meta.ogTitle});
    std.debug.print("  OG image: {s}\n", .{meta.ogImage});
    std.debug.print("  Canonical: {s}\n", .{meta.canonical});
    std.debug.print("  Language: {s}\n", .{meta.language});

    // Links
    const lnks = try doc.links();
    std.debug.print("  Links ({d}):\n", .{lnks.len});
    for (lnks) |lnk| {
        std.debug.print("    [{s}] {s} (text: {s})\n", .{ lnk.source, lnk.href, lnk.text });
    }

    // Images
    const imgs = try doc.images();
    std.debug.print("  Images ({d}):\n", .{imgs.len});
    for (imgs) |img| {
        std.debug.print("    src={s} alt={s}\n", .{ img.src, img.alt });
    }

    // Forms
    const frms = try doc.forms();
    std.debug.print("  Forms ({d}):\n", .{frms.len});
    for (frms) |frm| {
        std.debug.print("    action={s} method={s} fields={d}\n", .{ frm.action, frm.method, frm.fields.len });
    }

    // Stylesheets & Scripts
    const sheets = try doc.stylesheets();
    std.debug.print("  Stylesheets ({d})\n", .{sheets.len});

    const scrs = try doc.scripts();
    std.debug.print("  Scripts ({d})\n", .{scrs.len});

    // CSS Selectors
    std.debug.print("\n  CSS Selectors:\n", .{});
    var navLinks = try doc.select("nav a");
    defer navLinks.deinit();
    std.debug.print("  nav a  -> {d} elements\n", .{navLinks.len()});

    if (try doc.selectFirst("h1.hero-title")) |h1| {
        std.debug.print("  h1.hero-title: tag=<{s}>, text=\"{s}\"\n", .{ h1.tag(), try h1.text() });
    }

    // 2. RSS Feed Parsing
    std.debug.print("\n2. RSS Feed Parsing\n", .{});
    const rssSrc =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<rss version="2.0">
        \\  <channel>
        \\    <title>httpx Blog</title>
        \\    <link>https://httpx.zig/blog</link>
        \\    <description>Updates from httpx.zig</description>
        \\    <item>
        \\      <title>Version 0.2.0 Released</title>
        \\      <link>https://httpx.zig/blog/v0.2.0</link>
        \\      <description>Native DOM engine and parsing lands in Zig!</description>
        \\    </item>
        \\  </channel>
        \\</rss>
    ;

    var feed = try p.parseFeed(rssSrc, "application/rss+xml");
    defer feed.deinit();
    std.debug.print("  Feed Title: {s}\n", .{feed.title});
    std.debug.print("  Feed Link:  {s}\n", .{feed.link});
    std.debug.print("  Entries ({d}):\n", .{feed.entries.len});
    for (feed.entries) |entry| {
        std.debug.print("    - {s}: {s}\n", .{ entry.title, entry.link });
    }

    // 3. robots.txt Parsing
    std.debug.print("\n3. robots.txt Parsing\n", .{});
    const robotsSrc =
        \\User-agent: *
        \\Disallow: /admin/
        \\Disallow: /private/
        \\Allow: /admin/public/
        \\Sitemap: https://httpx.zig/sitemap.xml
    ;

    var r = try p.parseRobots(robotsSrc);
    defer r.deinit();
    std.debug.print("  Allowed '/' ? {}\n", .{r.isAllowed("MyBot", "/")});
    std.debug.print("  Allowed '/admin/dashboard' ? {}\n", .{r.isAllowed("MyBot", "/admin/dashboard")});
    std.debug.print("  Allowed '/admin/public/login' ? {}\n", .{r.isAllowed("MyBot", "/admin/public/login")});
    std.debug.print("  Sitemaps found: {d}\n", .{r.sitemaps.len});

    // 4. XML Sitemap Parsing
    std.debug.print("\n4. XML Sitemap Parsing\n", .{});
    const sitemapSrc =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        \\  <url>
        \\    <loc>https://httpx.zig/</loc>
        \\    <lastmod>2026-08-30</lastmod>
        \\    <changefreq>daily</changefreq>
        \\    <priority>1.0</priority>
        \\  </url>
        \\  <url>
        \\    <loc>https://httpx.zig/docs</loc>
        \\    <changefreq>weekly</changefreq>
        \\    <priority>0.8</priority>
        \\  </url>
        \\</urlset>
    ;

    var sm = try p.parseSitemap(sitemapSrc);
    defer sm.deinit();
    std.debug.print("  Sitemap URLs ({d}):\n", .{sm.urls.len});
    for (sm.urls) |u| {
        std.debug.print("    loc={s} lastMod={s} prio={d:.1}\n", .{ u.loc, u.lastMod, u.priority orelse 0.0 });
    }

    std.debug.print("\nAll parsing tests and demonstrations completed successfully.\n", .{});
}
```

## Expected Output

```text
==> httpx.zig Unified Parsing & Inspection Subsystem Demo

1. HTML Parsing & DOM Inspection
  Title: httpx Parsing Demo
  Description: A demo of httpx parsing
  OG title: httpx Demo
  OG image: https://example.com/img.png
  Canonical: https://example.com/demo
  Language: en
  Links (3):
    [nav] / (text: Home)
    [nav] /about (text: About)
    [nav] /blog (text: Blog)
  Images (2):
    src=logo.png alt=httpx logo
    src=banner.jpg alt=Banner
  Forms (1):
    action=/search method=get fields=3
  Stylesheets (2)
  Scripts (2)

  CSS Selectors:
  nav a  -> 3 elements
  h1.hero-title: tag=<h1>, text="Welcome to httpx"

2. RSS Feed Parsing
  Feed Title: httpx Blog
  Feed Link:  https://httpx.zig/blog
  Entries (1):
    - Version 0.2.0 Released: https://httpx.zig/blog/v0.2.0

3. robots.txt Parsing
  Allowed '/' ? true
  Allowed '/admin/dashboard' ? false
  Allowed '/admin/public/login' ? true
  Sitemaps found: 1

4. XML Sitemap Parsing
  Sitemap URLs (2):
    loc=https://httpx.zig/ lastMod=2026-08-30 prio=1.0
    loc=https://httpx.zig/docs lastMod= prio=0.8

All parsing tests and demonstrations completed successfully.
```

Counts, URLs, titles, and boolean results follow the embedded demo inputs above; they vary only if those inputs change.

## How to Run

```bash
zig build run-parse-html
```

## Related

* [Getting Started](/guide/getting-started)
* [All Examples](/examples/)
