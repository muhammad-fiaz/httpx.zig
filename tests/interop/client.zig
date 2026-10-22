//! Client half of the independent HTTP/2 and HTTP/3 interoperability
//! checks. Exits non-zero unless status, protocol, and body match.

const std = @import("std");
const httpx = @import("httpx");

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len < 6) return usage();
    const proto = argv[1];
    const method_str = argv[2];
    const url = argv[3];
    const expected = argv[4];
    const ca_path: ?[]const u8 = if (argv.len > 5 and argv[5].len > 0 and !std.mem.eql(u8, argv[5], "-")) argv[5] else null;
    const post_body: ?[]const u8 = if (argv.len > 6 and argv[6].len > 0 and !std.mem.eql(u8, argv[6], "-")) argv[6] else null;

    const method: httpx.Method = if (std.mem.eql(u8, method_str, "POST")) .POST else .GET;
    const version: httpx.HttpVersion = if (std.mem.eql(u8, proto, "h3")) .http3 else .http2;

    var ca_pem: ?[]const u8 = null;
    defer if (ca_pem) |p| a.free(p);
    if (ca_path) |path| {
        ca_pem = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 * 1024));
    }

    var client = httpx.Client.init(a, io, .{});
    defer client.deinit();

    const opts = .{
        .method = method,
        .httpVersion = version,
        .body = post_body,
        .tls = if (ca_pem) |pem| httpx.TlsOptions{ .verify = .caBundle, .caPem = pem } else null,
        .timeoutMs = @as(u64, 20_000),
        .followRedirects = false,
    };
    var res = try client.request(url, opts);
    defer res.deinit();

    if (res.status != 200) {
        std.debug.print("FAIL status={d} expected=200\n", .{res.status});
        return error.UnexpectedStatus;
    }
    if (res.version != version) {
        std.debug.print("FAIL protocol={s} expected={s}\n", .{ @tagName(res.version), @tagName(version) });
        return error.UnexpectedProtocol;
    }
    if (!std.mem.eql(u8, res.body, expected)) {
        if (std.mem.eql(u8, expected, "@large")) {
            if (res.body.len != 256 * 1024) {
                std.debug.print("FAIL large body len={d} expected=262144\n", .{res.body.len});
                return error.UnexpectedBody;
            }
            for (res.body, 0..) |b, i| {
                if (b != 'a' + @as(u8, @intCast(i % 26))) {
                    std.debug.print("FAIL large body mismatch at offset {d}\n", .{i});
                    return error.UnexpectedBody;
                }
            }
        } else {
            std.debug.print("FAIL body={s} expected={s}\n", .{ res.body, expected });
            return error.UnexpectedBody;
        }
    }
    std.debug.print("OK status={d} protocol={s} bytes={d}\n", .{ res.status, @tagName(res.version), res.body.len });
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: interop_client <h2|h3> <GET|POST> <url> <expected-body> [ca-pem] [post-body]\n", .{});
    return error.InvalidArguments;
}
