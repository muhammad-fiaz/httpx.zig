//! Simple GET Request Example
//!
//! Demonstrates making a basic HTTP GET request using httpx.zig
//! and deserializing the JSON response into a Zig type.

const std = @import("std");
const httpx = @import("httpx");

const HttpbinResponse = struct {
    args: std.json.Value,
    headers: Headers,
    origin: []const u8,
    url: []const u8,

    const Headers = struct {
        @"Accept": []const u8,
        @"Host": []const u8,
        @"User-Agent": []const u8,
        @"X-Amzn-Trace-Id": []const u8,
    };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Simple GET Request Example ===\n\n", .{});

    var client = httpx.Client.init(allocator);
    defer client.deinit();

    std.debug.print("Making GET request to httpbin.org/get...\n", .{});

    var response = try client.request(.GET, "https://httpbin.org/get", .{
        .headers = &.{
            .{ "Accept", "application/json" },
        },
    });
    defer response.deinit();

    std.debug.print("\nResponse Status: {d} {s}\n", .{ response.status.code, response.status.phrase });

    if (response.text()) |body| {
        const parsed = try std.json.parseFromSlice(HttpbinResponse, allocator, body, .{});
        defer parsed.deinit();
        const data = parsed.value;

        std.debug.print("\nDeserialized response:\n", .{});
        std.debug.print("  origin:     {s}\n", .{data.origin});
        std.debug.print("  url:        {s}\n", .{data.url});
        std.debug.print("  User-Agent: {s}\n", .{data.headers.@"User-Agent"});
        std.debug.print("  Host:       {s}\n", .{data.headers.@"Host"});
    } else {
        std.debug.print("(no body)\n", .{});
    }
}
