# Batch / Race / AllSettled Concurrent Requests

Demonstrates `httpx.all()`, `httpx.any()`, `httpx.race()`, and `httpx.allSettled()` for concurrent batch HTTP requests with different settling semantics.

## Demo Program

```zig
// Build a batch of requests using BatchBuilder
var batch = httpx.BatchBuilder.init(allocator);
defer batch.deinit();
_ = try batch.get(base_url);
_ = try batch.get(base_url);
_ = try batch.get(base_url);

// httpx.all() — wait for every request
const all_results = try httpx.all(allocator, &client, batch.requests.items, .{ .mode = .single_thread });

// httpx.any() — first 2xx response wins
const first_2xx = try httpx.any(allocator, &client, batch.requests.items, .{ .mode = .single_thread });

// httpx.race() — first completion wins (success or error)
var first_done = try httpx.race(allocator, &client, batch.requests.items, .{ .mode = .single_thread });

// httpx.allSettled() — all complete, never throws on individual errors
const settled = try httpx.allSettled(allocator, &client, batch.requests.items, .{ .mode = .single_thread });
```

## Run

```
zig build example-batch-concurrent
```

## Checklist

- [x] `httpx.all()` returns all results and reports successful count
- [x] `httpx.any()` returns the first 2xx response (or null)
- [x] `httpx.race()` returns whichever request finishes first
- [x] `httpx.allSettled()` returns all outcomes with no thrown errors
- [x] Convenience aliases print: `first()`, `fastest()`, `settled()`
