# Async Server Example

Run CPU-bound work off the request path with `httpx.concurrency.Pool`, and
serve results from normal handlers. See `examples/concurrentDemo.zig` for
parallel client requests.

```zig
var ctx = try httpx.IoContext.init(allocator);
defer ctx.deinit();

var pool = try httpx.concurrency.Pool.init(allocator, ctx.io, .{
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

## Expected Output

```text
Request 1: status=200 bodyLen=1234
Request 2: status=200 bodyLen=567
Request 3: status=200 bodyLen=89
Status: 200
Status: 200
Status: 200
```

Status values reflect the live endpoints and body lengths vary per response.

## Run

```bash
zig build run-concurrent-demo
```

## What to Verify

- Parallel `getAll` / `requestAll` calls all return 200.
- The worker pool submits background jobs without stalling request handling.
