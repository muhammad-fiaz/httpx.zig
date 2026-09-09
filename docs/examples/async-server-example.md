# Async Server Example

Run CPU-bound work off the request path with `httpx.WorkerPool`, and serve
results from normal handlers. See `examples/concurrent_demo.zig` for parallel
client requests.

```zig
var pool = httpx.WorkerPool.init(allocator, .{
    .workers = 4,
    .queueCapacity = 1024,
    .autoStart = true,
});
defer pool.deinit();
```

Handlers stay single-threaded and deterministic; submit background jobs to
the pool and poll or block on their completion. Server lifecycle is unchanged:
`server.run()` blocks, `server.start()` returns a joinable thread, and
`server.requestShutdown()` drains in-flight requests.

## Run

```bash
zig build run-concurrent-demo
```

## What to Verify

- Parallel `getAll` / `requestAll` calls all return 200.
- `WorkerPool` submits background jobs without stalling request handling.
