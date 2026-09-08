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
    /// Enable cookie handling
    cookies: bool = true,

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

    /// Initializes client with explicit allocator and shared IO.
    /// Matches `var client = httpx.Client.init(allocator, io, .{});`
    pub fn init(allocator: Allocator, io: std.Io, config: Config) Client {
        var c = Client{
            .allocator = allocator,
            .io = io,
            .pool = Pool.init(allocator, io, config.pool),
            .config = config,
        };
        if (config.dnsCache.enable) {
            c.dnsCache = dnsCache.Cache.init(
                allocator,
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
        errdefer {
            for (out) |*r| r.deinit();
            self.allocator.free(out);
        }
        if (slice.len <= 1) {
            for (slice, 0..) |item, i| {
                out[i] = try self.doRequest(item.method orelse .GET, item.url, item);
            }
            return out;
        }

        const TaskCtx = struct {
            client: *Client,
            reqs: []const RequestOptions,
            out: []Response,
            success: []bool,
            next_idx: *std.atomic.Value(usize),
            err_mutex: sync.Spinlock = .{},
            first_err: ?anyerror = null,

            fn worker(ctx: *@This()) void {
                while (true) {
                    const idx = ctx.next_idx.fetchAdd(1, .monotonic);
                    if (idx >= ctx.reqs.len) break;
                    {
                        ctx.err_mutex.lock();
                        const has_err = ctx.first_err != null;
                        ctx.err_mutex.unlock();
                        if (has_err) break;
                    }

                    const current = ctx.reqs[idx];
                    const resp = ctx.client.doRequestWithOverride(current.method orelse .GET, current.url, current) catch |e| {
                        ctx.err_mutex.lock();
                        if (ctx.first_err == null) ctx.first_err = e;
                        ctx.err_mutex.unlock();
                        break;
                    };
                    ctx.out[idx] = resp;
                    ctx.success[idx] = true;
                }
            }
        };

        const success = try self.allocator.alloc(bool, slice.len);
        defer self.allocator.free(success);
        @memset(success, false);

        var next_idx = std.atomic.Value(usize).init(0);
        var task_ctx = TaskCtx{
            .client = self,
            .reqs = slice,
            .out = out,
            .success = success,
            .next_idx = &next_idx,
        };

        const max_workers = @min(@as(usize, 16), slice.len);
        var threads = try self.allocator.alloc(?std.Thread, max_workers);
        defer self.allocator.free(threads);

        for (0..max_workers) |w| {
            threads[w] = std.Thread.spawn(.{}, TaskCtx.worker, .{&task_ctx}) catch null;
            if (threads[w] == null) {
                TaskCtx.worker(&task_ctx);
            }
        }

        for (threads) |m_th| {
            if (m_th) |th| th.join();
        }

        if (task_ctx.first_err) |e| {
            for (0..slice.len) |i| {
                if (success[i]) out[i].deinit();
            }
            self.allocator.free(out);
            return e;
        }
        return out;
    }

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
    pub fn download(self: *Client, url: []const u8, destination: []const u8, opts: anytype) DownloadError!DownloadResult {
        var dl = DownloadCore.Downloader.init(self.allocator, self);
        const downloadOptions = coerceDownloadOptions(opts);
        return dl.download(url, destination, downloadOptions);
    }

    /// Downloads a batch of files concurrently using the client's internal allocator.
    pub fn downloadBatch(self: *Client, tasks: []const struct { url: []const u8, dest: []const u8 }, opts: anytype) DownloadError!void {
        const downloadOptions = coerceDownloadOptions(opts);
        for (tasks) |t| {
            _ = try self.download(t.url, t.dest, downloadOptions);
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
    pub fn updateFile(self: *Client, url: []const u8, targetPath: []const u8, opts: anytype) DownloadError!DownloadResult {
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
        return DownloadCore.updateFile(self.allocator, self, url, targetPath, updateOptions);
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
    ///   var addresses = try client.resolve("httpbun.com", 443, .{});
    ///   defer addresses.deinit();
    ///   for (addresses.items) |addr| {
    ///       std.debug.print("Resolved: {f}\n", .{addr});
    ///   }
    ///
    /// IPv4-only:
    ///   var addresses = try client.resolve("httpbun.com", 443, .{ .family = .ipv4 });
    ///   defer addresses.deinit();
    pub fn resolve(self: *Client, host: []const u8, port: u16, opts: anytype) Error!ResolvedAddresses {
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
            addr.port = port;
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
            if (self.dnsCache.?.resolve(self.io, host)) |cached_strs| {
                defer {
                    for (cached_strs) |s| self.allocator.free(s);
                    self.allocator.free(cached_strs);
                }
                for (cached_strs) |s| {
                    if (req.parseAddrString(s, port)) |parsed| {
                        outList.append(self.allocator, parsed) catch return Error.OutOfMemory;
                    }
                }
            } else |_| {}
        }

        // 3. Fallback to fresh OS resolution if un-cached
        if (outList.items.len == 0) {
            const resolver = netResolve.Resolver.init(self.allocator);
            const resolvedRaw = resolver.lookupWithIo(self.io, host, port) catch |err| switch (err) {
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
    pub fn resolveUrl(self: *Client, urlStr: []const u8, opts: anytype) Error!ResolvedAddresses {
        const uriMod = @import("../common/uri.zig");
        const u = uriMod.parse(urlStr) catch return Error.InvalidUrl;
        const p = u.effectivePort();
        if (p == 0) return Error.InvalidUrl;
        return self.resolve(u.host, p, opts);
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

        var user_has_content_type = false;

        // Headers: support both []const Header and struct literal
        if (@hasField(@TypeOf(opts), "headers")) {
            const H = @TypeOf(opts.headers);
            if (comptime @typeInfo(H) == .pointer and @typeInfo(H).pointer.size == .slice) {
                for (opts.headers) |h| {
                    if (std.ascii.eqlIgnoreCase(h.name, "content-type")) user_has_content_type = true;
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
                    if (std.ascii.eqlIgnoreCase(norm_name, "content-type")) user_has_content_type = true;
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
                    hdrs.append(self.allocator, .{ .name = norm_name, .value = val_str }) catch return Error.OutOfMemory;
                }
            }
        }

        // Content-Type inference (only if not already explicitly provided in headers)
        if (!user_has_content_type) {
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
        var body_kind: req.BodyKind = .none;
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

            const field_name_val: []const u8 = mp.fieldName;
            const filename_val: ?[]const u8 = blk: {
                if (!@hasField(@TypeOf(mp), "filename")) break :blk null;
                const v = mp.filename;
                const T = @TypeOf(v);
                if (@typeInfo(T) == .optional) break :blk v;
                break :blk @as(?[]const u8, v);
            };
            const content_type_val: []const u8 = blk: {
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
                .content_type = content_type_val,
                .data = mp.data,
            };
            multipart_buf = mp_encoder.encodeAllocParts(self.allocator, boundary, &.{part}) catch return Error.OutOfMemory;
            if (multipart_buf) |b| {
                body_val = b;
                body_kind = .raw;
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
            .bodyKind = body_kind,
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
                .kind = .request_completed,
                .level = .info,
                .method = @tagName(method),
                .url = targetUrl,
                .status = resp.status,
            });
            return resp;
        } else |e| {
            if (self.config.eventCallback) |cb| cb(.{
                .kind = .request_failed,
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
    const c = defaultClient() orelse return Error.DefaultClientUnavailable;
    return c.getAll(urls);
}

pub fn globalRequestAll(reqs: anytype) ![]Response {
    const c = defaultClient() orelse return Error.DefaultClientUnavailable;
    return c.requestAll(reqs);
}

pub fn globalDownload(url: []const u8, destination: []const u8, opts: anytype) DownloadError!DownloadResult {
    const c = defaultClient() orelse return DownloadError.ConnectionFailed;
    return c.download(url, destination, opts);
}

pub fn globalUpdateFile(url: []const u8, targetPath: []const u8, opts: anytype) DownloadError!DownloadResult {
    const c = defaultClient() orelse return DownloadError.ConnectionFailed;
    return c.updateFile(url, targetPath, opts);
}

pub fn globalVerifyFile(path: []const u8, opts: VerifyOptions) DownloadError!void {
    return DownloadCore.verifyFile(path, opts);
}

pub fn globalLookupFileInfo(url: []const u8, opts: anytype) DownloadError!RemoteFileInfo {
    const c = defaultClient() orelse return DownloadError.ConnectionFailed;
    return c.lookupFileInfo(url, opts);
}

/// Zero-config global DNS resolution function.
pub fn globalResolve(host: []const u8, port: u16, opts: anytype) Error!ResolvedAddresses {
    const c = defaultClient() orelse return Error.DefaultClientUnavailable;
    return c.resolve(host, port, opts);
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
    const r1 = client.dnsCache.?.resolve(client.io, "localhost") catch return;
    defer {
        for (r1) |addr| a.free(addr);
        a.free(r1);
    }
    try std.testing.expect(r1.len >= 1);

    const r2 = client.dnsCache.?.resolve(client.io, "localhost") catch return;
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
    try std.testing.expect(mock.recorded_atyp.load(.acquire) != 0);
}

test "client resolve literal IP and hostname" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var client = Client.init(a, io, .{});
    defer client.deinit();

    // 1. Literal IP resolution
    var addrs = try client.resolve("127.0.0.1", 80, .{});
    defer addrs.deinit();
    try std.testing.expect(addrs.len() >= 1);
    try std.testing.expectEqual(addressMod.Family.ip4, addrs.first().?.family);
    try std.testing.expectEqual(@as(u16, 80), addrs.first().?.port);

    // 2. Family filter for IP
    var v4_only = try client.resolve("127.0.0.1", 8080, .{ .family = .ipv4 });
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
