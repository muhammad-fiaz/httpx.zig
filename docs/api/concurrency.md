# Concurrency API

The concurrency module provides tools for parallel execution and task management.

## Functions

These functions are available under `httpx.concurrency.*` and also as top-level helpers:

- `httpx.all`
- `httpx.any`
- `httpx.race`
- `httpx.allSettled`

Additional top-level aliases:

- `httpx.first` (alias for `httpx.any`)
- `httpx.fastest` (alias for `httpx.race`)
- `httpx.settled` (alias for `httpx.allSettled`)
- `httpx.successfulCount` (count `RequestResult.success` items)
- `httpx.errorCount` (count `RequestResult.err` items)

### `all`

Executes multiple requests in parallel and waits for all to complete.

```zig
pub fn all(allocator: Allocator, client: *Client, specs: []const RequestSpec) ![]RequestResult
```

### `allSettled`

Executes multiple requests in parallel and returns a result for **each** request.

- Successful requests are returned as `RequestResult.success`.
- Failed requests are returned as `RequestResult.err`.

```zig
pub fn allSettled(allocator: Allocator, client: *Client, specs: []const RequestSpec) ![]RequestResult
```

### `any`

Executes multiple requests and returns the first **successful (2xx)** response.

```zig
pub fn any(allocator: Allocator, client: *Client, specs: []const RequestSpec) !?Response
```

### `race`

Executes multiple requests and returns the result of the first one to complete (success or error).

```zig
pub fn race(allocator: Allocator, client: *Client, specs: []const RequestSpec) !RequestResult
```

### Top-Level Alias Signatures

```zig
pub fn first(allocator: Allocator, client: *Client, specs: []const RequestSpec) !?Response
pub fn fastest(allocator: Allocator, client: *Client, specs: []const RequestSpec) !RequestResult
pub fn settled(allocator: Allocator, client: *Client, specs: []const RequestSpec) ![]RequestResult
pub fn successfulCount(results: []const RequestResult) usize
pub fn errorCount(results: []const RequestResult) usize
```

## BatchBuilder

Use `httpx.BatchBuilder` to compose request batches fluently.

```zig
var builder = httpx.BatchBuilder.init(allocator);
defer builder.deinit();

_ = try builder.get("https://api.example.com/users");
_ = try builder.post("https://api.example.com/users", "{\"name\":\"demo\"}");
_ = try builder.postJson("https://api.example.com/users", "{\"name\":\"json\"}");
```

| Method | Description |
|--------|-------------|
| `get(url)` | Add GET request |
| `post(url, body)` | Add POST request |
| `postJson(url, json)` | Add POST request with JSON body |
| `put(url, body)` | Add PUT request |
| `delete(url)` | Add DELETE request |
| `add(spec)` | Add explicit `RequestSpec` |
| `count()` | Number of queued requests |
| `clear()` | Remove queued requests |

## Executor

A thread-pool based task executor.

```zig
const httpx = @import("httpx");
var executor = httpx.Executor.init(allocator);
defer executor.deinit();
```

### Configuration

```zig
pub const ExecutorConfig = struct {
    num_threads: u32 = 0,       // 0 = auto-detect
    task_queue_size: usize = 1024,
    idle_timeout_ms: u64 = 60_000,
};
```

### Methods

#### `execute`

Submits a function for execution.

```zig
pub fn execute(self: *Self, func: TaskFn, context: ?*anyopaque) !void
```

#### `submit`

Submits a `Task` struct.

```zig
pub fn submit(self: *Self, task: Task) !void
```

#### `runAll`

Runs all pending tasks synchronously (useful for testing).

```zig
pub fn runAll(self: *Self) void
```

#### `executeAll`

Submits a slice of `Task` values in order.

```zig
pub fn executeAll(self: *Self, tasks: []const Task) !void
```

#### `start` / `stop`

Start and stop worker threads explicitly.

```zig
pub fn start(self: *Self) !void
pub fn stop(self: *Self) void
```

#### `pendingCount`

Returns a snapshot count of queued tasks.

```zig
pub fn pendingCount(self: *const Self) usize
```

#### `isRunning` and `queueCapacity`

Inspect executor thread state and configured queue limit.

```zig
pub fn isRunning(self: *const Self) bool
pub fn queueCapacity(self: *const Self) usize
```

## Types

### `Task`

represents a unit of work.

```zig
pub const Task = struct {
    func: TaskFn,
    context: ?*anyopaque = null,
    priority: u8 = 0,
};
```

### `TaskFn`

```zig
pub const TaskFn = *const fn (?*anyopaque) void;
```

### `RequestSpec`

Specification for a request in a batch operation.

```zig
pub const RequestSpec = struct {
    method: Method = .GET,
    url: []const u8,
    body: ?[]const u8 = null,
    json: ?[]const u8 = null,
    headers: ?[]const [2][]const u8 = null,
    timeout_ms: ?u64 = null,
    follow_redirects: ?bool = null,
    version: ?Version = null,
};
```

All `RequestSpec` fields beyond `url` are optional customizations.

### `RequestResult`

Result wrapper for parallel requests.

```zig
pub const RequestResult = union(enum) {
    success: Response,
    err: anyerror,
    
    // Helper methods
    pub fn isSuccess(self: RequestResult) bool
    pub fn getResponse(self: *RequestResult) ?*Response
    pub fn deinit(self: *RequestResult) void
};
```
