//! httpx.zig Benchmarks
//!
//! Performance benchmarks for core httpx.zig operations.

const std = @import("std");
const httpx = @import("httpx");

const BenchConfig = struct {
    iterations: usize,
    warmup_iterations: usize,
    rounds: usize,
};

fn nowNanos() i96 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Timestamp.now(io, .awake).toNanoseconds();
}

fn runBenchmark(name: []const u8, cfg: BenchConfig, func: *const fn () void) void {
    for (0..cfg.warmup_iterations) |_| {
        func();
    }

    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var total_ns: u128 = 0;

    for (0..cfg.rounds) |_| {
        const start = nowNanos();
        for (0..cfg.iterations) |_| {
            func();
        }
        const end = nowNanos();

        const elapsed_ns = @as(u64, @intCast(end - start));
        min_ns = @min(min_ns, elapsed_ns);
        max_ns = @max(max_ns, elapsed_ns);
        total_ns += elapsed_ns;
    }

    const avg_ns = @as(u64, @intCast(total_ns / cfg.rounds));
    const min_ns_per_op = @as(f64, @floatFromInt(min_ns)) / @as(f64, @floatFromInt(cfg.iterations));
    const avg_ns_per_op = @as(f64, @floatFromInt(avg_ns)) / @as(f64, @floatFromInt(cfg.iterations));
    const max_ns_per_op = @as(f64, @floatFromInt(max_ns)) / @as(f64, @floatFromInt(cfg.iterations));

    const ops_per_sec = if (avg_ns_per_op > 0.0)
        @as(u64, @intFromFloat(1_000_000_000.0 / avg_ns_per_op))
    else
        0;

    std.debug.print("  {s: <22} rounds={d} iters={d} min={d:.2}ns/op avg={d:.2}ns/op max={d:.2}ns/op throughput={d} ops/sec\n", .{
        name,
        cfg.rounds,
        cfg.iterations,
        min_ns_per_op,
        avg_ns_per_op,
        max_ns_per_op,
        ops_per_sec,
    });
}

var bench_allocator: std.mem.Allocator = undefined;
var bench_pool: *httpx.concurrency.worker_pool.Pool = undefined;

fn benchHeadersParse() void {
    var headers = httpx.Headers.init(bench_allocator);
    defer headers.deinit();

    headers.append("Content-Type", "application/json") catch {};
    headers.append("Authorization", "Bearer token") catch {};
    headers.append("Accept", "application/json") catch {};
    headers.append("User-Agent", "benchmark") catch {};

    _ = headers.get("Content-Type");
    _ = headers.get("Authorization");
}

fn benchUriParse() void {
    _ = httpx.uri.parse("http://httpbun.com:8080/users/123?page=1&limit=10#section") catch {};
}

fn benchStatusLookup() void {
    _ = httpx.status.reasonPhrase(200);
    _ = httpx.status.reasonPhrase(404);
    _ = httpx.status.reasonPhrase(500);
}

fn benchBase64Encode() void {
    var out_buf: [256]u8 = undefined;
    _ = httpx.auth.basic.encodeHeaderValue(&out_buf, "user", "password123");
}

fn benchBase64Decode() void {
    var decode_buf: [256]u8 = undefined;
    _ = httpx.auth.basic.parse("Basic dXNlcjpwYXNzd29yZDEyMw==", &decode_buf) catch return;
}

fn benchMethodLookup() void {
    _ = httpx.Method.fromString("GET");
    _ = httpx.Method.fromString("POST");
    _ = httpx.Method.fromString("DELETE");
}

fn benchWorkerPoolSubmit() void {
    const Noop = struct {
        fn run(_: ?*anyopaque, _: *std.atomic.Value(bool)) void {}
    };

    bench_pool.submit(Noop.run, null, null) catch return;
}

fn benchResponseConstruction() void {
    const resp: httpx.Response = .{
        .status = 200,
        .body = "{\"ok\":true,\"source\":\"bench\"}",
        .content_type = "application/json",
    };
    _ = resp;
}

fn benchHttp2FrameHeader() void {
    const header = httpx.http2.frame.FrameHeader{
        .length = 1024,
        .frame_type = .data,
        .flags = 0x01,
        .stream_id = 1,
    };
    var serialized: [httpx.http2.frame.FRAME_HEADER_SIZE]u8 = undefined;
    header.serialize(&serialized);
    _ = httpx.http2.frame.FrameHeader.parse(&serialized);
}

fn benchVarIntEncoding() void {
    var buf: [8]u8 = undefined;
    _ = httpx.quic.varint.encode(&buf, 494878333) catch 0;
}

pub fn main() !void {
    bench_allocator = std.heap.smp_allocator;

    var pool = try httpx.WorkerPool.init(bench_allocator, .{ .workers = 2, .queue_capacity = 256 });
    try pool.start();
    defer pool.deinit();
    bench_pool = &pool;

    std.debug.print("=== httpx.zig Benchmarks ===\n\n", .{});
    std.debug.print("Host: {s}-{s} ({s})\n\n", .{
        @tagName(@import("builtin").cpu.arch),
        @tagName(@import("builtin").os.tag),
        @tagName(@import("builtin").mode),
    });

    const core_cfg = BenchConfig{ .iterations = 200_000, .warmup_iterations = 5_000, .rounds = 5 };
    const heavy_cfg = BenchConfig{ .iterations = 100_000, .warmup_iterations = 2_000, .rounds = 5 };
    const parser_cfg = BenchConfig{ .iterations = 1_000_000, .warmup_iterations = 20_000, .rounds = 5 };

    std.debug.print("Core Operations:\n", .{});
    runBenchmark("headers_parse", core_cfg, benchHeadersParse);
    runBenchmark("uri_parse", core_cfg, benchUriParse);
    runBenchmark("status_lookup", parser_cfg, benchStatusLookup);
    runBenchmark("method_lookup", parser_cfg, benchMethodLookup);

    std.debug.print("\nAuth & Encoding:\n", .{});
    runBenchmark("basic_auth_encode", heavy_cfg, benchBase64Encode);
    runBenchmark("basic_auth_decode", heavy_cfg, benchBase64Decode);

    std.debug.print("\nResponse Construction:\n", .{});
    runBenchmark("response_construct", heavy_cfg, benchResponseConstruction);

    std.debug.print("\nConcurrency:\n", .{});
    runBenchmark("worker_pool_submit", heavy_cfg, benchWorkerPoolSubmit);

    std.debug.print("\nHTTP/2 & HTTP/3:\n", .{});
    runBenchmark("h2_frame_header", parser_cfg, benchHttp2FrameHeader);
    runBenchmark("h3_varint_encode", BenchConfig{ .iterations = 5_000_000, .warmup_iterations = 50_000, .rounds = 5 }, benchVarIntEncoding);

    std.debug.print("\n=== Benchmark Complete ===\n", .{});
}
