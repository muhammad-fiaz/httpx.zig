//! Simple GET Request Example
//!
//! Demonstrates making a basic HTTP GET request using httpx.zig.

const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Simple GET Request Example ===\n\n", .{});

    const cfg = httpx.ClientConfig.forBaseUrl("https://httpbin.org")
        .withTimeouts(httpx.Timeouts.fast())
        .withPoolLimits(16, 4);
    var client = httpx.Client.initWithConfig(allocator, cfg);
    defer client.deinit();

    const req_opts = httpx.RequestOptions.defaults()
        .withTimeoutMs(5_000)
        .withFollowRedirects(true);

    std.debug.print("Creating GET request to httpbin.org...\n", .{});

    var request = try httpx.Request.init(allocator, .GET, "https://httpbin.org/get");
    defer request.deinit();

    try request.headers.set("Accept", "application/json");
    try request.headers.set("User-Agent", "httpx.zig/1.0");

    const serialized = try httpx.formatRequest(&request, allocator);
    defer allocator.free(serialized);

    std.debug.print("\nRequest:\n", .{});
    std.debug.print("--------\n", .{});
    std.debug.print("{s}\n", .{serialized});

    std.debug.print("\nClient config preview:\n", .{});
    std.debug.print("  base_url: {s}\n", .{client.config.base_url orelse "(none)"});
    std.debug.print("  connect timeout: {d}ms\n", .{client.config.timeouts.connect_ms});
    std.debug.print("  request timeout override: {d}ms\n", .{req_opts.timeout_ms orelse 0});

    std.debug.print("\nDemo complete! (Network request skipped for offline demo)\n", .{});
    std.debug.print("\nHTTP Method Properties:\n", .{});
    std.debug.print("  GET is idempotent: {}\n", .{httpx.Method.GET.isIdempotent()});
    std.debug.print("  GET is safe: {}\n", .{httpx.Method.GET.isSafe()});
    std.debug.print("  GET has request body: {}\n", .{httpx.Method.GET.hasRequestBody()});
}
