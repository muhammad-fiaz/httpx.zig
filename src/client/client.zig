//! HTTP Client with connection pooling, cookie jar, and zero-config support.
//!
//! Zero-config usage:
//!   const res = try httpx.get("http://example.com", .{});
//!   defer res.deinit();
//!
//! Explicit allocator and io:
//!   const io = std.Io.Threaded.global_single_threaded.io();
//!   var client = httpx.Client.init(allocator, io, .{});
//!   defer client.deinit();
//!   var res = try client.get("http://example.com", .{});
//!   defer res.deinit();
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
const req = @import("request.zig");
const Pool = @import("pool.zig").Pool;
const PoolConfig = @import("pool.zig").PoolConfig;
const tlsSessionCache = @import("../protocols/tls/session.zig");
const dnsCache = @import("../net/dns/cache.zig");
const clock = @import("../common/clock.zig");
const HttpVersion = @import("../common/http_version.zig").HttpVersion;
const DownloadCore = @import("download.zig");
const connectivity = @import("../net/connectivity.zig");
pub const ConnectivityOptions = connectivity.ConnectivityOptions;
pub const ConnectivityResult = connectivity.ConnectivityResult;
pub const DownloadOptions = DownloadCore.DownloadOptions;
pub const DownloadResult = DownloadCore.DownloadResult;
pub const DownloadError = DownloadCore.DownloadError;
pub const ProgressInfo = DownloadCore.ProgressInfo;
pub const ProgressState = DownloadCore.ProgressState;
pub const ProgressMode = DownloadCore.ProgressMode;
pub const ExistingFilePolicy = DownloadCore.ExistingFilePolicy;
pub const ChecksumAlgorithm = DownloadCore.ChecksumAlgorithm;
pub const VerifyOptions = DownloadCore.VerifyOptions;
pub const UpdateOptions = DownloadCore.UpdateOptions;
pub const RemoteFileInfo = DownloadCore.RemoteFileInfo;

const addressMod = @import("../net/address.zig");
const netResolve = @import("../net/resolve.zig");
pub const Address = addressMod.Address;
pub const AddressFamilyPreference = enum {
    any,
    ipv4,
    ipv6,
};
pub const ResolveOptions = struct {
    family: AddressFamilyPreference = .any,
    useCache: bool = true,
    timeoutMs: ?u64 = null,
    /// Port stamped onto every returned address. Defaults to 443 (HTTPS).
    port: u16 = 443,
};
pub const ResolvedAddresses = struct {
    allocator: Allocator,
    items: []addressMod.Address,

    pub fn deinit(self: *ResolvedAddresses) void {
        if (self.items.len > 0) {
            self.allocator.free(self.items);
        }
        self.items = &.{};
    }

    pub fn slice(self: *const ResolvedAddresses) []const addressMod.Address {
        return self.items;
    }

    pub fn first(self: *const ResolvedAddresses) ?addressMod.Address {
        return if (self.items.len > 0) self.items[0] else null;
    }

    pub fn len(self: *const ResolvedAddresses) usize {
        return self.items.len;
    }

    pub fn format(self: ResolvedAddresses, writer: anytype) !void {
        for (self.items, 0..) |item, i| {
            if (i > 0) try writer.writeAll(", ");
            try item.format(writer);
        }
    }
};

pub const Config = struct {
    maxRedirects: u8 = 10,
    followRedirects: bool = true,
    pool: PoolConfig = .{},
    /// Application-supplied callback for client events (request completed, failed, etc.).
    /// When null (the default), HTTPX produces no output.
    eventCallback: ?logging.ClientEventCallback = null,
    dnsCache: DnsCacheOptions = .{},
    /// Allow bare LF line endings (instead of strict CRLF) for
    /// non-compliant peers (issue #37). Stripping optional trailing
    /// \r. Default false (strict RFC 9110/9112).
    allowLfLineEndings: bool = false,
    /// Default HTTP version for requests when per-request version not set.
    httpVersion: ?HttpVersion = null,
    /// Default TLS options for https:// requests.
    tls: ?req.TlsOptions = null,
    /// Default request timeout in ms.
    timeoutMs: ?u64 = null,
    /// Default max response body size.
    maxResponseSize: ?usize = null,
    /// Number of retry attempts for failed requests (0 = no retry).
    maxRetries: u32 = 0,
    /// Delay between retry attempts in milliseconds.
    retryDelayMs: u64 = 1000,
    /// HTTP status codes that trigger a retry (502, 503, 504 by default).
    retryStatusCodes: []const u16 = &.{ 502, 503, 504 },
    /// Default proxy URL (e.g. "socks5://127.0.0.1:1080", "socks5h://127.0.0.1:1080", "http://127.0.0.1:8080").
    proxy: ?[]const u8 = null,
    /// Fast boolean toggle to use HTTP/1.0
    http10: bool = true,
    /// Fast boolean toggle to use HTTP/1.1
    http11: bool = true,
    /// Fast boolean toggle to use HTTP/2 as default protocol
    http2: bool = false,
    /// Fast boolean toggle to use HTTP/3 as default protocol
    http3: bool = false,

    pub const DnsCacheOptions = struct {
        enable: bool = true,
        ttlMs: i64 = 60_000,
        negativeTtlMs: i64 = 5_000,
        maxEntries: u32 = 1024,
    };
};

pub const RequestOptions = struct {
    url: []const u8,
    /// Explicit method for generic `request` (e.g. `.method = .GET` or `.method = .post`); if null, uses the wrapper's method.
    method: ?Method = null,
    headers: []const req.Header = &.{},
    query: []const req.Header = &.{},
    body: ?[]const u8 = null,
    /// Serialized JSON bytes; sets Content-Type automatically.
    json: ?[]const u8 = null,
    /// Typed JSON value (struct) — will be `json.stringify`ed; takes precedence over `json` string if set.
    jsonTyped: ?*const anyopaque = null,
    jsonTypedInfo: ?struct { ptr: *const anyopaque, stringify: *const fn (Allocator, *const anyopaque) anyerror![]u8 } = null,
    /// Encoded form body; sets Content-Type automatically.
    form: ?[]const u8 = null,
    text: ?[]const u8 = null,
    contentType: ?[]const u8 = null,
    followRedirects: ?bool = null,
    maxRedirects: ?u8 = null,
    /// Allow bare LF line endings for response parsing (issue #37).
    allowLfLineEndings: bool = false,
    /// HTTP version selection (auto or explicit). Reuses http_version.zig.
    httpVersion: ?HttpVersion = null,
    /// Fast boolean toggle to use HTTP/1.0 for this request
    http10: ?bool = null,
    /// Fast boolean toggle to use HTTP/1.1 for this request
    http11: ?bool = null,
    /// Fast boolean toggle to use HTTP/2 for this request
    http2: ?bool = null,
    /// Fast boolean toggle to use HTTP/3 for this request
    http3: ?bool = null,
    tls: ?req.TlsOptions = null,
    cookie: ?[]const u8 = null,
    basicAuth: ?[]const u8 = null,
    bearerAuth: ?[]const u8 = null,
    timeoutMs: ?u64 = null,
    maxResponseSize: ?usize = null,
    /// Optional proxy URL for this request.
    proxy: ?[]const u8 = null,
};

pub const Response = req.Response;
pub const Error = req.Error || error{DefaultClientUnavailable};

fn normalizeHttpVersion(val: anytype) HttpVersion {
    const T = @TypeOf(val);
    if (T == HttpVersion) return val;
    if (comptime @typeInfo(T) == .enum_literal) {
        const tag = @tagName(val);
        if (std.mem.eql(u8, tag, "http10")) return .http10;
        if (std.mem.eql(u8, tag, "http11")) return .http11;
        if (std.mem.eql(u8, tag, "http2") or std.mem.eql(u8, tag, "h2")) return .http2;
        if (std.mem.eql(u8, tag, "http3") or std.mem.eql(u8, tag, "h3")) return .http3;
        if (std.mem.eql(u8, tag, "auto")) return .auto;
    }
    return val;
}

fn normalizeMethod(raw: anytype) Method {
    const T = @TypeOf(raw);
    if (T == Method) return raw;
    if (comptime @typeInfo(T) == .enum_literal) {
        const tag = @tagName(raw);
        inline for (@typeInfo(Method).@"enum".fields) |f| {
            if (std.ascii.eqlIgnoreCase(tag, f.name)) {
                return @enumFromInt(f.value);
            }
        }
    }
    if (comptime @typeInfo(T) == .pointer) {
        if (Method.fromString(raw)) |m| return m;
    }
    return .GET;
}

fn extractMethod(opts: anytype) Method {
    if (@hasField(@TypeOf(opts), "method")) {
        const raw = opts.method;
        const T = @TypeOf(raw);
        if (comptime @typeInfo(T) == .optional) {
            if (raw) |m| return normalizeMethod(m);
            return .GET;
        } else {
            return normalizeMethod(raw);
        }
    }
    return .GET;
}

pub const Client = struct {
    allocator: Allocator,
    io: std.Io,
    pool: Pool,
    config: Config,
    dnsCache: ?dnsCache.Cache = null,
    /// Origin-keyed TLS 1.3 session cache for resumption on the native
    /// TLS paths (H2-TLS always; HTTPS/1.1 when already native via
    /// client certificates). Shared across threads; bounded.
    sessionCache: tlsSessionCache.SessionCache,

    /// Initializes client with explicit allocator and shared IO.
    /// Matches `var client = httpx.Client.init(allocator, io, .{});`
    pub fn init(allocator: Allocator, io: std.Io, config: Config) Client {
        var c = Client{
            .allocator = allocator,
            .io = io,
            .pool = Pool.init(allocator, io, config.pool),
            .config = config,
            .sessionCache = tlsSessionCache.SessionCache.init(allocator),
        };
        if (config.dnsCache.enable) {
            c.dnsCache = dnsCache.Cache.init(
                allocator,
                io,
                .{
                    .ttlMs = config.dnsCache.ttlMs,
                    .negativeTtlMs = config.dnsCache.negativeTtlMs,
                    .maxEntries = config.dnsCache.maxEntries,
                },
                req.systemLookupStrings,
                null,
            );
        }
        return c;
    }

    pub fn deinit(self: *Client) void {
        if (self.dnsCache) |*cache| cache.deinit();
        self.pool.deinit();
        self.sessionCache.deinit();
    }

    /// The primary unified HTTP client operation.
    ///
    /// Executes an HTTP request to `url` with options (method, headers, body, json, query, timeout, etc.):
    ///   const response = try client.fetch("https://api.example.com/users", .{
    ///       .method = .POST,
    ///       .json = CreateUser{ .name = "Fiaz", .email = "example@example.com" },
    ///   });
    ///   defer response.deinit();
    ///   const user = try response.json(User);
    pub fn fetch(self: *Client, url: []const u8, opts: anytype) Error!Response {
        const m: Method = extractMethod(opts);
        return self.doRequestWithOverride(m, url, opts);
    }

    /// GET request. `url` is the first argument; `opts` is request options.
    ///   const res = try client.get("https://example.com/api", .{});
    pub fn get(self: *Client, url: []const u8, opts: anytype) Error!Response {
        return self.doRequestWithOverride(.GET, url, opts);
    }

    /// POST request. `url` is the first argument; `opts` carries body/json/form.
    ///   const res = try client.post("https://example.com/api", .{ .json = payload });
    pub fn post(self: *Client, url: []const u8, opts: anytype) Error!Response {
        return self.doRequestWithOverride(.POST, url, opts);
    }

    /// PUT request.
    ///   const res = try client.put("https://example.com/api/1", .{ .json = payload });
    pub fn put(self: *Client, url: []const u8, opts: anytype) Error!Response {
        return self.doRequestWithOverride(.PUT, url, opts);
    }

    /// PATCH request.
    ///   const res = try client.patch("https://example.com/api/1", .{ .json = payload });
    pub fn patch(self: *Client, url: []const u8, opts: anytype) Error!Response {
        return self.doRequestWithOverride(.PATCH, url, opts);
    }

    /// DELETE request.
    ///   const res = try client.delete("https://example.com/api/1", .{});
    pub fn delete(self: *Client, url: []const u8, opts: anytype) Error!Response {
        return self.doRequestWithOverride(.DELETE, url, opts);
    }

    /// HEAD request — response has no body.
    ///   const res = try client.head("https://example.com/api", .{});
    pub fn head(self: *Client, url: []const u8, opts: anytype) Error!Response {
        return self.doRequestWithOverride(.HEAD, url, opts);
    }

    /// OPTIONS request.
    ///   const res = try client.options("https://example.com/api", .{});
    pub fn options(self: *Client, url: []const u8, opts: anytype) Error!Response {
        return self.doRequestWithOverride(.OPTIONS, url, opts);
    }

    /// TRACE request.
    pub fn trace(self: *Client, url: []const u8, opts: anytype) Error!Response {
        return self.doRequestWithOverride(.TRACE, url, opts);
    }

    /// CONNECT request.
    pub fn connect(self: *Client, url: []const u8, opts: anytype) Error!Response {
        return self.doRequestWithOverride(.CONNECT, url, opts);
    }

    /// Generic request with explicit method in opts (.method = .GET / .POST / ...).
    ///   const res = try client.request("https://example.com/", .{ .method = .GET });
    pub fn request(self: *Client, url: []const u8, opts: anytype) Error!Response {
        const m: Method = extractMethod(opts);
        return self.doRequestWithOverride(m, url, opts);
    }

    /// Batch: concurrent array of requests (runs in parallel, reuses pool and dns cache).
    ///
    /// Caller owns the returned slice: deinit each Response, then free the
    /// slice with this client's allocator.
    pub fn requestAll(self: *Client, reqs: anytype) ![]Response {
        const R = @TypeOf(reqs);
        const slice: []const RequestOptions = blk: {
            if (R == []const RequestOptions or R == []RequestOptions) break :blk reqs;
            const info = @typeInfo(R);
            if (info == .pointer) {
                if (info.pointer.size == .slice) break :blk reqs;
                if (info.pointer.size == .one and @typeInfo(info.pointer.child) == .array) break :blk reqs[0..];
            }
            if (info == .array) break :blk reqs[0..];
            @compileError("requestAll expects a slice or array of RequestOptions");
        };
        var out = try self.allocator.alloc(Response, slice.len);
        if (slice.len <= 1) {
            for (slice, 0..) |item, i| {
                out[i] = self.doRequest(item.method orelse .GET, item.url, item) catch |e| {
                    // Only entries before i were assigned; later slots are uninitialized.
                    for (out[0..i]) |*r| r.deinit();
                    self.allocator.free(out);
                    return e;
                };
            }
            return out;
        }

        const TaskCtx = struct {
            client: *Client,
            reqs: []const RequestOptions,
            out: []Response,
            success: []bool,
            nextIdx: *std.atomic.Value(usize),
            errMutex: sync.Spinlock = .{},
            firstErr: ?anyerror = null,

            fn worker(ctx: *@This()) void {
                while (true) {
                    const idx = ctx.nextIdx.fetchAdd(1, .monotonic);
                    if (idx >= ctx.reqs.len) break;
                    {
                        ctx.errMutex.lock();
                        const has_err = ctx.firstErr != null;
                        ctx.errMutex.unlock();
                        if (has_err) break;
                    }

                    const current = ctx.reqs[idx];
                    const resp = ctx.client.doRequestWithOverride(current.method orelse .GET, current.url, current) catch |e| {
                        ctx.errMutex.lock();
                        if (ctx.firstErr == null) ctx.firstErr = e;
                        ctx.errMutex.unlock();
                        break;
                    };
                    ctx.out[idx] = resp;
                    ctx.success[idx] = true;
                }
            }
        };

        const success = self.allocator.alloc(bool, slice.len) catch |e| {
            self.allocator.free(out);
            return e;
        };
        defer self.allocator.free(success);
        @memset(success, false);

        var nextIdx = std.atomic.Value(usize).init(0);
        var task_ctx = TaskCtx{
            .client = self,
            .reqs = slice,
            .out = out,
            .success = success,
            .nextIdx = &nextIdx,
        };

        const maxWorkers = @min(@as(usize, 16), slice.len);
        var threads = self.allocator.alloc(?std.Thread, maxWorkers) catch |e| {
            self.allocator.free(out);
            return e;
        };
        defer self.allocator.free(threads);

        for (0..maxWorkers) |w| {
            threads[w] = std.Thread.spawn(.{}, TaskCtx.worker, .{&task_ctx}) catch null;
            if (threads[w] == null) {
                TaskCtx.worker(&task_ctx);
            }
        }

        for (threads) |m_th| {
            if (m_th) |th| th.join();
        }

        if (task_ctx.firstErr) |e| {
            for (0..slice.len) |i| {
                if (success[i]) out[i].deinit();
            }
            self.allocator.free(out);
            return e;
        }
        return out;
    }

    /// Parallel GETs. Ownership: deinit each Response, then free the slice
    /// with this client's allocator (see requestAll).
    pub fn getAll(self: *Client, urls: anytype) ![]Response {
        const U = @TypeOf(urls);
        const slice: []const []const u8 = blk: {
            if (U == []const []const u8 or U == [][]const u8) break :blk urls;
            const info = @typeInfo(U);
            if (info == .pointer) {
                if (info.pointer.size == .slice) break :blk urls;
                if (info.pointer.size == .one and @typeInfo(info.pointer.child) == .array) break :blk urls[0..];
            }
            if (info == .array) break :blk urls[0..];
            @compileError("getAll expects a slice or array of URL strings");
        };
        var reqs = try self.allocator.alloc(RequestOptions, slice.len);
        defer self.allocator.free(reqs);
        for (slice, 0..) |url, i| reqs[i] = .{ .url = url };
        return self.requestAll(reqs);
    }

    fn coerceDownloadOptions(opts: anytype) DownloadOptions {
        if (@TypeOf(opts) == DownloadOptions) return opts;
        var o = DownloadOptions{};
        inline for (@typeInfo(@TypeOf(opts)).@"struct".fields) |f| {
            if (comptime std.mem.eql(u8, f.name, "verify")) {
                const v = @field(opts, f.name);
                if (@TypeOf(v) == VerifyOptions) {
                    o.verify = v;
                } else {
                    inline for (@typeInfo(@TypeOf(v)).@"struct".fields) |vf| {
                        if (@hasField(VerifyOptions, vf.name)) {
                            @field(o.verify, vf.name) = @field(v, vf.name);
                        }
                    }
                }
            } else if (@hasField(DownloadOptions, f.name)) {
                @field(o, f.name) = @field(opts, f.name);
            }
        }
        return o;
    }

    /// Streams a download to disk with progress reporting, resume, and verification.
    pub fn download(self: *Client, url: []const u8, opts: anytype) DownloadError!DownloadResult {
        var dl = DownloadCore.Downloader.init(self.allocator, self);
        const downloadOptions = coerceDownloadOptions(opts);
        return dl.download(url, downloadOptions);
    }

    /// Downloads a batch of files concurrently using the client's internal allocator.
    pub fn downloadBatch(self: *Client, tasks: []const struct { url: []const u8, dest: []const u8 }, opts: anytype) DownloadError!void {
        const downloadOptions = coerceDownloadOptions(opts);
        for (tasks) |t| {
            var per_task = downloadOptions;
            per_task.path = t.dest;
            _ = try self.download(t.url, per_task);
        }
    }

    /// Queries remote file metadata (size, filename, Content-Type, ETag, Range support) without downloading.
    pub fn lookupFileInfo(self: *Client, url: []const u8, opts: anytype) DownloadError!RemoteFileInfo {
        const downloadOptions = coerceDownloadOptions(opts);
        return DownloadCore.lookupFileInfo(self, url, downloadOptions);
    }

    /// Returns a Parser bound to this Client's allocator and config.
    pub fn parser(self: *Client) @import("../parsing/document.zig").Parser {
        return @import("../parsing/document.zig").Parser.init(self.allocator, .{});
    }

    /// Fetches a remote URL and parses it as a Document.
    pub fn fetchDocument(self: *Client, url: []const u8, opts: anytype) !@import("../parsing/document.zig").Document {
        var res = try self.get(url, opts);
        defer res.deinit();
        return @import("../parsing/document.zig").Document.parse(self.allocator, res.header("content-type"), res.body);
    }

    /// Fetches a remote URL and parses it as HTML.
    pub fn fetchHtml(self: *Client, url: []const u8, opts: anytype) !@import("../parsing/document.zig").Document {
        var res = try self.get(url, opts);
        defer res.deinit();
        return @import("../parsing/document.zig").Document.parseHtml(self.allocator, res.body);
    }

    /// Fetches a remote URL and parses it as XML.
    pub fn fetchXml(self: *Client, url: []const u8, opts: anytype) !@import("../parsing/document.zig").Document {
        var res = try self.get(url, opts);
        defer res.deinit();
        return @import("../parsing/document.zig").Document.parseXml(self.allocator, res.body);
    }

    /// Fetches a remote RSS/Atom/JSON feed.
    pub fn fetchFeed(self: *Client, url: []const u8, opts: anytype) !@import("../parsing/feed.zig").Feed {
        var res = try self.get(url, opts);
        defer res.deinit();
        return @import("../parsing/feed.zig").parse(self.allocator, res.body, res.header("content-type"));
    }

    /// Fetches robots.txt from a URL.
    pub fn fetchRobots(self: *Client, url: []const u8, opts: anytype) !@import("../parsing/robots.zig").RobotsFile {
        var res = try self.get(url, opts);
        defer res.deinit();
        return @import("../parsing/robots.zig").parse(self.allocator, res.body);
    }

    /// Fetches sitemap XML from a URL.
    pub fn fetchSitemap(self: *Client, url: []const u8, opts: anytype) !@import("../parsing/sitemap.zig").Sitemap {
        var res = try self.get(url, opts);
        defer res.deinit();
        return @import("../parsing/sitemap.zig").parse(self.allocator, res.body);
    }

    /// Executes a GraphQL query or mutation against a remote endpoint.
    /// `opts` may supply `.timeoutMs`, `.bearerAuth`, `.tls`, etc.
    pub fn graphql(self: *Client, url: []const u8, queryStr: []const u8, variables: anytype, opts: anytype) !Response {
        const VarsType = @TypeOf(variables);
        const payloadJson = if (VarsType == @TypeOf(null))
            try std.json.Stringify.valueAlloc(self.allocator, .{ .query = queryStr }, .{})
        else if (VarsType == []const u8 or VarsType == []u8)
            try std.json.Stringify.valueAlloc(self.allocator, .{ .query = queryStr, .variables = variables }, .{})
        else
            try std.json.Stringify.valueAlloc(self.allocator, .{ .query = queryStr, .variables = variables }, .{});
        defer self.allocator.free(payloadJson);

        const gqlHeaders = [_]req.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "accept", .value = "application/json" },
        };
        const timeout: ?u64 = if (@hasField(@TypeOf(opts), "timeoutMs")) opts.timeoutMs else null;
        const bearer: ?[]const u8 = if (@hasField(@TypeOf(opts), "bearerAuth")) opts.bearerAuth else null;

        return self.doRequestWithOverride(.POST, url, .{
            .body = payloadJson,
            .headers = @as([]const req.Header, &gqlHeaders),
            .timeoutMs = timeout,
            .bearerAuth = bearer,
        });
    }

    /// Safely updates an executable or asset on disk with rollback preservation.
    pub fn updateFile(self: *Client, url: []const u8, opts: anytype) DownloadError!DownloadResult {
        const updateOptions: UpdateOptions = if (@TypeOf(opts) == UpdateOptions) opts else blk: {
            var o = UpdateOptions{};
            inline for (@typeInfo(@TypeOf(opts)).@"struct".fields) |f| {
                if (comptime std.mem.eql(u8, f.name, "verify")) {
                    const v = @field(opts, f.name);
                    if (@TypeOf(v) == VerifyOptions) {
                        o.verify = v;
                    } else {
                        inline for (@typeInfo(@TypeOf(v)).@"struct".fields) |vf| {
                            if (@hasField(VerifyOptions, vf.name)) {
                                @field(o.verify, vf.name) = @field(v, vf.name);
                            }
                        }
                    }
                } else if (@hasField(UpdateOptions, f.name)) {
                    @field(o, f.name) = @field(opts, f.name);
                }
            }
            break :blk o;
        };
        return DownloadCore.updateFile(self.allocator, self, url, updateOptions);
    }

    /// Returns true if the internet is reachable from this machine.
    ///
    /// Probes a small set of highly-available public endpoints (Cloudflare /
    /// Google DNS on port 53) using the client's own I/O backend.  IPv4 and
    /// IPv6 are both attempted.
    ///
    /// Example:
    /// ```zig
    /// if (!client.isOnline()) return error.NoInternet;
    /// ```
    pub fn isOnline(self: *Client) bool {
        return connectivity.isOnline(self.io);
    }

    /// Probes internet connectivity and returns detailed results.
    ///
    /// Returns a `ConnectivityResult` with `.online`, `.family`, `.latencyMs`,
    /// and `.endpointStr()`.  Useful for diagnostics or choosing IPv4/IPv6.
    ///
    /// Example:
    /// ```zig
    /// const r = client.checkConnectivity(.{ .timeoutMs = 2000 });
    /// if (r.online) std.debug.print("online via {s} ({?d}ms)\n", .{ r.endpointStr(), r.latencyMs });
    /// ```
    pub fn checkConnectivity(self: *Client, opts: ConnectivityOptions) ConnectivityResult {
        return connectivity.checkConnectivity(self.io, opts);
    }

    /// Resolves a hostname or IP address to structured Address results,
    /// reusing the client's internal allocator, std.Io networking backend,
    /// and thread-safe DNS cache.
    ///
    /// Basic usage:
    ///   var addresses = try client.resolve("httpbun.com", .{});
    ///   defer addresses.deinit();
    ///   for (addresses.items) |addr| {
    ///       std.debug.print("Resolved: {f}\n", .{addr});
    ///   }
    ///
    /// IPv4-only:
    ///   var addresses = try client.resolve("httpbun.com", .{ .family = .ipv4 });
    ///   defer addresses.deinit();
    pub fn resolve(self: *Client, host: []const u8, opts: anytype) Error!ResolvedAddresses {
        const resolveOpts: ResolveOptions = blk: {
            if (@TypeOf(opts) == ResolveOptions) break :blk opts;
            var r = ResolveOptions{};
            inline for (@typeInfo(@TypeOf(opts)).@"struct".fields) |f| {
                if (@hasField(ResolveOptions, f.name)) {
                    @field(r, f.name) = @field(opts, f.name);
                }
            }
            break :blk r;
        };

        var outList = std.ArrayList(addressMod.Address).empty;
        errdefer outList.deinit(self.allocator);

        // 1. Literal IP check (no DNS query needed)
        var probe = addressMod.Address{ .family = .ip4, .port = 0 };
        if (probe.parseIp(host)) |parsed| {
            var addr = parsed;
            addr.port = resolveOpts.port;
            const matches_family = switch (resolveOpts.family) {
                .any => true,
                .ipv4 => addr.family == .ip4,
                .ipv6 => addr.family == .ip6,
            };
            if (matches_family) {
                outList.append(self.allocator, addr) catch return Error.OutOfMemory;
                return .{
                    .allocator = self.allocator,
                    .items = outList.toOwnedSlice(self.allocator) catch return Error.OutOfMemory,
                };
            } else {
                return Error.DnsFailed;
            }
        } else |_| {}

        // 2. Cached lookup when enabled
        if (resolveOpts.useCache and self.dnsCache != null) {
            if (self.dnsCache.?.resolve(host)) |cached_strs| {
                defer {
                    for (cached_strs) |s| self.allocator.free(s);
                    self.allocator.free(cached_strs);
                }
                for (cached_strs) |s| {
                    if (req.parseAddrString(s, resolveOpts.port)) |parsed| {
                        outList.append(self.allocator, parsed) catch return Error.OutOfMemory;
                    }
                }
            } else |_| {}
        }

        // 3. Fallback to fresh OS resolution if un-cached
        if (outList.items.len == 0) {
            const resolver = netResolve.Resolver.init(self.allocator, self.io);
            const resolvedRaw = resolver.lookup(host, .{ .port = resolveOpts.port }) catch |err| switch (err) {
                error.HostNotFound => return Error.DnsFailed,
                error.OutOfMemory => return Error.OutOfMemory,
                else => return Error.DnsFailed,
            };
            defer self.allocator.free(resolvedRaw);
            for (resolvedRaw) |addr| {
                outList.append(self.allocator, addr) catch return Error.OutOfMemory;
            }
        }

        // 4. Apply family filter if requested
        if (resolveOpts.family != .any) {
            var filtered = std.ArrayList(addressMod.Address).empty;
            errdefer filtered.deinit(self.allocator);
            for (outList.items) |addr| {
                const matches = switch (resolveOpts.family) {
                    .any => true,
                    .ipv4 => addr.family == .ip4,
                    .ipv6 => addr.family == .ip6,
                };
                if (matches) {
                    filtered.append(self.allocator, addr) catch return Error.OutOfMemory;
                }
            }
            outList.deinit(self.allocator);
            if (filtered.items.len == 0) return Error.DnsFailed;
            return .{
                .allocator = self.allocator,
                .items = filtered.toOwnedSlice(self.allocator) catch return Error.OutOfMemory,
            };
        }

        if (outList.items.len == 0) return Error.DnsFailed;
        return .{
            .allocator = self.allocator,
            .items = outList.toOwnedSlice(self.allocator) catch return Error.OutOfMemory,
        };
    }

    /// Resolves a URL string (e.g. "https://httpbun.com/get") by extracting its hostname and port.
    /// The URL's effective port always wins; other options come from `opts`.
    pub fn resolveUrl(self: *Client, urlStr: []const u8, opts: anytype) Error!ResolvedAddresses {
        const uriMod = @import("../common/uri.zig");
        const u = uriMod.parse(urlStr) catch return Error.InvalidUrl;
        const p = u.effectivePort();
        if (p == 0) return Error.InvalidUrl;
        if (@TypeOf(opts) == ResolveOptions) {
            var o = opts;
            o.port = p;
            return self.resolve(u.host, o);
        }
        // Anonymous options: copy known fields, then stamp the URL port.
        var r = ResolveOptions{};
        inline for (@typeInfo(@TypeOf(opts)).@"struct".fields) |f| {
            if (comptime std.mem.eql(u8, f.name, "port")) continue;
            if (@hasField(ResolveOptions, f.name)) {
                @field(r, f.name) = @field(opts, f.name);
            }
        }
        r.port = p;
        return self.resolve(u.host, r);
    }

    /// Graceful connection drain (purge pool, but don't destroy the client).
    pub fn close(self: *Client) void {
        self.pool.purge();
    }

    /// Full reset (close + clear DNS cache).
    pub fn reset(self: *Client) void {
        self.close();
        if (self.dnsCache) |*dc| {
            dc.deinit();
            dc.* = dnsCache.Cache.init(
                self.allocator,
                self.io,
                .{
                    .ttlMs = self.config.dnsCache.ttlMs,
                    .negativeTtlMs = self.config.dnsCache.negativeTtlMs,
                    .maxEntries = self.config.dnsCache.maxEntries,
                },
                req.systemLookupStrings,
                null,
            );
        }
    }

    fn doRequest(self: *Client, method: Method, url: []const u8, opts: anytype) Error!Response {
        return self.doRequestWithOverride(method, url, opts);
    }

    fn doRequestWithOverride(self: *Client, method: Method, urlOverride: []const u8, opts: anytype) Error!Response {
        var attempt: u32 = 0;
        const maxAttempts = self.config.maxRetries + 1;
        while (attempt < maxAttempts) : (attempt += 1) {
            var result = self.doRequestInner(method, urlOverride, opts) catch |err| {
                if (attempt + 1 >= maxAttempts) return err;
                clock.sleepMillis(self.config.retryDelayMs * (attempt + 1));
                continue;
            };
            if (self.config.maxRetries > 0 and attempt + 1 < maxAttempts) {
                var shouldRetry = false;
                for (self.config.retryStatusCodes) |code| {
                    if (result.status == code) {
                        shouldRetry = true;
                        break;
                    }
                }
                if (shouldRetry) {
                    result.deinit();
                    clock.sleepMillis(self.config.retryDelayMs * (attempt + 1));
                    continue;
                }
            }
            return result;
        }
        unreachable;
    }

    fn doRequestInner(self: *Client, method: Method, urlOverride: []const u8, opts: anytype) Error!Response {
        // Track allocations for header/query string conversions that need freeing.
        var allocated_strings: std.ArrayList([]u8) = .empty;
        defer {
            for (allocated_strings.items) |s| self.allocator.free(s);
            allocated_strings.deinit(self.allocator);
        }

        var hdrs: std.ArrayList(req.Header) = .empty;
        defer hdrs.deinit(self.allocator);

        var userHasContentType = false;

        // Headers: support both []const Header and struct literal
        if (@hasField(@TypeOf(opts), "headers")) {
            const H = @TypeOf(opts.headers);
            if (comptime @typeInfo(H) == .pointer and @typeInfo(H).pointer.size == .slice) {
                for (opts.headers) |h| {
                    if (std.ascii.eqlIgnoreCase(h.name, "content-type")) userHasContentType = true;
                    hdrs.append(self.allocator, h) catch return Error.OutOfMemory;
                }
            } else if (comptime @typeInfo(H) == .@"struct") {
                inline for (@typeInfo(H).@"struct".fields) |field| {
                    const norm_name = comptime blk: {
                        if (std.mem.eql(u8, field.name, "contentType")) break :blk "Content-Type";
                        if (std.mem.eql(u8, field.name, "userAgent")) break :blk "User-Agent";
                        if (std.mem.eql(u8, field.name, "authorization")) break :blk "Authorization";
                        if (std.mem.eql(u8, field.name, "acceptEncoding")) break :blk "Accept-Encoding";
                        break :blk field.name;
                    };
                    if (std.ascii.eqlIgnoreCase(norm_name, "content-type")) userHasContentType = true;
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
                                // String literals decay to array pointers (*const [N(:0)]u8),
                                // not slices — slice them instead of {any}-formatting bytes.
                                if (ptr.size == .one and @typeInfo(ptr.child) == .array and @typeInfo(ptr.child).array.child == u8) break :blk v[0..];
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
                    hdrs.append(self.allocator, .{ .name = norm_name, .value = val_str }) catch return Error.OutOfMemory;
                }
            }
        }

        // Content-Type inference (only if not already explicitly provided in headers)
        if (!userHasContentType) {
            var ct: ?[]const u8 = blk: {
                if (@hasField(@TypeOf(opts), "contentType")) {
                    const v = opts.contentType;
                    if (@typeInfo(@TypeOf(v)) == .optional) {
                        if (v) |val| break :blk val;
                    } else break :blk v;
                }
                break :blk null;
            };
            const has_json = blk: {
                if (!@hasField(@TypeOf(opts), "json")) break :blk false;
                const v = opts.json;
                const T = @TypeOf(v);
                if (comptime @typeInfo(T) == .optional) break :blk v != null;
                break :blk true;
            };
            const has_json_typed = @hasField(@TypeOf(opts), "jsonTyped") and opts.jsonTyped != null;
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
        }

        // Query: support both []const Header and struct literal
        var query_list: std.ArrayList(req.Header) = .empty;
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
                                // String literals decay to array pointers (*const [N(:0)]u8),
                                // not slices — slice them instead of {any}-formatting bytes.
                                if (ptr.size == .one and @typeInfo(ptr.child) == .array and @typeInfo(ptr.child).array.child == u8) break :blk v[0..];
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
        var bodyKind: req.BodyKind = .none;
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
                    bodyKind = .json;
                } else {
                    json_buf = std.json.Stringify.valueAlloc(self.allocator, payload, .{}) catch return Error.OutOfMemory;
                    if (json_buf) |b| {
                        body_val = b;
                        bodyKind = .json;
                    }
                }
            }
        }
        if (bodyKind == .none and @hasField(@TypeOf(opts), "form")) {
            const v = opts.form;
            const T = @TypeOf(v);
            if (comptime @typeInfo(T) == .optional) {
                if (v) |val| {
                    body_val = val;
                    bodyKind = .form;
                }
            } else {
                body_val = v;
                bodyKind = .form;
            }
        }
        if (bodyKind == .none and @hasField(@TypeOf(opts), "body")) {
            const v = opts.body;
            const T = @TypeOf(v);
            if (comptime @typeInfo(T) == .optional) {
                if (v) |val| {
                    body_val = val;
                    bodyKind = .raw;
                }
            } else {
                body_val = v;
                bodyKind = .raw;
            }
        }
        if (bodyKind == .none and @hasField(@TypeOf(opts), "text")) {
            const v = opts.text;
            const T = @TypeOf(v);
            if (comptime @typeInfo(T) == .optional) {
                if (v) |val| {
                    body_val = val;
                    bodyKind = .raw;
                }
            } else {
                body_val = v;
                bodyKind = .raw;
            }
        }

        // Multipart file upload support
        var multipart_buf: ?[]u8 = null;
        defer if (multipart_buf) |b| self.allocator.free(b);
        if (bodyKind == .none and @hasField(@TypeOf(opts), "multipart")) {
            const mp = opts.multipart;
            const mp_encoder = @import("../web/multipart/encoder.zig");
            var boundary_buf: [32]u8 = undefined;
            const boundary = mp_encoder.generateBoundary(&boundary_buf);
            var ct_buf: [128]u8 = undefined;
            const ct_val = mp_encoder.contentType(&ct_buf, boundary);

            const field_name_val: []const u8 = mp.name;
            const filename_val: ?[]const u8 = blk: {
                if (!@hasField(@TypeOf(mp), "filename")) break :blk null;
                const v = mp.filename;
                const T = @TypeOf(v);
                if (@typeInfo(T) == .optional) break :blk v;
                break :blk @as(?[]const u8, v);
            };
            const contentTypeVal: []const u8 = blk: {
                if (!@hasField(@TypeOf(mp), "contentType")) break :blk "application/octet-stream";
                const v = mp.contentType;
                const T = @TypeOf(v);
                if (@typeInfo(T) == .optional) {
                    if (v) |val| break :blk val;
                    break :blk "application/octet-stream";
                } else {
                    break :blk v;
                }
            };
            const part: mp_encoder.Part = .{
                .name = field_name_val,
                .filename = filename_val,
                .contentType = contentTypeVal,
                .data = mp.data,
            };
            multipart_buf = mp_encoder.encodeAllocParts(self.allocator, boundary, &.{part}) catch return Error.OutOfMemory;
            if (multipart_buf) |b| {
                body_val = b;
                bodyKind = .raw;
                hdrs.append(self.allocator, .{ .name = "Content-Type", .value = ct_val }) catch return Error.OutOfMemory;
            }
        }

        // Resolve httpVersion with hierarchy: per-request (.httpVersion / .http2 / .http3) > client default > auto
        const reqHttpVersion: HttpVersion = blk: {
            if (@hasField(@TypeOf(opts), "httpVersion")) {
                const raw = opts.httpVersion;
                const HVType = @TypeOf(raw);
                if (comptime @typeInfo(HVType) == .optional) {
                    if (raw) |v| break :blk normalizeHttpVersion(v);
                } else {
                    break :blk normalizeHttpVersion(raw);
                }
            }
            if (@hasField(@TypeOf(opts), "http10")) {
                const v = opts.http10;
                if (@TypeOf(v) == bool and v) break :blk .http10;
                if (@typeInfo(@TypeOf(v)) == .optional and v != null and v.?) break :blk .http10;
            }
            if (@hasField(@TypeOf(opts), "http11")) {
                const v = opts.http11;
                if (@TypeOf(v) == bool and v) break :blk .http11;
                if (@typeInfo(@TypeOf(v)) == .optional and v != null and v.?) break :blk .http11;
            }
            if (@hasField(@TypeOf(opts), "http2")) {
                const v = opts.http2;
                if (@TypeOf(v) == bool and v) break :blk .http2;
                if (@typeInfo(@TypeOf(v)) == .optional and v != null and v.?) break :blk .http2;
            }
            if (@hasField(@TypeOf(opts), "http3")) {
                const v = opts.http3;
                if (@TypeOf(v) == bool and v) break :blk .http3;
                if (@typeInfo(@TypeOf(v)) == .optional and v != null and v.?) break :blk .http3;
            }
            if (self.config.httpVersion) |v| break :blk v;
            if (self.config.http2) break :blk .http2;
            if (self.config.http3) break :blk .http3;
            if (!self.config.http11 and self.config.http10) break :blk .http10;
            break :blk .auto;
        };

        const reqTls: ?req.TlsOptions = blk: {
            if (!@hasField(@TypeOf(opts), "tls")) {
                // No per-request TLS: use client default, or auto-enable for HTTPS.
                if (self.config.tls) |c_tls| break :blk c_tls;
                break :blk req.TlsOptions{ .verify = .none, .allowTruncation = true };
            }
            const v = opts.tls;
            const T = @TypeOf(v);
            if (@typeInfo(T) == .optional) {
                break :blk v orelse req.TlsOptions{ .verify = .none, .allowTruncation = true };
            } else {
                break :blk req.TlsOptions{
                    .verify = v.verify,
                    .caBundle = if (@hasField(@TypeOf(v), "caBundle")) v.caBundle else null,
                    .caPem = if (@hasField(@TypeOf(v), "caPem")) v.caPem else null,
                    .clientCertPem = if (@hasField(@TypeOf(v), "clientCertPem")) v.clientCertPem else null,
                    .clientKeyPem = if (@hasField(@TypeOf(v), "clientKeyPem")) v.clientKeyPem else null,
                    .allowTruncation = if (@hasField(@TypeOf(v), "allowTruncation")) v.allowTruncation else true,
                };
            }
        };
        const reqCookie: ?[]const u8 = if (@hasField(@TypeOf(opts), "cookie")) opts.cookie else null;
        const reqBasicAuth: ?[]const u8 = if (@hasField(@TypeOf(opts), "basicAuth")) opts.basicAuth else null;
        const reqBearerAuth: ?[]const u8 = if (@hasField(@TypeOf(opts), "bearerAuth")) opts.bearerAuth else null;
        const reqTimeout: ?u64 = if (@hasField(@TypeOf(opts), "timeoutMs")) opts.timeoutMs else self.config.timeoutMs;
        const reqMaxSize: ?usize = if (@hasField(@TypeOf(opts), "maxResponseSize")) opts.maxResponseSize else self.config.maxResponseSize;
        const reqProxy: ?[]const u8 = if (@hasField(@TypeOf(opts), "proxy")) opts.proxy else self.config.proxy;

        const targetUrl: []const u8 = urlOverride;

        const result = req.request(self.allocator, self.io, .{
            .method = method,
            .url = targetUrl,
            .headers = hdrs.items,
            .query = query_list.items,
            .bodyKind = bodyKind,
            .body = body_val,
            .followRedirects = blk: {
                if (@hasField(@TypeOf(opts), "followRedirects")) {
                    const v = opts.followRedirects;
                    if (@typeInfo(@TypeOf(v)) == .optional) {
                        break :blk v orelse self.config.followRedirects;
                    } else {
                        break :blk v;
                    }
                }
                break :blk self.config.followRedirects;
            },
            .maxRedirects = blk: {
                if (@hasField(@TypeOf(opts), "maxRedirects")) {
                    const v = opts.maxRedirects;
                    if (@typeInfo(@TypeOf(v)) == .optional) {
                        break :blk v orelse self.config.maxRedirects;
                    } else {
                        break :blk v;
                    }
                }
                break :blk self.config.maxRedirects;
            },
            .dnsCache = if (self.dnsCache) |*cache| cache else null,
            .pool = &self.pool,
            .sessionCache = &self.sessionCache,
            .allowLfLineEndings = blk: {
                if (@hasField(@TypeOf(opts), "allowLfLineEndings")) {
                    break :blk opts.allowLfLineEndings or self.config.allowLfLineEndings;
                }
                break :blk self.config.allowLfLineEndings;
            },
            .httpVersion = reqHttpVersion,
            .tls = reqTls,
            .cookie = reqCookie,
            .basicAuth = reqBasicAuth,
            .bearerAuth = reqBearerAuth,
            .timeoutMs = reqTimeout,
            .maxResponseSize = reqMaxSize,
            .proxy = reqProxy,
        });
        if (result) |resp| {
            if (self.config.eventCallback) |cb| cb(.{
                .kind = .requestCompleted,
                .level = .info,
                .method = @tagName(method),
                .url = targetUrl,
                .status = resp.status,
            });
            return resp;
        } else |e| {
            if (self.config.eventCallback) |cb| cb(.{
                .kind = .requestFailed,
                .level = .err,
                .method = @tagName(method),
                .url = targetUrl,
                .message = @errorName(e),
            });
            return e;
        }
    }
};

// Default global client (zero-config). Lazily created; never deinit'd
// (process-lifetime resource, like the standard library's own globals).

var g_client: ?Client = null;
var g_ready = std.atomic.Value(bool).init(false);
var g_mu = sync.Spinlock{};

fn defaultClient() ?*Client {
    if (g_ready.load(.acquire)) return &g_client.?;

    g_mu.lock();
    defer g_mu.unlock();
    if (g_ready.load(.monotonic)) return &g_client.?;

    const gpa = std.heap.page_allocator;
    g_client = Client.init(gpa, std.Io.Threaded.global_single_threaded.io(), .{});
    g_ready.store(true, .release);
    return &g_client.?;
}

fn forwardMethod(method: Method, url: []const u8, opts: anytype) Error!Response {
    const c = defaultClient() orelse return Error.DefaultClientUnavailable;
    return c.doRequestWithOverride(method, url, opts);
}

/// Zero-config GET — uses the global client (lazy-initialized).
///   const res = try httpx.get("https://example.com", .{});
pub fn globalFetch(url: []const u8, opts: anytype) Error!Response {
    const c = defaultClient() orelse return Error.DefaultClientUnavailable;
    return c.fetch(url, opts);
}

pub fn globalGet(url: []const u8, opts: anytype) Error!Response {
    return forwardMethod(.GET, url, opts);
}

pub fn globalPost(url: []const u8, opts: anytype) Error!Response {
    return forwardMethod(.POST, url, opts);
}

pub fn globalPut(url: []const u8, opts: anytype) Error!Response {
    return forwardMethod(.PUT, url, opts);
}

pub fn globalPatch(url: []const u8, opts: anytype) Error!Response {
    return forwardMethod(.PATCH, url, opts);
}

pub fn globalDelete(url: []const u8, opts: anytype) Error!Response {
    return forwardMethod(.DELETE, url, opts);
}

pub fn globalHead(url: []const u8, opts: anytype) Error!Response {
    return forwardMethod(.HEAD, url, opts);
}

pub fn globalOptions(url: []const u8, opts: anytype) Error!Response {
    return forwardMethod(.OPTIONS, url, opts);
}

pub fn globalTrace(url: []const u8, opts: anytype) Error!Response {
    return forwardMethod(.TRACE, url, opts);
}

pub fn globalConnect(url: []const u8, opts: anytype) Error!Response {
    return forwardMethod(.CONNECT, url, opts);
}

/// Generic zero-config request — specify method in opts.
pub fn globalRequest(url: []const u8, opts: anytype) Error!Response {
    const m: Method = extractMethod(opts);
    return forwardMethod(m, url, opts);
}

pub fn globalGetAll(urls: anytype) ![]Response {
    // Slice is page_allocator-owned (see requestAll): deinit each Response,
    // then std.heap.page_allocator.free(results).
    const c = defaultClient() orelse return Error.DefaultClientUnavailable;
    return c.getAll(urls);
}

pub fn globalRequestAll(reqs: anytype) ![]Response {
    // Same ownership as globalGetAll.
    const c = defaultClient() orelse return Error.DefaultClientUnavailable;
    return c.requestAll(reqs);
}

pub fn globalDownload(url: []const u8, opts: anytype) DownloadError!DownloadResult {
    const c = defaultClient() orelse return DownloadError.ConnectionFailed;
    return c.download(url, opts);
}

pub fn globalUpdateFile(url: []const u8, opts: anytype) DownloadError!DownloadResult {
    const c = defaultClient() orelse return DownloadError.ConnectionFailed;
    return c.updateFile(url, opts);
}

pub fn globalVerifyFile(path: []const u8, opts: VerifyOptions) DownloadError!void {
    return DownloadCore.verifyFile(path, opts);
}

pub fn globalLookupFileInfo(url: []const u8, opts: anytype) DownloadError!RemoteFileInfo {
    const c = defaultClient() orelse return DownloadError.ConnectionFailed;
    return c.lookupFileInfo(url, opts);
}

/// Zero-config global DNS resolution function.
pub fn globalResolve(host: []const u8, opts: anytype) Error!ResolvedAddresses {
    const c = defaultClient() orelse return Error.DefaultClientUnavailable;
    return c.resolve(host, opts);
}

/// Zero-config global URL hostname resolution function.
pub fn globalResolveUrl(urlStr: []const u8, opts: anytype) Error!ResolvedAddresses {
    const c = defaultClient() orelse return Error.DefaultClientUnavailable;
    return c.resolveUrl(urlStr, opts);
}

pub fn globalGraphql(url: []const u8, query: []const u8, variables: anytype, opts: anytype) !Response {
    const c = defaultClient() orelse return Error.DefaultClientUnavailable;
    return c.graphql(url, query, variables, opts);
}

pub fn globalFetchSitemap(url: []const u8, opts: anytype) !@import("../parsing/sitemap.zig").Sitemap {
    const c = defaultClient() orelse return Error.DefaultClientUnavailable;
    return c.fetchSitemap(url, opts);
}

/// Returns true if the internet is reachable (zero-config, no client needed).
///
/// Uses a short-lived I/O context to probe Cloudflare/Google DNS (port 53).
/// Works on Windows (Winsock), Linux, and macOS.  IPv4 and IPv6 are both
/// attempted.
///
/// Example:
/// ```zig
/// if (!httpx.isOnline()) @panic("No internet connection");
/// ```
pub fn globalIsOnline() bool {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return connectivity.isOnline(threaded.io());
}

/// Probes internet connectivity and returns a `ConnectivityResult` (zero-config).
///
/// Example:
/// ```zig
/// const r = httpx.checkConnectivity(.{ .timeoutMs = 2000 });
/// if (r.online) std.debug.print("online via {s} ({?d}ms)\n", .{ r.endpointStr(), r.latencyMs });
/// ```
pub fn globalCheckConnectivity(opts: ConnectivityOptions) ConnectivityResult {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return connectivity.checkConnectivity(threaded.io(), opts);
}

test "explicit client init/deinit" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var c = Client.init(std.testing.allocator, io, .{});
    defer c.deinit();
}

test "dns cache serves second hostname request from cache" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var client = Client.init(a, io, .{});
    defer client.deinit();
    // Direct cache resolves avoid the localhost HTTP roundtrip which
    // hangs on Linux/macOS (dual-stack connect) and previously panicked
    // Windows (accept CANCELLED => unreachable). The HTTP path is
    // already covered by keep-alive / connection-close tests; the
    // FakeResolver unit test covers coalescing deterministically.
    const r1 = client.dnsCache.?.resolve("localhost") catch return;
    defer {
        for (r1) |addr| a.free(addr);
        a.free(r1);
    }
    try std.testing.expect(r1.len >= 1);

    const r2 = client.dnsCache.?.resolve("localhost") catch return;
    defer {
        for (r2) |addr| a.free(addr);
        a.free(r2);
    }
    try std.testing.expect(r2.len >= 1);

    const s = client.dnsCache.?.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 1), s.started);
    try std.testing.expect(s.hits >= 1);
}

test "disabled dns cache never stores" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var client = Client.init(a, io, .{ .dnsCache = .{ .enable = false } });
    defer client.deinit();
    try std.testing.expect(client.dnsCache == null);
}

test "client httpVersion forwarded from opts" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var client = Client.init(a, io, .{ .httpVersion = .http11 });
    defer client.deinit();
    try std.testing.expectEqual(HttpVersion.http11, client.config.httpVersion.?);
}

test "client anytype headers struct literal" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var client = Client.init(a, io, .{});
    defer client.deinit();
    // Use invalid port to reach ConnectFailed quickly (API shape test, no network needed)
    const res = client.get("http://127.0.0.1:1/", .{ .headers = .{ .X_Custom = "value", .X_Int = 42 } });
    try std.testing.expectError(Error.ConnectFailed, res);
}

test "client anytype query struct literal" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var client = Client.init(a, io, .{});
    defer client.deinit();
    const res = client.get("http://127.0.0.1:1/", .{ .query = .{ .page = 2, .active = true } });
    try std.testing.expectError(Error.ConnectFailed, res);
}

test "struct headers/query string literals serialize as strings on the wire" {
    // Regression test: string literals in struct-form headers/query decay to
    // array pointers (*const [N:0]u8), which were {any}-formatted as byte
    // dumps ("{ 66, 101, ... }") instead of sent as strings.
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var client = Client.init(a, io, .{});
    defer client.deinit();

    var addr: addressMod.Address = undefined;
    addr = try addr.parseIp("127.0.0.1");
    addr.port = 0;
    var listener = try tcp.Listener.bindAddress(io, &addr);
    defer listener.close(io);
    const port = listener.localPort();

    const Capture = struct {
        buf: [4096]u8 = [_]u8{0} ** 4096,
        len: usize = 0,
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This(), l: *tcp.Listener, io_in: std.Io) void {
            var conn = l.accept(io_in) catch return;
            defer conn.close();
            var total: usize = 0;
            while (total < self.buf.len) {
                const n = conn.read(self.buf[total..]) catch break;
                if (n == 0) break;
                total += n;
                if (std.mem.indexOf(u8, self.buf[0..total], "\r\n\r\n") != null) break;
            }
            self.len = total;
            conn.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok") catch {};
            self.done.store(true, .release);
        }
    };
    var cap = Capture{};
    const t = try std.Thread.spawn(.{}, Capture.run, .{ &cap, &listener, io });
    defer t.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});
    var res = try client.get(url, .{
        .headers = .{ .authorization = "Bearer my-token", .x_count = 42, .x_flag = true },
        .query = .{ .page = 2, .tag = "hi" },
    });
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 200), res.status);

    while (!cap.done.load(.acquire)) std.Thread.yield() catch {};
    const raw = cap.buf[0..cap.len];
    try std.testing.expect(std.mem.indexOf(u8, raw, "Authorization: Bearer my-token") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "x_count: 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "x_flag: true") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "page=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "tag=hi") != null);
    // No {any}-formatted byte dumps anywhere on the wire.
    try std.testing.expect(std.mem.indexOf(u8, raw, "{") == null);
}

test "client typed json struct" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var client = Client.init(a, io, .{});
    defer client.deinit();
    const Payload = struct { name: []const u8, age: u32 };
    const res = client.post("http://127.0.0.1:1/", .{ .json = Payload{ .name = "Alice", .age = 30 } });
    try std.testing.expectError(Error.ConnectFailed, res);
}

test "client unified fetch with typed json" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var client = Client.init(a, io, .{});
    defer client.deinit();
    const CreateUser = struct { name: []const u8, email: []const u8 };
    const res = client.fetch("http://127.0.0.1:1/", .{
        .method = .POST,
        .json = CreateUser{ .name = "Fiaz", .email = "fiaz@example.com" },
    });
    try std.testing.expectError(Error.ConnectFailed, res);
}

test "response bytes and jsonAlloc" {
    const a = std.testing.allocator;
    var headers = try a.alloc(req.Header, 1);
    headers[0] = .{
        .name = try a.dupe(u8, "Content-Type"),
        .value = try a.dupe(u8, "application/json"),
    };
    const body_str = "{\"id\":101,\"name\":\"Fiaz\"}";
    const body_bytes = try a.dupe(u8, body_str);

    var resp = Response{
        .allocator = a,
        .status = 200,
        .headers = headers,
        .body = body_bytes,
    };
    defer resp.deinit();

    try std.testing.expectEqualStrings(body_str, resp.bytes());
    try std.testing.expectEqualStrings(body_str, resp.text());

    const User = struct { id: u64, name: []const u8 };
    const parsed = try resp.jsonAlloc(User, a);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 101), parsed.value.id);
    try std.testing.expectEqualStrings("Fiaz", parsed.value.name);

    const user_leaky = try resp.json(User);
    try std.testing.expectEqual(@as(u64, 101), user_leaky.id);
    try std.testing.expectEqualStrings("Fiaz", user_leaky.name);
}

test "client fetch with socks5 proxy connects through mock server" {
    const a = std.testing.allocator;
    const IoContext = tcp.IoContext;
    var ctx = try IoContext.init(a);
    defer ctx.deinit();

    const socks5mod = @import("../net/socks5.zig");
    var mock = try socks5mod.MockSocksServer.start(ctx.io, false, 0x00);
    defer mock.deinit();

    var proxy_url_buf: [64]u8 = undefined;
    const proxy_url = try std.fmt.bufPrint(&proxy_url_buf, "socks5://127.0.0.1:{d}", .{mock.port});

    var client = Client.init(a, ctx.io, .{ .proxy = proxy_url });
    defer client.deinit();

    // Fetch through the mock proxy - verifies handshake was routed through SOCKS
    _ = client.fetch("http://127.0.0.1:8080/test", .{ .timeoutMs = 500 }) catch {};
    try std.testing.expect(mock.recordedAtyp.load(.acquire) != 0);
}

test "client fetch with socks4 proxy connects through mock server" {
    const a = std.testing.allocator;
    const IoContext = tcp.IoContext;
    var ctx = try IoContext.init(a);
    defer ctx.deinit();

    const socks4mod = @import("../net/socks4.zig");
    var mock = try socks4mod.MockSocks4Server.start(ctx.io, 0x5A);
    defer mock.deinit();

    var proxy_url_buf: [64]u8 = undefined;
    const proxy_url = try std.fmt.bufPrint(&proxy_url_buf, "socks4://127.0.0.1:{d}", .{mock.port});

    var client = Client.init(a, ctx.io, .{ .proxy = proxy_url });
    defer client.deinit();

    _ = client.fetch("http://127.0.0.1:8080/test", .{ .timeoutMs = 500 }) catch {};
    try std.testing.expectEqual(@as(u32, 0x7F000001), mock.recordedIp);
}

test "http CONNECT proxy tunnels with origin-form request target" {
    const a = std.testing.allocator;
    const IoContext = tcp.IoContext;
    var ctx = try IoContext.init(a);
    defer ctx.deinit();

    var listener = try tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const proxy_port = listener.localPort();

    const Mock = struct {
        var connect_line: [128]u8 = undefined;
        var connect_len: usize = 0;
        var tunneled_line: [128]u8 = undefined;
        var tunneled_len: usize = 0;

        fn readLine(sock: *tcp.Socket, buf: []u8) !usize {
            var n: usize = 0;
            while (n < buf.len) {
                const m = try sock.read(buf[n..][0..1]);
                if (m == 0) break;
                n += m;
                if (n >= 2 and buf[n - 2] == '\r' and buf[n - 1] == '\n') break;
            }
            return n;
        }

        fn run(lst: *tcp.Listener, io2: std.Io) void {
            var sock = lst.accept(io2) catch return;
            defer sock.close();
            // 1. CONNECT request line.
            var line_buf: [256]u8 = undefined;
            const n = readLine(&sock, &line_buf) catch return;
            const take = @min(n, connect_line.len);
            @memcpy(connect_line[0..take], line_buf[0..take]);
            connect_len = take;
            // Drain remaining CONNECT headers.
            while (true) {
                const m = readLine(&sock, &line_buf) catch return;
                if (m <= 2) break;
            }
            sock.writeAll("HTTP/1.1 200 Connection Established\r\n\r\n") catch return;
            // 2. First tunneled request line (must be origin-form).
            const t = readLine(&sock, &tunneled_line) catch return;
            tunneled_len = t;
            sock.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok") catch {};
        }
    };
    Mock.connect_len = 0;
    Mock.tunneled_len = 0;
    const th = try std.Thread.spawn(.{}, Mock.run, .{ &listener, ctx.io });
    defer th.join();

    var proxy_url_buf: [64]u8 = undefined;
    const proxy_url = try std.fmt.bufPrint(&proxy_url_buf, "http://127.0.0.1:{d}", .{proxy_port});
    var client = Client.init(a, ctx.io, .{});
    defer client.deinit();

    var res = try client.get("http://127.0.0.1:9/proxied/path", .{ .proxy = proxy_url, .timeoutMs = 10_000 });
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings("ok", res.body);

    // CONNECT carried host:port of the TARGET…
    try std.testing.expect(std.mem.startsWith(u8, Mock.connect_line[0..Mock.connect_len], "CONNECT 127.0.0.1:9 "));
    // …while the tunneled request uses the relative origin-form target.
    try std.testing.expect(std.mem.startsWith(u8, Mock.tunneled_line[0..Mock.tunneled_len], "GET /proxied/path "));
    try std.testing.expect(std.mem.indexOf(u8, Mock.tunneled_line[0..Mock.tunneled_len], "https://") == null);
}

test "http CONNECT proxy with credentials sends Proxy-Authorization" {
    const a = std.testing.allocator;
    const IoContext = tcp.IoContext;
    var ctx = try IoContext.init(a);
    defer ctx.deinit();

    var listener = try tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const proxy_port = listener.localPort();

    const Mock = struct {
        var head: [512]u8 = undefined;
        var head_len: usize = 0;

        fn readLine(sock: *tcp.Socket, buf: []u8) !usize {
            var n: usize = 0;
            while (n < buf.len) {
                const m = try sock.read(buf[n..][0..1]);
                if (m == 0) break;
                n += m;
                if (n >= 2 and buf[n - 2] == '\r' and buf[n - 1] == '\n') break;
            }
            return n;
        }

        fn run(lst: *tcp.Listener, io2: std.Io) void {
            var sock = lst.accept(io2) catch return;
            defer sock.close();
            // Capture the whole CONNECT head (request line + headers).
            var line_buf: [256]u8 = undefined;
            while (true) {
                const m = readLine(&sock, &line_buf) catch return;
                const take = @min(m, head.len - head_len);
                @memcpy(head[head_len..][0..take], line_buf[0..take]);
                head_len += take;
                if (m <= 2) break;
            }
            sock.writeAll("HTTP/1.1 200 Connection Established\r\n\r\n") catch return;
            // Drain the tunneled request head, then answer.
            while (true) {
                const m = readLine(&sock, &line_buf) catch return;
                if (m <= 2) break;
            }
            sock.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok") catch {};
        }
    };
    Mock.head_len = 0;
    const th = try std.Thread.spawn(.{}, Mock.run, .{ &listener, ctx.io });
    defer th.join();

    var proxy_url_buf: [96]u8 = undefined;
    const proxy_url = try std.fmt.bufPrint(&proxy_url_buf, "http://user:pass@127.0.0.1:{d}", .{proxy_port});
    var client = Client.init(a, ctx.io, .{});
    defer client.deinit();

    var res = try client.get("http://127.0.0.1:9/authed/path", .{ .proxy = proxy_url, .timeoutMs = 10_000 });
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 200), res.status);

    // "user:pass" base64s to dXNlcjpwYXNz (RFC 7617).
    const head = Mock.head[0..Mock.head_len];
    try std.testing.expect(std.mem.indexOf(u8, head, "Proxy-Authorization: Basic dXNlcjpwYXNz\r\n") != null);
    // Credentials stay on the CONNECT hop, never leak into the tunnel.
    try std.testing.expect(std.mem.indexOf(u8, head, "CONNECT 127.0.0.1:9 ") != null);
}

test "http CONNECT proxy 407 maps to ProxyAuthRequired" {
    const a = std.testing.allocator;
    const IoContext = tcp.IoContext;
    var ctx = try IoContext.init(a);
    defer ctx.deinit();

    var listener = try tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const proxy_port = listener.localPort();

    const Mock = struct {
        fn readLine(sock: *tcp.Socket, buf: []u8) !usize {
            var n: usize = 0;
            while (n < buf.len) {
                const m = try sock.read(buf[n..][0..1]);
                if (m == 0) break;
                n += m;
                if (n >= 2 and buf[n - 2] == '\r' and buf[n - 1] == '\n') break;
            }
            return n;
        }

        fn run(lst: *tcp.Listener, io2: std.Io) void {
            var sock = lst.accept(io2) catch return;
            defer sock.close();
            var line_buf: [256]u8 = undefined;
            while (true) {
                const m = readLine(&sock, &line_buf) catch return;
                if (m <= 2) break;
            }
            sock.writeAll("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"proxy\"\r\n\r\n") catch return;
        }
    };
    const th = try std.Thread.spawn(.{}, Mock.run, .{ &listener, ctx.io });
    defer th.join();

    var proxy_url_buf: [64]u8 = undefined;
    const proxy_url = try std.fmt.bufPrint(&proxy_url_buf, "http://127.0.0.1:{d}", .{proxy_port});
    var client = Client.init(a, ctx.io, .{});
    defer client.deinit();

    const err = client.get("http://127.0.0.1:9/needs-auth", .{ .proxy = proxy_url, .timeoutMs = 10_000 });
    try std.testing.expectError(error.ProxyAuthRequired, err);
}

test "client get over https negotiates h2 end to end" {
    const a = std.testing.allocator;
    const IoContext = tcp.IoContext;
    var ctx = try IoContext.init(a);
    defer ctx.deinit();

    const h2t = @import("../protocols/http2/transport.zig");
    const tlsServerMod = @import("../protocols/tls/tcp_tls.zig");
    const cert_pem = @embedFile("../protocols/tls/testdata/localhost_cert.pem");
    const key_pem = @embedFile("../protocols/tls/testdata/localhost_key.pem");

    var listener = try tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const port = listener.localPort();

    const H = struct {
        fn handle(_: ?*anyopaque, method: []const u8, path: []const u8, _: []const h2t.Header, _: []const u8) anyerror!h2t.HandlerResponse {
            if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/secure")) {
                return .{ .status = 200, .body = "secure-h2" };
            }
            return .{ .status = 404, .body = "nope" };
        }
    };
    const Acceptor = struct {
        fn run(lst: *tcp.Listener, io2: std.Io, out: *?anyerror) void {
            var conn = lst.accept(io2) catch {
                out.* = error.AcceptFailed;
                return;
            };
            defer conn.close();
            var srv = tlsServerMod.TlsServer.init(.{
                .allocator = std.heap.page_allocator,
                .defaultIdentity = .{ .certChainPem = cert_pem, .privateKeyPem = key_pem },
            });
            var tls_conn = srv.handshake(io2, &conn) catch |e| {
                out.* = e;
                return;
            };
            defer tls_conn.deinit();
            h2t.serveTlsConnection(std.heap.page_allocator, &tls_conn, H.handle, null) catch |e| {
                out.* = e;
                return;
            };
            out.* = null;
        }
    };
    var result: ?anyerror = error.NotRun;
    const th = try std.Thread.spawn(.{}, Acceptor.run, .{ &listener, ctx.io, &result });
    defer th.join();

    var client = Client.init(a, ctx.io, .{});
    defer client.deinit();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/secure", .{port});
    var res = try client.get(url, .{
        .httpVersion = .http2,
        .tls = .{ .verify = .caBundle, .caPem = cert_pem },
        .timeoutMs = 15_000,
    });
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings("secure-h2", res.body);
    try std.testing.expect(res.version == .http2);
}

test "client pools h2c sessions across sequential requests" {
    const a = std.testing.allocator;
    const IoContext = tcp.IoContext;
    var ctx = try IoContext.init(a);
    defer ctx.deinit();

    const h2t = @import("../protocols/http2/transport.zig");
    var listener = try tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const port = listener.localPort();

    const H = struct {
        fn handle(_: ?*anyopaque, method: []const u8, path: []const u8, _: []const h2t.Header, _: []const u8) anyerror!h2t.HandlerResponse {
            if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/a")) {
                return .{ .status = 200, .body = "first" };
            }
            if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/b")) {
                return .{ .status = 200, .body = "second" };
            }
            return .{ .status = 404, .body = "nope" };
        }
    };
    const Acceptor = struct {
        fn run(lst: *tcp.Listener, io2: std.Io) void {
            // ONE connection serves both requests: reuse is observable
            // only when the client parks instead of closing.
            var conn = lst.accept(io2) catch return;
            defer conn.close();
            h2t.serveConnection(std.heap.page_allocator, &conn, H.handle, null) catch {};
        }
    };
    const th = try std.Thread.spawn(.{}, Acceptor.run, .{ &listener, ctx.io });
    defer th.join();

    var client = Client.init(a, ctx.io, .{});
    defer client.deinit();

    var url_buf: [64]u8 = undefined;
    const url_a = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/a", .{port});
    var r1 = try client.get(url_a, .{ .httpVersion = .http2, .timeoutMs = 15_000 });
    defer r1.deinit();
    try std.testing.expectEqual(@as(u16, 200), r1.status);
    try std.testing.expectEqualStrings("first", r1.body);

    const url_b = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/b", .{port});
    var r2 = try client.get(url_b, .{ .httpVersion = .http2, .timeoutMs = 15_000 });
    defer r2.deinit();
    try std.testing.expectEqual(@as(u16, 200), r2.status);
    try std.testing.expectEqualStrings("second", r2.body);

    // The second request must have reused the parked session: one miss
    // (first dial), one hit (second request), one session parked.
    const st = client.pool.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 1), st.misses);
    try std.testing.expectEqual(@as(u64, 1), st.hits);
    try std.testing.expectEqual(@as(u64, 2), st.released);
    try std.testing.expectEqual(@as(usize, 1), client.pool.parkedCount());
}

test "client reaps h2 streams past maxConcurrentStreams" {
    const a = std.testing.allocator;
    const IoContext = tcp.IoContext;
    var ctx = try IoContext.init(a);
    defer ctx.deinit();

    const h2t = @import("../protocols/http2/transport.zig");
    var listener = try tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const port = listener.localPort();

    const H = struct {
        fn handle(_: ?*anyopaque, method: []const u8, path: []const u8, _: []const h2t.Header, _: []const u8) anyerror!h2t.HandlerResponse {
            if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/p")) {
                return .{ .status = 200, .body = "pong" };
            }
            return .{ .status = 404, .body = "nope" };
        }
    };
    const Acceptor = struct {
        fn run(lst: *tcp.Listener, io2: std.Io, out: *?anyerror) void {
            // ONE connection serves all requests: reuse is observable
            // only when the client parks instead of closing. Serving ends
            // at client EOF, so `join` after `client.deinit()` below can
            // never hang.
            var conn = lst.accept(io2) catch {
                out.* = error.AcceptFailed;
                return;
            };
            defer conn.close();
            h2t.serveConnection(std.heap.page_allocator, &conn, H.handle, null) catch |e| {
                out.* = e;
                return;
            };
            out.* = null;
        }
    };
    var result: ?anyerror = error.NotRun;
    const th = try std.Thread.spawn(.{}, Acceptor.run, .{ &listener, ctx.io, &result });
    // No defer join: explicit teardown below guarantees client EOF before
    // join (errdefer covers failure paths). A deferred join plus an
    // explicit join double-joins on Windows (INVALID_HANDLE).

    var client = Client.init(a, ctx.io, .{});
    errdefer client.deinit();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/p", .{port});
    // 250 sequential requests on one pooled session: completed streams
    // must be reaped (both sides), or the server falsely hits its
    // maxConcurrentStreams=100 admission cap and kills the connection.
    // testing.allocator additionally proves no per-stream memory leaks.
    var i: usize = 0;
    while (i < 250) : (i += 1) {
        var res = try client.get(url, .{ .httpVersion = .http2, .timeoutMs = 15_000 });
        defer res.deinit();
        try std.testing.expectEqual(@as(u16, 200), res.status);
        try std.testing.expectEqualStrings("pong", res.body);
    }
    const st = client.pool.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 1), st.misses);
    try std.testing.expectEqual(@as(u64, 249), st.hits);
    try std.testing.expectEqual(@as(u64, 250), st.released);
    try std.testing.expectEqual(@as(usize, 1), client.pool.parkedCount());
    client.deinit();
    th.join();
    try std.testing.expect(result == null);
}

test "client pools h2-tls sessions across sequential requests" {
    const a = std.testing.allocator;
    const IoContext = tcp.IoContext;
    var ctx = try IoContext.init(a);
    defer ctx.deinit();

    const h2t = @import("../protocols/http2/transport.zig");
    const tlsServerMod = @import("../protocols/tls/tcp_tls.zig");
    const cert_pem = @embedFile("../protocols/tls/testdata/localhost_cert.pem");
    const key_pem = @embedFile("../protocols/tls/testdata/localhost_key.pem");

    var listener = try tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const port = listener.localPort();

    const H = struct {
        fn handle(_: ?*anyopaque, method: []const u8, path: []const u8, _: []const h2t.Header, _: []const u8) anyerror!h2t.HandlerResponse {
            if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/s")) {
                return .{ .status = 200, .body = "secure-pooled" };
            }
            return .{ .status = 404, .body = "nope" };
        }
    };
    const Acceptor = struct {
        fn run(lst: *tcp.Listener, io2: std.Io, out: *?anyerror) void {
            var conn = lst.accept(io2) catch {
                out.* = error.AcceptFailed;
                return;
            };
            defer conn.close();
            var srv = tlsServerMod.TlsServer.init(.{
                .allocator = std.heap.page_allocator,
                .defaultIdentity = .{ .certChainPem = cert_pem, .privateKeyPem = key_pem },
            });
            var tls_conn = srv.handshake(io2, &conn) catch |e| {
                out.* = e;
                return;
            };
            defer tls_conn.deinit();
            h2t.serveTlsConnection(std.heap.page_allocator, &tls_conn, H.handle, null) catch |e| {
                out.* = e;
                return;
            };
            out.* = null;
        }
    };
    var result: ?anyerror = error.NotRun;
    const th = try std.Thread.spawn(.{}, Acceptor.run, .{ &listener, ctx.io, &result });

    var client = Client.init(a, ctx.io, .{});
    // No defer: the client is torn down explicitly below so the server
    // observes EOF and exits BEFORE the join (errdefer covers failures).
    errdefer client.deinit();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/s", .{port});
    var r1 = try client.get(url, .{
        .httpVersion = .http2,
        .tls = .{ .verify = .caBundle, .caPem = cert_pem },
        .timeoutMs = 15_000,
    });
    defer r1.deinit();
    try std.testing.expectEqualStrings("secure-pooled", r1.body);

    // A second request over the SAME TLS+H2 session: no new handshake.
    var r2 = try client.get(url, .{
        .httpVersion = .http2,
        .tls = .{ .verify = .caBundle, .caPem = cert_pem },
        .timeoutMs = 15_000,
    });
    defer r2.deinit();
    try std.testing.expectEqualStrings("secure-pooled", r2.body);

    const st = client.pool.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 1), st.misses);
    try std.testing.expectEqual(@as(u64, 1), st.hits);

    client.deinit();
    th.join();
    try std.testing.expect(result == null);
}

test "client resumes h2-tls across fresh handshakes via session cache" {
    const a = std.testing.allocator;
    const IoContext = tcp.IoContext;
    var ctx = try IoContext.init(a);
    defer ctx.deinit();

    const h2t = @import("../protocols/http2/transport.zig");
    const tlsServerMod = @import("../protocols/tls/tcp_tls.zig");
    const cert_pem = @embedFile("../protocols/tls/testdata/localhost_cert.pem");
    const key_pem = @embedFile("../protocols/tls/testdata/localhost_key.pem");

    var listener = try tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const port = listener.localPort();

    const H = struct {
        fn handle(_: ?*anyopaque, method: []const u8, path: []const u8, _: []const h2t.Header, _: []const u8) anyerror!h2t.HandlerResponse {
            if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/r")) {
                return .{ .status = 200, .body = "resumed-h2" };
            }
            return .{ .status = 404, .body = "nope" };
        }
    };
    const Acceptor = struct {
        fn run(lst: *tcp.Listener, io2: std.Io, out: *?anyerror) void {
            var resumed: [2]bool = .{ false, false };
            for (0..2) |i| {
                var conn = lst.accept(io2) catch {
                    out.* = error.AcceptFailed;
                    return;
                };
                defer conn.close();
                var srv = tlsServerMod.TlsServer.init(.{
                    .allocator = std.heap.page_allocator,
                    .defaultIdentity = .{ .certChainPem = cert_pem, .privateKeyPem = key_pem },
                    .ticketKeys = .{ .current = [_]u8{0x5E} ** 32 },
                });
                var tls_conn = srv.handshake(io2, &conn) catch |e| {
                    out.* = e;
                    return;
                };
                defer tls_conn.deinit();
                resumed[i] = tls_conn.resumed;
                h2t.serveTlsConnection(std.heap.page_allocator, &tls_conn, H.handle, null) catch |e| {
                    out.* = e;
                    return;
                };
            }
            if (resumed[0] or !resumed[1]) {
                out.* = error.ResumptionMismatch;
                return;
            }
            out.* = null;
        }
    };
    var result: ?anyerror = error.NotRun;
    const th = try std.Thread.spawn(.{}, Acceptor.run, .{ &listener, ctx.io, &result });

    // Pooling disabled so each get performs a fresh handshake; the
    // second must abbreviate via the session cache.
    var client = Client.init(a, ctx.io, .{ .pool = .{ .maxConnections = 0 } });
    errdefer client.deinit();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/r", .{port});
    var r1 = try client.get(url, .{
        .httpVersion = .http2,
        .tls = .{ .verify = .caBundle, .caPem = cert_pem },
        .timeoutMs = 15_000,
    });
    defer r1.deinit();
    try std.testing.expectEqualStrings("resumed-h2", r1.body);

    var r2 = try client.get(url, .{
        .httpVersion = .http2,
        .tls = .{ .verify = .caBundle, .caPem = cert_pem },
        .timeoutMs = 15_000,
    });
    defer r2.deinit();
    try std.testing.expectEqualStrings("resumed-h2", r2.body);

    client.deinit();
    th.join();
    try std.testing.expect(result == null);
}

test "client get over http3 serves loopback over real udp" {
    const a = std.testing.allocator;
    const IoContext = tcp.IoContext;
    var ctx = try IoContext.init(a);
    defer ctx.deinit();

    const quicConn = @import("../protocols/quic/connection.zig");
    const quicEp = @import("../protocols/quic/transport.zig");
    const quicHs = @import("../protocols/quic/handshake.zig");
    const quicFrames = @import("../protocols/quic/frames.zig");
    const h3conn = @import("../protocols/http3/connection.zig");
    const h3frame = @import("../protocols/http3/frame.zig");
    const h3qpack = @import("../protocols/http3/qpack.zig");
    const cert_pem = @embedFile("../protocols/tls/testdata/localhost_cert.pem");
    const key_pem = @embedFile("../protocols/tls/testdata/localhost_key.pem");

    // In-process H3/QUIC server: two sequential connections on one UDP
    // socket, one GET each. Pumps itself on its own thread; the client
    // under test pumps only itself (the external-peer path).
    const Server = struct {
        ep: quicEp.Endpoint = undefined,
        pump: quicEp.Pump = undefined,

        // One client-bidi request stream's bytes until FIN. Control and
        // QPACK uni streams are ignored (static-table responses need no
        // decoder traffic); only client bidi streams (id % 4 == 0) latch.
        const Acc = struct {
            sid: u64 = std.math.maxInt(u64),
            buf: std.ArrayList(u8) = .empty,
            fin: bool = false,
        };

        fn onStream(c: ?*anyopaque, sid: u64, data: []const u8, fin: bool) void {
            const acc: *Acc = @ptrCast(@alignCast(c.?));
            if (acc.sid == std.math.maxInt(u64) and sid % 4 == 0) acc.sid = sid;
            if (sid != acc.sid) return;
            acc.buf.appendSlice(std.testing.allocator, data) catch return;
            if (fin) acc.fin = true;
        }

        fn sendStream(conn: *quicConn.Connection, sid: u64, bytes: []const u8, fin: bool) !void {
            const B = struct {
                var s_id: u64 = 0;
                var s_fin: bool = false;
                var s_data: []const u8 = "";
                pub fn build(gpa: std.mem.Allocator, payload: *std.ArrayList(u8)) quicConn.Error!void {
                    quicFrames.encode(payload, gpa, .{ .stream = .{ .id = s_id, .offset = 0, .data = s_data, .fin = s_fin } }) catch
                        return quicConn.Error.OutOfMemory;
                }
            };
            B.s_id = sid;
            B.s_fin = fin;
            B.s_data = bytes;
            try conn.sendFrames(.application, B.build, 0);
        }

        fn serveOne(srv: *@This(), seed: u64, deadline_ms: u64) !void {
            const alloc = std.testing.allocator;
            var qconn = try quicConn.Connection.init(alloc, .server, .{}, seed);
            defer qconn.deinit();
            // The endpoint's conn pointer follows each fresh connection;
            // the previous one is already deinited by its own scope.
            srv.ep.conn = qconn;
            var drv = quicHs.Driver.initServer(alloc, .{ .certChainPem = cert_pem, .privateKeyPem = key_pem });
            defer drv.deinit();
            qconn.tls = .{ .ctx = &drv, .start = quicHs.Driver.clientStart, .onData = quicHs.Driver.onData };
            try quicHs.serveHandshake(&srv.ep, &srv.pump, &drv, deadline_ms);

            var h3 = h3conn.Connection.init(alloc, .server);
            defer h3.deinit();
            var acc = Acc{};
            defer acc.buf.deinit(alloc);
            qconn.cbs = .{ .ctx = &acc, .onStreamData = onStream };
            const start: u64 = @intCast(clock.millisNow());
            while (true) {
                const now: u64 = @intCast(clock.millisNow());
                if (now -| start > deadline_ms) return error.Timeout;
                try quicHs.feedPumped(&srv.ep, &srv.pump, null, 500, now);
                if (!acc.fin) continue;
                // Decode request HEADERS, route by :path, respond.
                var off: usize = 0;
                const fr = try h3frame.parseFrame(acc.buf.items, &off);
                const fields = try h3.qdec.decodeSectionWithPrefix(fr.payload);
                defer h3.qdec.freeFields(fields);
                var path: []const u8 = "";
                for (fields) |f| {
                    if (std.mem.eql(u8, f.name, ":path")) path = f.value;
                }
                const is_hello = std.mem.eql(u8, path, "/hello");
                var rs = h3conn.RequestStream{ .id = acc.sid, .allocator = alloc, .qpack = h3qpack.Encoder.init(alloc) };
                defer rs.qpack.deinit();
                const rhead = try rs.buildResponseHeaders(if (is_hello) 200 else 404, &.{});
                defer alloc.free(rhead);
                const rdata = try rs.buildData(if (is_hello) "hello-h3" else "not-found");
                defer alloc.free(rdata);
                var wire = std.ArrayList(u8).empty;
                defer wire.deinit(alloc);
                try wire.appendSlice(alloc, rhead);
                try wire.appendSlice(alloc, rdata);
                try sendStream(qconn, acc.sid, wire.items, true);
                _ = try srv.ep.flush(null);
                return;
            }
        }

        fn run(srv: *@This(), out: *?anyerror) void {
            serveOne(srv, 0x91, 15_000) catch |e| {
                out.* = e;
                return;
            };
            serveOne(srv, 0x92, 15_000) catch |e| {
                out.* = e;
                return;
            };
            // Third connection: untrusted client. It fails chain
            // verification and goes quiet, so the server must time out
            // (never complete). A completed third handshake would mean
            // the client accepted a forged chain — catastrophic.
            if (serveOne(srv, 0x93, 5_000)) {
                out.* = error.UnexpectedSuccess;
            } else |e| {
                out.* = if (e == error.HandshakeTimeout) null else e;
            }
        }
    };

    // Placeholder conn: replaced by each serveOne before any feeding.
    var placeholder = try quicConn.Connection.init(a, .server, .{}, 0x90);
    defer placeholder.deinit();
    var srv = Server{};
    srv.ep = try quicEp.Endpoint.initPort(a, ctx.io, placeholder, 0);
    const port = srv.ep.localPort();
    defer srv.ep.deinit();
    try srv.pump.start(&srv.ep, a);
    defer srv.pump.stop();

    var result: ?anyerror = error.NotRun;
    const th = try std.Thread.spawn(.{}, Server.run, .{ &srv, &result });

    // Explicit teardown (no defer join): the server exits on its own
    // after two requests, so join-then-assert is exact. errdefer covers
    // failures (server times out internally and exits by itself).
    var client = Client.init(a, ctx.io, .{});
    errdefer client.deinit();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/hello", .{port});
    var res = try client.get(url, .{
        .httpVersion = .http3,
        .tls = .{ .verify = .caBundle, .caPem = cert_pem },
        .timeoutMs = 15_000,
    });
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings("hello-h3", res.body);
    try std.testing.expect(res.version == .http3);

    const url404 = try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/missing", .{port});
    var res404 = try client.get(url404, .{
        .httpVersion = .http3,
        .tls = .{ .verify = .caBundle, .caPem = cert_pem },
        .timeoutMs = 15_000,
    });
    defer res404.deinit();
    try std.testing.expectEqual(@as(u16, 404), res404.status);

    // Untrusted chain fails fast and loudly (no 15s deadline burn: the
    // doomed handshake aborts as soon as the driver rejects the chain).
    const bad = client.get(url, .{
        .httpVersion = .http3,
        .tls = .{ .verify = .caBundle, .caPem = "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----" },
        .timeoutMs = 15_000,
    });
    try std.testing.expectError(Error.TlsCertificateNotVerified, bad);

    client.deinit();
    th.join();
    // Server side: two clean serves, then the quiet-abort timeout.
    try std.testing.expect(result == null);
}

test "client get over mtls presents certificate through high-level api" {
    const a = std.testing.allocator;
    const IoContext = tcp.IoContext;
    var ctx = try IoContext.init(a);
    defer ctx.deinit();

    const cert_pem = @embedFile("../protocols/tls/testdata/localhost_cert.pem");
    const key_pem = @embedFile("../protocols/tls/testdata/localhost_key.pem");

    var listener = try tcp.Listener.bind(ctx.io, 0);
    defer listener.close(ctx.io);
    const port = listener.localPort();

    // Plain HTTPS/1.1 server that *requires* a client certificate.
    const Acceptor = struct {
        fn run(lst: *tcp.Listener, io2: std.Io, out: *?anyerror) void {
            var conn = lst.accept(io2) catch {
                out.* = error.AcceptFailed;
                return;
            };
            defer conn.close();
            const tlsServerMod = @import("../protocols/tls/tcp_tls.zig");
            var srv = tlsServerMod.TlsServer.init(.{
                .allocator = std.heap.page_allocator,
                .defaultIdentity = .{ .certChainPem = cert_pem, .privateKeyPem = key_pem },
                .clientAuth = .required,
                .clientCaPem = cert_pem,
            });
            var tls_conn = srv.handshake(io2, &conn) catch |e| {
                out.* = e;
                return;
            };
            defer tls_conn.deinit();
            var buf: [256]u8 = undefined;
            var head_len: usize = 0;
            while (head_len < buf.len) {
                const n = tls_conn.read(buf[head_len..]) catch |e| {
                    out.* = e;
                    return;
                };
                if (n == 0) {
                    out.* = error.EarlyClose;
                    return;
                }
                head_len += n;
                if (std.mem.indexOf(u8, buf[0..head_len], "\r\n\r\n") != null) break;
            }
            const body = "mutual-high-level";
            var resp_buf: [256]u8 = undefined;
            const resp = std.fmt.bufPrint(&resp_buf, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch {
                out.* = error.NoSpace;
                return;
            };
            tls_conn.writeAll(resp) catch |e| {
                out.* = e;
                return;
            };
            out.* = null;
        }
    };
    var result: ?anyerror = error.NotRun;
    const th = try std.Thread.spawn(.{}, Acceptor.run, .{ &listener, ctx.io, &result });
    defer th.join();

    var client = Client.init(a, ctx.io, .{});
    defer client.deinit();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/", .{port});
    var res = try client.get(url, .{
        .tls = .{
            .verify = .caBundle,
            .caPem = cert_pem,
            .clientCertPem = cert_pem,
            .clientKeyPem = key_pem,
        },
        .timeoutMs = 15_000,
    });
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings("mutual-high-level", res.body);
}

test "client resolve literal IP and hostname" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var client = Client.init(a, io, .{});
    defer client.deinit();

    // 1. Literal IP resolution
    var addrs = try client.resolve("127.0.0.1", .{ .port = 80 });
    defer addrs.deinit();
    try std.testing.expect(addrs.len() >= 1);
    try std.testing.expectEqual(addressMod.Family.ip4, addrs.first().?.family);
    try std.testing.expectEqual(@as(u16, 80), addrs.first().?.port);

    // 2. Family filter for IP
    var v4_only = try client.resolve("127.0.0.1", .{ .port = 8080, .family = .ipv4 });
    defer v4_only.deinit();
    try std.testing.expectEqual(@as(usize, 1), v4_only.len());

    // 3. URL resolution
    var url_addrs = try client.resolveUrl("http://127.0.0.1:9000/test", .{});
    defer url_addrs.deinit();
    try std.testing.expectEqual(@as(u16, 9000), url_addrs.first().?.port);

    // 4. Test format method on ResolvedAddresses
    var fmt_buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&fmt_buf);
    try addrs.format(&w);
    try std.testing.expect(w.buffered().len > 0);
}

test "resolve uses safe .{} defaults and explicit overrides" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var client = Client.init(a, io, .{});
    defer client.deinit();

    // Default .{}: port 443, family any, cache on.
    var def = try client.resolve("127.0.0.1", .{});
    defer def.deinit();
    try std.testing.expectEqual(@as(u16, 443), def.first().?.port);

    // Single override leaves everything else default.
    var over = try client.resolve("127.0.0.1", .{ .port = 8080 });
    defer over.deinit();
    try std.testing.expectEqual(@as(u16, 8080), over.first().?.port);
}

test "client camelCase config options and request options" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var client = Client.init(a, io, .{
        .timeoutMs = 3500,
        .followRedirects = false,
        .maxRedirects = 3,
        .allowLfLineEndings = true,
        .httpVersion = .http11,
    });
    defer client.deinit();

    try std.testing.expectEqual(@as(?u64, 3500), client.config.timeoutMs);
    try std.testing.expectEqual(false, client.config.followRedirects);
    try std.testing.expectEqual(@as(u8, 3), client.config.maxRedirects);
    try std.testing.expectEqual(true, client.config.allowLfLineEndings);
    try std.testing.expectEqual(HttpVersion.http11, client.config.httpVersion.?);

    // Test per-request camelCase options and method variants
    const res1 = client.fetch("http://127.0.0.1:1/", .{
        .method = .post,
        .timeoutMs = 100,
        .followRedirects = false,
        .maxRedirects = 2,
        .bearerAuth = "test-token",
        .contentType = "application/json",
        .body = "{}",
    });
    try std.testing.expectError(Error.ConnectFailed, res1);

    const res2 = client.fetch("http://127.0.0.1:1/", .{
        .method = .GET,
        .basicAuth = "dXNlcjpwYXNz",
        .maxResponseSize = 1024,
    });
    try std.testing.expectError(Error.ConnectFailed, res2);

    const res3 = client.fetch("http://127.0.0.1:1/", .{
        .method = "PUT",
        .httpVersion = .http11,
    });
    try std.testing.expectError(Error.ConnectFailed, res3);
}

test "requestAll error path cleans up without double free" {
    // Regression test: batch failures previously double-freed the result
    // buffer (function errdefer + manual cleanup) and segfaulted.
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var client = Client.init(a, io, .{ .timeoutMs = 500 });
    defer client.deinit();

    // Parallel path (len > 1): all targets refused -> firstErr cleanup.
    const reqs = [_]RequestOptions{
        .{ .method = .GET, .url = "http://127.0.0.1:1/a" },
        .{ .method = .GET, .url = "http://127.0.0.1:1/b" },
        .{ .method = .GET, .url = "http://127.0.0.1:1/c" },
    };
    const batch = client.requestAll(reqs);
    try std.testing.expectError(Error.ConnectFailed, batch);

    // Single path (len == 1): error must free only the assigned prefix.
    const one = [_]RequestOptions{
        .{ .method = .GET, .url = "http://127.0.0.1:1/only" },
    };
    const single = client.requestAll(one);
    try std.testing.expectError(Error.ConnectFailed, single);

    // getAll wrapper shares the same cleanup path.
    const urls = [_][]const u8{
        "http://127.0.0.1:1/x",
        "http://127.0.0.1:1/y",
    };
    const multi = client.getAll(urls);
    try std.testing.expectError(Error.ConnectFailed, multi);
}

test "normalizeMethod enum and string literals" {
    try std.testing.expectEqual(Method.GET, normalizeMethod(.GET));
    try std.testing.expectEqual(Method.GET, normalizeMethod(.get));
    try std.testing.expectEqual(Method.POST, normalizeMethod(.POST));
    try std.testing.expectEqual(Method.POST, normalizeMethod(.post));
    try std.testing.expectEqual(Method.PUT, normalizeMethod(.PUT));
    try std.testing.expectEqual(Method.PUT, normalizeMethod(.put));
    try std.testing.expectEqual(Method.DELETE, normalizeMethod(.DELETE));
    try std.testing.expectEqual(Method.DELETE, normalizeMethod(.delete));
    try std.testing.expectEqual(Method.PATCH, normalizeMethod(.PATCH));
    try std.testing.expectEqual(Method.PATCH, normalizeMethod(.patch));
    try std.testing.expectEqual(Method.HEAD, normalizeMethod(.HEAD));
    try std.testing.expectEqual(Method.HEAD, normalizeMethod(.head));
    try std.testing.expectEqual(Method.OPTIONS, normalizeMethod(.OPTIONS));
    try std.testing.expectEqual(Method.OPTIONS, normalizeMethod(.options));
    try std.testing.expectEqual(Method.TRACE, normalizeMethod(.TRACE));
    try std.testing.expectEqual(Method.TRACE, normalizeMethod(.trace));
    try std.testing.expectEqual(Method.CONNECT, normalizeMethod(.CONNECT));
    try std.testing.expectEqual(Method.CONNECT, normalizeMethod(.connect));

    try std.testing.expectEqual(Method.GET, normalizeMethod("GET"));
    try std.testing.expectEqual(Method.GET, normalizeMethod("get"));
    try std.testing.expectEqual(Method.POST, normalizeMethod("post"));
}
