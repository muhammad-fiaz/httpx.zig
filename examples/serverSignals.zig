//! Cross-platform signal handling and graceful shutdown.
//!
//! With the default configuration Ctrl+C (Windows, Linux, macOS) and SIGTERM
//! (POSIX) stop the server gracefully: acceptance stops, active requests are
//! allowed to finish, and a second signal escalates to immediate shutdown.
//!
//! Build with: `zig build example-server-signals`

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Automatic signal handling is on by default; no custom handler is needed.
    var primary = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 8080,
        .signals = .{ .drainMs = 10_000 },
    });
    defer primary.deinit();

    // Independent second server in the same process. Process-wide termination
    // reaches every server whose signal mask matches.
    var metrics = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 9090,
        .signals = .{ .drainMs = 5_000 },
    });
    defer metrics.deinit();

    // Applications that own signals disable the integration:
    //
    //   .signals = .{ .enabled = false }
    //
    // and call `server.shutdown()` or `server.stop()` themselves.

    const MetricsThread = struct {
        fn run(server: *httpx.Server) void {
            server.run();
        }
    };
    const metricsThread = try std.Thread.spawn(.{}, MetricsThread.run, .{&metrics});

    primary.run();

    // Both servers received the same process-wide event and drained their own
    // in-flight requests. Join the second tier before leaving main.
    metrics.shutdown();
    metricsThread.join();
}
