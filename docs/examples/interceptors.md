# Interceptors

HTTPX has no client interceptor registry. Cross-cutting request/response
behavior belongs in server middleware (`httpx.middleware.*`) or in small
wrappers around the URL-first client calls. See
`examples/interceptorExample.zig`, which exercises a plain server route plus
a client GET against it.

```zig
fn timing(ctx: *httpx.web.router.Context, next: httpx.web.router.NextFn) anyerror!httpx.web.router.Response {
    const t0 = std.time.nanoTimestamp();
    const resp = try next(ctx);
    return resp;
}

try server.use(timing);
try server.use(httpx.middleware.logging);
```

## Expected Output

```text
Server running on http://127.0.0.1:54321
GET / -> status=200, body={"message":"Request example"}
Interceptor example verification completed successfully.
```

This is the output format of `zig build run-interceptor-example` (see `examples/interceptorExample.zig`); the port number varies per run.

## Run

```bash
zig build run-interceptor-example
```

## What to Verify

- `GET /` returns 200 with the expected JSON body.
- Middleware runs in registration order.
