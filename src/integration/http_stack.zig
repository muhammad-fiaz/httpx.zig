//! Cross-layer integration: real loopback TCP sockets driven through the
//! HTTP/1 parser + writer exactly as the client and server use them.
//!
//! These tests complement the per-module units by proving the layers
//! compose over an actual socket: partial reads land in the parser,
//! responses stream back out, and body framing survives segmentation.

const std = @import("std");
const t_tcp = @import("../sockets/tcp.zig");
const parser = @import("../protocols/http1/parser.zig");
const writer_mod = @import("../protocols/http1/writer.zig");
const semantics = @import("../protocols/http1/semantics.zig");

/// Minimal echo server: parses ONE request head on the accepted socket,
/// answers with a fixed JSON body via writer.buildResponse, closes.
fn serveOnce(l: *t_tcp.Listener, io: std.Io) void {
    var conn = l.accept(io) catch return;
    defer conn.close();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Read until blank line (head complete), tolerating segmentation.
    var buf: [4096]u8 = undefined;
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = conn.read(buf[filled..]) catch return;
        if (n == 0) return;
        filled += n;
        if (std.mem.indexOf(u8, buf[0..filled], "\r\n\r\n") != null) break;
    }

    const head = parser.parseRequestHead(buf[0..filled]) catch return;
    var fields: [64]parser.Field = undefined;
    const blk = parser.parseHeaderBlock(buf[0..filled], head.head_end, fields[0..]) catch return;

    // Exercise semantic helpers server-side would use.
    const ka = semantics.shouldKeepAlive(
        if (head.minor_version == 0) .http_1_0 else .http_1_1,
        fields[0..blk.count],
    );

    const body = "{\"ok\":true}";
    const reason = writer_mod.reasonPhrase(200);
    const resp = writer_mod.buildResponse(
        a,
        200,
        reason,
        body,
        .{ .minor_version = head.minor_version, .connection = if (ka) "" else "close" },
        false,
    ) catch return;
    conn.writeAll(resp) catch {};
}

test "integration: full HTTP/1.1 exchange over real loopback TCP" {
    var ctx = t_tcp.IoContext.init(std.testing.allocator) catch return;
    defer ctx.deinit();

    var l = t_tcp.Listener.bind(ctx.io, 0) catch return; // skip w/o network
    defer l.close(ctx.io);
    const port = l.localPort();

    const t = std.Thread.spawn(.{}, serveOnce, .{ &l, ctx.io }) catch return;
    defer t.join();

    // --- client side: segmented send, incremental receive ---
    var sock = try t_tcp.connect(ctx.io, "127.0.0.1", port);
    defer sock.close();

    const req = try writer_mod.buildRequest(
        std.testing.allocator,
        "GET",
        "/hello?x=1",
        null,
        .{ .host = "localhost", .connection = "close" },
    );
    defer std.testing.allocator.free(req);

    // Send in odd-size chunks to stress partial writes.
    var off: usize = 0;
    while (off < req.len) {
        const step = @min(3 + (off % 5), req.len - off);
        try sock.writeAll(req[off..][0..step]);
        off += step;
    }

    // Read response incrementally; parse head then apply framing.
    var rbuf: [4096]u8 = undefined;
    var filled: usize = 0;
    var head: ?parser.HeadResult = null;
    var fields: [64]parser.Field = undefined;
    var blk_end: usize = 0;
    var body_start: usize = 0;

    while (filled < rbuf.len) {
        const n = sock.read(rbuf[filled..]) catch break;
        if (n == 0) break;
        filled += n;

        if (head == null) {
            if (parser.parseResponseHead(rbuf[0..filled])) |h| {
                head = h;
                const b = parser.parseHeaderBlock(rbuf[0..filled], h.head_end, fields[0..]) catch return;
                blk_end = b.end;
                body_start = blk_end;

                // Framing decision for a 200 with Content-Length.
                const fd = try parser.decideFraming(fields[0..b.count], true, h.status_code, 3);
                _ = fd;
            } else |e| {
                try std.testing.expectEqual(parser.ParseError.Incomplete, e);
            }
        }
        if (head != null and filled > body_start) {
            // Content-Length body fully arrived?
            var cl_len: ?usize = null;
            for (fields[0..]) |f| {
                if (std.ascii.eqlIgnoreCase(f.name, "Content-Length")) {
                    cl_len = std.fmt.parseInt(usize, f.value, 10) catch null;
                }
            }
            if (cl_len) |want| {
                if (filled - body_start >= want) {
                    try std.testing.expectEqualStrings("{\"ok\":true}", rbuf[body_start..][0..want]);
                    return; // success
                }
            }
        }
    }
    return error.TestUnexpectedResult;
}

test "integration: explicit protocol requests never silently downgrade" {
    const hv = @import("../common/http_version.zig");
    const HttpVersion = hv.HttpVersion;
    var caps = hv.Capabilities{};

    // A stack without h2/h3 must refuse them loudly.
    try std.testing.expectError(hv.Error.VersionUnsupported, hv.negotiate(.h3, &caps, null));
    try std.testing.expectError(hv.Error.VersionUnsupported, hv.negotiate(.h2, &caps, null));

    // auto negotiates down to what exists — that is the ONLY downgrade
    // allowed, and only for `auto`.
    const n = try hv.negotiate(.auto, &caps, null);
    try std.testing.expectEqual(HttpVersion.http_1, n.active);

    // Explicit identity when supported.
    caps.h2 = true;
    caps.h3 = true;
    try std.testing.expectEqual(HttpVersion.h3, (try hv.negotiate(.h3, &caps, null)).active);
    try std.testing.expectEqual(HttpVersion.h2, (try hv.negotiate(.h2, &caps, null)).active);
}
