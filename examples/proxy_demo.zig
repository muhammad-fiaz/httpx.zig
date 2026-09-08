const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    // HTTP proxy (if you have one running)
    // Note: proxy config is set on the request, not client
    var response = client.get("http://httpbun.com/get", .{}) catch |err| {
        std.debug.print("Proxy request failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer response.deinit();

    std.debug.print("Status: {d}\n", .{response.status});
    std.debug.print("Body length: {d}\n", .{response.body.len});
}
