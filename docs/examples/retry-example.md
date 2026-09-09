# Retry Example

Automatic retries are configured on the client (linear backoff:
`retryDelayMs * (attempt + 1)`). See `examples/retry_demo.zig`.

```zig
var client = httpx.Client.init(allocator, io, .{
    .maxRetries = 3,                             // 3 retries (4 total attempts)
    .retryDelayMs = 500,                         // base delay between retries
    .retryStatusCodes = &.{ 502, 503, 504 },     // status codes that trigger retry
});
defer client.deinit();
```

Set `.maxRetries = 0` (the default) to disable retries.

## Run

```bash
zig build run-retry-demo
```

## Checklist

- [x] Retryable statuses trigger another attempt
- [x] Delay grows linearly per attempt
- [x] Non-retryable errors return immediately
