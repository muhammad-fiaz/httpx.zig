# Interceptors

HTTPX has no client interceptor registry. Cross-cutting request/response
behavior belongs in server middleware (`httpx.middleware.*`) or in small
wrappers around the URL-first client calls. See
`examples/interceptor_example.zig`, which exercises a plain server route plus
a client GET against it.

```zig
fn timing(ctx: *httpx.Context, next: httpx.router.NextFn) anyerror!httpx.Response {
    const t0 = std.time.nanoTimestamp();
    const resp = try next(ctx);
    return resp;
}

try server.use(timing);
try server.use(httpx.middleware.logging);
```

## Run

```bash
zig build run-interceptor-example
```

## What to Verify

- `GET /` returns 200 with the expected JSON body.
- Middleware runs in registration order.
