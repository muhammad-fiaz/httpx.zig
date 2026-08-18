const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var request = try httpx.Request.init(allocator, .GET, "http://httpbun.com/get");
    defer request.deinit();

    try request.headers.set("Accept", "application/json");
    try request.headers.set("User-Agent", httpx.DEFAULT_USER_AGENT);

    const serialized = try httpx.formatRequest(&request, allocator);
    defer allocator.free(serialized);

    std.debug.print("{s}\n", .{serialized});

    var client = httpx.Client.initWithConfig(allocator, httpx.ClientConfig.defaults()
        .withTimeouts(httpx.Timeouts.fast())
        .withRetryPolicy(httpx.RetryPolicy.noRetry()));
    defer client.deinit();

    var response = client.get("http://httpbun.com/get", .{
        .timeout_ms = 10_000,
    }) catch |err| {
        std.debug.print("Request failed: {} (network may be unavailable)\n", .{err});
        std.debug.print("  GET is idempotent: {}\n", .{httpx.Method.GET.isIdempotent()});
        std.debug.print("  GET is safe: {}\n", .{httpx.Method.GET.isSafe()});
        std.debug.print("  GET has request body: {}\n", .{httpx.Method.GET.hasRequestBody()});
        return;
    };
    defer response.deinit();

    std.debug.print("Status: {d}\n", .{response.status.code});
    const body = response.body orelse "";
    std.debug.print("Body length: {d} bytes\n", .{body.len});
    std.debug.print("Body:\n{s}\n", .{body});

    std.debug.print("  GET is idempotent: {}\n", .{httpx.Method.GET.isIdempotent()});
    std.debug.print("  GET is safe: {}\n", .{httpx.Method.GET.isSafe()});
    std.debug.print("  GET has request body: {}\n", .{httpx.Method.GET.hasRequestBody()});
}
