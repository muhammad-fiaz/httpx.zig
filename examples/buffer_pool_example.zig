const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pool = try httpx.BufferPool.init(allocator, 8, 4096);
    defer pool.deinit();

    std.debug.print("Pool created: {d} buffers x {d} bytes\n", .{ pool.capacity(), pool.bufferSize() });
    std.debug.print("Available: {d}\n", .{pool.available()});

    const buf1 = pool.acquire() orelse return error.Exhausted;
    const buf2 = pool.acquire() orelse return error.Exhausted;
    std.debug.print("After acquiring 2: {d} available\n", .{pool.available()});

    const msg = "Hello from buffer pool!";
    @memcpy(buf1[0..msg.len], msg);
    std.debug.print("buf1: \"{s}\"\n", .{buf1[0..msg.len]});

    @memset(buf2[0..128], 0xAA);
    std.debug.print("buf2: filled {d} bytes\n", .{128});

    try pool.release(buf1);
    try pool.release(buf2);
    std.debug.print("After releasing 2: {d} available\n", .{pool.available()});

    for (0..6) |cycle| {
        const buf = pool.acquire() orelse {
            std.debug.print("Cycle {d}: no buffers (all in use)\n", .{cycle + 1});
            continue;
        };

        const label = "Cycle";
        @memcpy(buf[0..label.len], label);
        std.debug.print("Cycle {d}: acquired, wrote {d} bytes\n", .{ cycle + 1, label.len });

        try pool.release(buf);
    }

    std.debug.print("Final available: {d}\n", .{pool.available()});

    const foreign = try allocator.alloc(u8, 64);
    defer allocator.free(foreign);

    const result = pool.release(foreign);
    if (result) |_| {
        std.debug.print("ERROR: foreign buffer was accepted!\n", .{});
    } else |err| {
        std.debug.print("Foreign buffer rejected: {}\n", .{err});
    }

    const buf3 = pool.acquire() orelse return error.Exhausted;
    try pool.release(buf3);
    const double_result = pool.release(buf3);
    if (double_result) |_| {
        std.debug.print("ERROR: double release was accepted!\n", .{});
    } else |err| {
        std.debug.print("Double release rejected: {}\n", .{err});
    }
}
