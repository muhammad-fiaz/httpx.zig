# Redirect Following Example

Demonstrates redirect configuration with `followRedirects` and
`maxRedirects` on the client and per-request overrides.

## Demo Program

```zig
var client = httpx.Client.init(allocator, io, .{
    .followRedirects = true,
    .maxRedirects = 5,
});
defer client.deinit();

std.debug.print("  maxRedirects:    {d}\n", .{client.config.maxRedirects});
std.debug.print("  followRedirects: {}\n", .{client.config.followRedirects});

// Per-request override: do not follow redirects for this call.
var res = try client.get("http://httpbun.com/redirect/2", .{ .followRedirects = false });
defer res.deinit();
```

## Run

```
zig build run-redirect
```

## Checklist

- [x] Default client follows redirects up to `maxRedirects`
- [x] `.followRedirects = false` disables following per request
- [x] 307/308 preserve the method; 301/302/303 may rewrite POST to GET
