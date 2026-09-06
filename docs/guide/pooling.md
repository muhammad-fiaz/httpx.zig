# Connection Pooling & Concurrency

`httpx.zig` handles connection concurrency at two levels: 
1. **Internal Connection Pooling**: Reusing socket connections for efficiency.
2. **Parallel Request Execution**: Running multiple requests essentially at the same time.

## Connection Pooling

The `Client` automatically manages a pool of TCP connections. When a request is made, it checks for an idle, healthy connection to the target host. If one exists, it is reused; otherwise, a new connection is created.

### Configuration

You can configure the pool size and behavior via `ClientConfig`:

```zig
const config = httpx.ClientConfig{
    .keep_alive = true,
    .pool_max_connections = 50,  // Total connections in pool
    .pool_max_per_host = 10,     // Max connections to a single host
};
```

This acts mostly transparently to the user.

For parallel request execution (all, race, any) and task execution, see the [Concurrency](/guide/concurrency) guide.

