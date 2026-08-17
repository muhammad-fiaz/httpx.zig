//! Retry Policy Example
//!
//! Demonstrates client retry with exponential backoff.
//! Shows RetryPolicy configuration including max_retries, initial_delay_ms,
//! max_delay_ms, backoff_multiplier, and retry_on_status.

const std = @import("std");
const httpx = @import("httpx");

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

    std.debug.print("=== Retry Policy Example ===\n\n", .{});

    // 1. Default retry policy
    std.debug.print("--- Default RetryPolicy ---\n", .{});
    const default = httpx.RetryPolicy{};
    std.debug.print("  max_retries:              {d}\n", .{default.max_retries});
    std.debug.print("  initial_delay_ms:         {d}\n", .{default.initial_delay_ms});
    std.debug.print("  max_delay_ms:             {d}\n", .{default.max_delay_ms});
    std.debug.print("  backoff_multiplier:       {d}\n", .{default.backoff_multiplier});
    std.debug.print("  retry_on_connection_err:  {}\n", .{default.retry_on_connection_error});
    std.debug.print("  retry_only_idempotent:    {}\n", .{default.retry_only_idempotent});

    // 2. Exponential backoff calculation
    std.debug.print("\n--- Exponential Backoff ---\n", .{});
    for (0..6) |attempt| {
        const delay = default.calculateDelay(@intCast(attempt));
        std.debug.print("  attempt {d}: {d}ms\n", .{ attempt, delay });
    }

    // 3. No-retry policy
    std.debug.print("\n--- No-Retry Policy ---\n", .{});
    const no_retry = httpx.RetryPolicy.noRetry();
    std.debug.print("  max_retries: {d}\n", .{no_retry.max_retries});

    // 4. Aggressive retry policy
    std.debug.print("\n--- Aggressive RetryPolicy ---\n", .{});
    const aggressive = httpx.RetryPolicy.aggressive();
    std.debug.print("  max_retries:          {d}\n", .{aggressive.max_retries});
    std.debug.print("  initial_delay_ms:     {d}\n", .{aggressive.initial_delay_ms});
    std.debug.print("  backoff_multiplier:   {d}\n", .{aggressive.backoff_multiplier});
    for (0..6) |attempt| {
        const delay = aggressive.calculateDelay(@intCast(attempt));
        std.debug.print("  attempt {d}: {d}ms\n", .{ attempt, delay });
    }

    // 5. Custom retry policy
    std.debug.print("\n--- Custom RetryPolicy ---\n", .{});
    const custom = httpx.RetryPolicy{
        .max_retries = 10,
        .initial_delay_ms = 200,
        .max_delay_ms = 10_000,
        .backoff_multiplier = 3.0,
        .retry_on_status = &.{ 429, 500, 502, 503, 504 },
        .retry_on_connection_error = true,
        .retry_only_idempotent = false,
    };
    std.debug.print("  max_retries:     {d}\n", .{custom.max_retries});
    std.debug.print("  initial_delay:   {d}ms\n", .{custom.initial_delay_ms});
    std.debug.print("  backoff:         {d}x\n", .{custom.backoff_multiplier});
    for (0..6) |attempt| {
        const delay = custom.calculateDelay(@intCast(attempt));
        std.debug.print("  attempt {d}: {d}ms\n", .{ attempt, delay });
    }

    // 6. Status-based retry check
    std.debug.print("\n--- Status-Based Retry ---\n", .{});
    const statuses = [_]u16{ 200, 429, 500, 503, 404, 502 };
    for (statuses) |s| {
        std.debug.print("  status {d}: retry={}\n", .{ s, custom.shouldRetryStatus(s) });
    }

    // 7. Client with retry policy
    std.debug.print("\n--- Client with Retry ---\n", .{});
    const port = try pickFreeTcpPort();
    var server = httpx.Server.initWithConfig(allocator, .{
        .host = "127.0.0.1",
        .port = port,
    });
    defer server.deinit();

    const server_thread = try server.listenInBackground();
    sleepMs(100);

    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(custom));
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{port});
    defer allocator.free(url);

    var resp = try client.get(url, .{});
    defer resp.deinit();
    std.debug.print("  GET -> status: {d}\n", .{resp.status.code});

    std.debug.print("\nRetry strategies:\n", .{});
    std.debug.print("  - Exponential backoff: delay doubles each retry\n", .{});
    std.debug.print("  - Jitter: add random variance to prevent thundering herd\n", .{});
    std.debug.print("  - Idempotent-only: only retry safe/idempotent methods\n", .{});
    std.debug.print("  - Status-based: retry on specific HTTP error codes\n", .{});

    server.stop();
    server_thread.join();
}
