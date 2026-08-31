//! Central I/O ownership for httpx.
//!
//! Provides a single shared `std.Io.Threaded` that lives for the lifetime of the
//! owning Client or Server. All sockets, listeners, TLS and protocol I/O reuse
//! this context, avoiding per-request or per-connection Threaded creation.
//!
//! The helper is intentionally tiny: it only owns the Threaded instance and
//! exposes the `std.Io` value. Callers store the IoContext in their top-level
//! struct (Client, Server, Pool) and pass `ctx.io` to all internal operations
//! without creating new I/O contexts.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const IoContext = struct {
    io: std.Io,
    threaded: *std.Io.Threaded,
    allocator: Allocator,

    pub fn init(allocator: Allocator) !IoContext {
        const threaded = try allocator.create(std.Io.Threaded);
        errdefer allocator.destroy(threaded);
        threaded.* = .init(allocator, .{});
        return .{ .io = threaded.io(), .threaded = threaded, .allocator = allocator };
    }

    pub fn deinit(self: *IoContext) void {
        self.threaded.deinit();
        self.allocator.destroy(self.threaded);
    }
};

/// Global shared I/O for convenience in examples and single-threaded use.
/// Lazily initialized on first use. Not thread-safe for init — call `globalInit`
/// once from the main thread before spawning workers.
var global_state: ?IoContext = null;
var global_mutex: std.Thread.Mutex = .{};

pub fn globalInit(allocator: Allocator) !std.Io {
    global_mutex.lock();
    defer global_mutex.unlock();
    if (global_state == null) {
        global_state = try IoContext.init(allocator);
    }
    return global_state.?.io;
}

pub fn globalDeinit() void {
    global_mutex.lock();
    defer global_mutex.unlock();
    if (global_state) |*s| {
        s.deinit();
        global_state = null;
    }
}

pub fn globalIo() ?std.Io {
    global_mutex.lock();
    defer global_mutex.unlock();
    if (global_state) |s| return s.io;
    return null;
}
