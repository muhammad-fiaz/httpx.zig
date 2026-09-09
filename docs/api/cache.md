# Cache API

HTTPX has no in-memory HTTP cache subsystem. HTTP caching is handled where
it is actually implemented:

- **Static files**: `server.static(mount, dir)` serves with ETags and honors
  `If-None-Match` conditional requests (`304 Not Modified`). Embedded assets
  carry content-hash ETags.
- **Client downloads**: `.existing = .verifyExisting` skips re-downloads of
  files already on disk, and `.replaceIfChanged` uses conditional headers.
- **DNS**: the client caches resolutions (`dnsCache: .{ .enable, .ttlMs,
  .negativeTtlMs, .maxEntries }` in `ClientConfig`).

See [Static Files](/guide/static-files), [Single File](/guide/single-file),
and [Client Basics](/guide/client-basics).
