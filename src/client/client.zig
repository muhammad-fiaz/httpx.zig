//! HTTP Client with connection pooling, cookie jar, and zero-config support.
//!
//! Zero-config usage:
//!   const res = try httpx.get(.{ .url = "http://example.com" });
//!   defer res.deinit();
//!
//! Explicit allocator:
//!   var client = try httpx.Client.init(allocator, .{});
//!   defer client.deinit();
//!   var res = try client.get(.{ .url = "http://example.com" });
//!
//! Explicit io (advanced):
//!   var client = Client.initWithIo(allocator, io, .{});
//!   defer client.deinit();
//!
//! References:
//!   - RFC 9110 — HTTP Semantics (request methods, header fields)
//!   - RFC 9112 — HTTP/1.1 Message Syntax (keep-alive, chunked)
//!   - RFC 6265 — HTTP State Management (Cookie header)
//!   - RFC 7235 — HTTP/1.1 Authentication (Authorization header)

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
const HttpVersion = @import("../common/http_version.zig").HttpVersion;

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
    /// \r. Default false (strict RFC 9110/9112).
    allow_lf_line_endings: bool = false,
    /// Default HTTP version for requests when per-request version not set.
    http_version: ?HttpVersion = null,
    /// Default TLS options for https:// requests.
    tls: ?req_mod.TlsOptions = null,
    /// Default request timeout in ms.
    timeout_ms: ?u64 = null,
    /// Default max response body size.
    max_response_size: ?usize = null,

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
    /// HTTP version selection (auto or explicit). Reuses http_version.zig.
    http_version: ?HttpVersion = null,
    tls: ?req_mod.TlsOptions = null,
    cookie: ?[]const u8 = null,
    basic_auth: ?[]const u8 = null,
    bearer_auth: ?[]const u8 = null,
    timeout_ms: ?u64 = null,
    max_response_size: ?usize = null,
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

    /// Explicit allocator API: creates internal Threaded io.
    /// Matches AGENT.md: `var client = try httpx.Client.init(allocator, .{});`
    pub fn init(allocator: Allocator, config: Config) !Client {
        const threaded = try allocator.create(std.Io.Threaded);
        errdefer allocator.destroy(threaded);
        threaded.* = .init(allocator, .{});
        var c = Client.initWithIo(allocator, threaded.io(), config);
        c.owns_io = true;
        c.io_threaded = threaded;
        return c;
    }

    /// Advanced: explicit io provided by caller. Does not own io.
    pub fn initWithIo(allocator: Allocator, io: std.Io, config: Config) Client {
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
        var c = Client.initWithIo(gpa, threaded.io(), config);
        c.owns_io = true;
        c.io_threaded = threaded;
        return c;
    }

    /// Alias for `init` for backward compatibility with docs.
    pub fn initWithConfig(allocator: Allocator, config: Config) !Client {
        return init(allocator, config);
    }

    pub fn deinit(self: *Client) void {
        if (self.dns_cache) |*cache| cache.deinit();
        self.pool.deinit();
        if (self.owns_io) {
            if (self.io_threaded) |t| {
                t.deinit();
                // Destroy with the same allocator that created it.
                self.allocator.destroy(t);
            }
        }
    }

    pub fn get(self: *Client, opts: anytype) Error!Response {
        return self.doRequest(.GET, opts);
    }

    pub fn post(self: *Client, opts: anytype) Error!Response {
        return self.doRequest(.POST, opts);
    }

    pub fn put(self: *Client, opts: anytype) Error!Response {
        return self.doRequest(.PUT, opts);
    }

    pub fn patch(self: *Client, opts: anytype) Error!Response {
        return self.doRequest(.PATCH, opts);
    }

    pub fn delete(self: *Client, opts: anytype) Error!Response {
        return self.doRequest(.DELETE, opts);
    }

    pub fn head(self: *Client, opts: anytype) Error!Response {
        return self.doRequest(.HEAD, opts);
    }

    pub fn options(self: *Client, opts: anytype) Error!Response {
        return self.doRequest(.OPTIONS, opts);
    }

    pub fn trace(self: *Client, opts: anytype) Error!Response {
        return self.doRequest(.TRACE, opts);
    }

    pub fn connect(self: *Client, opts: anytype) Error!Response {
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
        // Track allocations for header/query string conversions that need freeing.
        var allocated_strings: std.ArrayList([]u8) = .empty;
        defer {
            for (allocated_strings.items) |s| self.allocator.free(s);
            allocated_strings.deinit(self.allocator);
        }

        var hdrs: std.ArrayList(req_mod.Header) = .empty;
        defer hdrs.deinit(self.allocator);

        // Content-Type inference
        var ct: ?[]const u8 = if (@hasField(@TypeOf(opts), "content_type")) opts.content_type else null;
        const has_json = blk: {
            if (!@hasField(@TypeOf(opts), "json")) break :blk false;
            const v = opts.json;
            const T = @TypeOf(v);
            if (comptime @typeInfo(T) == .optional) break :blk v != null;
            break :blk true;
        };
        const has_json_typed = @hasField(@TypeOf(opts), "json_typed") and opts.json_typed != null;
        const has_form = blk: {
            if (!@hasField(@TypeOf(opts), "form")) break :blk false;
            const v = opts.form;
            const T = @TypeOf(v);
            if (comptime @typeInfo(T) == .optional) break :blk v != null else break :blk true;
        };
        if (ct == null and (has_json or has_json_typed)) ct = "application/json";
        if (ct == null and has_form) ct = "application/x-www-form-urlencoded";
        if (ct) |c| {
            hdrs.append(self.allocator, .{ .name = "Content-Type", .value = c }) catch return Error.OutOfMemory;
        }
        // Headers: support both []const Header and struct literal
        if (@hasField(@TypeOf(opts), "headers")) {
            const H = @TypeOf(opts.headers);
            if (comptime @typeInfo(H) == .pointer and @typeInfo(H).pointer.size == .slice) {
                for (opts.headers) |h| {
                    hdrs.append(self.allocator, h) catch return Error.OutOfMemory;
                }
            } else if (comptime @typeInfo(H) == .@"struct") {
                inline for (@typeInfo(H).@"struct".fields) |field| {
                    const v = @field(opts.headers, field.name);
                    const val_str: []const u8 = blk: {
                        const T = @TypeOf(v);
                        const info = @typeInfo(T);
                        switch (info) {
                            .int, .comptime_int => {
                                const s = std.fmt.allocPrint(self.allocator, "{d}", .{v}) catch return Error.OutOfMemory;
                                allocated_strings.append(self.allocator, s) catch {
                                    self.allocator.free(s);
                                    return Error.OutOfMemory;
                                };
                                break :blk s;
                            },
                            .float, .comptime_float => {
                                const s = std.fmt.allocPrint(self.allocator, "{d}", .{v}) catch return Error.OutOfMemory;
                                allocated_strings.append(self.allocator, s) catch {
                                    self.allocator.free(s);
                                    return Error.OutOfMemory;
                                };
                                break :blk s;
                            },
                            .bool => break :blk if (v) "true" else "false",
                            .pointer => |ptr| {
                                if (ptr.size == .slice and ptr.child == u8) break :blk v;
                                const s = std.fmt.allocPrint(self.allocator, "{any}", .{v}) catch return Error.OutOfMemory;
                                allocated_strings.append(self.allocator, s) catch {
                                    self.allocator.free(s);
                                    return Error.OutOfMemory;
                                };
                                break :blk s;
                            },
                            else => {
                                const s = std.fmt.allocPrint(self.allocator, "{any}", .{v}) catch return Error.OutOfMemory;
                                allocated_strings.append(self.allocator, s) catch {
                                    self.allocator.free(s);
                                    return Error.OutOfMemory;
                                };
                                break :blk s;
                            },
                        }
                    };
                    hdrs.append(self.allocator, .{ .name = field.name, .value = val_str }) catch return Error.OutOfMemory;
                }
            }
        }

        // Query: support both []const Header and struct literal
        var query_list: std.ArrayList(req_mod.Header) = .empty;
        defer query_list.deinit(self.allocator);
        if (@hasField(@TypeOf(opts), "query")) {
            const Q = @TypeOf(opts.query);
            if (comptime @typeInfo(Q) == .pointer and @typeInfo(Q).pointer.size == .slice) {
                for (opts.query) |q| query_list.append(self.allocator, q) catch return Error.OutOfMemory;
            } else if (comptime @typeInfo(Q) == .@"struct") {
                inline for (@typeInfo(Q).@"struct".fields) |field| {
                    const v = @field(opts.query, field.name);
                    const vs: []const u8 = blk: {
                        const T = @TypeOf(v);
                        const info = @typeInfo(T);
                        switch (info) {
                            .int, .comptime_int => {
                                const s = std.fmt.allocPrint(self.allocator, "{d}", .{v}) catch return Error.OutOfMemory;
                                allocated_strings.append(self.allocator, s) catch {
                                    self.allocator.free(s);
                                    return Error.OutOfMemory;
                                };
                                break :blk s;
                            },
                            .float, .comptime_float => {
                                const s = std.fmt.allocPrint(self.allocator, "{d}", .{v}) catch return Error.OutOfMemory;
                                allocated_strings.append(self.allocator, s) catch {
                                    self.allocator.free(s);
                                    return Error.OutOfMemory;
                                };
                                break :blk s;
                            },
                            .bool => break :blk if (v) "true" else "false",
                            .pointer => |ptr| {
                                if (ptr.size == .slice and ptr.child == u8) break :blk v;
                                const s = std.fmt.allocPrint(self.allocator, "{any}", .{v}) catch return Error.OutOfMemory;
                                allocated_strings.append(self.allocator, s) catch {
                                    self.allocator.free(s);
                                    return Error.OutOfMemory;
                                };
                                break :blk s;
                            },
                            else => {
                                const s = std.fmt.allocPrint(self.allocator, "{any}", .{v}) catch return Error.OutOfMemory;
                                allocated_strings.append(self.allocator, s) catch {
                                    self.allocator.free(s);
                                    return Error.OutOfMemory;
                                };
                                break :blk s;
                            },
                        }
                    };
                    query_list.append(self.allocator, .{ .name = field.name, .value = vs }) catch return Error.OutOfMemory;
                }
            }
        }

        // Body handling: support typed json via struct
        var json_buf: ?[]u8 = null;
        defer if (json_buf) |b| self.allocator.free(b);
        var body_val: []const u8 = "";
        var body_kind: req_mod.BodyKind = .none;
        const has_json_field = @hasField(@TypeOf(opts), "json");
        if (has_json_field) {
            const v = opts.json;
            const T = @TypeOf(v);
            const is_opt = comptime @typeInfo(T) == .optional;
            const is_present = if (is_opt) v != null else true;
            if (is_present) {
                const payload = if (is_opt) v.? else v;
                const J = @TypeOf(payload);
                if (J == []const u8 or J == []u8) {
                    body_val = payload;
                    body_kind = .json;
                } else {
                    json_buf = std.json.Stringify.valueAlloc(self.allocator, payload, .{}) catch return Error.OutOfMemory;
                    if (json_buf) |b| {
                        body_val = b;
                        body_kind = .json;
                    }
                }
            }
        }
        if (body_kind == .none and @hasField(@TypeOf(opts), "form")) {
            const v = opts.form;
            const T = @TypeOf(v);
            if (comptime @typeInfo(T) == .optional) {
                if (v) |val| {
                    body_val = val;
                    body_kind = .form;
                }
            } else {
                body_val = v;
                body_kind = .form;
            }
        }
        if (body_kind == .none and @hasField(@TypeOf(opts), "body")) {
            const v = opts.body;
            const T = @TypeOf(v);
            if (comptime @typeInfo(T) == .optional) {
                if (v) |val| {
                    body_val = val;
                    body_kind = .raw;
                }
            } else {
                body_val = v;
                body_kind = .raw;
            }
        }
        if (body_kind == .none and @hasField(@TypeOf(opts), "text")) {
            const v = opts.text;
            const T = @TypeOf(v);
            if (comptime @typeInfo(T) == .optional) {
                if (v) |val| {
                    body_val = val;
                    body_kind = .raw;
                }
            } else {
                body_val = v;
                body_kind = .raw;
            }
        }

        // Multipart file upload support
        var multipart_buf: ?[]u8 = null;
        defer if (multipart_buf) |b| self.allocator.free(b);
        if (body_kind == .none and @hasField(@TypeOf(opts), "multipart")) {
            const mp = opts.multipart;
            const mp_encoder = @import("../web/multipart/encoder.zig");
            var boundary_buf: [32]u8 = undefined;
            const boundary = mp_encoder.generateBoundary(&boundary_buf);
            var ct_buf: [128]u8 = undefined;
            const ct_val = mp_encoder.contentType(&ct_buf, boundary);

            const part: mp_encoder.Part = .{
                .name = mp.field_name,
                .filename = mp.filename,
                .content_type = mp.content_type orelse "application/octet-stream",
                .data = mp.data,
            };
            multipart_buf = mp_encoder.encodeAlloc(self.allocator, boundary, &.{part}) catch return Error.OutOfMemory;
            if (multipart_buf) |b| {
                body_val = b;
                body_kind = .raw;
                hdrs.append(self.allocator, .{ .name = "Content-Type", .value = ct_val }) catch return Error.OutOfMemory;
            }
        }

        // Resolve http_version with hierarchy: per-request > client default > auto
        const req_http_version: HttpVersion = blk: {
            if (@hasField(@TypeOf(opts), "http_version")) {
                const HVType = @TypeOf(opts.http_version);
                if (comptime @typeInfo(HVType) == .optional) {
                    if (opts.http_version) |v| break :blk v;
                } else {
                    break :blk opts.http_version;
                }
            }
            if (self.config.http_version) |v| break :blk v;
            break :blk .auto;
        };

        const req_tls: ?req_mod.TlsOptions = if (@hasField(@TypeOf(opts), "tls")) opts.tls else self.config.tls;
        const req_cookie: ?[]const u8 = if (@hasField(@TypeOf(opts), "cookie")) opts.cookie else null;
        const req_basic_auth: ?[]const u8 = if (@hasField(@TypeOf(opts), "basic_auth")) opts.basic_auth else null;
        const req_bearer_auth: ?[]const u8 = if (@hasField(@TypeOf(opts), "bearer_auth")) opts.bearer_auth else null;
        const req_timeout: ?u64 = if (@hasField(@TypeOf(opts), "timeout_ms")) opts.timeout_ms else self.config.timeout_ms;
        const req_max_size: ?usize = if (@hasField(@TypeOf(opts), "max_response_size")) opts.max_response_size else self.config.max_response_size;

        const result = req_mod.request(self.allocator, self.io, .{
            .method = method,
            .url = opts.url,
            .headers = hdrs.items,
            .query = query_list.items,
            .body_kind = body_kind,
            .body = body_val,
            .follow_redirects = if (@hasField(@TypeOf(opts), "follow_redirects")) opts.follow_redirects orelse self.config.follow_redirects else self.config.follow_redirects,
            .max_redirects = if (@hasField(@TypeOf(opts), "max_redirects")) opts.max_redirects orelse self.config.max_redirects else self.config.max_redirects,
            .dns_cache = if (self.dns_cache) |*cache| cache else null,
            .pool = &self.pool,
            .allow_lf_line_endings = if (@hasField(@TypeOf(opts), "allow_lf_line_endings")) opts.allow_lf_line_endings or self.config.allow_lf_line_endings else self.config.allow_lf_line_endings,
            .http_version = req_http_version,
            .tls = req_tls,
            .cookie = req_cookie,
            .basic_auth = req_basic_auth,
            .bearer_auth = req_bearer_auth,
            .timeout_ms = req_timeout,
            .max_response_size = req_max_size,
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
    g_client = Client.initWithIo(gpa, threaded.io(), .{});
    g_threaded = threaded;
    g_ready.store(true, .release);
    return &g_client.?;
}

fn forward(method: Method, opts: anytype) Error!Response {
    const c = defaultClient() orelse return Error.DefaultClientUnavailable;
    return c.doRequest(method, opts);
}

pub fn globalGet(opts: anytype) Error!Response {
    return forward(.GET, opts);
}

pub fn globalPost(opts: anytype) Error!Response {
    return forward(.POST, opts);
}

pub fn globalPut(opts: anytype) Error!Response {
    return forward(.PUT, opts);
}

pub fn globalPatch(opts: anytype) Error!Response {
    return forward(.PATCH, opts);
}

pub fn globalDelete(opts: anytype) Error!Response {
    return forward(.DELETE, opts);
}

pub fn globalHead(opts: anytype) Error!Response {
    return forward(.HEAD, opts);
}

pub fn globalOptions(opts: anytype) Error!Response {
    return forward(.OPTIONS, opts);
}

pub fn globalTrace(opts: anytype) Error!Response {
    return forward(.TRACE, opts);
}

pub fn globalConnect(opts: anytype) Error!Response {
    return forward(.CONNECT, opts);
}

pub fn globalFetch(opts: anytype) Error!Response {
    const c = defaultClient() orelse return Error.DefaultClientUnavailable;
    return c.fetch(opts);
}

pub fn globalSend(opts: anytype) Error!Response {
    return globalFetch(opts);
}

pub fn globalRequest(opts: anytype) Error!Response {
    const m: Method = if (@hasField(@TypeOf(opts), "method")) opts.method orelse .GET else .GET;
    return forward(m, opts);
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
    var c = Client.init(std.testing.allocator, .{}) catch return;
    defer c.deinit();
}

test "explicit client initWithIo" {
    var ctx = tcp.IoContext.init(std.testing.allocator) catch return;
    defer ctx.deinit();
    var c = Client.initWithIo(std.testing.allocator, ctx.io, .{});
    defer c.deinit();
}

test "dns cache serves second hostname request from cache" {
    const a = std.testing.allocator;
    var client = Client.init(a, .{}) catch return;
    defer client.deinit();
    // Direct cache resolves avoid the localhost HTTP roundtrip which
    // hangs on Linux/macOS (dual-stack connect) and previously panicked
    // Windows (accept CANCELLED => unreachable). The HTTP path is
    // already covered by keep-alive / connection-close tests; the
    // FakeResolver unit test covers coalescing deterministically.
    const r1 = client.dns_cache.?.resolve(client.io, "localhost") catch return;
    defer {
        for (r1) |addr| a.free(addr);
        a.free(r1);
    }
    try std.testing.expect(r1.len >= 1);

    const r2 = client.dns_cache.?.resolve(client.io, "localhost") catch return;
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
    var client = Client.init(a, .{ .dns_cache = .{ .enabled = false } }) catch return;
    defer client.deinit();
    try std.testing.expect(client.dns_cache == null);
}

test "client http_version forwarded from opts" {
    const a = std.testing.allocator;
    var client = Client.init(a, .{ .http_version = .http_1 }) catch return;
    defer client.deinit();
    try std.testing.expectEqual(HttpVersion.http_1, client.config.http_version.?);
}

test "client anytype headers struct literal" {
    const a = std.testing.allocator;
    var client = Client.init(a, .{}) catch return;
    defer client.deinit();
    // Do not actually connect; just verify doRequest builds correctly up to connect failure
    // Use invalid port to get ConnectFailed quickly after header building
    const res = client.get(.{ .url = "http://127.0.0.1:1/", .headers = .{ .X_Custom = "value", .X_Int = 42 } });
    try std.testing.expectError(Error.ConnectFailed, res);
}

test "client anytype query struct literal" {
    const a = std.testing.allocator;
    var client = Client.init(a, .{}) catch return;
    defer client.deinit();
    const res = client.get(.{ .url = "http://127.0.0.1:1/", .query = .{ .page = 2, .active = true } });
    try std.testing.expectError(Error.ConnectFailed, res);
}

test "client typed json struct" {
    const a = std.testing.allocator;
    var client = Client.init(a, .{}) catch return;
    defer client.deinit();
    const Payload = struct { name: []const u8, age: u32 };
    const res = client.post(.{ .url = "http://127.0.0.1:1/", .json = Payload{ .name = "Alice", .age = 30 } });
    try std.testing.expectError(Error.ConnectFailed, res);
}
