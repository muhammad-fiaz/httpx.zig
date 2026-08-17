//! Server-Sent Events (SSE) Example
//!
//! Demonstrates SSE event formatting and streaming from server to client.
//! Uses `httpx.sse.Event` for W3C-compliant SSE wire format and
//! `Context.sse()` for server-side SSE responses.

const std = @import("std");
const httpx = @import("httpx");

fn sseHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const events = [_]httpx.SseEvent{
        .{ .event = "message", .id = "1", .data = "Hello, SSE!" },
        .{ .event = "update", .id = "2", .data = "Second event" },
        .{ .event = "close", .id = "3", .data = "Stream finished" },
    };
    return ctx.sse(&events);
}

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

fn pickFreeTcpPort() !u16 {
    var listener = try httpx.TcpListener.init(try httpx.Address.parseIp("127.0.0.1", 0));
    defer listener.deinit();
    const addr = try listener.getLocalAddress();
    return addr.getPort();
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Server-Sent Events (SSE) Example ===\n\n", .{});

    // 1. SSE event formatting (W3C wire format)
    std.debug.print("--- SSE Event Formatting ---\n", .{});

    const event1 = httpx.sse.Event{
        .event = "message",
        .id = "1",
        .data = "Hello, World!",
    };
    const formatted = try event1.format(allocator);
    defer allocator.free(formatted);
    std.debug.print("Formatted event:\n{s}\n", .{formatted});

    const event2 = httpx.sse.Event{
        .data = "Multi-line\ndata here",
    };
    const formatted2 = try event2.format(allocator);
    defer allocator.free(formatted2);
    std.debug.print("Multi-line event:\n{s}\n", .{formatted2});

    const event3 = httpx.sse.Event{
        .event = "retry",
        .retry_ms = 5000,
        .data = "Connection lost, reconnecting...",
    };
    const formatted3 = try event3.format(allocator);
    defer allocator.free(formatted3);
    std.debug.print("Retry event:\n{s}\n", .{formatted3});

    // 2. Server returning SSE response
    std.debug.print("--- SSE Server Response ---\n", .{});

    const port = try pickFreeTcpPort();
    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port,
    });
    defer server.deinit();

    try server.get("/events", sseHandler);

    const server_thread = try server.listenInBackground();
    sleepMs(100);

    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry()));
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/events", .{port});
    defer allocator.free(url);

    var resp = try client.get(url, .{});
    defer resp.deinit();

    std.debug.print("GET /events -> status: {d}\n", .{resp.status.code});
    if (resp.text()) |body| {
        std.debug.print("Body:\n{s}\n", .{body});
    }

    std.debug.print("\nSSE use cases:\n", .{});
    std.debug.print("  - Real-time notifications\n", .{});
    std.debug.print("  - Live data feeds (stock prices, logs)\n", .{});
    std.debug.print("  - Progressive content loading\n", .{});

    server.stop();
    server_thread.join();
}
