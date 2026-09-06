# Concurrency & Async Tasks

`httpx.zig` provides robust primitives for concurrent execution and background task management.

The concurrency model is intentionally explicit:
1. **Single-Threaded**: Runs requests sequentially on the calling thread, with zero extra worker threads.
2. **Multi-Threaded**: Runs requests concurrently on a configurable pool of background request workers.
3. **Explicit Workers**: Runs requests concurrently by reusing an explicitly provided `Executor` thread pool.

When configuration is omitted, sensible defaults are used. The library derives worker counts from the host CPU when appropriate, while keeping the final values visible on the config objects so explicit overrides always win.

## Configuration Options

Configure concurrent request execution using `ConcurrencyConfig`:

```zig
pub const ConcurrencyMode = enum {
    single_thread,
    multi_thread,
    explicit_workers,
};

pub const ConcurrencyConfig = struct {
    mode: ConcurrencyMode = .multi_thread,
    workers: ?u32 = null, // Number of background thread workers (multi_thread mode)
    executor: ?*Executor = null, // Explicit executor instance (explicit_workers mode)
};
```

`ConcurrencyConfig` currently exposes request worker selection only. CPU affinity and per-thread pinning are not exposed as public APIs, so portable defaults remain the recommended path.

For unreachable or slow hosts, set per-request timeouts on each `RequestSpec` so concurrent tests and production batch jobs fail fast instead of waiting on the default 30 second socket budgets:

```zig
const specs = [_]httpx.RequestSpec{
    .{ .method = .GET, .url = "https://slow.example.com", .timeout_ms = 2_000 },
};
const results = try httpx.all(allocator, &client, &specs, .{ .mode = .multi_thread });
defer allocator.free(results);
```

## Parallel Requests

Execute multiple HTTP requests simultaneously using the helpful wrapper functions.

### `all`

Waits for **all** requests to complete. Returns a list of `RequestResult`.

```zig
const httpx = @import("httpx");

var builder = httpx.concurrency.BatchBuilder.init(allocator);
defer builder.deinit();

try builder.get("https://site-a.com");
try builder.post("https://site-b.com", body);

// Execute all using the default multi-threaded worker pool
const results = try httpx.concurrency.all(allocator, &client, builder.requests.items, .{});
defer allocator.free(results);

for (results) |res| {
    if (res.isSuccess()) {
        const response = res.success;
        // ...
        response.deinit();
    }
}
```

To limit execution to at most 2 threads:
```zig
const results = try httpx.concurrency.all(allocator, &client, specs, .{
    .mode = .multi_thread,
    .workers = 2,
});
```

To execute sequentially on the calling thread (no background threads):
```zig
const results = try httpx.concurrency.all(allocator, &client, specs, .{
    .mode = .single_thread,
});
```

### `race`

Returns the result of the **first** request to complete (success or failure).

```zig
const result = try httpx.concurrency.race(allocator, &client, specs, .{});
if (result.isSuccess()) {
    // ...
}
```

### `any`

Returns the **first successful** (2xx) response. Other workers check the winner atomic and bail out early, preventing unnecessary network calls once a response is resolved.

```zig
if (try httpx.concurrency.any(allocator, &client, specs, .{})) |success_response| {
    // ...
}
```

---

## Task Executor

The `Executor` provides a thread pool for running background tasks, useful for offloading heavy work from the main request thread in a server environment.

### Executor Defaults

- `num_threads = 0` means "choose a sensible default from the host CPU count".
- `task_queue_size = 1024` bounds pending tasks before submission fails.
- `idle_timeout_ms = 60_000` is the default idle timeout used by higher-level schedulers.

### Initialization

```zig
// Create an executor (defaults to CPU count)
var exec = httpx.executor.Executor.init(allocator);

// Start the worker threads
try exec.start();
defer exec.deinit(); // Stops threads cleanup
```

### Submitting Tasks

Tasks are functions that accept an optional context pointer.

```zig
fn heavyWork(ctx: ?*anyopaque) void {
    const data: *MyData = @ptrCast(@alignCast(ctx.?));
    // Do heavy computation...
}

var data = MyData{ .val = 123 };
try exec.execute(heavyWork, &data);
```

#### Non-blocking task submission (`trySubmit`)

To submit a task without blocking if the task queue is locked or full, use `trySubmit`:

```zig
try exec.trySubmit(.{
    .func = heavyWork,
    .context = &data,
});
```

#### Task completion callbacks (`submitWithCallback`)

You can submit a task and register a completion callback function using `submitWithCallback`:

```zig
fn callback(ctx: ?*anyopaque) void {
    // Runs after heavyWork completes
}

try exec.submitWithCallback(
    .{ .func = heavyWork, .context = &data },
    callback,
    &callback_data_context,
);
```

### Using Executor as Explicit Concurrency Workers

You can pass the `Executor` directly to concurrent request calls:

```zig
const results = try httpx.concurrency.all(allocator, &client, specs, .{
    .mode = .explicit_workers,
    .executor = &exec,
});
```
