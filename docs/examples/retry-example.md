# Retry Policy Example

Demonstrates client retry with exponential backoff. Shows `RetryPolicy` configuration including `max_retries`, `initial_delay_ms`, `max_delay_ms`, `backoff_multiplier`, and `retry_on_status`.

## Demo Program

```zig
const default = httpx.RetryPolicy{};
// max_retries, initial_delay_ms, backoff_multiplier, etc.

const no_retry = httpx.RetryPolicy.noRetry();
const aggressive = httpx.RetryPolicy.aggressive();

const custom = httpx.RetryPolicy{
    .max_retries = 10,
    .initial_delay_ms = 200,
    .backoff_multiplier = 3.0,
    .retry_on_status = &.{ 429, 500, 502, 503, 504 },
};

const delay = custom.calculateDelay(attempt);
const should = custom.shouldRetryStatus(503); // true
```

## Run

```
zig build run-all-retry_example
```

## Checklist

- [x] Default retry policy has sensible defaults
- [x] `RetryPolicy.noRetry()` disables all retries
- [x] `RetryPolicy.aggressive()` uses higher retry counts
- [x] Exponential backoff doubles delay each attempt
- [x] `calculateDelay` returns correct backoff values
- [x] `shouldRetryStatus` checks against configured status list
- [x] Status 429 (rate limit) triggers retry
