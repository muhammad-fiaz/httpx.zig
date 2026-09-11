# Parsing Architecture & Tree-sitter Usage

HTTPX parses two fundamentally different kinds of input with two
different engines. This page documents where each lives and why.

## Tree-sitter usage

HTTPX uses Tree-sitter internally for structured-text edit vocabulary
(points, ranges, text edits) shared by the document/template/watcher
pipeline, so a future grammar can plug in without changing call sites.

Tree-sitter is intentionally hidden from the normal HTTPX API: user code
only needs `@import("httpx")`. Each parsing module imports the
`treesitter` dependency directly where Tree-sitter is the parsing
foundation (no shared wrapper): `src/parsing/html.zig` (HTML grammar),
`src/parsing/xml.zig` (XML grammar), `src/parsing/feed.zig` (JSON
grammar), `src/parsing/document.zig` (incremental edits, queries),
`src/web/templates/parser.zig` (template grammar), and
`src/web/watcher/reload.zig` + `src/web/watcher/backend.zig` (incremental analysis and event intake).

Used by:

- Templates — edit descriptors for development invalidation
  (`Document.computeEdit`, consumed by the dev watcher flow)
- HTML/document parsing — source positions for incremental updates
- Incremental development parsing — offsets/points shared with the watcher
- JSON Feed — syntax layer: the bundled JSON grammar parses the document
  into a syntax tree (`feed.zig` maps it onto feed semantics; malformed
  input fails closed, escapes/surrogates decode per RFC 8259)

Not used for:

- HTTP wire parsing
- HTTP/2 frames
- HTTP/3 frames
- QUIC
- TLS
- DNS wire format
- WebSocket frames
- FTP wire protocol
- compression
- other binary/protocol parsing

## Why native parsers remain

The installed `treesitter-0.0.1` dependency ships exactly four grammars:
arithmetic expressions, s-expressions, JSON, and an indentation outline
demo, so HTTPX defines first-class HTML, XML, and template grammars on
top of the Tree-sitter runtime: `htmlLanguage` in `src/parsing/html.zig`,
`xmlLanguage` in `src/parsing/xml.zig`, and `templateLanguage` in
`src/web/templates/parser.zig`. Syntax tokens and ranges come from the
syntax tree, while tag matching, DOM building, and template nesting/AST
semantics stay in HTTPX.
JSON *value* decoding stays on `std.json`; structural consumers are JSON
Feed and templates (syntax tree + positions from the grammar, field/AST
mapping in HTTPX). Tiny line-oriented formats (robots.txt, sitemap) and
small recursive-descent languages (GraphQL, route patterns, selectors)
are objectively simpler, faster, and lower-allocation as specialized
native parsers.

## Grammar inventory

| Grammar | Ships in dep | HTTPX consumer | Reason |
| ------- | ------------ | -------------- | ------ |
| Arithmetic expressions | Yes (demo) | None | Demo grammar; template expressions are paths/filters, not arithmetic |
| S-expressions | Yes (demo) | None | No s-expression input in HTTPX |
| JSON | Yes | Feed (JSON Feed syntax layer) | Only shipped grammar with an HTTPX consumer; value decoding stays `std.json` |
| Outline (indent demo) | Yes (demo) | None | Demo only |
| HTML | **No** | — | Native parser retained |
| Templates (`{{ }}`, `{% %}`, `{# #}`) | HTTPX-defined (`templateLanguage`) | Templates (syntax layer) | Tree-sitter tokenizes; nesting/AST stays in HTTPX |
| CSS selectors | **No** | — | Native parser retained |
| GraphQL | **No** | — | Native spec-driven parser retained |
| OpenAPI/YAML | **No** | — | Generation from router metadata + `std.json`; retained |

## Parser decision matrix

| Component       | Current parser              | Tree-sitter | Decision      | Reason |
| --------------- | --------------------------- | ----------- | ------------- | ------ |
| Templates       | Tree-sitter syntax tokens + HTTPX AST (`web/templates/parser.zig`) | **Yes** | Integrated | Grammar tokenizes text/expression/directive/comment; nesting stays native |
| HTML            | native tokenizer + DOM (`parsing/html.zig`, `dom.zig`) | No grammar | Keep native | No HTML grammar ships; streaming + arena DOM fits serving |
| DOM             | built from native HTML parse | No | Keep native | Single representation already; no second tree |
| Document        | native HTML + `computeEdit` vocabulary | Vocabulary only | Keep native | Edit descriptors shared with watcher; no grammar to parse with |
| Selectors       | native CSS-selector parser (`parsing/selector.zig`) | No | Keep native | Tiny grammar; dedicated parser is faster/simpler |
| Extraction      | DOM traversal (`parsing/extract.zig`) | No | Keep native | Operates on the single DOM; no reparse |
| JSON            | `std.json` for values | Structural for feeds | Values decode via std; feed documents parse via the grammar |
| XML             | native streaming parser (`parsing/xml.zig`) | No | Keep native | Streaming fits feeds; no XML grammar ships |
| Feed (RSS/Atom) | native over XML/DOM | No | Keep native | Thin layer over retained parsers |
| Feed (JSON)     | Tree-sitter JSON syntax + HTTPX semantics | **Yes** | Integrated | Grammar fits; replaces a stub that ignored its input |
| Robots.txt      | native line parser (`parsing/robots.zig`) | No | Keep native | Line-oriented; Tree-sitter is overkill |
| Sitemap         | native XML-backed parser (`parsing/sitemap.zig`) | No | Keep native | Same as XML/feeds |
| GraphQL         | native lexer + recursive descent (`web/graphql/`) | No | Keep native | Spec-driven with depth/complexity limits; no GraphQL grammar ships |
| OpenAPI         | built from router metadata + `std.json` | No | Keep native | Generation, not parsing; no grammar needed |
| Router patterns | native segment parser (`web/router/pattern.zig`) | No | Keep native | Trivial syntax (`{param}`, `*wild`); overhead unjustified |
| URI/URL         | native (`common/uri.zig`) | No | Keep native | Not a Tree-sitter domain |
| HTTP/1.x        | native wire parser | No | Keep native | Binary/protocol parsing |
| HTTP/2 (frames/HPACK) | native | No | Keep native | Binary/protocol parsing |
| HTTP/3/QUIC     | native | No | Keep native | Binary/protocol parsing |
| TLS/DNS/WS/FTP  | native | No | Keep native | Binary/protocol parsing |
| Multipart       | native boundary parser | No | Keep native | Wire format parsing |
| Compression     | brotli/zstd deps + std | No | Keep deps/std | Codec domain, not parsing |

## Related

- [Templates](/web/templates)
- [Development watcher flow](/guide/static-files)
- [Parse HTML example](/examples/parse-html)
