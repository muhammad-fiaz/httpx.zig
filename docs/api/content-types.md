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

JSON media type detection is available as `httpx.mime.isJson`. It recognizes
JSON media types and structured syntax suffixes such as `application/problem+json`,
while rejecting unrelated names that merely contain the letters `json`.

The static-file server uses the shared Accept matcher. It honors case-insensitive
media ranges, wildcards, q values, and the most-specific matching range; a
specific `q=0` excludes that representation even when a broader wildcard allows
it.
