# Content types and MIME lookup

`httpx.mime` is backed by the shared registry in `src/common/mime.zig`.
Lookups are case insensitive and allocate no memory.

```zig
const content_type = httpx.mime.fromPath("C:\\site\\assets\\app.js");
const known = httpx.mime.fromExtension("woff2"); // ?[]const u8
const extension = httpx.mime.extensionFor("image/jpeg; q=1"); // ?[]const u8
```

`fromPath` returns `application/octet-stream` when a path has no recognized
extension. `fromExtension` and `lookupExtension` return `null` for unknown
extensions. `extensionFor` ignores media-type parameters and returns the first
registered extension when a media type has aliases (for example, `jpg` for
`image/jpeg`). Paths may use either slash convention.

Use `httpx.mediaType` for canonical values that appear in request and response
headers, including `applicationJson`, `applicationJsonUtf8`, `formUrlEncoded`,
`multipartFormData`, `textPlainUtf8`, and `textHtmlUtf8`. The MIME registry
re-exports the same constants for code using `httpx.mime`.

JSON media-type validation is available as `httpx.json.classifyMediaType` and
`httpx.mime.isJson`. It validates type and parameter syntax, and distinguishes
single-document JSON from JSON5, NDJSON/JSONL, and JSON text sequences. `isJson`
accepts JSON document types, including structured syntax suffixes such as
`application/problem+json`, and rejects unrelated or malformed values.

The static-file server uses the shared Accept matcher. It honors case-insensitive
media ranges, wildcards, q values, and the most-specific matching range; a
specific `q=0` excludes that representation even when a broader wildcard allows
it.
