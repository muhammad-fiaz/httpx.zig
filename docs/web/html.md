# HTML & Document Parsing

HTTPX provides high-performance, structured HTML and XML document parsing, DOM manipulation, and CSS selector inspection.

> [!NOTE]
> HTTPX parses HTML/XML with its bundled DOM engine, built on Tree-sitter grammars in `parsing/html.zig` and `parsing/xml.zig`. Tree-sitter also backs the JSON Feed syntax layer, the template syntax layer, and the shared incremental-edit vocabulary (`Point`/`SourceRange`/`TextEdit`). Applications normally interact only with HTTPX's HTML/document APIs (`httpx.parsing.Parser`, `response.html()`, `doc.select()`). Applications do not need to install or import Tree-sitter directly.

## Parsing Documents

Parse HTML directly from an HTTP response or from a string using `httpx.parsing.Parser`:

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const html_content =
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>My Website</title></head>
        \\<body>
        \\  <div class="container">
        \\    <h1 id="header">Welcome to HTTPX</h1>
        \\    <a href="https://github.com" class="link">GitHub</a>
        \\  </div>
        \\</body>
        \\</html>
    ;

    var parser = httpx.parsing.Parser.init(allocator, .{});
    var doc = try parser.parseHtml(html_content);
    defer doc.deinit();

    // Query title, body text, or links
    const title = try doc.title();
    std.debug.print("Title: {s}\n", .{title});

    // CSS Selector query
    var headers = try doc.select("#header");
    defer headers.deinit();
    var i: usize = 0;
    while (i < headers.len()) : (i += 1) {
        const h = headers.get(i).?;
        std.debug.print("Header text: {s}\n", .{try h.text()});
    }

    var links = try doc.select("a.link");
    defer links.deinit();
    var j: usize = 0;
    while (j < links.len()) : (j += 1) {
        const l = links.get(j).?;
        std.debug.print("Href: {s}\n", .{l.attr("href") orelse ""});
    }
}
```

## Direct Response Parsing

When executing HTTP requests, responses can be parsed directly into an HTML document with `response.html()`:

```zig
var client = httpx.Client.init(allocator, io, .{});
defer client.deinit();

var response = try client.get("https://httpbun.com/html", .{});
defer response.deinit();

var doc = try response.html();
defer doc.deinit();

std.debug.print("Title: {s}\n", .{try doc.title()});

const links = try doc.links();
for (links) |link| {
    std.debug.print("Link: {s} -> {s}\n", .{ link.text, link.href });
}
```

## Supported Selectors

* Tag names: `div`, `p`, `h1`
* Class names: `.card`, `.button-primary`, `div.container`
* IDs: `#main-nav`, `#submit-button`, `h1#header`
* Attribute matching: `[target="_blank"]`, `[href]`, `[class*="active"]`
* Descendant combinator: `div.container p`
* Child combinator: `ul > li`
* Selector lists: `h1, h2, h3`

## Incremental Document Updates

For live-reloading and development mode, HTTPX runs Tree-sitter incremental reparses (`htmlLanguage` in `parsing/html.zig`) to obtain structurally changed ranges; `Document.incrementalUpdate` rebuilds the DOM from the new syntax tree. The file watcher (`web/watcher`) uses the same incremental analysis plus template dependency tracking for targeted cache invalidation.

## Related

* [API: Response](/api/response)
* [Example: Parse HTML](/examples/parse-html)
* [Web: Live Reload & Watcher](/web/static-files)

