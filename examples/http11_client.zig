const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = httpx.Client.init(allocator, io, .{
        .allowLfLineEndings = true,
    });
    defer client.deinit();

    // Dedicated HTTP/1.1 request with headers and query parameters
    var response = try client.get("http://httpbun.com/get", .{
        .httpVersion = .http11,
        .headers = &.{
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "User-Agent", .value = "httpx-http11-client/0.2.0" },
        },
        .query = &.{
            .{ .name = "protocol", .value = "http11" },
            .{ .name = "format", .value = "json" },
        },
    });
    defer response.deinit();

    std.debug.print("Status: {d}\n", .{response.status});
    std.debug.print("Protocol Version: {s}\n", .{@tagName(response.version)});
    if (response.header("content-type")) |ct| {
        std.debug.print("Content-Type: {s}\n", .{ct});
    }
    std.debug.print("Body length: {d} bytes\n", .{response.body.len});
}
