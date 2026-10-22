//! HTTP/2 Multiplexing, Flow Control, and HPACK Example.
//!
//! Demonstrates:
//! 1. HPACK Dynamic Table Header Encoding and Decoding (RFC 7541)
//! 2. Frame serialization: HEADERS, DATA, SETTINGS, PING, WINDOW_UPDATE, GOAWAY
//! 3. Full stream multiplexing: three requests in flight on one connection
//! Run with: `zig build run-http2-multiplex`

const std = @import("std");
const httpx = @import("httpx");

/// The response body is copied by the transport right after the handler
/// returns, so it lives in a static buffer.
var response_buf: [256]u8 = undefined;

fn handle(
    _: ?*anyopaque,
    method: []const u8,
    path: []const u8,
    _: []const httpx.http2.transport.Header,
    body: []const u8,
) anyerror!httpx.http2.transport.HandlerResponse {
    if (!std.mem.eql(u8, method, "POST")) {
        return .{ .status = 405, .body = "method not allowed" };
    }
    const head = path[1..];
    @memcpy(response_buf[0..head.len], head);
    response_buf[head.len] = ':';
    @memcpy(response_buf[head.len + 1 ..][0..body.len], body);
    return .{ .status = 200, .body = response_buf[0 .. head.len + 1 + body.len] };
}

fn runServer(lst: *httpx.tcp.Listener, io: std.Io) void {
    var conn = lst.accept(io) catch return;
    defer conn.close();
    httpx.http2.transport.serveConnection(std.heap.page_allocator, &conn, handle, null) catch {};
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== HTTP/2 Advanced Protocol & Multiplexing ===\n", .{});

    // 1. HPACK Dynamic Table Compression (RFC 7541)
    var enc = httpx.http2.hpack.Encoder.init(allocator);
    defer enc.deinit();
    var dec = httpx.http2.hpack.Decoder.init(allocator);
    defer dec.deinit();

    var outEncoded = std.ArrayList(u8).empty;
    defer outEncoded.deinit(allocator);

    const testHeaders = [_]httpx.http2.hpack.HeaderField{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/api/v2/stream" },
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "x-custom-trace", .value = "trace-id-998877" },
    };

    for (testHeaders) |h| {
        try enc.encode(&outEncoded, h.name, h.value, .incremental, false);
    }
    std.debug.print("1. HPACK Encoded {d} headers into {d} compressed bytes (dynamic table entries: {d})\n", .{
        testHeaders.len,
        outEncoded.items.len,
        enc.dyn.entries.items.len,
    });

    const decoded = try dec.decode(outEncoded.items);
    defer {
        for (decoded.fields) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        allocator.free(decoded.fields);
    }
    std.debug.print("   Decoded {d} headers successfully:\n", .{decoded.fields.len});
    for (decoded.fields) |h| {
        std.debug.print("     {s}: {s}\n", .{ h.name, h.value });
    }

    // 2. A real h2c connection with three concurrent streams.
    var ctx = try httpx.tcp.IoContext.init(allocator);
    defer ctx.deinit();
    var listener = try httpx.tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const port = listener.localPort();

    const thread = try std.Thread.spawn(.{}, runServer, .{ &listener, ctx.io });
    defer thread.join();

    const sock = try httpx.tcp.connect(ctx.io, "127.0.0.1", port);
    var client = try httpx.http2.transport.Client.connect(allocator, sock);
    defer client.deinit();

    // 3. Multiplexing: all three requests are in flight before any
    // response is read.
    const bodies = [_][]const u8{ "{\"item\":1}", "{\"item\":2}", "{\"item\":3}" };
    const paths = [_][]const u8{ "/one", "/two", "/three" };
    var sids: [3]u31 = undefined;
    for (paths, 0..) |path, i| {
        sids[i] = try client.beginRequest("POST", path, &.{}, "http", "localhost", bodies[i], httpx.http2.transport.maxResponseBodySize);
    }
    std.debug.print("2. Multiplexed streams {d}, {d}, {d} in flight on one connection\n", .{ sids[0], sids[1], sids[2] });

    // The request bodies are written afterwards; every stream shares the
    // connection-level flow-control window.
    for (sids, 0..) |sid, i| {
        var sent: usize = 0;
        while (!try client.sendRequestBody(sid, bodies[i], &sent)) {
            // The window is exhausted: let the peer open it.
            try client.pump();
        }
    }

    for (sids) |sid| {
        const res = try client.awaitResponse(sid);
        defer res.deinit();
        std.debug.print("   stream {d}: status={d} body={s}\n", .{ sid, res.status, res.body });
    }

    std.debug.print("HTTP/2 multiplexing demonstration completed successfully.\n", .{});
}
