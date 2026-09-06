# Metrics API

Thread-safe, allocation-free request/response metrics using atomic operations.

Located in `src/metrics/`.

## Metrics

| Method | Description |
|--------|-------------|
| `init()` | Create a zeroed Metrics instance |
| `initWithCallback(fn)` | Create with a custom event callback |
| `recordRequest()` | Increment total requests |
| `recordResponse(status, bytes, latency_ns)` | Record response, update status buckets and latency |
| `recordBytesSent(bytes)` | Increment bytes sent |
| `recordError()` | Increment error counter |
| `connectionOpened()` | Increment active connections |
| `connectionClosed()` | Decrement active connections |
| `reset()` | Reset all counters to zero |
| `snapshot()` | Return a `MetricsSnapshot` |

## MetricsSnapshot

| Field | Type | Description |
|-------|------|-------------|
| `total_requests` | `u64` | Total requests recorded |
| `total_responses` | `u64` | Total responses recorded |
| `active_connections` | `i64` | Current open connections |
| `errors` | `u64` | Total errors |
| `bytes_sent` | `u64` | Total bytes sent |
| `bytes_received` | `u64` | Total bytes received |
| `responses_2xx` | `u64` | 2xx response count |
| `responses_3xx` | `u64` | 3xx response count |
| `responses_4xx` | `u64` | 4xx response count |
| `responses_5xx` | `u64` | 5xx response count |
| `avg_latency_ns` | `u64` | Average latency in nanoseconds |
| `min_latency_ns` | `u64` | Minimum latency in nanoseconds |
| `max_latency_ns` | `u64` | Maximum latency in nanoseconds |

| Method | Returns | Description |
|--------|---------|-------------|
| `errorRate()` | `f64` | `errors / total_requests` |
| `successRate()` | `f64` | `responses_2xx / total_responses` |
| `print()` | `void` | Print a human-readable summary to stderr |

## MetricsEvent

Tagged union passed to the optional callback:

- `.request` — a request was recorded
- `.response` — `{ status: u16, bytes: u64, latency_ns: u64 }`
- `.bytes_sent` — `u64`
- `.err` — an error was recorded
- `.connection_open` / `.connection_close`

## MetricsCallbackFn

`*const fn (event: MetricsEvent) void`

Root-level aliases: `httpx.Metrics`, `httpx.MetricsSnapshot`, `httpx.MetricsEvent`, `httpx.MetricsCallbackFn`.
