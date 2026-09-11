# Metrics API

Thread-safe, allocation-free request/response metrics using atomic operations.

Located in `src/web/metrics/` (`registry.zig`, `snapshot.zig`).

## Registry

`httpx.metrics.Registry` (aliased as `httpx.Metrics`) holds atomic counters,
gauges, and a latency histogram. The server owns one (`server.metricsRegistry`)
and records automatically; use the API below for custom instrumentation.

| Method | Description |
|--------|-------------|
| `recordRequest()` | Increment total requests (+1 in-flight) |
| `recordRequestMethod(method)` | Count by method (`GET`, `POST`, …) |
| `recordResponse(bytes)` | Increment responses, decrement in-flight, add bytes out |
| `recordResponseFull(status, durationNs, bytes)` | Response + status class + latency sample |
| `recordStatus(status)` | Bucket a status code (`status2xx`…`status5xx`) |
| `recordError()` | Increment errors (decrements in-flight) |
| `recordBytesIn(n)` / `recordBytesOut(n)` | Byte counters |
| `recordTimeout()` | Increment timeouts |
| `connectionOpened()` / `connectionClosed()` | Active-connection gauge (underflow-safe) |
| `reset()` | Reset all counters to zero |
| `snapshot()` | Return an immutable `MetricsSnapshot` |
| `render(writer)` / `renderPrometheus(writer)` | Prometheus 0.0.4 text exposition |

Root-level aliases: `httpx.Metrics`, `httpx.MetricsSnapshot`,
`httpx.ServerSnapshot`, `httpx.ClientSnapshot`, `httpx.Counter`,
`httpx.Gauge`, `httpx.Histogram`.

## MetricsSnapshot

Immutable point-in-time copy. All multi-word fields are camelCase:

| Field | Type | Description |
|-------|------|-------------|
| `requestsTotal` | `u64` | Total requests recorded |
| `responsesTotal` | `u64` | Total responses recorded |
| `errorsTotal` | `u64` | Total errors |
| `timeoutsTotal` | `u64` | Total timeouts |
| `bytesIn` / `bytesOut` | `u64` | Byte counters |
| `activeConnections` / `activeRequests` | `u64` | Current gauges |
| `status2xx` / `status3xx` / `status4xx` / `status5xx` | `u64` | Status class counts |
| `methodGet` / `methodPost` / `methodPut` / `methodDelete` / `methodPatch` / `methodHead` / `methodOptions` / `methodOther` | `u64` | Per-method counts |
| `durationCount` | `u64` | Latency sample count |
| `durationSumSeconds` | `f64` | Latency sum in seconds |
| `durationBuckets` | `[11]u64` | Cumulative histogram buckets |

| Method | Returns | Description |
|--------|---------|-------------|
| `errorRate()` | `f64` | `errorsTotal / requestsTotal` (0.0 when empty) |
| `averageLatencySeconds()` | `f64` | Mean latency in seconds |
| `averageLatencyMs()` | `f64` | Mean latency in milliseconds |

## ServerSnapshot

`server.snapshot()` returns uptime, gauges, totals, and the embedded
`metrics: MetricsSnapshot`. `errorRate()` and `requestsPerSecond()` are
computed from the snapshot (no duplicated stored state).

## Prometheus exposition

`renderPrometheus` emits standard snake_case wire names (`http_requests_total`,
`http_requests_by_method_total{method="GET"}`, `http_responses_by_status_total`,
`http_request_duration_seconds_bucket/count/sum`). Wire names follow the
Prometheus convention; Zig identifiers stay camelCase.
