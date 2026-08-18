const std = @import("std");
const httpx = @import("httpx");

fn logRequest(request: *httpx.Request, context: ?*anyopaque) anyerror!void {
    _ = context;
    std.debug.print("[Interceptor] Request: {s} {s}\n", .{
        request.method.toString(),
        request.uri.path,
    });
}

fn logResponse(response: *httpx.Response, context: ?*anyopaque) anyerror!void {
    _ = context;
    std.debug.print("[Interceptor] Response: {d} {s}\n", .{
        response.status.code,
        response.status.phrase,
    });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = httpx.Client.initWithConfig(allocator, .{
        .user_agent = "httpx.zig-interceptor-demo/1.0",
        .follow_redirects = true,
    });
    defer client.deinit();

    try client.addInterceptor(.{
        .request_fn = logRequest,
        .response_fn = logResponse,
        .context = null,
    });

    std.debug.print("Interceptors registered: {d}\n", .{client.interceptors.items.len});
}
