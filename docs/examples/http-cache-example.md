# HTTP Cache

HTTPX has no in-memory HTTP cache subsystem. HTTP caching is handled where
it is actually implemented:

- **Static files**: `server.static(mount, dir)` serves with ETags and honors
  `If-None-Match` (`304 Not Modified`). See `examples/staticFiles.zig`.
- **Downloads**: `.existing = .verifyExisting` skips re-downloads, and
  `.replaceIfChanged` uses conditional headers. See
  `examples/downloadExisting.zig`.
- **DNS**: client-side cache via `ClientConfig.dnsCache`.

## Expected Output

Representative static-file conditional GET exchange (ports, sizes, and ETag values vary):

```text
serving examples/static on http://127.0.0.1:54321/static
health endpoint on http://127.0.0.1:54321/healthz
GET /static/index.html -> 200 (1234 bytes)
```

```text
GET /static/index.html HTTP/1.1
Host: 127.0.0.1:54321

HTTP/1.1 200 OK
ETag: "abc123"
Content-Length: 1234

GET /static/index.html HTTP/1.1
Host: 127.0.0.1:54321
If-None-Match: "abc123"

HTTP/1.1 304 Not Modified
```

## Checklist

- [x] ETag generation and matching on static routes
- [x] Conditional GET (304 Not Modified)
- [x] Download resume and existing-file policies
