# Example: Concurrent Demo

Demonstrates concurrentDemo.zig using `httpx.concurrency.Pool` and `httpx.Client`.

## Complete Example

```zig
const std = @import("std");
const httpx = @import("httpx");

fn okHandler(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return .{
        .status = 200,
        .body = "{\"status\":\"ok\"}",
        .contentType = "application/json",
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
    });
    defer server.deinit();
    try server.router.add(.GET, "/get", okHandler, .{});
    try server.router.add(.GET, "/headers", okHandler, .{});
    try server.router.add(.GET, "/ip", okHandler, .{});
    const port = server.localPort();
    const thread = try server.start();

    var u1Buf: [64]u8 = undefined;
    var u2Buf: [64]u8 = undefined;
    var u3Buf: [64]u8 = undefined;
    const urlGet = try std.fmt.bufPrint(&u1Buf, "http://127.0.0.1:{d}/get", .{port});
    const urlHeaders = try std.fmt.bufPrint(&u2Buf, "http://127.0.0.1:{d}/headers", .{port});
    const urlIp = try std.fmt.bufPrint(&u3Buf, "http://127.0.0.1:{d}/ip", .{port});

    var pool = try httpx.concurrency.Pool.init(allocator, io, .{ .workers = 4 });
    defer pool.deinit();

    const FetchTask = struct {
        url: []const u8,
        status: u16 = 0,
        bodyLen: usize = 0,

        fn run(ctx: ?*anyopaque, _: *std.atomic.Value(bool)) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const t_io = std.Io.Threaded.global_single_threaded.io();
            var c = httpx.Client.init(std.heap.smp_allocator, t_io, .{});
            defer c.deinit();

            var resp = try c.get(self.url, .{});
            defer resp.deinit();
            self.status = resp.status;
            self.bodyLen = resp.body.len;
        }
    };

    var tasks = [_]FetchTask{
        .{ .url = urlGet },
        .{ .url = urlHeaders },
        .{ .url = urlIp },
    };

    for (&tasks) |*t| {
        try pool.submit(FetchTask.run, t, null);
    }
    pool.shutdownDrain();
    pool.join();

    for (tasks, 0..) |t, i| {
        std.debug.print("Request {d}: status={d} bodyLen={d}\n", .{ i + 1, t.status, t.bodyLen });
    }

    server.requestShutdown();
    thread.join();
}
```

## Run

```bash
zig build run-concurrent-demo
```
