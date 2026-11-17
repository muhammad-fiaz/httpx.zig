//! HTTP/2 over the public client/server API, plus the HPACK engine.
//!
//! Demonstrates:
//! 1. HPACK dynamic-table header encoding and decoding (RFC 7541)
//! 2. A live HTTP/2 (h2c) server started with `httpx.Server.init`
//! 3. Requests issued through `httpx.Client` with `.httpVersion = .http2`
//!
//! The high-level client pools one HTTP/2 connection per origin and
//! serializes requests over it; the protocol engine itself supports true
//! stream multiplexing, which the server side exercises for every stream it
//! accepts.
//!
//! Run with: `zig build run-http2-multiplex`

const std = @import("std");
const httpx = @import("httpx");

/// The response body is copied by the router right after the handler returns,
/// so it lives in a static buffer.
var response_buf: [256]u8 = undefined;

fn echoHandler(ctx: *httpx.router.Context) anyerror!httpx.router.Response {
    const path = ctx.path;
    const body = ctx.body;
    const head = if (path.len > 0 and path[0] == '/') path[1..] else path;
    if (head.len + body.len + 1 > response_buf.len) return error.ResponseTooLarge;
    @memcpy(response_buf[0..head.len], head);
    response_buf[head.len] = ':';
    @memcpy(response_buf[head.len + 1 ..][0..body.len], body);
    return .{
        .status = 200,
        .body = response_buf[0 .. head.len + 1 + body.len],
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

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

    // 2. A live HTTP/2 server, started through the regular server API.
    var server = try httpx.Server.init(allocator, io, .{
        .host = "127.0.0.1",
        .port = 0,
        .protocols = .{ .http2 = true },
    });
    defer server.deinit();

    try server.router.add(.POST, "/{name}", echoHandler, .{});

    const port = server.localPort();
    const thread = try server.start();
    defer {
        server.requestShutdown();
        thread.join();
    }

    // 3. The client speaks HTTP/2 over the pooled connection.
    var client = httpx.Client.init(allocator, io, .{
        .httpVersion = .http2,
    });
    defer client.deinit();

    const bodies = [_][]const u8{ "{\"item\":1}", "{\"item\":2}", "{\"item\":3}" };
    const paths = [_][]const u8{ "/one", "/two", "/three" };
    for (paths, 0..) |path, i| {
        var urlBuf: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&urlBuf, "http://127.0.0.1:{d}{s}", .{ port, path });
        var res = try client.post(url, .{ .body = bodies[i] });
        defer res.deinit();
        std.debug.print("2. POST {s} -> status={d} version={s} body={s}\n", .{ path, res.status, @tagName(res.version), res.body });
        if (res.status != 200) return error.UnexpectedStatus;
        if (res.version != .http2) return error.UnexpectedVersion;
    }

    std.debug.print("HTTP/2 multiplexing demonstration completed successfully.\n", .{});
}
