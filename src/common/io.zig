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

test "IoContext lifecycle" {
    const a = std.testing.allocator;
    var ctx = try IoContext.init(a);
    defer ctx.deinit();
    _ = ctx.io;
}
