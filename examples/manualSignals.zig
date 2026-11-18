//! Manual signal coordination instead of automatic server integration.
//!
//! Use this pattern when the application owns process shutdown: it disables
//! `.signals`, subscribes to `httpx.signals`, and drives `requestShutdown` /
//! `stop` explicitly. The callback receives the server pointer directly.
//!
//! Build with:
//!   zig build example-manual-signals
//!
//! Run with (real process signals):
//!   zig build run-manual-signals

const std = @import("std");
const httpx = @import("httpx");

fn onSignal(context: ?*anyopaque, event: httpx.signals.Event) void {
    const server: *httpx.Server = @ptrCast(@alignCast(context.?));

    // A second coalesced delivery means the operator asked twice: stop now.
    if (event.count >= 2) {
        server.stop();
    } else {
        server.requestShutdown();
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // The server no longer touches process signals.
    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 8080,
        .signals = .{ .enabled = false },
    });
    defer server.deinit();

    // One process-wide subscription. The server pointer is the context, so no
    // intermediate wrapper type is needed.
    var subscription = try httpx.signals.register(&server, onSignal, .{
        .interrupt = true,
        .terminate = true,
        .close = true,
        .logoff = true,
        .shutdown = true,
    });
    defer subscription.unregister();

    server.run();

    // `unregister` waits for any in-flight callback before returning, so the
    // server is safe to destroy afterwards.
    subscription.unregister();
}
