# Logging Guide

HTTPX follows a strict zero-print architecture: the core library never invokes `std.debug.print` or logs directly to stdout/stderr in production paths. All logging is structured, optional, and controlled by the application.

## Principles

1. **Zero Unexpected I/O**: Library code never pollutes stdout/stderr.
2. **Redaction of Secrets**: Sensitive headers (`Authorization`, `Cookie`, `Set-Cookie`, `Proxy-Authorization`) and private keys are never logged by default.
3. **Plug-and-Play Loggers**: Integrate seamlessly with standard `std.log` or custom structured JSON logging libraries.

## Logging Middleware

Attach a logging middleware to your HTTPX server to log all incoming HTTP requests:

```zig
const std = @import("std");
const httpx = @import("httpx");

fn requestLoggerMiddleware(ctx: *httpx.Context) !void {
    const start_time = std.time.nanoTimestamp();

    // Proceed with route handler
    try ctx.next();

    const elapsed_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1_000_000.0;
    std.log.info("{s} {s} {d} - {d:.2}ms", .{
        ctx.request.method.toString(),
        ctx.request.path,
        ctx.response.status,
        elapsed_ms,
    });
}
```

## Redacting Sensitive Information

When logging headers, use `httpx.logging.redactHeader(name, value)`:

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
