# Parsing API

`httpx.parsing` provides parsers for HTML, XML, feeds, `robots.txt`, and
sitemaps. The client also exposes convenience methods for fetching these
documents.

## Fetch a document

```zig
var document = try client.html.fetch("https://example.com/", .{});
defer document.deinit();
```

The available client helpers are:

| Method | Result |
|---|---|
| `client.document.fetch(url, options)` | Auto-detected `Document` |
| `client.html.fetch(url, options)` | HTML `Document` |
| `client.xml.fetch(url, options)` | XML `Document` |
| `client.feed.fetch(url, options)` | `Feed` |
| `client.robots.fetch(url, options)` | `Robots` |
| `client.sitemap.fetch(url, options)` | `Sitemap` |

## Public parsing types

| Type | Purpose |
|---|---|
| `httpx.parsing.Document` | Parsed document tree |
| `httpx.parsing.Parser` | Configurable document parser |
| `httpx.parsing.Handle` | Node reference |
| `httpx.parsing.Nodes` | Node collection |
| `httpx.parsing.Kind` | Detected content kind |
| `httpx.parsing.Feed` | Parsed RSS or Atom feed |
| `httpx.parsing.Robots` | Parsed robots rules |
| `httpx.parsing.Sitemap` | Parsed sitemap |
| `httpx.parsing.Selector` | Parsed selector expression |

## Initialize a parser

```zig
var parser = httpx.parsing.init(allocator, .{});
```

Use `httpx.parsing.detectKind` when content type must be selected before
parsing. Parsed values own allocations made through the allocator supplied at
initialization.

## Related documentation

- [Parsing guide](/guide/parsing)
- [HTML and DOM](/web/html)
- [Response API](/api/response)
