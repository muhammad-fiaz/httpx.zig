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
//!   - TLS Cryptography (Record AEAD seal, X.509 chain parse)
//!   - Local Loopback Client/Server (End-to-end HTTP/1.1 keep-alive requests)
//!   - HTTP/2 Pooled Requests (amortized H2c GET via the session pool)
//!   - HTTP/3 Live Requests (full QUIC+TLS handshake + GET per op)
//!   - TLS Handshakes (full vs PSK-resumed abbreviated handshake)

const std = @import("std");
const builtin = @import("builtin");
const httpx = @import("httpx");

pub const BenchConfig = struct {
    iterations: usize,
    warmupIterations: usize,
    rounds: usize,
};

pub const BenchMetric = struct {
    name: []const u8,
    category: []const u8,
    rounds: usize,
    iterations: usize,
    minNs: f64,
    avgNs: f64,
    maxNs: f64,
    opsPerSec: u64,
    unit: []const u8,
    /// Iterations that could not complete. A benchmark that failed every
    /// iteration still reports a timing, which is worse than no number at
    /// all, so the count is surfaced and fails the run.
    failures: usize = 0,
};

var recordedMetrics: std.ArrayList(BenchMetric) = .empty;

/// Iterations across the whole run that could not complete.
var benchFailures: usize = 0;

/// Records one failed iteration. Bench bodies return `void`, so a failure
/// would otherwise be indistinguishable from a very fast success.
fn noteFailure() void {
    benchFailures += 1;
}

/// Held once rather than rebuilt per call: `nowNanos` runs twice per round
/// across every benchmark, and re-acquiring the `Io` each time would put
/// harness overhead inside the measurement.
var benchIo: std.Io = undefined;

fn nowNanos() i128 {
    return std.Io.Clock.now(.awake, benchIo).nanoseconds;
}

/// UTC date of this run, so a report never carries a stale hand-written
/// date. Uses the library's wall clock, not the monotonic one the timings
/// use: `.awake` is a performance counter, so it has no calendar epoch.
fn runDate(buf: []u8) []const u8 {
    const epochSecs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divTrunc(httpx.clock.millisNow(), 1000)) };
    const yearDay = epochSecs.getEpochDay().calculateYearDay();
    const md = yearDay.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2}", .{
        yearDay.year,
        md.month.numeric(),
        md.day_index + 1,
    }) catch "unknown";
}

fn runBench(
    category: []const u8,
    name: []const u8,
    unit: []const u8,
    cfg: BenchConfig,
    func: *const fn () void,
) void {
    const failuresBefore = benchFailures;
    for (0..cfg.warmupIterations) |_| {
        func();
    }

    var minNs: u64 = std.math.maxInt(u64);
    var maxNs: u64 = 0;
    var totalNs: u128 = 0;

    for (0..cfg.rounds) |_| {
        const start = nowNanos();
        for (0..cfg.iterations) |_| {
            func();
        }
        const end = nowNanos();

        const elapsedNs = @as(u64, @intCast(end - start));
        minNs = @min(minNs, elapsedNs);
        maxNs = @max(maxNs, elapsedNs);
        totalNs += elapsedNs;
    }

    const avgNs = @as(u64, @intCast(totalNs / cfg.rounds));
    const minNsPerOp = @as(f64, @floatFromInt(minNs)) / @as(f64, @floatFromInt(cfg.iterations));
    const avgNsPerOp = @as(f64, @floatFromInt(avgNs)) / @as(f64, @floatFromInt(cfg.iterations));
    const maxNsPerOp = @as(f64, @floatFromInt(maxNs)) / @as(f64, @floatFromInt(cfg.iterations));

    const throughput = if (avgNsPerOp > 0.0)
        @as(u64, @intFromFloat(1_000_000_000.0 / avgNsPerOp))
    else
        0;

    const failures = benchFailures - failuresBefore;

    std.debug.print("  {s: <24} rounds={d} iters={d: >7} min={d: >8.2}ns avg={d: >8.2}ns max={d: >8.2}ns throughput={d: >10} {s}", .{
        name,
        cfg.rounds,
        cfg.iterations,
        minNsPerOp,
        avgNsPerOp,
        maxNsPerOp,
        throughput,
        unit,
    });
    if (failures != 0) {
        std.debug.print("  !! {d} ITERATIONS FAILED", .{failures});
    }
    std.debug.print("\n", .{});

    recordedMetrics.append(benchAllocator, .{
        .name = name,
        .category = category,
        .rounds = cfg.rounds,
        .iterations = cfg.iterations,
        .minNs = minNsPerOp,
        .avgNs = avgNsPerOp,
        .maxNs = maxNsPerOp,
        .opsPerSec = throughput,
        .unit = unit,
        .failures = failures,
    }) catch {};
}

// Global benchmark states
var benchAllocator: std.mem.Allocator = undefined;
var benchPool: *httpx.WorkerPool = undefined;
var benchQueue: httpx.concurrency.queue.BoundedQueue(usize) = undefined;
var benchRouter: httpx.router.Router = undefined;
var benchDnsCache: *httpx.dns.Cache = undefined;

var sampleCompressRaw: []const u8 = undefined;
var sampleGzipPayload: []const u8 = undefined;
var sampleDeflatePayload: []const u8 = undefined;

// Group 1: Core Operations & Parsing

fn benchHeadersParse() void {
    var headers = httpx.Headers.init(benchAllocator);
    defer headers.deinit();

    headers.append("Content-Type", "application/json") catch {};
    headers.append("Authorization", "Bearer token-xyz-123456789") catch {};
    headers.append("Accept", "application/json, text/plain, */*") catch {};
    headers.append("User-Agent", "httpx.zig-benchmark/0.2.1") catch {};

    std.mem.doNotOptimizeAway(headers.get("Content-Type").?.len);
    std.mem.doNotOptimizeAway(headers.get("Authorization").?.len);
}

fn benchUriParse() void {
    const u = httpx.uri.parse("http://httpbun.com:8080/users/123?page=1&limit=10#section") catch return;
    std.mem.doNotOptimizeAway(u.host.len + u.path.len);
}

fn benchStatusLookup() void {
    const codes = [_]u16{ 200, 404, 500, 301, 403, 204 };
    // `codes` is runtime state, so the lookups cannot be folded away.
    for (codes) |c| std.mem.doNotOptimizeAway(httpx.status.reasonPhrase(c).len);
}

fn benchMethodLookup() void {
    const names = [_][]const u8{ "GET", "POST", "DELETE", "PUT", "PATCH", "HEAD" };
    for (names) |n| std.mem.doNotOptimizeAway(@intFromEnum(httpx.Method.fromString(n) orelse .GET));
}

const rawReqHead = "GET /api/v1/users?page=1 HTTP/1.1\r\nHost: httpbun.com\r\nUser-Agent: httpx/0.2.1\r\nAccept: application/json\r\n\r\n";

fn benchHttp1RequestHead() void {
    const head = httpx.http1.parser.parseRequestHead(rawReqHead, .{}) catch return;
    std.mem.doNotOptimizeAway(head.method.len + head.path.len);
}

const rawHdrBlock = "Host: httpbun.com\r\nUser-Agent: httpx/0.2.1\r\nAccept: application/json\r\nAuthorization: Bearer secret-tok\r\nContent-Type: application/json\r\n\r\n";

fn benchHttp1HeaderBlock() void {
    var fields: [16]httpx.http1.parser.Field = undefined;
    const n = httpx.http1.parser.parseHeaderBlock(rawHdrBlock, 0, &fields, .{}) catch return;
    std.mem.doNotOptimizeAway(n);
}

// Group 2: Routing & Middleware

fn dummyHandler(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return httpx.router.Response{
        .status = 200,
        .body = "{\"status\":\"ok\"}",
        .contentType = "application/json",
    };
}

fn benchRouterStaticMatch() void {
    var ctx = httpx.router.Context{
        .allocator = benchAllocator,
        .path = "/api/v1/health",
        .method = .GET,
    };
    _ = benchRouter.match(.GET, "/api/v1/health", &ctx);
}

fn benchRouterParamMatch() void {
    var ctx = httpx.router.Context{
        .allocator = benchAllocator,
        .path = "/users/42/profile",
        .method = .GET,
    };
    _ = benchRouter.match(.GET, "/users/42/profile", &ctx);
}

fn benchRouterDispatch() void {
    var ctx = httpx.router.Context{
        .allocator = benchAllocator,
        .path = "/api/v1/health",
        .method = .GET,
    };
    _ = benchRouter.dispatch(&ctx);
}

fn benchRouterTypedMatch() void {
    var ctx = httpx.router.Context{
        .allocator = benchAllocator,
        .path = "/users/42/posts/99",
        .method = .GET,
    };
    _ = benchRouter.match(.GET, "/users/42/posts/99", &ctx);
}

fn benchRouterMiss() void {
    var ctx = httpx.router.Context{
        .allocator = benchAllocator,
        .path = "/no/such/route",
        .method = .GET,
    };
    _ = benchRouter.dispatch(&ctx);
}

fn benchRouterReverse() void {
    const u = benchRouter.url("bench_user_post", .{ .userId = 7, .postId = 9 }) catch return;
    defer benchAllocator.free(u);
    std.mem.doNotOptimizeAway(u.len);
}

// Group 3: Data Serialization

const UserProfile = struct {
    id: u64,
    username: []const u8,
    email: []const u8,
    active: bool,
    score: f64,
};

const sampleUserVal = UserProfile{
    .id = 1001,
    .username = "alice_dev",
    .email = "alice@example.com",
    .active = true,
    .score = 99.4,
};

const sampleJsonBytes = "{\"id\":1001,\"username\":\"alice_dev\",\"email\":\"alice@example.com\",\"active\":true,\"score\":99.4}";

fn benchJsonStringify() void {
    const str = std.json.Stringify.valueAlloc(benchAllocator, sampleUserVal, .{}) catch return;
    defer benchAllocator.free(str);
    std.mem.doNotOptimizeAway(str.len);
}

fn benchJsonParse() void {
    const parsed = std.json.parseFromSlice(UserProfile, benchAllocator, sampleJsonBytes, .{}) catch return;
    defer parsed.deinit();
    std.mem.doNotOptimizeAway(parsed.value.id);
}

// Group 4: Auth & Security

fn benchBasicAuthEncode() void {
    var outBuf: [256]u8 = undefined;
    const n = httpx.auth.basic.encodeHeaderValue(&outBuf, "benchmark_user", "password123!");
    std.mem.doNotOptimizeAway(n);
}

fn benchBasicAuthDecode() void {
    var decodeBuf: [256]u8 = undefined;
    const parsed = httpx.auth.basic.parse("Basic YmVuY2htYXJrX3VzZXI6cGFzc3dvcmQxMjMh", &decodeBuf) catch return;
    std.mem.doNotOptimizeAway(parsed.username.len + parsed.password.len);
}

fn benchBearerTokenParse() void {
    const headerVal = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3j";
    std.mem.doNotOptimizeAway(httpx.auth.bearer.parseBearer(headerVal).?.len);
}

// Group 5: Compression & Codecs

fn benchGzipCompress() void {
    const compressed = httpx.compression.compress(benchAllocator, .gzip, sampleCompressRaw) catch return;
    defer benchAllocator.free(compressed);
    std.mem.doNotOptimizeAway(compressed.len);
}

fn benchGzipDecompress() void {
    const decompressed = httpx.compression.decompress(benchAllocator, .gzip, sampleGzipPayload) catch return;
    defer benchAllocator.free(decompressed);
    std.mem.doNotOptimizeAway(decompressed.len);
}

fn benchDeflateCompress() void {
    const compressed = httpx.compression.compress(benchAllocator, .deflate, sampleCompressRaw) catch return;
    defer benchAllocator.free(compressed);
    std.mem.doNotOptimizeAway(compressed.len);
}

fn benchDeflateDecompress() void {
    const decompressed = httpx.compression.decompress(benchAllocator, .deflate, sampleDeflatePayload) catch return;
    defer benchAllocator.free(decompressed);
    std.mem.doNotOptimizeAway(decompressed.len);
}

// Group 6: Web & DOM Parsing

const sampleHtmlDoc =
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
    var arena = std.heap.ArenaAllocator.init(benchAllocator);
    defer arena.deinit();
    _ = httpx.parsing.html.parse(arena.allocator(), sampleHtmlDoc, .{}) catch return;
}

const sampleTemplateSrc = "<h1>{{ title }}</h1>{% for item in items %}<p>{{ item }}</p>{% endfor %}";

fn benchTemplateParse() void {
    var parser = httpx.templates.parser.Parser.init(benchAllocator, "bench.html", sampleTemplateSrc);
    var ast = parser.parse() catch return;
    defer ast.deinit();
}

var benchTemplateAst: ?httpx.templates.parser.TemplateAst = null;

fn benchTemplateRender() void {
    const ast = benchTemplateAst orelse return;
    var ctx = httpx.templates.Context.init(benchAllocator, .{
        .title = "Bench",
        .items = [_][]const u8{ "a", "b", "c" },
    }) catch return;
    defer ctx.deinit();
    const renderer = httpx.templates.renderer.Renderer{};
    const out = renderer.renderToString(benchAllocator, &ast, &ctx, null) catch return;
    defer benchAllocator.free(out);
    std.mem.doNotOptimizeAway(out.len);
}

fn benchTemplateIncremental() void {
    _ = httpx.parsing.html.changedRanges(benchAllocator, sampleHtmlDoc, sampleHtmlDoc) catch return;
}

const sampleJsonFeed =
    \\{
    \\  "version": "https://jsonfeed.org/version/1.1",
    \\  "title": "Benchmark Feed",
    \\  "home_page_url": "https://example.com/",
    \\  "items": [
    \\    { "id": "1", "url": "https://example.com/1", "title": "First", "content_text": "Body one", "author": { "name": "Ada" } },
    \\    { "id": "2", "url": "https://example.com/2", "title": "Second", "content_text": "Body two", "author": { "name": "Grace" } },
    \\    { "id": "3", "url": "https://example.com/3", "title": "Third", "content_text": "Body three", "author": { "name": "Alan" } }
    \\  ]
    \\}
;

fn benchJsonFeedParse() void {
    var feed = httpx.parsing.feed.parse(benchAllocator, sampleJsonFeed, "application/feed+json") catch return;
    defer feed.deinit();
    std.mem.doNotOptimizeAway(feed.entries.len);
}

const sampleReloadPage = "<!DOCTYPE html><html><head><link rel=\"stylesheet\" href=\"/a.css\"></head><body><h1>x</h1></body></html>";

fn benchLiveReloadInject() void {
    const out = httpx.static.reload.inject(benchAllocator, sampleReloadPage, "/__httpx_liveReload") catch return;
    std.mem.doNotOptimizeAway(out.len);
    benchAllocator.free(out);
}

var benchWatcher: ?*httpx.Watcher = null;

fn benchWatcherScan() void {
    const w = benchWatcher orelse return;
    _ = w.scan() catch false;
}

var benchDepGraph: ?*httpx.web.watcherDependency.DependencyGraph = null;

fn benchWatcherDeps() void {
    const g = benchDepGraph orelse return;
    const affected = g.affectedSet(benchAllocator, "base.html") catch return;
    defer {
        for (affected) |s| benchAllocator.free(s);
        benchAllocator.free(affected);
    }
    std.mem.doNotOptimizeAway(affected.len);
}

// Group 7: Concurrency & Queues

fn benchWorkerPoolSubmit() void {
    const Noop = struct {
        fn run(_: ?*anyopaque, _: *std.atomic.Value(bool)) void {}
    };
    benchPool.submit(Noop.run, null, null) catch return;
}

fn benchConcurrencyQueue() void {
    benchQueue.push(42) catch return;
    _ = benchQueue.pop() catch return;
}

// Group 8: DNS Subsystem

fn dummyDnsLookup(
    _: ?*anyopaque,
    _: std.Io,
    _: []const u8,
    alloc: std.mem.Allocator,
) httpx.dns.LookupError![]const []const u8 {
    const list = alloc.alloc([]const u8, 1) catch return error.OutOfMemory;
    list[0] = alloc.dupe(u8, "64.23.183.159") catch return error.OutOfMemory;
    return list;
}

fn benchDnsCacheHit() void {
    const addrs = benchDnsCache.resolve("httpbun.com") catch return;
    defer {
        for (addrs) |a| benchAllocator.free(a);
        benchAllocator.free(addrs);
    }
    std.mem.doNotOptimizeAway(addrs.len);
}

// Group 9: HTTP/2 & QUIC / HTTP/3 Primitives

fn benchHttp2FrameHeader() void {
    const header = httpx.http2.FrameHeader{
        .length = 1024,
        .frameType = .data,
        .flags = 0x01,
        .streamId = 1,
    };
    var serialized: [httpx.http2.frame.FRAME_HEADER_SIZE]u8 = undefined;
    header.serialize(&serialized);
    const parsed = httpx.http2.FrameHeader.parse(&serialized);
    std.mem.doNotOptimizeAway(parsed.length);
    std.mem.doNotOptimizeAway(parsed.streamId);
}

fn benchHpackIntEncode() void {
    var buf: [16]u8 = undefined;
    const n = httpx.proto.common.integer.encode(&buf, 5, 0x20, 1337) catch return;
    std.mem.doNotOptimizeAway(n);
}

fn benchHpackIntDecode() void {
    const encoded = [_]u8{ 0x3F, 0x9A, 0x0A };
    var offset: usize = 0;
    const v = httpx.proto.common.integer.decode(&encoded, &offset, 5) catch return;
    std.mem.doNotOptimizeAway(v);
}

fn benchH3VarIntEncode() void {
    var buf: [8]u8 = undefined;
    // Varying the magnitude keeps the encoder from being folded to a
    // constant and makes the 1/2/4/8-byte branches all get exercised.
    const values = [_]u64{ 25, 15293, 494878333, 1512888099419124471 };
    for (values) |v| std.mem.doNotOptimizeAway(httpx.quic.varint.encode(&buf, v) catch 0);
}

fn benchH3VarIntDecode() void {
    const encodeds = [_][]const u8{
        &[_]u8{0x19},
        &[_]u8{ 0x7B, 0xBD },
        &[_]u8{ 0x9D, 0x7F, 0x3E, 0x7D },
        &[_]u8{ 0xC2, 0x19, 0x7C, 0x5E, 0xFF, 0x14, 0xE8, 0x8C },
    };
    for (encodeds) |encoded| {
        var offset: usize = 0;
        std.mem.doNotOptimizeAway(httpx.quic.varint.decode(encoded, &offset) catch return);
    }
}

// Group 10: TLS Record Cryptography & X.509 Parsing

var sampleTlsPayload: [1024]u8 = undefined;
const sampleTlsKey: [32]u8 = [_]u8{0x42} ** 32;
const sampleTlsIv: [12]u8 = [_]u8{0x24} ** 12;
const sampleCertPem =
    \\-----BEGIN CERTIFICATE-----
    \\MIIBmTCCAT+gAwIBAgIURhx0CMJWTUTFJXV9z2OlmW/cNlcwCgYIKoZIzj0EAwIw
    \\FDESMBAGA1UEAwwJMTI3LjAuMC4xMB4XDTI2MDkwOTE4MTczOFoXDTM2MDkwNjE4
    \\MTczOFowFDESMBAGA1UEAwwJMTI3LjAuMC4xMFkwEwYHKoZIzj0CAQYIKoZIzj0D
    \\AQcDQgAE71D4pM0SAPK8sdt+xlEESZX/EJoKHUC+4IpPuSlOiQuCXOkN04ozVGKA
    \\mrmUtDqQCdvmdjHbjqGY6TCszXTCnKNvMG0wHQYDVR0OBBYEFFjYJYGodkVKyvXf
    \\4qrn7rvQx+PFMB8GA1UdIwQYMBaAFFjYJYGodkVKyvXf4qrn7rvQx+PFMA8GA1Ud
    \\EwEB/wQFMAMBAf8wGgYDVR0RBBMwEYcEfwAAAYIJbG9jYWxob3N0MAoGCCqGSM49
    \\BAMCA0gAMEUCIQD0sAcuw/jdWdfBrxLXY1ur2cU8F0CAkPCvS2qKn7XK4QIgAP71
    \\95toW+Gsh8/VZlNoHL2s14olRp5zl3cYDPzKM10=
    \\-----END CERTIFICATE-----
;

fn benchTlsRecordSeal() void {
    const rec = httpx.tls.record.encodeRecord(
        .application_data,
        &sampleTlsPayload,
        0,
        &sampleTlsKey,
        &sampleTlsIv,
        .chacha20Poly1305,
    ) catch return;
    std.mem.doNotOptimizeAway(rec.len);
}

fn benchCertParse() void {
    var chain = httpx.tls.certificate.parseCertificateChainPem(benchAllocator, sampleCertPem) catch return;
    defer chain.deinit();
    std.mem.doNotOptimizeAway(chain.count());
}

// Group 11: Loopback End-to-End Client/Server Request

var loopbackServer: *httpx.Server = undefined;
var loopbackThread: std.Thread = undefined;
var loopbackClient: httpx.Client = undefined;
var loopbackUrl: [64]u8 = undefined;
var loopbackUrlSlice: []const u8 = undefined;

fn loopbackPingHandler(_: *httpx.router.Context) anyerror!httpx.router.Response {
    return httpx.router.Response{
        .status = 200,
        .body = "pong",
        .contentType = "text/plain",
    };
}

fn benchClientServerLoopback() void {
    var res = loopbackClient.get(loopbackUrlSlice, .{}) catch {
        noteFailure();
        return;
    };
    defer res.deinit();
    std.mem.doNotOptimizeAway(res.status);
}

// Group 12: HTTP/2 pooled loopback (h2c prior knowledge, one server conn)

var h2BenchListener: httpx.tcp.Listener = undefined;
var h2BenchThread: std.Thread = undefined;
var h2BenchClient: httpx.Client = undefined;
var h2BenchUrl: [64]u8 = undefined;
var h2BenchUrlSlice: []const u8 = undefined;
var h2BenchIo: std.Io = undefined;

fn h2BenchHandler(_: ?*anyopaque, method: []const u8, path: []const u8, _: []const httpx.http2.transport.Header, _: []const u8) anyerror!httpx.http2.transport.HandlerResponse {
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/ping")) {
        return .{ .status = 200, .body = "pong" };
    }
    return .{ .status = 404, .body = "nope" };
}

var h2BenchStop: std.atomic.Value(bool) = .init(false);

fn h2BenchServe() void {
    while (!h2BenchStop.load(.acquire)) {
        var conn = h2BenchListener.accept(h2BenchIo) catch {
            if (h2BenchStop.load(.acquire)) return;
            continue;
        };
        defer conn.close();
        httpx.http2.transport.serveConnection(benchAllocator, &conn, h2BenchHandler, null) catch {};
    }
}

fn benchH2PooledGet() void {
    var res = h2BenchClient.get(h2BenchUrlSlice, .{ .httpVersion = .http2 }) catch {
        noteFailure();
        return;
    };
    defer res.deinit();
    std.mem.doNotOptimizeAway(res.status);
}

// Group 13: HTTP/3 live loopback (fresh QUIC+TLS handshake per op)

var h3BenchServer: H3BenchServer = undefined;
var h3BenchThread: std.Thread = undefined;
var h3BenchClient: httpx.Client = undefined;
var h3BenchUrl: [128]u8 = undefined;
var h3BenchUrlSlice: []const u8 = undefined;
var h3BenchStop: std.atomic.Value(bool) = .init(false);

const H3BenchServer = struct {
    ep: httpx.quic.Endpoint = undefined,
    pump: httpx.quic.Pump = undefined,

    const Acc = struct {
        sid: u64 = std.math.maxInt(u64),
        buf: std.ArrayList(u8) = .empty,
        fin: bool = false,
    };

    fn onStream(c: ?*anyopaque, sid: u64, data: []const u8, fin: bool) void {
        const acc: *Acc = @ptrCast(@alignCast(c.?));
        if (acc.sid == std.math.maxInt(u64) and sid % 4 == 0) acc.sid = sid;
        if (sid != acc.sid) return;
        acc.buf.appendSlice(benchAllocator, data) catch return;
        if (fin) acc.fin = true;
    }

    fn run(srv: *H3BenchServer) void {
        // Free the placeholder connection installed during setup; each
        // iteration below allocates its own fresh server Connection.
        srv.ep.conn.deinit();
        srv.ep.conn = undefined;
        while (!h3BenchStop.load(.acquire)) {
            const alloc = benchAllocator;

            // Stop and restart the pump so stale datagrams from the previous
            // client are drained and the reader thread is synchronized with
            // the fresh connection. Without this, datagrams arriving during
            // the conn-swap gap are fed to an uninitialized connection, the
            // boot handshake discards them, and the next feedPumped call
            // blocks until its full 10-second timeout — deadlocking the bench.
            srv.pump.stop();
            // Reset peer: old client address must not bleed into the new conn.
            srv.ep.peer = null;

            // Allocate a fresh server Connection for this incoming client.
            const qconn = httpx.quic.Connection.init(alloc, srv.ep.io, .server, .{}) catch continue;
            srv.ep.conn = qconn;

            // Restart pump with the new conn in place BEFORE serveOne so the
            // reader thread starts capturing the client's Initial packet
            // immediately.
            srv.pump.start(&srv.ep, alloc) catch {
                qconn.deinit();
                srv.ep.conn = undefined;
                continue;
            };

            serveOne(srv, qconn) catch {
                // deinit before looping to avoid leaking on error path.
                qconn.deinit();
                srv.ep.conn = undefined;
                continue;
            };
            qconn.deinit();
            srv.ep.conn = undefined;
        }
        // Final pump stop so the global defer in main can join cleanly.
        srv.pump.stop();
    }

    /// Serve exactly one HTTP/3 request on the already-assigned `srv.ep.conn`.
    /// Ownership of `qconn` stays with `run()`; this function must not deinit it.
    fn serveOne(srv: *H3BenchServer, qconn: *httpx.quic.Connection) !void {
        const alloc = benchAllocator;
        var drv = httpx.quic.HandshakeDriver.initServer(srv.ep.io, alloc, .{ .certChainPem = benchCertPem, .privateKeyPem = benchKeyPem });
        defer drv.deinit();
        qconn.tls = .{ .ctx = &drv, .start = httpx.quic.HandshakeDriver.clientStart, .onData = httpx.quic.HandshakeDriver.onData };
        try httpx.quic.handshake.serveHandshake(&srv.ep, &srv.pump, &drv, 10_000);
        var h3 = httpx.http3.Connection.init(alloc, .server);
        defer h3.deinit();
        var acc = Acc{};
        defer acc.buf.deinit(alloc);
        qconn.cbs = .{ .ctx = &acc, .onStreamData = onStream };
        const start: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(h3BenchIo, .awake).toNanoseconds(), 1_000_000));
        while (true) {
            const now: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(h3BenchIo, .awake).toNanoseconds(), 1_000_000));
            if (now -| start > 10_000) return error.Timeout;
            // Use a short 50 ms quantum so the loop stays responsive.
            // PumpStopped means shutdown was signalled — propagate immediately
            // so the server thread exits cleanly rather than burning the timeout.
            httpx.quic.handshake.feedPumped(&srv.ep, &srv.pump, null, 50, now) catch |e| switch (e) {
                error.PumpStopped => return error.PumpStopped,
                else => {},
            };
            if (!acc.fin) continue;
            var off: usize = 0;
            const fr = try httpx.http3.frame.parseFrame(acc.buf.items, &off);
            const fields = try h3.qdec.decodeSectionCounted(fr.payload, 0, null);
            defer h3.qdec.freeFields(fields);
            var benchQenc = httpx.http3.qpack.Encoder.init(alloc);
            defer benchQenc.deinit();
            var rs = httpx.http3.RequestStream{ .id = acc.sid, .allocator = alloc, .qpack = &benchQenc };
            const rhead = try rs.buildResponseHeaders(200, &.{});
            defer alloc.free(rhead);
            const rdata = try rs.buildData("pong");
            defer alloc.free(rdata);
            var wire = std.ArrayList(u8).empty;
            defer wire.deinit(alloc);
            try wire.appendSlice(alloc, rhead);
            try wire.appendSlice(alloc, rdata);
            try sendH3(qconn, acc.sid, wire.items);
            _ = try srv.ep.flush(null);
            return;
        }
    }

    fn sendH3(conn: *httpx.quic.Connection, sid: u64, bytes: []const u8) !void {
        const B = struct {
            var sId: u64 = 0;
            var sData: []const u8 = "";
            pub fn build(gpa: std.mem.Allocator, payload: *std.ArrayList(u8)) httpx.quic.connection.Error!void {
                httpx.quic.frames.encode(payload, gpa, .{ .stream = .{ .id = sId, .offset = 0, .data = sData, .fin = true } }) catch
                    return httpx.quic.connection.Error.OutOfMemory;
            }
        };
        B.sId = sid;
        B.sData = bytes;
        try conn.sendFrames(.application, B.build, 0);
    }
};

var h3BenchIo: std.Io = undefined;

fn benchH3Get() void {
    var res = h3BenchClient.get(h3BenchUrlSlice, .{
        .httpVersion = .http3,
        .tls = .{ .verify = .caBundle, .caPem = benchCertPem },
        .timeoutMs = 10_000,
    }) catch {
        noteFailure();
        return;
    };
    defer res.deinit();
    std.mem.doNotOptimizeAway(res.status);
}

// Group 14: TLS handshakes, full vs PSK-resumed (raw native client)

const benchCertPem = sampleCertPem;
const benchKeyPem =
    \\-----BEGIN PRIVATE KEY-----
    \\MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgyp549r9FrXbm02Cn
    \\81gAdAbUzHatPYQWVDIWnQdCMPChRANCAATvUPikzRIA8ryx237GUQRJlf8Qmgod
    \\QL7gik+5KU6JC4Jc6Q3TijNUYoCauZS0OpAJ2+Z2MduOoZjpMKzNdMKc
    \\-----END PRIVATE KEY-----
;

var tlsBenchListener: httpx.tcp.Listener = undefined;
var tlsBenchThread: std.Thread = undefined;
var tlsBenchPort: u16 = 0;
var tlsBenchStop: std.atomic.Value(bool) = .init(false);
var tlsBenchIo: std.Io = undefined;
var tlsBenchSession: ?httpx.tls.Session = null;

fn tlsBenchServe() void {
    while (!tlsBenchStop.load(.acquire)) {
        var sock = tlsBenchListener.accept(tlsBenchIo) catch {
            if (tlsBenchStop.load(.acquire)) return;
            continue;
        };
        defer sock.close();
        var srv = httpx.tls.Server.init(benchAllocator, tlsBenchIo, .{
            .certificatePem = benchCertPem,
            .privateKeyPem = benchKeyPem,
            .ticketKeys = .{ .current = [_]u8{0xBE} ** 32 },
        }) catch continue;
        defer srv.deinit();
        var conn = srv.accept(&sock) catch continue;
        defer conn.deinit();
        var b: [8]u8 = undefined;
        _ = conn.read(&b) catch continue;
        conn.writeAll("ok") catch continue;
    }
}

fn tlsBenchDial(session: ?*const httpx.tls.Session) void {
    var sock = httpx.tcp.connect(tlsBenchIo, "127.0.0.1", tlsBenchPort) catch {
        noteFailure();
        return;
    };
    defer sock.close();
    var cli = httpx.tls.Client.init(benchAllocator, tlsBenchIo, .{}) catch {
        noteFailure();
        return;
    };
    defer cli.deinit();
    var conn = cli.connect(&sock, "127.0.0.1", .{
        .verify = .caBundle,
        .caPem = benchCertPem,
        .transport = .native,
        .session = session,
        .captureSession = true,
    }) catch {
        noteFailure();
        return;
    };
    defer conn.deinit();
    conn.writeAll("ping") catch {
        noteFailure();
        return;
    };
    var b: [8]u8 = undefined;
    var got: usize = 0;
    while (got < 2) {
        const n = conn.read(b[got..]) catch {
            noteFailure();
            return;
        };
        if (n == 0) return;
        got += n;
    }
    std.mem.doNotOptimizeAway(got);
}

fn benchTlsFullHandshake() void {
    tlsBenchDial(null);
}

fn benchTlsResumedHandshake() void {
    if (tlsBenchSession) |*s| {
        tlsBenchDial(s);
    }
}

pub fn main() !void {
    benchAllocator = std.heap.smp_allocator;
    recordedMetrics = std.ArrayList(BenchMetric).empty;
    defer recordedMetrics.deinit(benchAllocator);

    const io = std.Io.Threaded.global_single_threaded.io();
    benchIo = io;

    // 1. Initialize WorkerPool
    var pool = try httpx.WorkerPool.init(benchAllocator, .{ .workers = 2, .queueCapacity = 256 });
    try pool.start();
    defer pool.deinit();
    benchPool = &pool;

    // 2. Initialize BoundedQueue
    benchQueue = try httpx.concurrency.queue.BoundedQueue(usize).init(benchAllocator, 1024);
    defer benchQueue.deinit();

    // 3. Initialize Router with diverse routes
    benchRouter = httpx.router.Router.init(benchAllocator);
    defer benchRouter.deinit();
    try benchRouter.get("/", dummyHandler, .{});
    try benchRouter.get("/api/v1/health", dummyHandler, .{});
    try benchRouter.get("/api/v1/status", dummyHandler, .{});
    try benchRouter.get("/users/{id}", dummyHandler, .{});
    try benchRouter.get("/users/{id}/profile", dummyHandler, .{});
    try benchRouter.get("/users/{id}/posts", dummyHandler, .{});
    try benchRouter.get("/items/{category}/{id}", dummyHandler, .{});
    try benchRouter.get("/docs", dummyHandler, .{});
    try benchRouter.get("/users/{userId:int}/posts/{postId:int}", dummyHandler, .{ .name = "bench_user_post" });
    try benchRouter.get("/openapi.json", dummyHandler, .{});

    // 4. Initialize DNS Cache
    var dnsCache = httpx.dns.Cache.init(benchAllocator, io, .{}, dummyDnsLookup, null);
    defer dnsCache.deinit();
    benchDnsCache = &dnsCache;
    // Prime the cache with an entry
    const primed = try benchDnsCache.resolve("httpbun.com");
    defer {
        for (primed) |a| benchAllocator.free(a);
        benchAllocator.free(primed);
    }

    // 5. Initialize watcher + dependency graph for watcher benchmarks.
    var benchW = try httpx.Watcher.init(benchAllocator, io, .{ .dirPath = "examples/web/templates" });
    defer benchW.deinit();
    benchWatcher = benchW;
    var benchG = httpx.web.watcherDependency.DependencyGraph.init(benchAllocator);
    defer benchG.deinit();
    var gi: usize = 0;
    while (gi < 64) : (gi += 1) {
        var nb: [32]u8 = undefined;
        const dep = try std.fmt.bufPrint(&nb, "page-{d}.html", .{gi});
        benchG.addEdge(dep, "base.html") catch {};
    }
    benchDepGraph = &benchG;

    // 6. Initialize Compression Sample Data (1024 bytes repetitive JSON payload)
    const jsonChunk = "{\"id\":1001,\"name\":\"Benchmark Item\",\"active\":true,\"category\":\"networking\"},";
    var compRaw = std.ArrayList(u8).empty;
    defer compRaw.deinit(benchAllocator);
    while (compRaw.items.len < 1024) {
        try compRaw.appendSlice(benchAllocator, jsonChunk);
    }
    sampleCompressRaw = compRaw.items;
    sampleGzipPayload = try httpx.compression.compress(benchAllocator, .gzip, sampleCompressRaw);
    defer benchAllocator.free(sampleGzipPayload);
    sampleDeflatePayload = try httpx.compression.compress(benchAllocator, .deflate, sampleCompressRaw);
    defer benchAllocator.free(sampleDeflatePayload);

    // 6. Initialize Local Loopback Server & Client
    var srv = try httpx.Server.init(benchAllocator, io, .{
        .port = 0,
        .enableDocs = false,
        .keepAlive = true,
        .maxConnections = 100000,
    });
    try srv.router.get("/ping", loopbackPingHandler, .{});
    loopbackServer = &srv;

    loopbackThread = try std.Thread.spawn(.{}, httpx.Server.run, .{&srv});
    defer {
        loopbackClient.deinit();
        srv.requestShutdown();
        loopbackThread.join();
        srv.deinit();
    }

    const boundPort = srv.localPort();
    loopbackUrlSlice = try std.fmt.bufPrint(&loopbackUrl, "http://127.0.0.1:{d}/ping", .{boundPort});
    loopbackClient = httpx.Client.init(benchAllocator, io, .{});

    // Warm up loopback connection
    {
        var warmupRes = try loopbackClient.get(loopbackUrlSlice, .{});
        warmupRes.deinit();
    }

    // 7. HTTP/2 pooled loopback (h2c, one server connection, pooled client).
    // Each teardown defer is registered only after its setup succeeds,
    // so a fatal setup error exits without joining garbage threads.
    h2BenchIo = io;
    h2BenchListener = try httpx.tcp.Listener.bind(io, 0);
    const h2port = h2BenchListener.localPort();
    h2BenchThread = try std.Thread.spawn(.{}, h2BenchServe, .{});
    h2BenchUrlSlice = try std.fmt.bufPrint(&h2BenchUrl, "http://127.0.0.1:{d}/ping", .{h2port});
    h2BenchClient = httpx.Client.init(benchAllocator, io, .{});
    {
        var warmupRes = try h2BenchClient.get(h2BenchUrlSlice, .{ .httpVersion = .http2 });
        warmupRes.deinit();
    }
    defer {
        // Stop server, wake listener, join thread, then close and deinit.
        h2BenchStop.store(true, .release);
        httpx.tcp.wakeListenerPort(h2port);
        h2BenchClient.deinit();
        h2BenchThread.join();
        h2BenchListener.close(io);
    }

    // 8. HTTP/3 live loopback (fresh QUIC+TLS handshake per op)
    h3BenchIo = io;
    h3BenchServer.ep = try httpx.quic.transport.Endpoint.init(benchAllocator, io, try httpx.quic.Connection.init(benchAllocator, io, .server, .{}), .{});
    const h3port = h3BenchServer.ep.localPort();
    try h3BenchServer.pump.start(&h3BenchServer.ep, benchAllocator);
    h3BenchThread = try std.Thread.spawn(.{}, H3BenchServer.run, .{&h3BenchServer});
    h3BenchUrlSlice = try std.fmt.bufPrint(&h3BenchUrl, "https://127.0.0.1:{d}/ping", .{h3port});
    h3BenchClient = httpx.Client.init(benchAllocator, io, .{});
    defer {
        // Stop flag + pump stop abort in-flight server waits instantly;
        // then join, then release client and endpoint.
        h3BenchStop.store(true, .release);
        h3BenchServer.pump.stop();
        h3BenchThread.join();
        h3BenchClient.deinit();
        h3BenchServer.ep.deinit();
    }

    // 9. TLS loopback server (tickets enabled) + one captured session
    tlsBenchIo = io;
    tlsBenchListener = try httpx.tcp.Listener.bind(io, 0);
    tlsBenchPort = tlsBenchListener.localPort();
    tlsBenchThread = try std.Thread.spawn(.{}, tlsBenchServe, .{});
    defer {
        tlsBenchStop.store(true, .release);
        tlsBenchListener.close(io);
        tlsBenchThread.join();
    }
    {
        // Prime the resumption session (full handshake + read captures NST).
        var sock = try httpx.tcp.connect(io, "127.0.0.1", tlsBenchPort);
        defer sock.close();
        var cli = httpx.tls.Client.init(benchAllocator, io, .{}) catch return error.NoSessionCaptured;
        defer cli.deinit();
        var conn = try cli.connect(&sock, "127.0.0.1", .{
            .verify = .caBundle,
            .caPem = benchCertPem,
            .transport = .native,
            .captureSession = true,
        });
        defer conn.deinit();
        try conn.writeAll("ping");
        var b: [8]u8 = undefined;
        var got: usize = 0;
        while (got < 2) {
            const n = try conn.read(b[got..]);
            if (n == 0) break;
            got += n;
        }
        if (conn.takeCapturedSession()) |taken| {
            tlsBenchSession = taken;
        } else return error.NoSessionCaptured;
    }
    defer if (tlsBenchSession) |*s| s.deinit(benchAllocator);

    std.debug.print("=================================================================================\n", .{});
    std.debug.print("                         httpx.zig Benchmark Suite                              \n", .{});
    std.debug.print("=================================================================================\n\n", .{});
    var dateBuf: [16]u8 = undefined;
    std.debug.print("Library:     httpx {s}\n", .{httpx.version});
    std.debug.print("Environment: {s}-{s} | Optimization: {s} | Zig: 0.16.0\n", .{
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
        @tagName(builtin.mode),
    });
    std.debug.print("Run date:    {s} (UTC)\n\n", .{runDate(&dateBuf)});

    const fastCfg = BenchConfig{ .iterations = 2_000_000, .warmupIterations = 20_000, .rounds = 5 };
    const coreCfg = BenchConfig{ .iterations = 200_000, .warmupIterations = 5_000, .rounds = 5 };
    const medCfg = BenchConfig{ .iterations = 20_000, .warmupIterations = 500, .rounds = 3 };
    const compCfg = BenchConfig{ .iterations = 2_000, .warmupIterations = 100, .rounds = 3 };
    const scanCfg = BenchConfig{ .iterations = 500, .warmupIterations = 20, .rounds = 3 };
    const ioCfg = BenchConfig{ .iterations = 2_000, .warmupIterations = 100, .rounds = 3 };
    const tlsCfg = BenchConfig{ .iterations = 5_000, .warmupIterations = 100, .rounds = 3 };
    const netCfg = BenchConfig{ .iterations = 200, .warmupIterations = 20, .rounds = 3 };
    const hsCfg = BenchConfig{ .iterations = 50, .warmupIterations = 5, .rounds = 3 };
    const h3Cfg = BenchConfig{ .iterations = 10, .warmupIterations = 2, .rounds = 3 };
    @memset(&sampleTlsPayload, 0xAB);

    std.debug.print("[1] Core Operations & Parsing:\n", .{});
    runBench("Core Operations", "headers_parse", "ops/sec", coreCfg, benchHeadersParse);
    runBench("Core Operations", "uri_parse", "ops/sec", coreCfg, benchUriParse);
    runBench("Core Operations", "status_lookup", "ops/sec", fastCfg, benchStatusLookup);
    runBench("Core Operations", "method_lookup", "ops/sec", fastCfg, benchMethodLookup);
    runBench("Core Operations", "http1_request_head", "ops/sec", coreCfg, benchHttp1RequestHead);
    runBench("Core Operations", "http1_header_block", "ops/sec", coreCfg, benchHttp1HeaderBlock);

    std.debug.print("\n[2] Server Routing & Dispatch:\n", .{});
    runBench("Routing", "router_static_match", "ops/sec", coreCfg, benchRouterStaticMatch);
    runBench("Routing", "router_param_match", "ops/sec", coreCfg, benchRouterParamMatch);
    runBench("Routing", "router_dispatch", "ops/sec", coreCfg, benchRouterDispatch);
    runBench("Routing", "router_typed_match", "ops/sec", coreCfg, benchRouterTypedMatch);
    runBench("Routing", "router_miss_404", "ops/sec", coreCfg, benchRouterMiss);
    runBench("Routing", "router_reverse", "ops/sec", coreCfg, benchRouterReverse);

    std.debug.print("\n[3] Data Serialization:\n", .{});
    runBench("Serialization", "json_stringify", "ops/sec", coreCfg, benchJsonStringify);
    runBench("Serialization", "json_parse", "ops/sec", coreCfg, benchJsonParse);

    std.debug.print("\n[4] Authentication & Security:\n", .{});
    runBench("Security", "basic_auth_encode", "ops/sec", coreCfg, benchBasicAuthEncode);
    runBench("Security", "basic_auth_decode", "ops/sec", coreCfg, benchBasicAuthDecode);
    runBench("Security", "bearer_token_parse", "ops/sec", fastCfg, benchBearerTokenParse);

    std.debug.print("\n[5] Compression & Codecs (1 KiB payload):\n", .{});
    runBench("Compression", "gzip_compress", "ops/sec", compCfg, benchGzipCompress);
    runBench("Compression", "gzip_decompress", "ops/sec", compCfg, benchGzipDecompress);
    runBench("Compression", "deflate_compress", "ops/sec", compCfg, benchDeflateCompress);
    runBench("Compression", "deflate_decompress", "ops/sec", compCfg, benchDeflateDecompress);

    std.debug.print("\n[6] Web & Document Parsing:\n", .{});
    runBench("Parsing", "html_parse", "ops/sec", medCfg, benchHtmlParse);
    runBench("Parsing", "template_parse", "ops/sec", medCfg, benchTemplateParse);
    {
        var parser = httpx.templates.parser.Parser.init(benchAllocator, "bench.html", sampleTemplateSrc);
        benchTemplateAst = parser.parse() catch null;
    }
    runBench("Parsing", "template_render", "ops/sec", medCfg, benchTemplateRender);
    if (benchTemplateAst) |*ast| ast.deinit();
    runBench("Parsing", "template_incremental", "ops/sec", medCfg, benchTemplateIncremental);
    runBench("Parsing", "json_feed_parse", "ops/sec", medCfg, benchJsonFeedParse);
    runBench("Parsing", "live_reload_inject", "ops/sec", medCfg, benchLiveReloadInject);
    runBench("Watcher", "watcher_scan", "ops/sec", scanCfg, benchWatcherScan);
    runBench("Watcher", "watcher_deps", "ops/sec", medCfg, benchWatcherDeps);

    std.debug.print("\n[7] Concurrency & Queues:\n", .{});
    runBench("Concurrency", "worker_pool_submit", "ops/sec", coreCfg, benchWorkerPoolSubmit);
    runBench("Concurrency", "concurrency_queue", "ops/sec", coreCfg, benchConcurrencyQueue);

    std.debug.print("\n[8] DNS Resolution Subsystem:\n", .{});
    runBench("DNS", "dns_cache_hit", "ops/sec", coreCfg, benchDnsCacheHit);

    std.debug.print("\n[9] HTTP/2 & QUIC / HTTP/3 Primitives:\n", .{});
    runBench("Protocols", "h2_frame_header", "ops/sec", fastCfg, benchHttp2FrameHeader);
    runBench("Protocols", "hpack_int_encode", "ops/sec", fastCfg, benchHpackIntEncode);
    runBench("Protocols", "hpack_int_decode", "ops/sec", fastCfg, benchHpackIntDecode);
    runBench("Protocols", "h3_varint_encode", "ops/sec", fastCfg, benchH3VarIntEncode);
    runBench("Protocols", "h3_varint_decode", "ops/sec", fastCfg, benchH3VarIntDecode);

    std.debug.print("\n[10] TLS Cryptography (1 KiB record, P-256 chain):\n", .{});
    runBench("TLS", "tls_record_seal", "ops/sec", coreCfg, benchTlsRecordSeal);
    runBench("TLS", "tls_cert_parse", "ops/sec", tlsCfg, benchCertParse);

    std.debug.print("\n[11] Local Loopback Client/Server (HTTP/1.1 keep-alive):\n", .{});
    runBench("Network", "client_server_get", "req/sec", ioCfg, benchClientServerLoopback);

    std.debug.print("\n[12] HTTP/2 Pooled Requests (h2c, amortized via session pool):\n", .{});
    runBench("Network", "h2_pooled_get", "req/sec", netCfg, benchH2PooledGet);

    std.debug.print("\n[13] HTTP/3 Live Requests (fresh QUIC+TLS handshake per op):\n", .{});
    runBench("Network", "h3_get", "req/sec", h3Cfg, benchH3Get);

    std.debug.print("\n[14] TLS Handshakes (full vs PSK-resumed, loopback):\n", .{});
    runBench("TLS", "tls_full_handshake", "ops/sec", hsCfg, benchTlsFullHandshake);
    runBench("TLS", "tls_resumed_handshake", "ops/sec", hsCfg, benchTlsResumedHandshake);

    std.debug.print("\n=================================================================================\n", .{});
    std.debug.print("                         Generated Markdown Table                                \n", .{});
    std.debug.print("=================================================================================\n\n", .{});

    std.debug.print("| Benchmark | Category | Avg Latency | Throughput | Target |\n", .{});
    std.debug.print("| :--- | :--- | :---: | :---: | :---: |\n", .{});
    for (recordedMetrics.items) |m| {
        if (m.avgNs < 1000.0) {
            std.debug.print("| `{s}` | {s} | {d:.2} ns/op | **{d} {s}** | `{s}-{s}` |\n", .{
                m.name,
                m.category,
                m.avgNs,
                m.opsPerSec,
                m.unit,
                @tagName(builtin.cpu.arch),
                @tagName(builtin.os.tag),
            });
        } else if (m.avgNs < 1_000_000.0) {
            std.debug.print("| `{s}` | {s} | {d:.2} µs/op | **{d} {s}** | `{s}-{s}` |\n", .{
                m.name,
                m.category,
                m.avgNs / 1000.0,
                m.opsPerSec,
                m.unit,
                @tagName(builtin.cpu.arch),
                @tagName(builtin.os.tag),
            });
        } else {
            std.debug.print("| `{s}` | {s} | {d:.2} ms/op | **{d} {s}** | `{s}-{s}` |\n", .{
                m.name,
                m.category,
                m.avgNs / 1_000_000.0,
                m.opsPerSec,
                m.unit,
                @tagName(builtin.cpu.arch),
                @tagName(builtin.os.tag),
            });
        }
    }

    std.debug.print("\n=== Benchmark Complete ===\n", .{});

    if (benchFailures != 0) {
        std.debug.print("\n", .{});
        for (recordedMetrics.items) |m| {
            if (m.failures == 0) continue;
            std.debug.print("  {s: <24} {d} of {d} iterations failed\n", .{
                m.name,
                m.failures,
                m.iterations * (m.rounds + 1),
            });
        }
        std.debug.print(
            "\n{d} benchmark iterations failed. The timings above are not valid for those rows.\n",
            .{benchFailures},
        );
        return error.BenchmarkFailed;
    }
}
