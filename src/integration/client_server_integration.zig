//! Cross-layer Client-Server integration tests.
//!
//! Validates the complete real-world communication path:
//!   Client -> HTTP Request -> TCP Socket -> Server -> Router -> Middleware -> Response -> Client.

const std = @import("std");
const testing = std.testing;
const httpx = @import("../httpx.zig");

fn helloHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    _ = ctx;
    return .{
        .status = 200,
        .body = "Hello from httpx integration!",
        .content_type = "text/plain",
    };
}

fn echoJsonHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    return .{
        .status = 200,
        .body = ctx.body,
        .content_type = "application/json",
    };
}

fn userParamHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    const name = ctx.param("name") orelse "unknown";
    return .{
        .status = 200,
        .body = name,
        .content_type = "text/plain",
    };
}

test "integration: full client-to-server HTTP/1.1 request-response lifecycle" {
    const a = testing.allocator;

    var server = try httpx.Server.init(a, .{
        .port = 0,
        .docs_enabled = false,
        .logging = .{
            .enabled = true,
            .color = .never,
            .requests = true,
        },
    });
    defer server.deinit();
    // NOTE: Do NOT use max_connections here. The client connection pool reuses a
    // single TCP socket for all 3 requests, so only 1 TCP connection is accepted.
    // max_connections=3 would wait forever for 3 distinct TCP connections that
    // never arrive, causing thread.join() to deadlock.
    // Instead, call server.requestShutdown() after client work is done — it closes
    // the active keep-alive socket (unblocking the server's read loop) and closes
    // the listener so Server.run() exits cleanly.

    try server.get("/hello", &helloHandler);
    try server.post("/echo", &echoJsonHandler);
    try server.get("/users/{name}", &userParamHandler);

    const port = server.localPort();

    const ServerThread = struct {
        fn run(s: *httpx.Server) void {
            s.run();
        }
    };
    const thread = try std.Thread.spawn(.{}, ServerThread.run, .{&server});
    // Shutdown must be signalled BEFORE join so we don't deadlock.
    // defer ordering: join runs first (outer), shutdown runs after (inner).
    defer thread.join();
    defer server.requestShutdown();

    var client = try httpx.Client.init(a, .{});
    defer client.deinit();

    // 1. Test GET /hello
    const url1 = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/hello", .{port});
    defer a.free(url1);
    var res1 = try client.get(.{ .url = url1 });
    defer res1.deinit();

    try testing.expectEqual(@as(u16, 200), res1.status);
    try testing.expectEqualStrings("Hello from httpx integration!", res1.body);

    // 2. Test POST /echo
    const url2 = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/echo", .{port});
    defer a.free(url2);
    const Payload = struct { message: []const u8, count: u32 };
    var res2 = try client.post(.{
        .url = url2,
        .json = Payload{ .message = "integration test", .count = 42 },
    });
    defer res2.deinit();

    try testing.expectEqual(@as(u16, 200), res2.status);
    const parsed = try res2.json(Payload);
    try testing.expectEqualStrings("integration test", parsed.message);
    try testing.expectEqual(@as(u32, 42), parsed.count);

    // 3. Test GET /users/{name}
    const url3 = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/users/alice", .{port});
    defer a.free(url3);
    var res3 = try client.get(.{ .url = url3 });
    defer res3.deinit();

    try testing.expectEqual(@as(u16, 200), res3.status);
    try testing.expectEqualStrings("alice", res3.body);
}
