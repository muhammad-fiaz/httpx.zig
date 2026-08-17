//! Redirect Following Example
//!
//! Demonstrates redirect policy configuration: follow_redirects,
//! max_redirects, preserve_method, preserve_headers, allow_cross_origin,
//! and the getRedirectMethod logic.

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

    std.debug.print("=== Redirect Following Example ===\n\n", .{});

    // 1. Default redirect policy
    std.debug.print("--- Default RedirectPolicy ---\n", .{});
    const default = httpx.RedirectPolicy{};
    std.debug.print("  max_redirects:    {d}\n", .{default.max_redirects});
    std.debug.print("  follow_redirects: {}\n", .{default.follow_redirects});
    std.debug.print("  preserve_method:  {}\n", .{default.preserve_method});
    std.debug.print("  preserve_headers: {}\n", .{default.preserve_headers});
    std.debug.print("  allow_cross_origin: {}\n", .{default.allow_cross_origin});

    // 2. No-follow policy
    std.debug.print("\n--- No-Follow Policy ---\n", .{});
    const no_follow = httpx.RedirectPolicy.noFollow();
    std.debug.print("  follow_redirects: {}\n", .{no_follow.follow_redirects});

    // 3. Strict policy (preserve method)
    std.debug.print("\n--- Strict Policy ---\n", .{});
    const strict = httpx.RedirectPolicy.strict();
    std.debug.print("  preserve_method: {}\n", .{strict.preserve_method});

    // 4. Redirect method determination
    std.debug.print("\n--- Redirect Method Logic ---\n", .{});
    const scenarios = [_]struct { status: u16, method: httpx.Method, label: []const u8 }{
        .{ .status = 301, .method = .POST, .label = "301 Moved (POST)" },
        .{ .status = 302, .method = .POST, .label = "302 Found (POST)" },
        .{ .status = 303, .method = .POST, .label = "303 See Other (POST)" },
        .{ .status = 307, .method = .POST, .label = "307 Temporary (POST)" },
        .{ .status = 308, .method = .POST, .label = "308 Permanent (POST)" },
        .{ .status = 301, .method = .GET, .label = "301 Moved (GET)" },
    };

    for (scenarios) |s| {
        const redirect_method = default.getRedirectMethod(s.status, s.method);
        std.debug.print("  {s: <30} -> {s}\n", .{ s.label, @tagName(redirect_method) });
    }

    std.debug.print("\n  Strict policy:\n", .{});
    for (scenarios) |s| {
        const redirect_method = strict.getRedirectMethod(s.status, s.method);
        std.debug.print("    {s: <30} -> {s}\n", .{ s.label, @tagName(redirect_method) });
    }

    // 5. Client with redirect policy
    std.debug.print("\n--- Client with Redirect ---\n", .{});
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
        .withRetryPolicy(httpx.RetryPolicy.noRetry()));
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{port});
    defer allocator.free(url);

    var resp = try client.get(url, .{});
    defer resp.deinit();
    std.debug.print("  GET -> status: {d}\n", .{resp.status.code});

    // 6. Request options with redirect
    std.debug.print("\n--- Request Options ---\n", .{});
    std.debug.print("  .withFollowRedirects(true/false)  - enable/disable following\n", .{});
    std.debug.print("  .withMaxRedirects(n)              - limit redirect count\n", .{});
    std.debug.print("  .withRedirectPolicy(policy)       - custom policy\n", .{});

    std.debug.print("\nRedirect status codes:\n", .{});
    std.debug.print("  301 Moved Permanently    - follow, change method to GET\n", .{});
    std.debug.print("  302 Found                - follow, change method to GET\n", .{});
    std.debug.print("  303 See Other            - always change to GET\n", .{});
    std.debug.print("  307 Temporary Redirect   - follow, preserve method\n", .{});
    std.debug.print("  308 Permanent Redirect   - follow, preserve method\n", .{});

    std.debug.print("\n=== Redirect Following Example Complete ===\n", .{});

    server.stop();
    server_thread.join();
}
