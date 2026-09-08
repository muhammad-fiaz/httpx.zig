//! httpx.zig Comprehensive Performance Benchmark Suite
//!
//! Measures real-world performance of all core HTTPX subsystems targeting
//! Zig 0.16.0 ReleaseFast:
//!   - Core Operations & Parsing (Headers, URI, Status, Method, HTTP/1.1 parser)
//!   - Server Routing & Dispatch (Static routes, Parameterized routes, Dispatch)
//!   - Data Serialization (JSON stringify & typed parsing)
//!   - Authentication (Basic Auth encode/decode, Bearer token parsing)
//!   - Compression & Codecs (Gzip & Deflate compression/decompression)
//!   - Web & DOM Parsing (HTML5 document tokenization & DOM tree construction)
//!   - Concurrency & Threading (Worker pool task submit, Bounded MPMC queue)
//!   - DNS Resolution Subsystem (Thread-safe DNS cache hit lookup)
//!   - HTTP/2 & QUIC/HTTP/3 Primitives (Frame header, HPACK integer, QUIC varint)
//!   - Local Loopback Client/Server (End-to-end HTTP/1.1 keep-alive requests)

const std = @import("std");
const builtin = @import("builtin");
const httpx = @import("httpx");

pub const BenchConfig = struct {
    iterations: usize,
    warmup_iterations: usize,
    rounds: usize,
};

pub const BenchMetric = struct {
    name: []const u8,
    category: []const u8,
    rounds: usize,
    iterations: usize,
    min_ns: f64,
    avg_ns: f64,
    max_ns: f64,
    ops_per_sec: u64,
    unit: []const u8,
};

var recorded_metrics: std.ArrayList(BenchMetric) = .empty;

fn nowNanos() i96 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Timestamp.now(io, .awake).toNanoseconds();
}

fn runBench(
    category: []const u8,
    name: []const u8,
    unit: []const u8,
    cfg: BenchConfig,
    func: *const fn () void,
) void {
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

    const throughput = if (avg_ns_per_op > 0.0)
        @as(u64, @intFromFloat(1_000_000_000.0 / avg_ns_per_op))
    else
        0;

    std.debug.print("  {s: <24} rounds={d} iters={d: >7} min={d: >8.2}ns avg={d: >8.2}ns max={d: >8.2}ns throughput={d: >10} {s}\n", .{
        name,
        cfg.rounds,
        cfg.iterations,
        min_ns_per_op,
        avg_ns_per_op,
        max_ns_per_op,
        throughput,
        unit,
    });

    recorded_metrics.append(bench_allocator, .{
        .name = name,
        .category = category,
        .rounds = cfg.rounds,
        .iterations = cfg.iterations,
        .min_ns = min_ns_per_op,
        .avg_ns = avg_ns_per_op,
        .max_ns = max_ns_per_op,
        .ops_per_sec = throughput,
        .unit = unit,
    }) catch {};
}

// Global benchmark states
var bench_allocator: std.mem.Allocator = undefined;
var bench_pool: *httpx.WorkerPool = undefined;
var bench_queue: httpx.concurrency.queue.BoundedQueue(usize) = undefined;
var bench_router: httpx.router.Router = undefined;
var bench_dns_cache: *httpx.dns.cache.Cache = undefined;

var sample_compress_raw: []const u8 = undefined;
var sample_gzip_payload: []const u8 = undefined;
var sample_deflate_payload: []const u8 = undefined;

// Group 1: Core Operations & Parsing

fn benchHeadersParse() void {
    var headers = httpx.Headers.init(bench_allocator);
    defer headers.deinit();

    headers.append("Content-Type", "application/json") catch {};
    headers.append("Authorization", "Bearer token-xyz-123456789") catch {};
    headers.append("Accept", "application/json, text/plain, */*") catch {};
    headers.append("User-Agent", "httpx.zig-benchmark/0.2.0") catch {};

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

fn benchMethodLookup() void {
    _ = httpx.Method.fromString("GET");
    _ = httpx.Method.fromString("POST");
    _ = httpx.Method.fromString("DELETE");
}

const raw_req_head = "GET /api/v1/users?page=1 HTTP/1.1\r\nHost: httpbun.com\r\nUser-Agent: httpx/0.2.0\r\nAccept: application/json\r\n\r\n";

fn benchHttp1RequestHead() void {
    _ = httpx.http1.parser.parseRequestHead(raw_req_head) catch return;
}

const raw_hdr_block = "Host: httpbun.com\r\nUser-Agent: httpx/0.2.0\r\nAccept: application/json\r\nAuthorization: Bearer secret-tok\r\nContent-Type: application/json\r\n\r\n";

fn benchHttp1HeaderBlock() void {
    var fields: [16]httpx.http1.parser.Field = undefined;
    _ = httpx.http1.parser.parseHeaderBlock(raw_hdr_block, 0, &fields) catch return;
}

// Group 2: Routing & Middleware

fn dummyHandler(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return httpx.router.Response{
        .status = 200,
        .body = "{\"status\":\"ok\"}",
        .content_type = "application/json",
    };
}

fn benchRouterStaticMatch() void {
    var ctx = httpx.router.Context{
        .allocator = bench_allocator,
        .path = "/api/v1/health",
        .method = .GET,
    };
    _ = bench_router.match(.GET, "/api/v1/health", &ctx);
}

fn benchRouterParamMatch() void {
    var ctx = httpx.router.Context{
        .allocator = bench_allocator,
        .path = "/users/42/profile",
        .method = .GET,
    };
    _ = bench_router.match(.GET, "/users/42/profile", &ctx);
}

fn benchRouterDispatch() void {
    var ctx = httpx.router.Context{
        .allocator = bench_allocator,
        .path = "/api/v1/health",
        .method = .GET,
    };
    _ = bench_router.dispatch(&ctx);
}

// Group 3: Data Serialization

const UserProfile = struct {
    id: u64,
    username: []const u8,
    email: []const u8,
    active: bool,
    score: f64,
};

const sample_user_val = UserProfile{
    .id = 1001,
    .username = "alice_dev",
    .email = "alice@example.com",
    .active = true,
    .score = 99.4,
};

const sample_json_bytes = "{\"id\":1001,\"username\":\"alice_dev\",\"email\":\"alice@example.com\",\"active\":true,\"score\":99.4}";

fn benchJsonStringify() void {
    const str = std.json.Stringify.valueAlloc(bench_allocator, sample_user_val, .{}) catch return;
    defer bench_allocator.free(str);
    std.mem.doNotOptimizeAway(str.len);
}

fn benchJsonParse() void {
    const parsed = std.json.parseFromSlice(UserProfile, bench_allocator, sample_json_bytes, .{}) catch return;
    defer parsed.deinit();
    std.mem.doNotOptimizeAway(parsed.value.id);
}

// Group 4: Auth & Security

fn benchBasicAuthEncode() void {
    var out_buf: [256]u8 = undefined;
    _ = httpx.auth.basic.encodeHeaderValue(&out_buf, "benchmark_user", "password123!");
}

fn benchBasicAuthDecode() void {
    var decode_buf: [256]u8 = undefined;
    _ = httpx.auth.basic.parse("Basic YmVuY2htYXJrX3VzZXI6cGFzc3dvcmQxMjMh", &decode_buf) catch return;
}

fn benchBearerTokenParse() void {
    const header_val = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3j";
    _ = httpx.auth.bearer.parseBearer(header_val);
}

// Group 5: Compression & Codecs

fn benchGzipCompress() void {
    const compressed = httpx.compression.compress(bench_allocator, .gzip, sample_compress_raw) catch return;
    defer bench_allocator.free(compressed);
    std.mem.doNotOptimizeAway(compressed.len);
}

fn benchGzipDecompress() void {
    const decompressed = httpx.compression.decompress(bench_allocator, .gzip, sample_gzip_payload) catch return;
    defer bench_allocator.free(decompressed);
    std.mem.doNotOptimizeAway(decompressed.len);
}

fn benchDeflateCompress() void {
    const compressed = httpx.compression.compress(bench_allocator, .deflate, sample_compress_raw) catch return;
    defer bench_allocator.free(compressed);
    std.mem.doNotOptimizeAway(compressed.len);
}

fn benchDeflateDecompress() void {
    const decompressed = httpx.compression.decompress(bench_allocator, .deflate, sample_deflate_payload) catch return;
    defer bench_allocator.free(decompressed);
    std.mem.doNotOptimizeAway(decompressed.len);
}

// Group 6: Web & DOM Parsing

const sample_html_doc =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head><meta charset="utf-8"><title>HTTPX Benchmark</title></head>
    \\<body>
    \\  <div id="container" class="main-wrapper">
    \\    <header><nav><a href="/">Home</a><a href="/about">About</a></nav></header>
    \\    <main><article><h1>Benchmark</h1><p>High-performance Zig HTTP stack.</p></article></main>
    \\  </div>
    \\</body>
    \\</html>
;

fn benchHtmlParse() void {
    var arena = std.heap.ArenaAllocator.init(bench_allocator);
    defer arena.deinit();
    _ = httpx.parsing.html.parse(arena.allocator(), sample_html_doc, .{}) catch return;
}

// Group 7: Concurrency & Queues

fn benchWorkerPoolSubmit() void {
    const Noop = struct {
        fn run(_: ?*anyopaque, _: *std.atomic.Value(bool)) void {}
    };
    bench_pool.submit(Noop.run, null, null) catch return;
}

fn benchConcurrencyQueue() void {
    bench_queue.push(42) catch return;
    _ = bench_queue.pop() catch return;
}

// Group 8: DNS Subsystem

fn dummyDnsLookup(
    _: ?*anyopaque,
    _: std.Io,
    _: []const u8,
    alloc: std.mem.Allocator,
) httpx.dns.cache.LookupError![]const []const u8 {
    const list = alloc.alloc([]const u8, 1) catch return error.OutOfMemory;
    list[0] = alloc.dupe(u8, "64.23.183.159") catch return error.OutOfMemory;
    return list;
}

fn benchDnsCacheHit() void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const addrs = bench_dns_cache.resolve(io, "httpbun.com") catch return;
    defer {
        for (addrs) |a| bench_allocator.free(a);
        bench_allocator.free(addrs);
    }
    std.mem.doNotOptimizeAway(addrs.len);
}

// Group 9: HTTP/2 & QUIC / HTTP/3 Primitives

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

fn benchHpackIntEncode() void {
    var buf: [16]u8 = undefined;
    _ = httpx.proto.common.integer.encode(&buf, 5, 0x20, 1337) catch return;
}

fn benchHpackIntDecode() void {
    const encoded = [_]u8{ 0x3F, 0x9A, 0x0A };
    var offset: usize = 0;
    _ = httpx.proto.common.integer.decode(&encoded, &offset, 5) catch return;
}

fn benchH3VarIntEncode() void {
    var buf: [8]u8 = undefined;
    _ = httpx.quic.varint.encode(&buf, 494878333) catch 0;
}

fn benchH3VarIntDecode() void {
    const encoded = [_]u8{ 0x9D, 0x7F, 0x3E, 0x7D };
    var offset: usize = 0;
    _ = httpx.quic.varint.decode(&encoded, &offset) catch return;
}

// Group 10: Loopback End-to-End Client/Server Request

var loopback_server: *httpx.Server = undefined;
var loopback_thread: std.Thread = undefined;
var loopback_client: httpx.Client = undefined;
var loopback_url: [64]u8 = undefined;
var loopback_url_slice: []const u8 = undefined;

fn loopbackPingHandler(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return httpx.router.Response{
        .status = 200,
        .body = "pong",
        .content_type = "text/plain",
    };
}

fn benchClientServerLoopback() void {
    var res = loopback_client.get(loopback_url_slice, .{}) catch return;
    defer res.deinit();
    std.mem.doNotOptimizeAway(res.status);
}

pub fn main() !void {
    bench_allocator = std.heap.smp_allocator;
    recorded_metrics = std.ArrayList(BenchMetric).empty;
    defer recorded_metrics.deinit(bench_allocator);

    const io = std.Io.Threaded.global_single_threaded.io();

    // 1. Initialize WorkerPool
    var pool = try httpx.WorkerPool.init(bench_allocator, .{ .workers = 2, .queue_capacity = 256 });
    try pool.start();
    defer pool.deinit();
    bench_pool = &pool;

    // 2. Initialize BoundedQueue
    bench_queue = try httpx.concurrency.queue.BoundedQueue(usize).init(bench_allocator, 1024);
    defer bench_queue.deinit();

    // 3. Initialize Router with diverse routes
    bench_router = httpx.router.Router.init(bench_allocator);
    defer bench_router.deinit();
    try bench_router.get("/", dummyHandler);
    try bench_router.get("/api/v1/health", dummyHandler);
    try bench_router.get("/api/v1/status", dummyHandler);
    try bench_router.get("/users/:id", dummyHandler);
    try bench_router.get("/users/:id/profile", dummyHandler);
    try bench_router.get("/users/:id/posts", dummyHandler);
    try bench_router.get("/items/:category/:id", dummyHandler);
    try bench_router.get("/docs", dummyHandler);
    try bench_router.get("/openapi.json", dummyHandler);

    // 4. Initialize DNS Cache
    var dns_cache = httpx.dns.cache.Cache.init(bench_allocator, .{}, dummyDnsLookup, null);
    defer dns_cache.deinit();
    bench_dns_cache = &dns_cache;
    // Prime the cache with an entry
    const primed = try bench_dns_cache.resolve(io, "httpbun.com");
    defer {
        for (primed) |a| bench_allocator.free(a);
        bench_allocator.free(primed);
    }

    // 5. Initialize Compression Sample Data (1024 bytes repetitive JSON payload)
    const json_chunk = "{\"id\":1001,\"name\":\"Benchmark Item\",\"active\":true,\"category\":\"networking\"},";
    var comp_raw = std.ArrayList(u8).empty;
    defer comp_raw.deinit(bench_allocator);
    while (comp_raw.items.len < 1024) {
        try comp_raw.appendSlice(bench_allocator, json_chunk);
    }
    sample_compress_raw = comp_raw.items;
    sample_gzip_payload = try httpx.compression.compress(bench_allocator, .gzip, sample_compress_raw);
    defer bench_allocator.free(sample_gzip_payload);
    sample_deflate_payload = try httpx.compression.compress(bench_allocator, .deflate, sample_compress_raw);
    defer bench_allocator.free(sample_deflate_payload);

    // 6. Initialize Local Loopback Server & Client
    var srv = try httpx.Server.init(bench_allocator, io, .{
        .port = 0,
        .enableDocs = false,
        .keep_alive = true,
        .max_connections = 100000,
    });
    try srv.router.get("/ping", loopbackPingHandler);
    loopback_server = &srv;

    loopback_thread = try std.Thread.spawn(.{}, httpx.Server.run, .{&srv});
    defer {
        loopback_client.deinit();
        srv.requestShutdown();
        loopback_thread.join();
        srv.deinit();
    }

    const bound_port = srv.localPort();
    loopback_url_slice = try std.fmt.bufPrint(&loopback_url, "http://127.0.0.1:{d}/ping", .{bound_port});
    loopback_client = httpx.Client.init(bench_allocator, io, .{});

    // Warm up loopback connection
    {
        var warmup_res = try loopback_client.get(loopback_url_slice, .{});
        warmup_res.deinit();
    }

    std.debug.print("=================================================================================\n", .{});
    std.debug.print("                         httpx.zig Benchmark Suite                              \n", .{});
    std.debug.print("=================================================================================\n\n", .{});
    std.debug.print("Environment: {s}-{s} | Optimization: {s} | Zig: 0.16.0\n", .{
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
        @tagName(builtin.mode),
    });
    std.debug.print("Timestamp:   2026-09-07\n\n", .{});

    const fast_cfg = BenchConfig{ .iterations = 2_000_000, .warmup_iterations = 20_000, .rounds = 5 };
    const core_cfg = BenchConfig{ .iterations = 200_000, .warmup_iterations = 5_000, .rounds = 5 };
    const med_cfg = BenchConfig{ .iterations = 50_000, .warmup_iterations = 1_000, .rounds = 5 };
    const io_cfg = BenchConfig{ .iterations = 5_000, .warmup_iterations = 200, .rounds = 5 };

    std.debug.print("[1] Core Operations & Parsing:\n", .{});
    runBench("Core Operations", "headers_parse", "ops/sec", core_cfg, benchHeadersParse);
    runBench("Core Operations", "uri_parse", "ops/sec", core_cfg, benchUriParse);
    runBench("Core Operations", "status_lookup", "ops/sec", fast_cfg, benchStatusLookup);
    runBench("Core Operations", "method_lookup", "ops/sec", fast_cfg, benchMethodLookup);
    runBench("Core Operations", "http1_request_head", "ops/sec", core_cfg, benchHttp1RequestHead);
    runBench("Core Operations", "http1_header_block", "ops/sec", core_cfg, benchHttp1HeaderBlock);

    std.debug.print("\n[2] Server Routing & Dispatch:\n", .{});
    runBench("Routing", "router_static_match", "ops/sec", core_cfg, benchRouterStaticMatch);
    runBench("Routing", "router_param_match", "ops/sec", core_cfg, benchRouterParamMatch);
    runBench("Routing", "router_dispatch", "ops/sec", core_cfg, benchRouterDispatch);

    std.debug.print("\n[3] Data Serialization:\n", .{});
    runBench("Serialization", "json_stringify", "ops/sec", core_cfg, benchJsonStringify);
    runBench("Serialization", "json_parse", "ops/sec", core_cfg, benchJsonParse);

    std.debug.print("\n[4] Authentication & Security:\n", .{});
    runBench("Security", "basic_auth_encode", "ops/sec", core_cfg, benchBasicAuthEncode);
    runBench("Security", "basic_auth_decode", "ops/sec", core_cfg, benchBasicAuthDecode);
    runBench("Security", "bearer_token_parse", "ops/sec", fast_cfg, benchBearerTokenParse);

    std.debug.print("\n[5] Compression & Codecs (1 KiB payload):\n", .{});
    runBench("Compression", "gzip_compress", "ops/sec", med_cfg, benchGzipCompress);
    runBench("Compression", "gzip_decompress", "ops/sec", med_cfg, benchGzipDecompress);
    runBench("Compression", "deflate_compress", "ops/sec", med_cfg, benchDeflateCompress);
    runBench("Compression", "deflate_decompress", "ops/sec", med_cfg, benchDeflateDecompress);

    std.debug.print("\n[6] Web & Document Parsing:\n", .{});
    runBench("Parsing", "html_parse", "ops/sec", med_cfg, benchHtmlParse);

    std.debug.print("\n[7] Concurrency & Queues:\n", .{});
    runBench("Concurrency", "worker_pool_submit", "ops/sec", core_cfg, benchWorkerPoolSubmit);
    runBench("Concurrency", "concurrency_queue", "ops/sec", core_cfg, benchConcurrencyQueue);

    std.debug.print("\n[8] DNS Resolution Subsystem:\n", .{});
    runBench("DNS", "dns_cache_hit", "ops/sec", core_cfg, benchDnsCacheHit);

    std.debug.print("\n[9] HTTP/2 & QUIC / HTTP/3 Primitives:\n", .{});
    runBench("Protocols", "h2_frame_header", "ops/sec", fast_cfg, benchHttp2FrameHeader);
    runBench("Protocols", "hpack_int_encode", "ops/sec", fast_cfg, benchHpackIntEncode);
    runBench("Protocols", "hpack_int_decode", "ops/sec", fast_cfg, benchHpackIntDecode);
    runBench("Protocols", "h3_varint_encode", "ops/sec", fast_cfg, benchH3VarIntEncode);
    runBench("Protocols", "h3_varint_decode", "ops/sec", fast_cfg, benchH3VarIntDecode);

    std.debug.print("\n[10] Local Loopback Client/Server (HTTP/1.1 keep-alive):\n", .{});
    runBench("Network", "client_server_get", "req/sec", io_cfg, benchClientServerLoopback);

    std.debug.print("\n=================================================================================\n", .{});
    std.debug.print("                         Generated Markdown Table                                \n", .{});
    std.debug.print("=================================================================================\n\n", .{});

    std.debug.print("| Benchmark | Category | Avg Latency | Throughput | Target |\n", .{});
    std.debug.print("| :--- | :--- | :---: | :---: | :---: |\n", .{});
    for (recorded_metrics.items) |m| {
        if (m.avg_ns < 1000.0) {
            std.debug.print("| `{s}` | {s} | {d:.2} ns/op | **{d} {s}** | `{s}-{s}` |\n", .{
                m.name,
                m.category,
                m.avg_ns,
                m.ops_per_sec,
                m.unit,
                @tagName(builtin.cpu.arch),
                @tagName(builtin.os.tag),
            });
        } else if (m.avg_ns < 1_000_000.0) {
            std.debug.print("| `{s}` | {s} | {d:.2} µs/op | **{d} {s}** | `{s}-{s}` |\n", .{
                m.name,
                m.category,
                m.avg_ns / 1000.0,
                m.ops_per_sec,
                m.unit,
                @tagName(builtin.cpu.arch),
                @tagName(builtin.os.tag),
            });
        } else {
            std.debug.print("| `{s}` | {s} | {d:.2} ms/op | **{d} {s}** | `{s}-{s}` |\n", .{
                m.name,
                m.category,
                m.avg_ns / 1_000_000.0,
                m.ops_per_sec,
                m.unit,
                @tagName(builtin.cpu.arch),
                @tagName(builtin.os.tag),
            });
        }
    }

    std.debug.print("\n=== Benchmark Complete ===\n", .{});
}
