//! HTTP/2 High-Level Client Runtime Example for httpx.zig
//!
//! This example demonstrates an end-to-end HTTP/2 request/response flow using
//! the high-level client API (`ClientConfig.http2_enabled = true`) against a
//! local loopback HTTP/2 server built from protocol primitives.

const std = @import("std");
const httpx = @import("httpx");

fn sleepMs(ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch {};
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const listen_addr = try httpx.Address.parseIp("127.0.0.1", 0);
    var listener = try httpx.TcpListener.init(listen_addr);
    const addr = try listener.getLocalAddress();
    const port = addr.getPort();

    const server_thread = try std.Thread.spawn(.{}, serverThreadMain, .{&listener});
    defer server_thread.join();
    defer listener.deinit();

    var client = httpx.Client.initWithConfig(allocator, .{
        .http2_enabled = true,
        .keep_alive = false,
    });
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/runtime", .{port});
    defer allocator.free(url);

    var response = try client.get(url, .{});
    defer response.deinit();

    std.debug.print("\n=== HTTP/2 Client Runtime Example ===\n", .{});
    std.debug.print("Response version: {s}\n", .{response.version.toString()});
    std.debug.print("Status: {d}\n", .{response.status.code});
    std.debug.print("Body: {s}\n", .{response.text() orelse ""});
}

fn serverThreadMain(listener: *httpx.TcpListener) void {
    runServer(listener) catch |err| {
        std.debug.print("local h2 server error: {s}\n", .{@errorName(err)});
    };
}

fn runServer(listener: *httpx.TcpListener) !void {
    const allocator = std.heap.page_allocator;

    var accepted = try listener.accept();
    defer accepted.socket.close();

    var preface: [httpx.http.HTTP2_PREFACE.len]u8 = undefined;
    try readNoEofSocket(&accepted.socket, &preface);
    if (!std.mem.eql(u8, &preface, httpx.http.HTTP2_PREFACE)) {
        return error.ProtocolError;
    }

    var h2_conn = httpx.Http2Connection.init(
        allocator,
        accepted.socket.reader(),
        accepted.socket.writer(),
    );

    // Server sends its SETTINGS frame right after receiving the client preface.
    try h2_conn.writeFrame(.{
        .length = 0,
        .frame_type = .settings,
        .flags = 0,
        .stream_id = 0,
    }, &.{});

    var stream_manager = httpx.StreamManager.init(allocator, false);
    defer stream_manager.deinit();

    var request_stream_id: u31 = 0;
    var request_complete = false;

    while (!request_complete) {
        var frame = try h2_conn.readFrame(allocator, 1024 * 1024);
        defer frame.deinit(allocator);

        switch (frame.header.frame_type) {
            .settings => {
                if ((frame.header.flags & 0x01) == 0) {
                    try h2_conn.writeFrame(.{
                        .length = 0,
                        .frame_type = .settings,
                        .flags = 0x01,
                        .stream_id = 0,
                    }, &.{});
                }
            },
            .ping => {
                if ((frame.header.flags & 0x01) == 0 and frame.payload.len == 8) {
                    try h2_conn.writeFrame(.{
                        .length = 8,
                        .frame_type = .ping,
                        .flags = 0x01,
                        .stream_id = 0,
                    }, frame.payload);
                }
            },
            .headers => {
                request_stream_id = frame.header.stream_id;
                const parsed = try httpx.stream.parseHeadersFramePayload(
                    &stream_manager,
                    frame.payload,
                    frame.header.flags,
                    allocator,
                );
                defer {
                    for (parsed.headers) |header| {
                        allocator.free(header.name);
                        allocator.free(header.value);
                    }
                    allocator.free(parsed.headers);
                }

                if ((frame.header.flags & 0x01) != 0) {
                    request_complete = true;
                }
            },
            .data => {
                request_stream_id = frame.header.stream_id;
                if ((frame.header.flags & 0x01) != 0) {
                    request_complete = true;
                }
            },
            .window_update, .priority, .continuation, .push_promise, .goaway, .rst_stream => {},
        }
    }

    if (request_stream_id == 0) return error.ProtocolError;

    const response_body = "hello from local h2 server";
    var len_buf: [32]u8 = undefined;
    const len_str = try std.fmt.bufPrint(&len_buf, "{d}", .{response_body.len});

    const headers = [_]httpx.hpack.HeaderEntry{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-type", .value = "text/plain" },
        .{ .name = "content-length", .value = len_str },
    };

    const headers_payload = try httpx.stream.buildHeadersFramePayload(
        &stream_manager,
        &headers,
        null,
        allocator,
    );
    defer allocator.free(headers_payload.payload);

    try h2_conn.writeFrame(.{
        .length = @intCast(headers_payload.payload.len),
        .frame_type = .headers,
        .flags = headers_payload.flags,
        .stream_id = request_stream_id,
    }, headers_payload.payload);

    try h2_conn.writeFrame(.{
        .length = @intCast(response_body.len),
        .frame_type = .data,
        .flags = 0x01,
        .stream_id = request_stream_id,
    }, response_body);

    // Allow a graceful close so queued response bytes are delivered reliably.
    accepted.socket.shutdownWrite() catch {};
    sleepMs(25);
}

fn readNoEofSocket(socket: *httpx.Socket, out: []u8) !void {
    var read: usize = 0;
    while (read < out.len) {
        const n = try socket.recv(out[read..]);
        if (n == 0) return error.UnexpectedEof;
        read += n;
    }
}
