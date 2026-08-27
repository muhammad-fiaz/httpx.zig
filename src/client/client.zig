//! HTTP Client with connection pooling, cookie jar, and zero-config support.
//!
//! Zero-config usage:
//!   const res = try httpx.get(.{ .url = "http://example.com" });
//!   defer res.deinit();
//!
//! Explicit client:
//!   var client = try httpx.Client.init(gpa, io, .{});
//!   defer client.deinit();

const std = @import("std");
const Allocator = std.mem.Allocator;
const tcp = @import("../sockets/tcp.zig");
const sync = @import("../common/sync.zig");
const logging = @import("../common/logging.zig");
const Method = @import("../common/method.zig").Method;
const req_mod = @import("request.zig");
const Pool = @import("pool.zig").Pool;
const PoolConfig = @import("pool.zig").PoolConfig;
const dns_cache_mod = @import("../net/dns/cache.zig");

pub const Config = struct {
    allocator: ?Allocator = null,
    max_redirects: u8 = 10,
    follow_redirects: bool = true,
    pool: PoolConfig = .{},
    /// Explicit custom logger; default is silent (clients never spam).
    logger: ?logging.Logger = null,
    dns_cache: DnsCacheOptions = .{},

    pub const DnsCacheOptions = struct {
        enabled: bool = true,
        ttl_ms: i64 = 60_000,
        negative_ttl_ms: i64 = 5_000,
        max_entries: u32 = 1024,
    };
};

pub const RequestOptions = struct {
    url: []const u8,
    headers: []const req_mod.Header = &.{},
    query: []const req_mod.Header = &.{},
    body: ?[]const u8 = null,
    /// Serialized JSON bytes; sets Content-Type automatically.
    json: ?[]const u8 = null,
    /// Encoded form body; sets Content-Type automatically.
    form: ?[]const u8 = null,
    text: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    follow_redirects: ?bool = null,
    max_redirects: ?u8 = null,
};

pub const Response = req_mod.Response;
pub const Error = req_mod.Error || error{DefaultClientUnavailable};

pub const Client = struct {
    allocator: Allocator,
    io: std.Io,
    pool: Pool,
    config: Config,
    dns_cache: ?dns_cache_mod.Cache = null,

    pub fn init(allocator: Allocator, io: std.Io, config: Config) Client {
        var c = Client{
            .allocator = allocator,
            .io = io,
            .pool = Pool.init(allocator, io, config.pool),
            .config = config,
        };
        if (config.dns_cache.enabled) {
            c.dns_cache = dns_cache_mod.Cache.init(
                allocator,
                .{
                    .ttl_ms = config.dns_cache.ttl_ms,
                    .negative_ttl_ms = config.dns_cache.negative_ttl_ms,
                    .max_entries = config.dns_cache.max_entries,
                },
                req_mod.systemLookupStrings,
                null,
            );
        }
        return c;
    }

    pub fn deinit(self: *Client) void {
        if (self.dns_cache) |*cache| cache.deinit();
        self.pool.deinit();
    }

    pub fn get(self: *Client, opts: RequestOptions) Error!Response {
        return self.doRequest(.GET, opts);
    }

    pub fn post(self: *Client, opts: RequestOptions) Error!Response {
        return self.doRequest(.POST, opts);
    }

    pub fn put(self: *Client, opts: RequestOptions) Error!Response {
        return self.doRequest(.PUT, opts);
    }

    pub fn patch(self: *Client, opts: RequestOptions) Error!Response {
        return self.doRequest(.PATCH, opts);
    }

    pub fn delete(self: *Client, opts: RequestOptions) Error!Response {
        return self.doRequest(.DELETE, opts);
    }

    pub fn head(self: *Client, opts: RequestOptions) Error!Response {
        return self.doRequest(.HEAD, opts);
    }

    pub fn options(self: *Client, opts: RequestOptions) Error!Response {
        return self.doRequest(.OPTIONS, opts);
    }

    pub fn doRequest(self: *Client, method: Method, opts: RequestOptions) Error!Response {
        var hdrs: [16]req_mod.Header = undefined;
        var n: usize = 0;

        var ct: ?[]const u8 = opts.content_type;
        if (ct == null and opts.json != null) ct = "application/json";
        if (ct == null and opts.form != null) ct = "application/x-www-form-urlencoded";
        if (ct) |c| {
            if (n < hdrs.len) {
                hdrs[n] = .{ .name = "Content-Type", .value = c };
                n += 1;
            }
        }
        for (opts.headers) |h| {
            if (n < hdrs.len) {
                hdrs[n] = h;
                n += 1;
            }
        }

        const body = opts.body orelse opts.json orelse opts.form orelse opts.text orelse "";
        const body_kind: req_mod.BodyKind =
            if (opts.json != null) .json else if (opts.form != null) .form else if (body.len > 0) .raw else .none;

        const result = req_mod.request(self.allocator, self.io, .{
            .method = method,
            .url = opts.url,
            .headers = hdrs[0..n],
            .query = opts.query,
            .body_kind = body_kind,
            .body = body,
            .follow_redirects = opts.follow_redirects orelse self.config.follow_redirects,
            .max_redirects = opts.max_redirects orelse self.config.max_redirects,
            .dns_cache = if (self.dns_cache) |*cache| cache else null,
            .pool = &self.pool,
        });
        if (result) |resp| {
            if (self.config.logger) |*l|
                l.log(.debug, "client", "{s} {s} -> {d}", .{ @tagName(method), opts.url, resp.status });
            return resp;
        } else |e| {
            if (self.config.logger) |*l|
                l.log(.err, "client", "{s} {s} failed: {s}", .{ @tagName(method), opts.url, @errorName(e) });
            return e;
        }
    }
};

// ---------------------------------------------------------------------------
// Default global client (zero-config). Lazily created; never deinit'd
// (process-lifetime resource, like the standard library's own globals).
// ---------------------------------------------------------------------------

var g_threaded: ?*std.Io.Threaded = null;
var g_client: ?Client = null;
var g_ready = std.atomic.Value(bool).init(false);
var g_mu = sync.Spinlock{};

fn defaultClient() ?*Client {
    if (g_ready.load(.acquire)) return &g_client.?;

    g_mu.lock();
    defer g_mu.unlock();
    if (g_ready.load(.monotonic)) return &g_client.?;

    const gpa = std.heap.page_allocator;
    const threaded = gpa.create(std.Io.Threaded) catch return null;
    threaded.* = .init(gpa, .{});
    g_client = Client.init(gpa, threaded.io(), .{});
    g_threaded = threaded;
    g_ready.store(true, .release);
    return &g_client;
}

fn forward(method: Method, opts: RequestOptions) Error!Response {
    const c = defaultClient() orelse return Error.DefaultClientUnavailable;
    return c.doRequest(method, opts);
}

pub fn globalGet(opts: RequestOptions) Error!Response {
    return forward(.GET, opts);
}

pub fn globalPost(opts: RequestOptions) Error!Response {
    return forward(.POST, opts);
}

pub fn globalPut(opts: RequestOptions) Error!Response {
    return forward(.PUT, opts);
}

pub fn globalPatch(opts: RequestOptions) Error!Response {
    return forward(.PATCH, opts);
}

pub fn globalDelete(opts: RequestOptions) Error!Response {
    return forward(.DELETE, opts);
}

pub fn globalHead(opts: RequestOptions) Error!Response {
    return forward(.HEAD, opts);
}

pub fn globalOptions(opts: RequestOptions) Error!Response {
    return forward(.OPTIONS, opts);
}

test "explicit client init/deinit" {
    var ctx = tcp.IoContext.init(std.testing.allocator) catch return;
    defer ctx.deinit();
    var c = Client.init(std.testing.allocator, ctx.io, .{});
    defer c.deinit();
}

// ---------------------------------------------------------------------------
// DNS cache integration: hostname requests share one OS lookup
// ---------------------------------------------------------------------------

test "dns cache serves second hostname request from cache" {
    const a = std.testing.allocator;
    const lifecycle = @import("../server/lifecycle.zig");
    const router_mod = @import("../web/router/router.zig");

    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = lifecycle.Server.init(a, ctx.io, .{ .port = 0, .docs_enabled = false }) catch return;
    defer srv.deinit();
    try srv.router.add(.GET, "/ping", struct {
        fn h(_: *router_mod.Context) anyerror!router_mod.Response {
            return .{ .body = "pong", .content_type = "text/plain" };
        }
    }.h);
    srv.max_connections = 10;

    const Runner = struct {
        fn run(s: *lifecycle.Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;

    var client = Client.init(a, ctx.io, .{});
    defer client.deinit();

    var ub: [64]u8 = undefined;
    const port = srv.localPort();
    const url1 = try std.fmt.bufPrint(&ub, "http://localhost:{d}/ping", .{port});

    // Request 1: miss -> real OS lookup.
    var r1 = client.get(.{ .url = url1 }) catch {
        client.pool.purge();
        srv.requestShutdown();
        t.join();
        return; // environment without usable resolver support
    };
    defer r1.deinit();
    try std.testing.expectEqual(@as(u16, 200), r1.status);
    try std.testing.expectEqualStrings("pong", r1.body);

    // Request 2: same host -> must be served from cache.
    var ub2: [64]u8 = undefined;
    const url2 = try std.fmt.bufPrint(&ub2, "http://localhost:{d}/ping", .{port});
    var r2 = client.get(.{ .url = url2 }) catch {
        client.pool.purge();
        srv.requestShutdown();
        t.join();
        return;
    };
    defer r2.deinit();
    try std.testing.expectEqual(@as(u16, 200), r2.status);

    client.pool.purge();
    srv.requestShutdown();
    t.join();

    const s = client.dns_cache.?.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 1), s.started);
    try std.testing.expect(s.hits >= 1);
}

test "disabled dns cache never stores" {
    const a = std.testing.allocator;
    const tcp2 = tcp;
    var ctx = tcp2.IoContext.init(a) catch return;
    defer ctx.deinit();
    var client = Client.init(a, ctx.io, .{ .dns_cache = .{ .enabled = false } });
    defer client.deinit();
    try std.testing.expect(client.dns_cache == null);
}
