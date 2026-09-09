# HTTP Cache

HTTPX has no in-memory HTTP cache subsystem. HTTP caching is handled where
it is actually implemented:

- **Static files**: `server.static(mount, dir)` serves with ETags and honors
  `If-None-Match` (`304 Not Modified`). See `examples/static_files.zig`.
- **Downloads**: `.existing = .verifyExisting` skips re-downloads, and
  `.replaceIfChanged` uses conditional headers. See
  `examples/download_existing.zig`.
- **DNS**: client-side cache via `ClientConfig.dnsCache`.

## Checklist

- [x] ETag generation and matching on static routes
- [x] Conditional GET (304 Not Modified)
- [x] Download resume and existing-file policies
