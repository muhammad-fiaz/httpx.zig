const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var headers = httpx.Headers.init(allocator);
    defer headers.deinit();

    try headers.set(httpx.HeaderName.TRANSFER_ENCODING, "chunked");
    std.debug.print("Transfer-Encoding: chunked\n", .{});
    std.debug.print("  Is chunked: {}\n", .{headers.isChunked()});

    const chunks = [_][]const u8{
        "Hello, ",
        "this is ",
        "chunked ",
        "data!",
    };

    for (chunks) |chunk| {
        std.debug.print("  {x}\r\n", .{chunk.len});
        std.debug.print("  {s}\r\n", .{chunk});
    }
    std.debug.print("  0\r\n", .{});
    std.debug.print("  \r\n", .{});

    var buf = try httpx.buffer.Buffer.init(allocator, 1024);
    defer buf.deinit();

    try buf.append("Streaming data...");
    std.debug.print("  Buffer capacity: {d}\n", .{buf.capacity});
    std.debug.print("  Bytes available: {d}\n", .{buf.len});

    var fixed = httpx.buffer.FixedBuffer(256){};
    try fixed.append("Fixed buffer data");
    std.debug.print("\n  Fixed buffer length: {d}\n", .{fixed.len});
    std.debug.print("  Fixed buffer remaining: {d}\n", .{fixed.remaining()});
}
