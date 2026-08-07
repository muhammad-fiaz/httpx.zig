# Logging Callback

Demonstrates custom log functions for server and client, including routing logs to an external logger, silent mode, and verbose timestamped logging.

## Demo Program

```zig
// External logger callback — prefixes messages with level
fn externalLogger(level: httpx.LogLevel, message: []const u8) void {
    std.debug.print("[EXT-{s}] {s}\n", .{ @tagName(level), message });
}

// Silent logger — suppresses all output
fn silentLogger(level: httpx.LogLevel, message: []const u8) void {
    _ = level; _ = message;
}

// Timestamp logger — prepends level without brackets
fn timestampLogger(level: httpx.LogLevel, message: []const u8) void {
    std.debug.print("[{s}] {s}\n", .{ @tagName(level), message });
}

// Attach to server
var server = httpx.Server.initWithConfig(allocator, .{
    .log_fn = externalLogger,
});

// Attach to client
var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
    .withLogFn(externalLogger));
```

## Run

```
zig build example-logging-callback
```

## Checklist

- [x] External logger prints `[EXT-INFO]` / `[EXT-DEBUG]` prefixed messages
- [x] Silent logger suppresses all server and client output
- [x] Timestamp logger prints `[INFO]` / `[DEBUG]` prefixed messages
- [x] Each mode (external, silent, timestamp) runs a full request cycle
- [x] Response status codes are printed after each request
