//! Process-wide signal manager.
//!
//! Operating-system signals are process resources, so exactly one backend is
//! installed for the whole process and every server subscribes to it. There is
//! no global server pointer: subscribers are opaque `(context, notifyFn)`
//! pairs stored in a fixed-capacity table.
//!
//! Safety model:
//!   - The OS handler (POSIX signal or Windows console callback) performs only
//!     async-signal-safe work: atomic counters plus a pipe write / event set.
//!   - A single notification thread waits for the backend and invokes
//!     subscribers in normal execution context.
//!   - Subscribers are never called while the registry mutex is held, so a
//!     callback cannot deadlock the manager.
//!   - `unregister` waits for in-flight notifications on that slot before it
//!     returns, so destroying a server after unregistering cannot race a
//!     callback.
//!   - The backend is installed on the first subscription and restored when
//!     the last subscription is removed. No per-server handlers are created.
//!
//! The notification thread exists only while at least one subscription is
//! active. Normal request processing never touches the manager.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const syncMod = @import("../common/sync.zig");

const backend = switch (builtin.os.tag) {
    .windows => @import("windows.zig"),
    .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly => @import("posix.zig"),
    else => @import("unsupported.zig"),
};

pub const Kind = types.Kind;
pub const Event = types.Event;
pub const Mask = types.Mask;

/// True when this target has a real backend.
pub const supported = types.supported;

/// Kinds this backend can actually produce.
const backendKinds: []const Kind = if (builtin.os.tag == .windows)
    &.{ .interrupt, .close, .logoff, .shutdown }
else if (types.supported)
    &.{ .interrupt, .terminate }
else
    &.{};

pub const NotifyFn = *const fn (context: ?*anyopaque, event: Event) void;

pub const Error = error{
    SignalCapacityExceeded,
    SignalsUnsupported,
    ThreadSpawnFailed,
};

const maxSubscribers = 32;

const Slot = struct {
    context: ?*anyopaque = null,
    notifyFn: ?NotifyFn = null,
    mask: Mask = .{},
    active: bool = false,
    inFlight: std.atomic.Value(usize) = .init(0),
};

var slots: [maxSubscribers]Slot = @splat(.{});
var stateMutex: syncMod.Spinlock = .{};
/// Serializes register/unregister transitions (backend install/restore and
/// thread start/join). Never taken by the notification thread.
var transitionMutex: syncMod.Spinlock = .{};
var thread: ?std.Thread = null;
var running = false;
var installed = false;
var activeCount: usize = 0;

pub const Subscription = struct {
    slot: *Slot,

    /// Removes this subscription. Idempotent. Waits for any callback already
    /// executing on behalf of this slot before returning.
    pub fn unregister(self: Subscription) void {
        remove(self.slot);
    }
};

/// Registers a subscriber. The first subscription installs the OS backend and
/// starts the notification thread; later ones reuse it.
pub fn register(context: ?*anyopaque, notifyFn: NotifyFn, mask: Mask) Error!Subscription {
    if (!types.supported) return error.SignalsUnsupported;

    transitionMutex.lock();
    defer transitionMutex.unlock();

    if (!installed) {
        backend.init() catch return error.SignalsUnsupported;
        installed = true;
    }

    stateMutex.lock();
    var selected: ?*Slot = null;
    for (&slots) |*slot| {
        if (!slot.active) {
            selected = slot;
            break;
        }
    }
    if (selected == null) {
        stateMutex.unlock();
        if (activeCount == 0) {
            backend.deinit();
            installed = false;
        }
        return error.SignalCapacityExceeded;
    }

    const slot = selected.?;
    slot.context = context;
    slot.notifyFn = notifyFn;
    slot.mask = mask;
    slot.inFlight.store(0, .release);
    slot.active = true;
    activeCount += 1;

    if (thread == null) {
        running = true;
        thread = std.Thread.spawn(.{}, threadMain, .{}) catch {
            slot.active = false;
            slot.notifyFn = null;
            activeCount -= 1;
            running = false;
            stateMutex.unlock();
            if (activeCount == 0) {
                backend.deinit();
                installed = false;
            }
            return error.ThreadSpawnFailed;
        };
    }
    stateMutex.unlock();

    return .{ .slot = slot };
}

fn remove(slot: *Slot) void {
    transitionMutex.lock();
    defer transitionMutex.unlock();

    stateMutex.lock();
    if (!slot.active) {
        stateMutex.unlock();
        return;
    }
    slot.active = false;
    slot.notifyFn = null;
    activeCount -= 1;
    const last = activeCount == 0;
    if (last) running = false;
    stateMutex.unlock();

    if (last) {
        backend.wake();
        if (thread) |handle| {
            handle.join();
            stateMutex.lock();
            thread = null;
            stateMutex.unlock();
        }
        if (installed) {
            backend.deinit();
            installed = false;
        }
    }

    // A notification may already have snapshotted this slot before `active`
    // was cleared. Wait for it to finish before the caller frees the context.
    while (slot.inFlight.load(.acquire) != 0) std.atomic.spinLoopHint();
    slot.context = null;
    slot.mask = .{};
}

fn threadMain() void {
    while (true) {
        backend.wait();

        stateMutex.lock();
        const shouldRun = running;
        stateMutex.unlock();
        if (!shouldRun) return;

        for (backendKinds) |kind| {
            const count = backend.take(kind);
            if (count != 0) dispatch(kind, count);
        }
    }
}

fn dispatch(kind: Kind, count: u32) void {
    var targets: [maxSubscribers]*Slot = undefined;
    var targetCount: usize = 0;

    stateMutex.lock();
    for (&slots) |*slot| {
        if (slot.active and slot.mask.includes(kind)) {
            _ = slot.inFlight.fetchAdd(1, .acq_rel);
            targets[targetCount] = slot;
            targetCount += 1;
        }
    }
    stateMutex.unlock();

    for (targets[0..targetCount]) |slot| {
        if (slot.notifyFn) |notify| notify(slot.context, .{ .kind = kind, .count = count });
        _ = slot.inFlight.fetchSub(1, .acq_rel);
    }
}

test "mask includes only enabled kinds" {
    const mask = Mask{ .interrupt = true, .terminate = false };
    try std.testing.expect(mask.includes(.interrupt));
    try std.testing.expect(!mask.includes(.terminate));
}

test "multiple subscriptions share one process backend" {
    if (!supported) return error.SkipZigTest;
    const Handler = struct {
        fn notify(_: ?*anyopaque, _: Event) void {}
    };
    const first = try register(null, Handler.notify, .{});
    const second = try register(null, Handler.notify, .{});
    first.unregister();
    // Idempotent: a second unregister is safe and does not disturb `second`.
    first.unregister();
    second.unregister();
}

test "subscription capacity is bounded and reusable" {
    if (!supported) return error.SkipZigTest;
    const Handler = struct {
        fn notify(_: ?*anyopaque, _: Event) void {}
    };
    var subscriptions: [maxSubscribers]Subscription = undefined;
    for (&subscriptions) |*subscription| {
        subscription.* = try register(null, Handler.notify, .{});
    }
    try std.testing.expectError(error.SignalCapacityExceeded, register(null, Handler.notify, .{}));
    for (&subscriptions) |*subscription| subscription.unregister();
    // Capacity is available again after the last unregister.
    const again = try register(null, Handler.notify, .{});
    again.unregister();
}
