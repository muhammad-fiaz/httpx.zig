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
    /// Allow bare LF line endings (instead of strict CRLF) for
    /// non-compliant peers (issue #37). Stripping optional trailing
    /// \\r. Default false (strict RFC 9110/9112).
    allow_lf_line_endings: bool = false,

    pub const DnsCacheOptions = struct {
        enabled: bool = true,
        ttl_ms: i64 = 60_000,
        negative_ttl_ms: i64 = 5_000,
        max_entries: u32 = 1024,
    };
};

pub const RequestOptions = struct {
    url: []const u8,
    /// Explicit method for generic `request` (e.g. `.method = .GET`); if null, uses the wrapper's method.
    method: ?Method = null,
    headers: []const req_mod.Header = &.{},
    query: []const req_mod.Header = &.{},
    body: ?[]const u8 = null,
    /// Serialized JSON bytes; sets Content-Type automatically.
    json: ?[]const u8 = null,
    /// Typed JSON value (struct) — will be `json.stringify`ed; takes precedence over `json` string if set.
    json_typed: ?*const anyopaque = null,
    json_typed_info: ?struct { ptr: *const anyopaque, stringify: *const fn (Allocator, *const anyopaque) anyerror![]u8 } = null,
    /// Encoded form body; sets Content-Type automatically.
    form: ?[]const u8 = null,
    text: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    follow_redirects: ?bool = null,
    max_redirects: ?u8 = null,
    /// Allow bare LF line endings for response parsing (issue #37).
    allow_lf_line_endings: bool = false,
    /// HTTP version selection (auto or explicit).
    http_version: ?@import("../common/http_version.zig").HttpVersion = null,
    /// Optional pre-allocated headers/query as struct (ergonomic). Use `headersFromStruct` helper.
    headers_struct: ?*const anyopaque = null,
    query_struct: ?*const anyopaque = null,
};

pub const Response = req_mod.Response;
pub const Error = req_mod.Error || error{DefaultClientUnavailable};

pub const Client = struct {
    allocator: Allocator,
    io: std.Io,
    pool: Pool,
    config: Config,
    dns_cache: ?dns_cache_mod.Cache = null,
    owns_io: bool = false,
    io_threaded: ?*std.Io.Threaded = null,

    /// Explicit allocator + io (production).
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

    /// Out-of-box: uses page_allocator + internal Threaded io, no explicit allocator/io required.
    pub fn initDefault(config: Config) !Client {
        const gpa = std.heap.page_allocator;
        const threaded = try gpa.create(std.Io.Threaded);
        threaded.* = .init(gpa, .{});
        var c = Client.init(gpa, threaded.io(), config);
        c.owns_io = true;
        c.io_threaded = threaded;
        return c;
    }

    pub fn deinit(self: *Client) void {
        if (self.dns_cache) |*cache| cache.deinit();
        self.pool.deinit();
        if (self.owns_io) {
            if (self.io_threaded) |t| {
                t.deinit();
                std.heap.page_allocator.destroy(t);
            }
        }
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

    pub fn trace(self: *Client, opts: RequestOptions) Error!Response {
        return self.doRequest(.TRACE, opts);
    }

    pub fn connect(self: *Client, opts: RequestOptions) Error!Response {
        return self.doRequest(.CONNECT, opts);
    }

    pub fn fetch(self: *Client, opts: anytype) Error!Response {
        return self.request(opts);
    }

    pub fn send(self: *Client, opts: anytype) Error!Response {
        return self.request(opts);
    }

    pub fn request(self: *Client, opts: anytype) Error!Response {
        const m: Method = if (@hasField(@TypeOf(opts), "method")) opts.method orelse .GET else .GET;
        return self.doRequest(m, opts);
    }

    /// Batch: sequential array of requests (reuses pool, uses client's allocator).
    pub fn requestAll(self: *Client, reqs: []const RequestOptions) ![]Response {
        var out = try self.allocator.alloc(Response, reqs.len);
        errdefer {
            for (out) |*r| r.deinit();
            self.allocator.free(out);
        }
        for (reqs, 0..) |req, i| {
            out[i] = try self.doRequest(req.method orelse .GET, req);
        }
        return out;
    }

    pub fn getAll(self: *Client, urls: []const []const u8) ![]Response {
        var reqs = try self.allocator.alloc(RequestOptions, urls.len);
        defer self.allocator.free(reqs);
        for (urls, 0..) |url, i| reqs[i] = .{ .url = url };
        return self.requestAll(reqs);
    }

    pub fn doRequest(self: *Client, method: Method, opts: anytype) Error!Response {
        var hdrs: [16]req_mod.Header = undefined;
        var n: usize = 0;

        // Content-Type inference
        var ct: ?[]const u8 = if (@hasField(@TypeOf(opts), "content_type")) opts.content_type else null;
        const has_json = @hasField(@TypeOf(opts), "json") and opts.json != null;
        const has_json_typed = @hasField(@TypeOf(opts), "json_typed") and opts.json_typed != null;
        const has_form = @hasField(@TypeOf(opts), "form") and opts.form != null;
        if (ct == null and (has_json or has_json_typed)) ct = "application/json";
        if (ct == null and has_form) ct = "application/x-www-form-urlencoded";
        if (ct) |c| {
            if (n < hdrs.len) {
                hdrs[n] = .{ .name = "Content-Type", .value = c };
                n += 1;
            }
        }
        // Headers: support both []const Header and struct literal
        if (@hasField(@TypeOf(opts), "headers")) {
            const H = @TypeOf(opts.headers);
            if (@typeInfo(H) == .pointer and @typeInfo(H).pointer.size == .slice) {
                for (opts.headers) |h| {
                    if (n < hdrs.len) {
                        hdrs[n] = h;
                        n += 1;
                    }
                }
            } else if (@typeInfo(H) == .@"struct") {
                inline for (@typeInfo(H).@"struct".fields) |field| {
                    const v = @field(opts.headers, field.name);
                    if (n < hdrs.len) {
                        hdrs[n] = .{ .name = field.name, .value = switch (@typeInfo(@TypeOf(v))) {
                            .int, .comptime_int => blk: {
                                var buf: [32]u8 = undefined;
                                const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch "";
                                break :blk s;
                            },
                            else => v,
                        } };
                        n += 1;
                    }
                }
            }
        }

        // Query: support both []const Header and struct literal
        var query_hdrs: [16]req_mod.Header = undefined;
        var qn: usize = 0;
        var query_slice: []const req_mod.Header = &.{};
        if (@hasField(@TypeOf(opts), "query")) {
            const Q = @TypeOf(opts.query);
            if (@typeInfo(Q) == .pointer and @typeInfo(Q).pointer.size == .slice) {
                query_slice = opts.query;
            } else if (@typeInfo(Q) == .@"struct") {
                inline for (@typeInfo(Q).@"struct".fields) |field| {
                    const v = @field(opts.query, field.name);
                    if (qn < query_hdrs.len) {
                        var qbuf: [32]u8 = undefined;
                        const vs = switch (@typeInfo(@TypeOf(v))) {
                            .int, .comptime_int => std.fmt.bufPrint(&qbuf, "{d}", .{v}) catch "",
                            .float, .comptime_float => std.fmt.bufPrint(&qbuf, "{d}", .{v}) catch "",
                            .bool => if (v) "true" else "false",
                            else => v,
                        };
                        query_hdrs[qn] = .{ .name = field.name, .value = vs };
                        qn += 1;
                    }
                }
                query_slice = query_hdrs[0..qn];
            }
        }

        // Body handling: support typed json via struct
        var json_buf: ?[]u8 = null;
        defer if (json_buf) |b| self.allocator.free(b);
        var body_val: []const u8 = "";
        var body_kind: req_mod.BodyKind = .none;
        if (@hasField(@TypeOf(opts), "json") and opts.json != null) {
            const J = @TypeOf(opts.json.?);
            if (J == []const u8 or J == []u8) {
                body_val = opts.json.?;
                body_kind = .json;
            } else {
                // Typed struct: stringify via Stringify.valueAlloc
                json_buf = std.json.Stringify.valueAlloc(self.allocator, opts.json.?, .{}) catch null;
                if (json_buf) |b| {
                    body_val = b;
                    body_kind = .json;
                }
            }
        } else if (@hasField(@TypeOf(opts), "form") and opts.form != null) {
            body_val = opts.form.?;
            body_kind = .form;
        } else if (@hasField(@TypeOf(opts), "body") and opts.body != null) {
            body_val = opts.body.?;
            body_kind = .raw;
        } else if (@hasField(@TypeOf(opts), "text") and opts.text != null) {
            body_val = opts.text.?;
            body_kind = .raw;
        } else if (has_json) {
            body_val = "";
        }

        if (body_kind == .none and @hasField(@TypeOf(opts), "json") and opts.json != null) {
            const jv = opts.json.?;
            if (@typeInfo(@TypeOf(jv)) == .@"struct") {
                json_buf = std.json.Stringify.valueAlloc(self.allocator, jv, .{}) catch null;
                if (json_buf) |b| {
                    body_val = b;
                    body_kind = .json;
                }
            }
        }

        const result = req_mod.request(self.allocator, self.io, .{
            .method = method,
            .url = opts.url,
            .headers = hdrs[0..n],
            .query = query_slice,
            .body_kind = body_kind,
            .body = body_val,
            .follow_redirects = if (@hasField(@TypeOf(opts), "follow_redirects")) opts.follow_redirects orelse self.config.follow_redirects else self.config.follow_redirects,
            .max_redirects = if (@hasField(@TypeOf(opts), "max_redirects")) opts.max_redirects orelse self.config.max_redirects else self.config.max_redirects,
            .dns_cache = if (self.dns_cache) |*cache| cache else null,
            .pool = &self.pool,
            .allow_lf_line_endings = if (@hasField(@TypeOf(opts), "allow_lf_line_endings")) opts.allow_lf_line_endings or self.config.allow_lf_line_endings else self.config.allow_lf_line_endings,
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

// Default global client (zero-config). Lazily created; never deinit'd
// (process-lifetime resource, like the standard library's own globals).

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

pub fn globalTrace(opts: RequestOptions) Error!Response {
    return forward(.TRACE, opts);
}

pub fn globalConnect(opts: RequestOptions) Error!Response {
    return forward(.CONNECT, opts);
}

pub fn globalFetch(opts: anytype) Error!Response {
    const c = defaultClient() orelse return Error.DefaultClientUnavailable;
    return c.fetch(opts);
}

pub fn globalSend(opts: anytype) Error!Response {
    return globalFetch(opts);
}

pub fn globalRequest(opts: RequestOptions) Error!Response {
    return forward(opts.method orelse .GET, opts);
}

pub fn globalGetAll(urls: []const []const u8) ![]Response {
    const c = defaultClient() orelse return Error.DefaultClientUnavailable;
    return c.getAll(urls);
}

pub fn globalRequestAll(reqs: []const RequestOptions) ![]Response {
    const c = defaultClient() orelse return Error.DefaultClientUnavailable;
    return c.requestAll(reqs);
}

test "explicit client init/deinit" {
    var ctx = tcp.IoContext.init(std.testing.allocator) catch return;
    defer ctx.deinit();
    var c = Client.init(std.testing.allocator, ctx.io, .{});
    defer c.deinit();
}

// DNS cache integration: hostname requests share one OS lookup

test "dns cache serves second hostname request from cache" {
    const a = std.testing.allocator;

    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var client = Client.init(a, ctx.io, .{});
    defer client.deinit();

    // Direct cache resolves avoid the localhost HTTP roundtrip which
    // hangs on Linux/macOS (dual-stack connect) and previously panicked
    // Windows (accept CANCELLED => unreachable). The HTTP path is
    // already covered by keep-alive / connection-close tests; the
    // FakeResolver unit test covers coalescing deterministically.
    const r1 = client.dns_cache.?.resolve(ctx.io, "localhost") catch return;
    defer {
        for (r1) |addr| a.free(addr);
        a.free(r1);
    }
    try std.testing.expect(r1.len >= 1);

    const r2 = client.dns_cache.?.resolve(ctx.io, "localhost") catch return;
    defer {
        for (r2) |addr| a.free(addr);
        a.free(r2);
    }
    try std.testing.expect(r2.len >= 1);

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
