# Redirect Following Example

Demonstrates redirect configuration with `followRedirects` and
`maxRedirects` on the client and per-request overrides.

## Example

```zig
var client = httpx.Client.init(allocator, io, .{
    .followRedirects = true,
    .maxRedirects = 5,
});
defer client.deinit();

std.debug.print("  maxRedirects:    {d}\n", .{client.config.maxRedirects});
std.debug.print("  followRedirects: {}\n", .{client.config.followRedirects});

// Per-request override: do not follow redirects for this call.
var res = try client.get("https://httpbun.com/redirect/2", .{ .followRedirects = false });
defer res.deinit();
```

## Expected Output

```text
  maxRedirects:    5
  followRedirects: true
```

Values reflect the client config shown above and vary if `maxRedirects` / `followRedirects` are configured differently.

## Run

```
zig build run-redirect
```
