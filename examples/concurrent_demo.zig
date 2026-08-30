const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const urls = [_][]const u8{
        "http://httpbun.com/get",
        "http://httpbun.com/headers",
        "http://httpbun.com/ip",
    };

    // Run all requests concurrently (array passed directly, no explicit & needed)
    const results = try httpx.getAll(urls);
    defer {
        for (results) |*r| r.deinit();
    }

    for (results, 0..) |result, i| {
        std.debug.print("Request {d}: status={d} body_len={d}\n", .{ i + 1, result.status, result.body.len });
    }

    // Request with options
    const reqs = [_]httpx.RequestOptions{
        .{ .method = .GET, .url = "http://httpbun.com/get" },
        .{ .method = .GET, .url = "http://httpbun.com/headers" },
        .{ .method = .GET, .url = "http://httpbun.com/ip" },
    };

    const results2 = try httpx.requestAll(reqs);
    defer {
        for (results2) |*r| r.deinit();
    }


    for (results2) |result| {
        std.debug.print("Status: {d}\n", .{result.status});
    }
}
