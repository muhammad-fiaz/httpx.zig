const std = @import("std");
const httpx = @import("httpx");

const CreateUser = struct {
    name: []const u8,
    role: []const u8,
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    // POST with typed JSON struct using unified fetch
    var response = try client.fetch("http://httpbun.com/post", .{
        .method = .POST,
        .json = CreateUser{ .name = "Alice", .role = "developer" },
    });
    defer response.deinit();

    std.debug.print("Status: {d}\n", .{response.status});
    std.debug.print("Body: {s}\n", .{response.bytes()});
}
