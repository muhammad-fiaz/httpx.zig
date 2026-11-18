# Signals & Graceful Shutdown

HTTPX treats process signals as process resources: one backend is installed for
the whole process and every server subscribes to it. You get automatic Ctrl+C
and `SIGTERM` handling with no setup, and you can override the policy per server
or take full ownership of the process lifecycle.

## Default behavior

With no configuration, `.signals = .{}` is applied:

| Option | Default | Meaning |
|---|---|---|
| `enabled` | `true` | Install process-wide handling for this server. |
| `interrupt` | `true` | React to Ctrl+C (`SIGINT` / `CTRL_C_EVENT`). |
| `terminate` | `true` | React to `SIGTERM` (POSIX only). |
| `close` | `true` | React to `CTRL_CLOSE_EVENT` (Windows console closed). |
| `logoff` | `false` | React to `CTRL_LOGOFF_EVENT` (Windows). |
| `shutdown` | `true` | React to `CTRL_SHUTDOWN_EVENT` (Windows). |
| `drainMs` | `10000` | Graceful drain deadline after the first signal. |
| `onSignal` | `null` | Optional application hook (normal context). |
| `ctx` | `null` | Opaque pointer passed to `onSignal`. |

The first matching signal calls `requestShutdown()`: acceptance stops, active
requests finish, and the deadline monitor interrupts any remaining I/O once
`drainMs` expires. A second signal calls `stop()`, cancelling active
I/O immediately.

```zig
var server = try httpx.Server.init(allocator, io, .{
    .host = "0.0.0.0",
    .port = 8080,
    .signals = .{ .drainMs = 30_000 },
});
defer server.deinit();
server.run();
```

`httpx.server.init(...)` is the same constructor; both spellings share one
implementation.

## Per-server policies

Each server gets its own mask and deadline. Multiple servers in one process are
independent subscribers to the same backend:

```zig
// Public API: drain on every supported event.
var api = try httpx.Server.init(allocator, io, .{
    .port = 8080,
    .signals = .{ .drainMs = 30_000 },
});

// Background worker: drain only on SIGTERM / Windows shutdown.
var worker = try httpx.Server.init(allocator, io, .{
    .port = 9090,
    .signals = .{
        .interrupt = false,
        .terminate = true,
        .close = false,
        .shutdown = true,
        .drainMs = 60_000,
    },
});
```

There is no global "active server" pointer and no last-server-wins behavior.
Destroying one server unregisters only that subscription.

## Application hooks

`onSignal` runs on the manager's notification thread, in normal execution
context. It may log, record metrics, or mutate atomics. It must not block for
long: other subscribers wait behind it.

```zig
const Telemetry = struct {
    interrupts: std.atomic.Value(u32) = .init(0),
};

fn observe(event: httpx.server.SignalEvent, context: ?*anyopaque) void {
    const telemetry: *Telemetry = @ptrCast(@alignCast(context.?));
    if (event.kind == .interrupt) {
        _ = telemetry.interrupts.fetchAdd(event.count, .acq_rel);
    }
}

var telemetry: Telemetry = .{};
var server = try httpx.Server.init(allocator, io, .{
    .port = 8080,
    .signals = .{
        .onSignal = observe,
        .ctx = &telemetry,
    },
});
```

The default drain/escalation policy still runs. To replace it entirely, disable
the integration and own the signals yourself.

## Manual coordination

```zig
var server = try httpx.Server.init(allocator, io, .{
    .port = 8080,
    .signals = .{ .enabled = false },
});
defer server.deinit();

fn onSignal(context: ?*anyopaque, event: httpx.signals.Event) void {
    const server_ptr: *httpx.Server = @ptrCast(@alignCast(context.?));
    if (event.count >= 2) server_ptr.stop() else server_ptr.requestShutdown();
}

var subscription = try httpx.signals.register(&server, onSignal, .{});
defer subscription.unregister();

server.run();
```

Pass the server pointer directly as the subscription context; no wrapper type
is required. `unregister()` is idempotent and waits for any callback already
executing on behalf of that subscription. That makes it safe to free the server
immediately afterwards.

## Lifecycle API

| Method | Behavior | Safe from signal hook |
|---|---|---|
| `requestShutdown()` | Non-blocking: stop accepting, let requests finish. | Yes |
| `stop()` | Immediate: interrupt active socket I/O. | Yes |
| `shutdown()` | Requests shutdown, then waits up to `drainMs`; escalates to `stop()`. | Avoid (blocks the notification thread) |
| `run()` | Blocking accept loop; returns after shutdown. | No |
| `deinit()` | Unregisters signals and releases resources; safe after `run()`. | No |

`shutdown()` must not be called from the thread executing `run()` or from a
signal hook that other subscribers depend on. Prefer `requestShutdown()` in
hooks and call `shutdown()` from an owning thread when you need a bounded wait.

## Safety model

* The OS handler performs only async-signal-safe work: atomic counters plus a
  pipe write (POSIX) or event set (Windows). It never allocates, locks, logs, or
  calls application code.
* A single notification thread reads the backend and dispatches events in
  normal execution context.
* Subscribers live in a fixed-capacity registry (32 entries). Registration
  installs the backend; the last unregister restores the previous OS handlers.
* Each server owns its subscription. There is no global server state to corrupt
  when several servers start, stop, or are destroyed concurrently.

## Platform support

| Target | Backend | Events |
|---|---|---|
| Linux, macOS, FreeBSD, NetBSD, OpenBSD, DragonFly | `sigaction` + self-pipe | `SIGINT`, `SIGTERM` |
| Windows | `SetConsoleCtrlHandler` + event | Ctrl+C, Ctrl+Break, close, logoff, shutdown |
| Others | none | `httpx.signals.supported == false` |

On unsupported targets the server logs a warning and keeps running; callers
that use `httpx.signals.register` receive `error.SignalsUnsupported`.

## Production checklist

* Keep `drainMs` below your orchestrator's termination grace period
  (for example Kubernetes `terminationGracePeriodSeconds`).
* Use `requestShutdown()` in hooks. Move slow persistence to an owning thread.
* Give each tier its own mask rather than duplicating process handlers.
* Disable `.signals` only when another component already installs handlers.
* Use atomics (or a queue) for state shared with the notification thread.

## Examples

* [Custom per-server policies](/examples/custom-signals)
* [Manual signal coordinator](/examples/manual-signals)
* [Signal-aware server](/examples/server-signals)

## Related

* [API: Signals](/api/signals)
* [API: Server](/api/server)
* [Guide: Deployment](/guide/deployment)
