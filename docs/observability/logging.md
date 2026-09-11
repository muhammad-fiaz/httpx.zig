# Logging Guide

HTTPX follows a strict zero-print architecture: the core library never invokes `std.debug.print` or logs directly to stdout/stderr in production paths. All logging is structured, optional, and controlled by the application.

## Principles

1. **Zero Unexpected I/O**: Library code never pollutes stdout/stderr.
2. **Redaction of Secrets**: Sensitive headers (`Authorization`, `Cookie`, `Set-Cookie`, `Proxy-Authorization`) and private keys are never logged by default.
3. **Plug-and-Play Loggers**: Integrate seamlessly with standard `std.log` or custom structured JSON logging libraries.

## Logging Middleware

Attach the built-in logging middleware to your HTTPX server. Middleware has
the shape `fn (ctx: *httpx.Context, next: httpx.router.NextFn) anyerror!httpx.Response`
and must return the downstream response:

```zig
const std = @import("std");
const httpx = @import("httpx");

try server.use(httpx.middleware.logging);
```

For structured production events (method, path, status, duration, bytes —
never secrets), set the server logging callback instead; HTTPX emits nothing
unless you provide one:

```zig
fn onEvent(event: httpx.ServerEvent) void {
    if (event.kind == .requestCompleted) {
        std.debug.print("{s} {s} {d} {d}ms\n", .{
            event.method, event.path, event.status, event.durationMs,
        });
    }
}

var server = try httpx.Server.init(allocator, io, .{
    .logging = .{ .callback = onEvent },
});
```

## Redacting Sensitive Information

When logging headers, use `httpx.logging.isSensitiveHeader(name)` to decide
what to redact:

```zig
pub fn formatHeaderSafe(name: []const u8, value: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(name, "authorization") or
        std.ascii.eqlIgnoreCase(name, "cookie") or
        std.ascii.eqlIgnoreCase(name, "x-api-key"))
    {
        return "[REDACTED]";
    }
    return value;
}
```

## Related

* [Observability: Events](/observability/events)
* [Observability: Metrics](/observability/metrics)
* [Example: Interceptors](/examples/interceptors)
