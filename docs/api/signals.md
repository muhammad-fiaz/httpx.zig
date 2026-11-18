# API: Signals

Cross-platform process signal management used by every server. The OS handler
is installed once per process; servers and applications subscribe to it.

```zig
const httpx = @import("httpx");
```

## `httpx.signals`

| Declaration | Description |
|---|---|
| `httpx.signals.supported` | `true` when the current target has a real backend. |
| `httpx.signals.Kind` | `interrupt`, `terminate`, `close`, `logoff`, `shutdown`. |
| `httpx.signals.Event` | `{ kind: Kind, count: u32 }`; `count` coalesces repeated deliveries. |
| `httpx.signals.Mask` | Per-kind opt-in booleans; defaults match the server defaults. |
| `httpx.signals.Subscription` | Handle with idempotent `unregister()`. |
| `httpx.signals.register(context, notifyFn, mask)` | Subscribes; installs the backend on the first call. |
| `httpx.signals.Error` | `SignalCapacityExceeded`, `SignalsUnsupported`, `ThreadSpawnFailed`. |

`notifyFn` has the signature `*const fn (?*anyopaque, Event) void`. It is called
from the manager's notification thread in normal execution context, never from
the OS handler.

```zig
const Handler = struct {
    fn notify(context: ?*anyopaque, event: httpx.signals.Event) void {
        const flag: *std.atomic.Value(bool) = @ptrCast(@alignCast(context.?));
        _ = event;
        flag.store(true, .release);
    }
};

var stopRequested = std.atomic.Value(bool).init(false);
var subscription = try httpx.signals.register(&stopRequested, Handler.notify, .{
    .interrupt = true,
    .terminate = true,
});
defer subscription.unregister();
```

### Mask

```zig
pub const Mask = struct {
    interrupt: bool = true,
    terminate: bool = true,
    close: bool = true,
    logoff: bool = false,
    shutdown: bool = true,

    pub fn includes(self: Mask, kind: Kind) bool;
    pub fn matches(self: Mask, other: Mask) bool;
};
```

## Server integration

`.signals = .{}` enables automatic handling. The option type is intentionally
not exported; pass it inline.

```zig
var server = try httpx.Server.init(allocator, io, .{
    .port = 8080,
    .signals = .{
        .enabled = true,
        .interrupt = true,
        .terminate = true,
        .close = true,
        .logoff = false,
        .shutdown = true,
        .drainMs = 30_000,
        .onSignal = hook,
        .ctx = &state,
    },
});
```

| Field | Default | Notes |
|---|---|---|
| `enabled` | `true` | `false` leaves signals entirely to the application. |
| `interrupt` | `true` | Ctrl+C / `SIGINT`. |
| `terminate` | `true` | `SIGTERM` (POSIX). |
| `close` | `true` | Windows `CTRL_CLOSE_EVENT`. |
| `logoff` | `false` | Windows `CTRL_LOGOFF_EVENT`. |
| `shutdown` | `true` | Windows `CTRL_SHUTDOWN_EVENT`. |
| `drainMs` | `10000` | Graceful drain deadline. |
| `onSignal` | `null` | `*const fn (httpx.server.SignalEvent, ?*anyopaque) void`. |
| `ctx` | `null` | Opaque pointer for the hook. |

`httpx.server.SignalEvent` and `httpx.server.SignalCallback` are the hook types:

```zig
pub const SignalEvent = httpx.signals.Event;
pub const SignalCallback = *const fn (event: SignalEvent, context: ?*anyopaque) void;
```

## Lifecycle methods

| Method | Contract |
|---|---|
| `server.requestShutdown()` | Non-blocking. Stops accepting; active requests finish. Idempotent. |
| `server.stop()` | Immediate cancellation of active socket I/O; each worker still owns socket cleanup. Idempotent. |
| `server.shutdown()` | `requestShutdown()` plus a bounded wait for `run()` to return; escalates to `stop()` at the deadline. |
| `server.run()` | Blocking accept loop. Returns after shutdown. Not callable from a signal hook. |
| `server.deinit()` | Unregisters the subscription and releases resources. Safe after `run()`. |

The automatic policy uses `requestShutdown()` on the first delivery and `stop()`
on the second and later deliveries. The deadline monitor enforces
`drainMs`.

## Semantics

* Registration is process-wide and reference-counted: the backend is installed
  by the first subscriber and the previous OS dispositions are restored by the
  last unregister.
* Capacity is fixed at 32 subscriptions. Exceeding it returns
  `error.SignalCapacityExceeded` without disturbing existing subscribers.
* `unregister()` waits for in-flight callbacks for that slot before returning,
  so the context may be destroyed immediately afterwards.
* Hooks must not call `shutdown()` or block: the notification thread dispatches
  other subscribers only after the current hook returns.

## Related

* [Guide: Signals & Graceful Shutdown](/guide/signals)
* [API: Server](/api/server)
* [Example: Custom Signals](/examples/custom-signals)
* [Example: Manual Signals](/examples/manual-signals)
