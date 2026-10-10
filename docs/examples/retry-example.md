# Retry Example

Automatic retries are configured on the client (linear backoff:
`retryDelayMs * (attempt + 1)`). See `examples/retryDemo.zig`.

```zig
var client = httpx.Client.init(allocator, io, .{
    .maxRetries = 3,                             // 3 retries (4 total attempts)
    .retryDelayMs = 500,                         // base delay between retries
    .retryStatusCodes = &.{ 502, 503, 504 },     // status codes that trigger retry
});
defer client.deinit();
```

Set `.maxRetries = 0` (the default) to disable retries.

## Expected Output

The configuration snippet itself prints nothing; `examples/retryDemo.zig`
prints lines in this format (representative values shown):

```text
Status: 200
```

On failure it prints `Attempt 1 failed: <ErrorName>` per attempt and finally `All retries exhausted`. Status codes, attempt counts, and error names vary with network conditions.

## Run

```bash
zig build run-retry-demo
```

## Checklist

- [x] Retryable statuses trigger another attempt
- [x] Delay grows linearly per attempt
- [x] Non-retryable errors return immediately
