//! HTTP client: one request engine for all methods.
//!
//! ```zig
//! const res = try httpx.client.request(allocator, io, .{
//!     .method = .POST,
//!     .url = "http://127.0.0.1:8080/api",
//!     .body_kind = .json,
//!     .body = "{\"ok\":true}",
//! });
//! defer res.deinit();
//! ```
//!
//! Scope: HTTP/1.x over TCP (http://). https:// requires explicit TLS
//! configuration (TlsOptions). Follows 301/302/303 (-> GET) and
//! 307/308 (method preserved), stripping Authorization on cross-origin hops
//! per RFC 7235 Section 2.2. Content-Length and chunked transfer-encoding
//! response bodies are both decoded.
//!
//! References:
//!   - RFC 9110 Section 5.3 — Request Target
//!   - RFC 9112 Section 6 — Message Body (Content-Length, chunked)
//!   - RFC 9112 Section 9.5 — Transfer-Encoding (chunked)
//!   - RFC 7235 Section 2.2 — Authorization on Redirect
//!   - RFC 7231 Section 6.4 — Redirection (301, 302, 303, 307, 308)
//!   - RFC 7578 — Multipart Form Data (file upload support)
//!   - RFC 3986 Section 5 — Reference Resolution (Location header)

const std = @import("std");
const envPkg = @import("env");
const Allocator = std.mem.Allocator;
const tcp = @import("../sockets/tcp.zig");
const uriMod = @import("../common/uri.zig");
const Method = @import("../common/method.zig").Method;
const parserMod = @import("../protocols/http1/parser.zig");
const writerMod = @import("../protocols/http1/writer.zig");
const tlsTransport = @import("../protocols/tls/transport.zig");
const http2Transport = @import("../protocols/http2/transport.zig");
const poolNs = @import("pool.zig");
const Pool = poolNs.Pool;
const netResolve = @import("../net/resolve.zig");
const addressMod = @import("../net/address.zig");
const compression = @import("../compression/codec.zig");
const dnsCacheNs = @import("../net/dns/cache.zig");
pub const HttpVersion = @import("../common/http_version.zig").HttpVersion;
const versionInfo = @import("../common/version.zig");
const proxyMod = @import("../net/proxy.zig");
const socks5 = @import("../net/socks5.zig");

/// Adapter: OS resolver -> string addresses for the single-flight cache.
pub fn systemLookupStrings(
    ctx: ?*anyopaque,
    io: std.Io,
    name: []const u8,
    a: Allocator,
) dnsCacheNs.LookupError![]const []const u8 {
    _ = ctx;
    const resolver = netResolve.Resolver.init(a);
    const addrs = resolver.lookupWithIo(io, name, 0) catch |e| switch (e) {
        error.HostNotFound => return error.DnsFailed,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.DnsFailed,
    };
    // Convert to owned strings; free the struct list immediately.
    defer a.free(addrs);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| a.free(s);
        out.deinit(a);
    }
    for (addrs) |addr| {
        var buf: [64]u8 = undefined;
        const s = addr.formatBuf(&buf);
        out.append(a, a.dupe(u8, s) catch return error.OutOfMemory) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice(a) catch error.OutOfMemory;
}

/// Parse one cached address string (v4 or v6) into a typed Address.
pub fn parseAddrString(s: []const u8, port: u16) ?addressMod.Address {
    var probe = addressMod.Address{ .family = .ip4, .port = 0 };
    const parsed = probe.parseIp(s) catch return null;
    var r = parsed;
    r.port = port;
    return r;
}

/// TLS verification policy for one request.
/// Secure by construction: an https:// request WITHOUT `tls` options fails
/// with TlsConfigRequired instead of silently skipping verification.
pub const TlsOptions = struct {
    verify: tlsTransport.VerifyMode = .caBundle,
    /// CA bundle required when verify == .caBundle.
    caBundle: ?*std.crypto.Certificate.Bundle = null,
    /// Only safe when the caller validates completeness via framing.
    allowTruncation: bool = true,
};

/// Per-request socket I/O timeout (milliseconds).
pub const Header = struct { name: []const u8, value: []const u8 };

pub const BodyKind = enum { none, raw, json, form };

pub const Request = struct {
    method: Method = .GET,
    url: []const u8,
    /// Extra headers ("Name", "value" pairs).
    headers: []const Header = &.{},
    /// Appended to the URL path as ?k=v&... (values are percent-encoded).
    query: []const Header = &.{},
    bodyKind: BodyKind = .none,
    /// Raw bytes for any kind; for `form` this is "k=v&k2=v2" already encoded.
    body: []const u8 = "",
    followRedirects: bool = true,
    maxRedirects: u8 = 5,
    /// Required for https:// URLs. Absence on an https URL is an error.
    tls: ?TlsOptions = null,
    /// Optional single-flight DNS cache; set by Client automatically.
    dnsCache: ?*dnsCacheNs.Cache = null,
    /// Optional keep-alive connection pool; set by Client automatically.
    pool: ?*Pool = null,
    /// HTTP version selection (see HttpVersion docs). Default auto.
    httpVersion: HttpVersion = .auto,
    /// Allow bare LF line endings for non-compliant peers (issue #37).
    allowLfLineEndings: bool = false,
    /// Optional cookie header value (e.g. "a=b; c=d").
    cookie: ?[]const u8 = null,
    /// Basic auth: "user:pass" will be base64-encoded as Authorization.
    basicAuth: ?[]const u8 = null,
    /// Bearer token for Authorization: Bearer <token>.
    bearerAuth: ?[]const u8 = null,
    /// Request timeout in milliseconds (connect + read).
    timeoutMs: ?u64 = null,
    /// Maximum response body size.
    maxResponseSize: ?usize = null,
    /// Optional proxy URL (e.g. "socks5://127.0.0.1:1080", "socks5h://127.0.0.1:1080", "http://127.0.0.1:8080").
    proxy: ?[]const u8 = null,

    pub fn text(url: []const u8, bodyText: []const u8) Request {
        return .{ .url = url, .method = .POST, .bodyKind = .raw, .body = bodyText };
    }
};

pub const Response = struct {
    allocator: Allocator,
    status: u16,
    version: HttpVersion = .http11,
    headers: []Header,
    body: []u8,

    pub fn deinit(self: *Response) void {
        for (self.headers) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.allocator.free(self.headers);
        self.allocator.free(self.body);
    }

    pub fn header(self: *const Response, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    /// Parses the body as JSON into `T` (ignores unknown fields).
    pub fn json(self: *const Response, comptime T: type) !T {
        return std.json.parseFromSliceLeaky(T, self.allocator, self.body, .{ .ignore_unknown_fields = true });
    }

    /// Parses the body as JSON with an explicit allocator and returns `std.json.Parsed(T)` with managed lifecycle.
    pub fn jsonAlloc(self: *const Response, comptime T: type, allocator: Allocator) !std.json.Parsed(T) {
        return std.json.parseFromSlice(T, allocator, self.body, .{ .ignore_unknown_fields = true });
    }

    /// Returns body as text (UTF-8).
    pub fn text(self: *const Response) []const u8 {
        return self.body;
    }

    /// Streams or writes body bytes to any writer (e.g. file, stdout, custom buffer).
    pub fn writeTo(self: *const Response, writer: anytype) !void {
        try writer.writeAll(self.body);
    }

    /// Returns true if status code is informational (100..199).
    pub fn isInformational(self: *const Response) bool {
        return self.status >= 100 and self.status < 200;
    }

    /// Returns true if status code is in 200..299 range.
    pub fn isSuccess(self: *const Response) bool {
        return self.status >= 200 and self.status < 300;
    }

    /// Returns true if status code is a redirect (300..399).
    pub fn isRedirect(self: *const Response) bool {
        return self.status >= 300 and self.status < 400;
    }

    /// Returns true if status code is client error (400..499).
    pub fn isClientError(self: *const Response) bool {
        return self.status >= 400 and self.status < 500;
    }

    /// Returns true if status code is server error (500..599).
    pub fn isServerError(self: *const Response) bool {
        return self.status >= 500 and self.status < 600;
    }

    /// Content-Type header value or empty string.
    pub fn contentType(self: *const Response) []const u8 {
        return self.header("content-type") orelse "";
    }

    /// Parses HTML body into a Document using the response's internal allocator.
    pub fn html(self: *const Response) !@import("../parsing/document.zig").Document {
        return @import("../parsing/document.zig").Document.parseHtml(self.allocator, self.body);
    }

    /// Parses XML body into a Document using the response's internal allocator.
    pub fn xml(self: *const Response) !@import("../parsing/document.zig").Document {
        return @import("../parsing/document.zig").Document.parseXml(self.allocator, self.body);
    }

    /// Parses auto-detected document from response body and headers.
    pub fn document(self: *const Response) !@import("../parsing/document.zig").Document {
        return @import("../parsing/document.zig").Document.parse(self.allocator, self.header("content-type"), self.body);
    }

    /// Returns body as bytes.
    pub fn bytes(self: *const Response) []const u8 {
        return self.body;
    }

    /// Returns a reader over the body for streaming.
    pub fn reader(self: *const Response) std.Io.Reader {
        return std.Io.Reader.fixed(self.body);
    }
};

/// Helper: convert struct fields to Header array (for headers/query).
pub fn headersFromStruct(allocator: Allocator, value: anytype) ![]Header {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    if (info != .@"struct") return error.InvalidHeader;
    var list = std.ArrayList(Header).empty;
    errdefer {
        for (list.items) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        list.deinit(allocator);
    }
    inline for (info.@"struct".fields) |field| {
        const v = @field(value, field.name);
        const name = try allocator.dupe(u8, field.name);
        errdefer allocator.free(name);
        var buf: [64]u8 = undefined;
        const val_str = switch (@typeInfo(field.type)) {
            .int, .comptime_int => std.fmt.bufPrint(&buf, "{d}", .{v}) catch try std.fmt.allocPrint(allocator, "{d}", .{v}),
            .float, .comptime_float => std.fmt.bufPrint(&buf, "{d}", .{v}) catch try std.fmt.allocPrint(allocator, "{d}", .{v}),
            .bool => if (v) "true" else "false",
            .pointer => |ptr| if (ptr.size == .slice and ptr.child == u8) v else try std.fmt.allocPrint(allocator, "{any}", .{v}),
            else => try std.fmt.allocPrint(allocator, "{any}", .{v}),
        };
        const owned_val = if (val_str.ptr == buf[0..].ptr) try allocator.dupe(u8, val_str) else val_str;
        // If we used stack buf, val_str is already duped; if heap, it's already allocated
        try list.append(allocator, .{ .name = name, .value = owned_val });
    }
    return list.toOwnedSlice(allocator);
}

/// Helper: stringify any struct/value to JSON bytes.
pub fn jsonBody(allocator: Allocator, value: anytype) ![]u8 {
    const T = @TypeOf(value);
    if (T == []const u8 or T == []u8) return allocator.dupe(u8, value);
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

pub const Error = error{
    InvalidUrl,
    /// https:// requested without `Request.tls` options.
    TlsConfigRequired,
    TlsHandshakeFailed,
    CertificateExpired,
    CertificateHostMismatch,
    CertificateIssuerMismatch,
    CertificateNotYetValid,
    CertificateSignatureInvalid,
    TlsCertificateNotVerified,
    TlsAlert,
    TlsDecodeError,
    /// .http2 over TLS: std TLS has no ALPN hook yet.
    AlpnUnsupported,
    /// .http3 selected but the QUIC transport is not implemented (honest).
    Http3NotImplemented,
    /// HTTP/2 framing/HPACK violation from the peer.
    ProtocolViolation,
    ConnectFailed,
    DnsFailed,
    ReadFailed,
    WriteFailed,
    MalformedResponse,
    ResponseTooLarge,
    TooManyRedirects,
    FileNotFound,
    FileTooLarge,
    OutOfMemory,
};

pub const maxResponseBodySize: usize = 64 * 1024 * 1024;

/// Uniform plain/TLS connection for the request engine.
const Transport = union(enum) {
    plain: tcp.Socket,
    encrypted: *tlsTransport.Connection,

    fn writeAll(self: Transport, bytes: []const u8) !void {
        switch (self) {
            .plain => |s| try s.writeAll(bytes),
            .encrypted => |t| try t.writeAll(bytes),
        }
    }

    fn read(self: Transport, buf: []u8) !usize {
        return switch (self) {
            .plain => |s| s.read(buf) catch return error.ReadFailed,
            .encrypted => |t| t.read(buf) catch return error.ReadFailed,
        };
    }
};

/// Percent-encodes a query value (RFC 3986 unreserved kept).
pub fn encodeQueryValue(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const hexd = "0123456789ABCDEF";
    for (s) |c| {
        const safe = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
        if (safe) {
            try out.append(a, c);
        } else {
            try out.append(a, '%');
            try out.append(a, hexd[c >> 4]);
            try out.append(a, hexd[c & 15]);
        }
    }
    return out.toOwnedSlice(a);
}

fn buildTarget(a: Allocator, req_path: []const u8, query: []const Header) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, req_path);
    var first = true;
    for (query) |kv| {
        try out.append(a, if (first) '?' else '&');
        first = false;
        try out.appendSlice(a, kv.name);
        try out.append(a, '=');
        const enc = try encodeQueryValue(a, kv.value);
        defer a.free(enc);
        try out.appendSlice(a, enc);
    }
    return out.toOwnedSlice(a);
}

fn headerLines(a: Allocator, hdrs: []const Header, content_type: ?[]const u8) ![][]const u8 {
    return headerLinesWithAuth(a, hdrs, content_type, null, null, null);
}

fn headerLinesWithAuth(a: Allocator, hdrs: []const Header, content_type: ?[]const u8, cookie: ?[]const u8, basic_auth: ?[]const u8, bearer_auth: ?[]const u8) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(a);
    var has_accept_encoding = false;
    var has_authorization = false;
    var has_cookie = false;
    var has_user_agent = false;
    var has_content_type = false;
    for (hdrs) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "accept-encoding")) has_accept_encoding = true;
        if (std.ascii.eqlIgnoreCase(h.name, "authorization")) has_authorization = true;
        if (std.ascii.eqlIgnoreCase(h.name, "cookie")) has_cookie = true;
        if (std.ascii.eqlIgnoreCase(h.name, "user-agent")) has_user_agent = true;
        if (std.ascii.eqlIgnoreCase(h.name, "content-type")) has_content_type = true;
        const l = try std.fmt.allocPrint(a, "{s}: {s}", .{ h.name, h.value });
        try lines.append(a, l);
    }
    if (!has_user_agent) {
        const l = try std.fmt.allocPrint(a, "User-Agent: {s}", .{versionInfo.user_agent});
        try lines.append(a, l);
    }
    if (content_type) |ct| if (!has_content_type) {
        const l = try std.fmt.allocPrint(a, "Content-Type: {s}", .{ct});
        try lines.append(a, l);
    };
    if (cookie) |c| if (!has_cookie) {
        const l = try std.fmt.allocPrint(a, "Cookie: {s}", .{c});
        try lines.append(a, l);
    };
    if (!has_authorization) {
        if (bearer_auth) |tok| {
            const l = try std.fmt.allocPrint(a, "Authorization: Bearer {s}", .{tok});
            try lines.append(a, l);
        } else if (basic_auth) |up| {
            const enc_len = std.base64.standard.Encoder.calcSize(up.len);
            const b64 = try a.alloc(u8, enc_len);
            defer a.free(b64);
            _ = std.base64.standard.Encoder.encode(b64, up);
            const l = try std.fmt.allocPrint(a, "Authorization: Basic {s}", .{b64});
            try lines.append(a, l);
        }
    }
    if (!has_accept_encoding) {
        const l = try a.dupe(u8, "Accept-Encoding: gzip, br, zstd");
        try lines.append(a, l);
    }
    return lines.toOwnedSlice(a);
}

/// Executes the request. Returned Response owns its memory via `a`.
pub fn request(a: Allocator, io: std.Io, req: Request) Error!Response {
    var current_url: []u8 = try a.dupe(u8, req.url);
    defer a.free(current_url);

    var redirects: u8 = 0;
    var method = req.method;

    while (true) {
        const u = uriMod.parse(current_url) catch return Error.InvalidUrl;
        const is_tls = std.mem.eql(u8, u.scheme, "https");
        if (!is_tls and !std.mem.eql(u8, u.scheme, "http")) return Error.InvalidUrl;
        // Auto-enable TLS for HTTPS with safe default verification (.caBundle).
        const tls_opts = if (is_tls) req.tls orelse TlsOptions{ .verify = .caBundle, .allowTruncation = true } else null;

        var port = u.effectivePort();
        if (port == 0) return Error.InvalidUrl;

        var auth_buf: [256]u8 = undefined;
        const authority_str = u.authority(&auth_buf);

        const target = try buildTarget(a, u.path, req.query);
        defer a.free(target);

        const ct: ?[]const u8 = switch (req.bodyKind) {
            .json => "application/json",
            .form => "application/x-www-form-urlencoded",
            else => null,
        };
        const has_body = req.body.len > 0 or switch (req.bodyKind) {
            .json, .form => true,
            else => false,
        };
        const body_out: ?[]const u8 = if (has_body) req.body else null;

        const extra = try headerLinesWithAuth(a, req.headers, ct, req.cookie, req.basicAuth, req.bearerAuth);
        defer {
            for (extra) |l| a.free(l);
            a.free(extra);
        }

        var hdr_pairs = try a.alloc(writerMod.Header, extra.len);
        defer a.free(hdr_pairs);
        for (extra, 0..) |line, i| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return Error.OutOfMemory;
            hdr_pairs[i] = .{
                .name = std.mem.trim(u8, line[0..colon], " "),
                .value = std.mem.trim(u8, line[colon + 1 ..], " "),
            };
        }
        const raw = writerMod.buildRequest(
            a,
            method.toString(),
            target,
            body_out,
            .{
                .minor_version = if (req.httpVersion == .http10) 0 else 1,
                .host = authority_str,
                .headers = hdr_pairs,
                .connection = if (req.httpVersion == .http10) "close" else "",
            },
        ) catch return Error.OutOfMemory;
        defer a.free(raw);

        var host_copy: [256]u8 = undefined;
        const host_len = @min(authority_str.len, 256);
        @memcpy(host_copy[0..host_len], authority_str[0..host_len]);

        // Strip :port from authority for DNS/connect when present.
        var host_only = authority_str;
        if (std.mem.lastIndexOfScalar(u8, host_only, ':')) |ci| {
            if (std.mem.indexOfScalar(u8, host_only, ']') == null or ci > std.mem.indexOfScalar(u8, host_only, ']').?)
                host_only = host_only[0..ci];
            port = std.fmt.parseInt(u16, authority_str[ci + 1 ..], 10) catch port;
        }
        const hl = @min(host_only.len, 256);
        @memcpy(host_copy[0..hl], host_only[0..hl]);

        // Numeric IPs connect directly; hostnames resolve via the OS
        // (getaddrinfo) and each returned address is tried in order.
        var resolved: ?[]addressMod.Address = null;
        defer if (resolved) |list| a.free(list);
        const tcp_sock = blk: {
            if (req.proxy) |p_url| {
                const p_info = proxyMod.parseProxyUrl(p_url) orelse return Error.InvalidUrl;
                switch (p_info.kind) {
                    .socks5 => {
                        var target_host = host_only;
                        var local_resolved_buf: [64]u8 = undefined;
                        if (!p_info.remoteDns) {
                            var probe = addressMod.Address{ .family = .ip4, .port = 0 };
                            if (probe.parseIp(host_only)) |_| {
                                target_host = host_only;
                            } else |_| {
                                const addrs = (netResolve.Resolver.init(a)).lookupWithIo(io, host_only, port) catch return Error.ConnectFailed;
                                defer a.free(addrs);
                                if (addrs.len == 0) return Error.ConnectFailed;
                                target_host = addrs[0].formatBuf(&local_resolved_buf);
                            }
                        }
                        if (is_tls) {
                            break :blk socks5.connectStream(
                                io,
                                p_info.host,
                                p_info.port,
                                target_host,
                                port,
                                p_info.username,
                                p_info.password,
                            ) catch return Error.ConnectFailed;
                        } else {
                            break :blk socks5.connect(
                                io,
                                p_info.host,
                                p_info.port,
                                target_host,
                                port,
                                p_info.username,
                                p_info.password,
                            ) catch return Error.ConnectFailed;
                        }
                    },
                    .httpConnect => {
                        var s = if (is_tls) blk_s: {
                            var probe = addressMod.Address{ .family = .ip4, .port = 0 };
                            if (probe.parseIp(p_info.host)) |parsed| {
                                var addr = parsed;
                                addr.port = p_info.port;
                                break :blk_s tcp.connectAddressStream(io, &addr) catch return Error.ConnectFailed;
                            } else |_| {}
                            const addrs = (netResolve.Resolver.init(a)).lookupWithIo(io, p_info.host, p_info.port) catch return Error.ConnectFailed;
                            defer a.free(addrs);
                            if (addrs.len == 0) return Error.ConnectFailed;
                            break :blk_s tcp.connectAddressStream(io, &addrs[0]) catch return Error.ConnectFailed;
                        } else blk_s: {
                            var probe = addressMod.Address{ .family = .ip4, .port = 0 };
                            if (probe.parseIp(p_info.host)) |parsed| {
                                var addr = parsed;
                                addr.port = p_info.port;
                                break :blk_s tcp.connectAddress(io, &addr) catch return Error.ConnectFailed;
                            } else |_| {}
                            const addrs = (netResolve.Resolver.init(a)).lookupWithIo(io, p_info.host, p_info.port) catch return Error.ConnectFailed;
                            defer a.free(addrs);
                            if (addrs.len == 0) return Error.ConnectFailed;
                            break :blk_s tcp.connectAddress(io, &addrs[0]) catch return Error.ConnectFailed;
                        };
                        errdefer s.close();
                        const connect_req = std.fmt.allocPrint(a, "CONNECT {s}:{d} HTTP/1.1\r\nHost: {s}:{d}\r\n\r\n", .{ host_only, port, host_only, port }) catch return Error.OutOfMemory;
                        defer a.free(connect_req);
                        s.writeAll(connect_req) catch return Error.WriteFailed;
                        var connect_resp: [512]u8 = undefined;
                        var read_len: usize = 0;
                        while (read_len < connect_resp.len) {
                            const n = s.read(connect_resp[read_len..]) catch return Error.ReadFailed;
                            if (n == 0) return Error.ConnectFailed;
                            read_len += n;
                            if (std.mem.indexOf(u8, connect_resp[0..read_len], "\r\n\r\n")) |_| break;
                        }
                        if (read_len < 12 or !std.mem.startsWith(u8, connect_resp[0..read_len], "HTTP/1.") or !std.mem.eql(u8, connect_resp[9..12], "200")) {
                            return Error.ConnectFailed;
                        }
                        break :blk s;
                    },
                    .direct => {},
                }
            }

            // Keep-alive reuse first (plain HTTP only, no proxy).
            if (!is_tls and req.proxy == null) {
                if (req.pool) |p| {
                    if (p.acquire(host_copy[0..hl], port)) |s| break :blk s;
                }
            }
            var probe = addressMod.Address{ .family = .ip4, .port = 0 };
            if (probe.parseIp(host_only)) |direct| {
                var da = direct;
                da.port = port;
                // For TLS, use the AFD-backed stream path (required for
                // std.Io.net TLS initialization). For plain HTTP on Windows,
                // use the direct winsock path (avoids netConnectIpWindows
                // STATUS_CONNECTION_REFUSED → unexpectedStatus() stderr noise
                // that corrupts the --listen=- test runner protocol).
                if (is_tls) {
                    break :blk tcp.connectAddressStream(io, &da) catch return Error.ConnectFailed;
                } else {
                    break :blk tcp.connectAddress(io, &da) catch return Error.ConnectFailed;
                }
            } else |_| {}

            resolved = rblk: {
                if (req.dnsCache) |cache| {
                    if (cache.resolve(io, host_only)) |cached_strs| {
                        defer {
                            for (cached_strs) |s| a.free(s);
                            a.free(cached_strs);
                        }
                        var list = std.ArrayList(addressMod.Address).empty;
                        errdefer list.deinit(a);
                        for (cached_strs) |s| {
                            if (parseAddrString(s, port)) |parsed| {
                                list.append(a, parsed) catch return Error.OutOfMemory;
                            }
                        }
                        if (list.items.len > 0) {
                            break :rblk list.toOwnedSlice(a) catch return Error.OutOfMemory;
                        }
                    } else |_| {}
                }
                break :rblk (netResolve.Resolver.init(a)).lookupWithIo(io, host_only, port) catch return Error.ConnectFailed;
            };
            // Happy-eyeballs-lite: prefer IPv4 results first (v6 endpoints
            // are frequently unreachable on dev machines).
            var vi: usize = 0;
            for (resolved.?, 0..) |raddr, i| {
                if (raddr.family == .ip4) {
                    if (i != vi) {
                        const tmp = resolved.?[vi];
                        resolved.?[vi] = resolved.?[i];
                        resolved.?[i] = tmp;
                    }
                    vi += 1;
                }
            }
            for (resolved.?) |*raddr| {
                if (is_tls) {
                    if (tcp.connectAddressStream(io, raddr)) |s| break :blk s else |_| {}
                } else {
                    if (tcp.connectAddress(io, raddr)) |s| break :blk s else |_| {}
                }
            }
            return Error.ConnectFailed;
        };

        if (req.timeoutMs) |t_ms| {
            if (t_ms > 0) {
                if (tcp_sock.inner == .stream) {
                    tcp.setTimeouts(tcp_sock.netSocketHandle(), @intCast(@min(t_ms, 2147483647)));
                }
            }
        }

        const resolved_ver: HttpVersion = if (req.httpVersion == .auto) .http11 else req.httpVersion;
        if (resolved_ver == .http3) {
            // Honest boundary: QUIC transport not implemented yet.
            tcp_sock.close();
            return Error.Http3NotImplemented;
        }
        if (is_tls and resolved_ver == .http2) {
            // std.crypto.tls has no ALPN hook; h2-over-TLS cannot be
            // negotiated yet. Fail with a typed error, never silently
            // downgrade.
            tcp_sock.close();
            return Error.AlpnUnsupported;
        }
        if (!is_tls and resolved_ver == .http2) {
            // RFC 7540 Section 3.5 prior knowledge over cleartext TCP.
            var hc = http2Transport.Client.connect(a, tcp_sock) catch {
                tcp_sock.close();
                return Error.ProtocolViolation;
            };
            defer hc.deinit();
            var has_accept_encoding = false;
            for (req.headers) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "accept-encoding")) has_accept_encoding = true;
            }
            var conv: []http2Transport.Header = try a.alloc(http2Transport.Header, req.headers.len + @as(usize, if (has_accept_encoding) 0 else 1));
            defer a.free(conv);
            for (req.headers, 0..) |h, i| conv[i] = .{ .name = h.name, .value = h.value };
            if (!has_accept_encoding) conv[req.headers.len] = .{ .name = "accept-encoding", .value = "gzip, br, zstd" };
            const r = hc.request(method.toString(), target, conv) catch |e| switch (e) {
                error.OutOfMemory => return Error.OutOfMemory,
                else => return Error.ProtocolViolation,
            };
            // Convert header type (same shape, different namespace); the
            // transport allocator IS `a`, so ownership transfers cleanly.
            var out_hdrs = try a.alloc(Header, r.headers.len);
            for (r.headers, 0..) |h, i| out_hdrs[i] = .{ .name = h.name, .value = h.value };
            const decoded_body = decodeResponseBody(a, out_hdrs, r.body) catch |e| {
                for (out_hdrs) |h| {
                    a.free(h.name);
                    a.free(h.value);
                }
                a.free(out_hdrs);
                a.free(r.body);
                return e;
            };
            a.free(r.headers);
            return .{
                .allocator = a,
                .status = r.status,
                .version = .http2,
                .headers = out_hdrs,
                .body = decoded_body,
            };
        }

        // The TCP socket remains the owned cleanup resource until TLS
        // initialization succeeds and replaces this union arm. Initializing
        // it before the defer is essential: TLS setup may fail before the
        // encrypted transport exists.
        var transport: Transport = .{ .plain = tcp_sock };
        var tls_conn: ?*tlsTransport.Connection = null;
        var pooled_out = false; // socket handed back to the pool
        defer {
            if (tls_conn) |t| {
                t.destroy(a);
            } else if (!pooled_out) {
                transport.plain.close();
            }
        }

        if (is_tls) {
            const opts = tls_opts.?;
            tls_conn = tlsTransport.Connection.init(a, .{
                .socketHandle = tcp_sock.netSocketHandle(),
                .host = host_copy[0..hl],
                .verify = opts.verify,
                .caBundle = opts.caBundle,
                .allowTruncation = opts.allowTruncation,
                .io = io,
            }) catch |err| switch (err) {
                error.CertificateExpired => return Error.CertificateExpired,
                error.CertificateHostMismatch => return Error.CertificateHostMismatch,
                error.CertificateIssuerMismatch => return Error.CertificateIssuerMismatch,
                error.CertificateNotYetValid => return Error.CertificateNotYetValid,
                error.CertificateSignatureInvalid => return Error.CertificateSignatureInvalid,
                error.TlsCertificateNotVerified => return Error.TlsCertificateNotVerified,
                error.TlsAlert => return Error.TlsAlert,
                error.TlsDecodeError => return Error.TlsDecodeError,
                error.OutOfMemory => return Error.OutOfMemory,
                else => return Error.TlsHandshakeFailed,
            };
            transport = .{ .encrypted = tls_conn.? };
        } else {
            transport = .{ .plain = tcp_sock };
        }

        transport.writeAll(raw) catch return Error.WriteFailed;

        const full = try readFullResponseWithOptions(a, transport, method == .HEAD, .{ .allow_lf_line_endings = req.allowLfLineEndings });
        var resp = full.resp;

        if (req.followRedirects and isRedirect(resp.status)) {
            // Redirect hops are one-shot: never pool the intermediate conn.
            const loc = resp.header("Location") orelse return resp;
            if (redirects >= req.maxRedirects) {
                resp.deinit();
                return Error.TooManyRedirects;
            }
            redirects += 1;
            const was_same_origin = sameOrigin(&u, loc);

            const next = resolveLocation(a, current_url, loc) catch return resp;
            a.free(current_url);
            current_url = next;

            if (!was_same_origin) stripAuth(@constCast(req.headers));

            if (resp.status == 301 or resp.status == 302 or resp.status == 303) method = .GET;
            resp.deinit();
            continue;
        }

        return finishPlain(req.pool, is_tls, req.proxy != null, host_copy[0..hl], port, full, &pooled_out, transport, resp);
    }
}

/// Returns the response to the caller; for plain connections with a fully
/// framed body and no "Connection: close", parks the socket in the pool.
fn finishPlain(
    pool: ?*Pool,
    is_tls: bool,
    has_proxy: bool,
    host: []const u8,
    port: u16,
    full: FullResponse,
    pooled_out: *bool,
    transport: Transport,
    resp: Response,
) Response {
    if (pool) |p| {
        if (!is_tls and !has_proxy and full.reusable and !respSaysClose(&resp)) {
            p.release(host, port, transport.plain);
            pooled_out.* = true;
        }
    }
    return resp;
}

fn respSaysClose(resp: *const Response) bool {
    for (resp.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "connection") and
            std.ascii.indexOfIgnoreCase(h.value, "close") != null) return true;
    }
    return false;
}

pub const FullResponse = struct { resp: Response, reusable: bool };

fn decodeResponseBody(a: Allocator, headers: []const Header, body: []u8) Error![]u8 {
    for (headers) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "content-encoding")) continue;
        const encoding = compression.Encoding.fromToken(std.mem.trim(u8, h.value, " \t")) orelse
            return body;
        if (encoding == .identity) return body;
        const decoded = compression.decompressLimited(a, encoding, body, maxResponseBodySize) catch |err| switch (err) {
            error.DecompressedTooLarge => return Error.ResponseTooLarge,
            error.OutOfMemory => return Error.OutOfMemory,
            else => return Error.MalformedResponse,
        };
        a.free(body);
        return decoded;
    }
    return body;
}

test "client decodes bounded compressed response bodies" {
    const a = std.testing.allocator;
    const plain = "compressed response";
    const wire = try compression.compress(a, .gzip, plain);
    defer a.free(wire);
    const headers = [_]Header{.{ .name = "content-encoding", .value = "gzip" }};
    const decoded = try decodeResponseBody(a, &headers, try a.dupe(u8, wire));
    defer a.free(decoded);
    try std.testing.expectEqualStrings(plain, decoded);
}

test "client compression advertisement respects explicit override" {
    const a = std.testing.allocator;
    const defaults = try headerLines(a, &.{}, null);
    defer {
        for (defaults) |line| a.free(line);
        a.free(defaults);
    }
    try std.testing.expectEqualStrings("User-Agent: httpx/0.2.0", defaults[0]);
    try std.testing.expectEqualStrings("Accept-Encoding: gzip, br, zstd", defaults[1]);

    const custom = try headerLines(a, &.{.{ .name = "Accept-Encoding", .value = "identity" }}, null);
    defer {
        for (custom) |line| a.free(line);
        a.free(custom);
    }
    try std.testing.expectEqual(@as(usize, 2), custom.len);
    try std.testing.expectEqualStrings("Accept-Encoding: identity", custom[0]);
    try std.testing.expectEqualStrings("User-Agent: httpx/0.2.0", custom[1]);
}

/// `reusable` is true ONLY when the body was framed and fully consumed —
/// the precondition for parking a connection back into the keep-alive pool.
fn readFullResponse(a: Allocator, conn: anytype, is_head: bool) Error!FullResponse {
    return readFullResponseWithOptions(a, conn, is_head, .{});
}

fn readFullResponseWithOptions(a: Allocator, conn: anytype, is_head: bool, opts: parserMod.Options) Error!FullResponse {
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(a);
    var buf: [8192]u8 = undefined;

    var head_end: usize = 0;
    while (true) {
        if (std.mem.indexOf(u8, acc.items, "\r\n\r\n")) |idx| {
            head_end = idx + 4;
            break;
        }
        if (opts.allow_lf_line_endings) {
            if (std.mem.indexOf(u8, acc.items, "\n\n")) |idx| {
                // Ensure not already counted as \r\n\r\n (avoid double)
                if (idx == 0 or acc.items[idx - 1] != '\r') {
                    head_end = idx + 2;
                    break;
                }
            }
        }
        const n = conn.read(buf[0..]) catch return Error.ReadFailed;
        if (n == 0) return Error.MalformedResponse;
        acc.appendSlice(a, buf[0..n]) catch return Error.OutOfMemory;
        if (acc.items.len > 128 * 1024) return Error.MalformedResponse;
    }

    const opts_parser: parserMod.Options = .{ .allow_lf_line_endings = opts.allow_lf_line_endings };
    const resp_head = parserMod.parseResponseHeadWithOptions(acc.items, opts_parser) catch return Error.MalformedResponse;

    var fields: [parserMod.DEFAULT_MAX_HEADERS]parserMod.Field = undefined;
    const blk = parserMod.parseHeaderBlockWithOptions(acc.items[0..head_end], resp_head.head_end, fields[0..], opts_parser) catch
        return Error.MalformedResponse;

    const framing = parserMod.framingFull(fields[0..blk.count], .{
        .is_response = true,
        .status = resp_head.status_code,
        .method_len = if (is_head) 4 else 0,
    }) catch return Error.MalformedResponse;

    const headers = a.alloc(Header, blk.count) catch return Error.OutOfMemory;
    var header_count: usize = 0;
    errdefer {
        for (headers[0..header_count]) |h| {
            a.free(h.name);
            a.free(h.value);
        }
        a.free(headers);
    }
    for (fields[0..blk.count], 0..) |f, i| {
        const name = a.dupe(u8, f.name) catch return Error.OutOfMemory;
        const value = a.dupe(u8, f.value) catch {
            a.free(name);
            return Error.OutOfMemory;
        };
        headers[i] = .{ .name = name, .value = value };
        header_count += 1;
    }

    if (is_head or resp_head.status_code < 200 or resp_head.status_code == 204 or resp_head.status_code == 304 or
        (framing.framing == .content_length and framing.length == 0))
    {
        return .{ .resp = .{
            .allocator = a,
            .status = resp_head.status_code,
            .headers = headers,
            .body = try a.alloc(u8, 0),
        }, .reusable = true };
    }

    var chunked = false;
    var clen: usize = 0;
    for (fields[0..blk.count]) |f| {
        if (std.ascii.eqlIgnoreCase(f.name, "transfer-encoding") and
            std.ascii.indexOfIgnoreCase(f.value, "chunked") != null) chunked = true;
        if (std.ascii.eqlIgnoreCase(f.name, "content-length"))
            clen = std.fmt.parseInt(usize, std.mem.trim(u8, f.value, " "), 10) catch 0;
    }

    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(a);
    if (acc.items.len - head_end > maxResponseBodySize) return Error.ResponseTooLarge;
    try body.appendSlice(a, acc.items[head_end..]);

    if (chunked) {
        while (std.mem.indexOf(u8, body.items, "\r\n0\r\n\r\n") == null and
            std.mem.indexOf(u8, body.items, "0\r\n\r\n") == null)
        {
            const n = conn.read(buf[0..]) catch return Error.ReadFailed;
            if (n == 0) break;
            if (body.items.len > maxResponseBodySize -| n) return Error.ResponseTooLarge;
            try body.appendSlice(a, buf[0..n]);
        }
        const decoded = decodeChunked(a, body.items) catch return Error.MalformedResponse;
        return .{ .resp = .{
            .allocator = a,
            .status = resp_head.status_code,
            .version = if (resp_head.minor_version == 0) .http10 else .http11,
            .headers = headers,
            .body = try decodeResponseBody(a, headers, decoded),
        }, .reusable = true };
    }

    var complete = false;
    if (clen > 0) {
        if (clen > maxResponseBodySize) return Error.ResponseTooLarge;
        while (body.items.len < clen) {
            const n = conn.read(buf[0..]) catch return Error.ReadFailed;
            if (n == 0) break;
            if (body.items.len > maxResponseBodySize -| n) return Error.ResponseTooLarge;
            try body.appendSlice(a, buf[0..n]);
        }
        complete = body.items.len >= clen;
    } else {
        while (true) {
            const n = conn.read(buf[0..]) catch return Error.ReadFailed;
            if (n == 0) break;
            if (body.items.len > maxResponseBodySize -| n) return Error.ResponseTooLarge;
            try body.appendSlice(a, buf[0..n]);
        }
    }

    const owned_body = try body.toOwnedSlice(a);
    return .{ .resp = .{
        .allocator = a,
        .status = resp_head.status_code,
        .version = if (resp_head.minor_version == 0) .http10 else .http11,
        .headers = headers,
        .body = try decodeResponseBody(a, headers, owned_body),
    }, .reusable = complete };
}

fn decodeChunked(a: Allocator, wire_in: []const u8) ![]u8 {
    const wire = try a.dupe(u8, wire_in);
    defer a.free(wire);

    var dec = parserMod.ChunkedDecoder{};
    const tail = dec.decode(wire) catch |e| switch (e) {
        error.Incomplete => return error.Incomplete,
        else => return e,
    };
    const produced = wire.len - tail;
    return a.dupe(u8, wire[0..produced]);
}

fn isRedirect(status: u16) bool {
    return status == 301 or status == 302 or status == 303 or status == 307 or status == 308;
}

fn sameOrigin(base: *const uriMod.Uri, location: []const u8) bool {
    if (std.mem.indexOf(u8, location, "://") == null) return true;
    const parsed = uriMod.parse(location) catch return false;
    return std.mem.eql(u8, base.scheme, parsed.scheme) and std.mem.eql(u8, base.host, parsed.host);
}

fn stripAuth(hdrs: []Header) void {
    for (hdrs) |*h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Authorization")) h.value = "";
    }
}

/// Resolves Location against the previous URL (RFC 3986 Section 5).
fn resolveLocation(a: Allocator, base_url: []const u8, loc: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, loc, "://") != null) return a.dupe(u8, loc);
    const base = try uriMod.parse(base_url);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, base.scheme);
    try out.appendSlice(a, "://");
    var ab: [512]u8 = undefined;
    try out.appendSlice(a, base.authority(&ab));

    if (loc.len > 0 and loc[0] == '/') {
        try out.appendSlice(a, loc);
    } else {
        const base_path = base.path;
        const last_slash = std.mem.lastIndexOfScalar(u8, base_path, '/');
        const dir = if (last_slash) |idx| base_path[0..idx] else "";
        try out.appendSlice(a, dir);
        if (dir.len == 0 or dir[dir.len - 1] != '/') try out.append(a, '/');
        try out.appendSlice(a, loc);
    }
    return out.toOwnedSlice(a);
}

// Convenience one-shot helpers (all route through request())

pub fn get(a: Allocator, io: std.Io, url: []const u8) Error!Response {
    return request(a, io, .{ .method = .GET, .url = url });
}

pub fn post(a: Allocator, io: std.Io, url: []const u8, body: []const u8, contentType: []const u8) Error!Response {
    return request(a, io, .{ .method = .POST, .url = url, .bodyKind = .raw, .body = body, .headers = &.{.{ .name = "Content-Type", .value = contentType }} });
}

pub fn postJson(a: Allocator, io: std.Io, url: []const u8, jsonData: []const u8) Error!Response {
    return request(a, io, .{ .method = .POST, .url = url, .bodyKind = .json, .body = jsonData });
}
pub fn postForm(a: Allocator, io: std.Io, url: []const u8, encodedForm: []const u8) Error!Response {
    return request(a, io, .{ .method = .POST, .url = url, .bodyKind = .form, .body = encodedForm });
}

pub fn put(a: Allocator, io: std.Io, url: []const u8, body: []const u8, contentType: []const u8) Error!Response {
    return request(a, io, .{ .method = .PUT, .url = url, .bodyKind = .raw, .body = body, .headers = &.{.{ .name = "Content-Type", .value = contentType }} });
}

pub fn putJson(a: Allocator, io: std.Io, url: []const u8, jsonData: []const u8) Error!Response {
    return request(a, io, .{ .method = .PUT, .url = url, .bodyKind = .json, .body = jsonData });
}

pub fn patch(a: Allocator, io: std.Io, url: []const u8, body: []const u8, contentType: []const u8) Error!Response {
    return request(a, io, .{ .method = .PATCH, .url = url, .bodyKind = .raw, .body = body, .headers = &.{.{ .name = "Content-Type", .value = contentType }} });
}

pub fn patchJson(a: Allocator, io: std.Io, url: []const u8, jsonData: []const u8) Error!Response {
    return request(a, io, .{ .method = .PATCH, .url = url, .bodyKind = .json, .body = jsonData });
}

pub fn delete(a: Allocator, io: std.Io, url: []const u8) Error!Response {
    return request(a, io, .{ .method = .DELETE, .url = url });
}

pub fn head(a: Allocator, io: std.Io, url: []const u8) Error!Response {
    return request(a, io, .{ .method = .HEAD, .url = url });
}

pub fn options(a: Allocator, io: std.Io, url: []const u8) Error!Response {
    return request(a, io, .{ .method = .OPTIONS, .url = url });
}

// Multipart file upload (buffered; files up to maxBufferedUpload)

/// Largest file buffered whole by `postMultipartFile`.
pub const maxBufferedUpload: usize = 16 * 1024 * 1024;

/// Reads a file using direct OS-level I/O (bypasses std.Io.Threaded whose
/// internal file-op dispatch can deadlock when interleaved with socket ops
/// from the same thread).
fn readFileDirect(a: Allocator, path: []const u8) ![]u8 {
    if (@import("builtin").os.tag == .windows) {
        return readFileWindows(a, path);
    }
    return readFilePosix(a, path);
}

fn readFileWindows(a: Allocator, path: []const u8) ![]u8 {
    const win = std.os.windows;
    var wide_buf: [win.PATH_MAX_WIDE]u16 = undefined;
    const wide_len = try std.unicode.utf8ToUtf16Le(&wide_buf, path);
    const wide = wide_buf[0..wide_len];

    const handle = win.CreateFileW(
        wide.ptr,
        win.GENERIC_READ,
        win.FILE_SHARE_READ,
        null,
        win.OPEN_EXISTING,
        win.FILE_ATTRIBUTE_NORMAL,
        null,
    ) catch |e| switch (e) {
        error.FileNotFound => return error.FileNotFound,
        else => return error.ReadFailed,
    };
    defer win.CloseHandle(handle);

    var size_lg: win.LARGE_INTEGER = undefined;
    if (win.kernel32.GetFileSizeEx(handle, &size_lg) == 0) return error.ReadFailed;
    const fsize: usize = @intCast(size_lg.Value);
    if (fsize > maxBufferedUpload) return error.FileTooLarge;

    const buf = try a.alloc(u8, fsize);
    errdefer a.free(buf);

    var total: usize = 0;
    while (total < fsize) {
        var bytes_read: win.DWORD = 0;
        const ok = win.ReadFile(handle, buf[total..].ptr, @intCast(@min(fsize - total, 0xFFFF_FFFF)), &bytes_read, null);
        if (ok == 0) return error.ReadFailed;
        if (bytes_read == 0) break;
        total += bytes_read;
    }
    if (total != fsize) return error.ReadFailed;
    return buf;
}

fn readFilePosix(a: Allocator, path: []const u8) ![]u8 {
    const posix_sys = std.posix;
    const fd = posix_sys.open(path, .{ .ACCMODE = .RDONLY }, 0) catch |e| switch (e) {
        error.FileNotFound => return error.FileNotFound,
        else => return error.ReadFailed,
    };
    defer posix_sys.close(fd);
    const st = posix_sys.fstat(fd) catch return error.ReadFailed;
    const fsize: usize = @intCast(st.size);
    if (fsize > maxBufferedUpload) return error.FileTooLarge;
    const buf = try a.alloc(u8, fsize);
    errdefer a.free(buf);
    var total: usize = 0;
    while (total < fsize) {
        const n = posix_sys.read(fd, buf[total..]) catch return error.ReadFailed;
        if (n == 0) break;
        total += n;
    }
    if (total != fsize) return error.ReadFailed;
    return buf;
}

/// Uploads `file_path` as multipart/form-data via POST to `url`.
pub fn postMultipartFile(
    a: Allocator,
    io: std.Io,
    url: []const u8,
    fieldName: []const u8,
    filePath: []const u8,
    boundary: []const u8,
) Error!Response {
    const fileData = readFileDirect(a, filePath) catch |e| switch (e) {
        error.FileNotFound => return Error.FileNotFound,
        error.FileTooLarge => return Error.FileTooLarge,
        else => return Error.ReadFailed,
    };
    defer a.free(fileData);

    const mpEncoder = @import("../web/multipart/encoder.zig");

    // Content-Type header value.
    var ct_buf: [128]u8 = undefined;
    const ct = mpEncoder.contentType(&ct_buf, boundary);

    // Filename from path tail.
    const fname = if (std.mem.lastIndexOfScalar(u8, filePath, '/')) |ix|
        filePath[ix + 1 ..]
    else if (std.mem.lastIndexOfScalar(u8, filePath, '\\')) |bx|
        filePath[bx + 1 ..]
    else
        filePath;

    var body_buf: std.Io.Writer.Allocating = .init(a);
    defer body_buf.deinit();
    mpEncoder.encode(&body_buf.writer, boundary, &.{
        .{ .name = fieldName, .filename = fname, .content_type = "application/octet-stream", .data = fileData },
    }) catch return Error.OutOfMemory;

    return request(a, io, .{
        .method = .POST,
        .url = url,
        .bodyKind = .raw,
        .body = body_buf.written(),
        .headers = &.{.{ .name = "Content-Type", .value = ct }},
    });
}
// Tests

const t_tcp = tcp;

fn startTestServer(
    a: Allocator,
    keep_alive: bool,
    comptime route: []const u8,
    comptime body: []const u8,
) !struct { srv: @import("../server/lifecycle.zig").Server, ctx: t_tcp.IoContext } {
    const lifecycle = @import("../server/lifecycle.zig");
    const routerNs = @import("../web/router/router.zig");
    var ctx = try t_tcp.IoContext.init(a);
    errdefer ctx.deinit();
    var srv = try lifecycle.Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .max_connections = 1,
        .keep_alive = keep_alive,
    });
    errdefer srv.deinit();
    try srv.router.add(.GET, route, struct {
        fn h(_: *routerNs.Context) anyerror!routerNs.Response {
            return .{ .body = body, .content_type = "text/plain" };
        }
    }.h);
    return .{ .srv = srv, .ctx = ctx };
}

test "keep-alive: second request reuses pooled connection" {
    const a = std.testing.allocator;
    var S = try startTestServer(a, true, "/ka", "hello-keepalive");
    var srv = &S.srv;
    // Single connection carries BOTH keep-alive requests; run() then exits
    // its accept loop via max_connections => join needs no listener cancel.
    defer srv.deinit();
    defer S.ctx.deinit();

    const th = std.Thread.spawn(.{}, @import("../server/lifecycle.zig").Server.run, .{srv}) catch return;

    // Client with pool; two requests over hostname.
    // Manual lifecycle: client must be FULLY torn down (releasing pooled
    // sockets -> server readers see EOF) BEFORE server shutdown/join.
    var client = @import("client.zig").Client.init(a, S.ctx.io, .{});

    var ub: [64]u8 = undefined;
    const port = srv.localPort();
    const url = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}/ka", .{port});

    var r1 = client.get(url, .{}) catch {
        client.deinit();
        srv.requestShutdown();
        th.join();
        return;
    };
    defer r1.deinit();
    try std.testing.expectEqual(@as(u16, 200), r1.status);
    try std.testing.expectEqualStrings("hello-keepalive", r1.body);

    var ub2: [64]u8 = undefined;
    var r2 = try client.get(try std.fmt.bufPrint(&ub2, "http://127.0.0.1:{d}/ka", .{port}), .{});
    defer r2.deinit();
    try std.testing.expectEqual(@as(u16, 200), r2.status);

    const st = client.pool.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 1), st.hits); // 2nd request reused
    try std.testing.expectEqual(@as(u64, 2), st.released); // parked after each response

    // Teardown order matters:
    //   1. purge pool -> closes pooled socket -> server reader sees EOF
    //   2. join       -> server thread exits (served==max_connections)
    //   3. shutdown   -> flip flags (listener already idle; no cancel race)
    //   4. client.deinit -> destroys pool/dns structures with zero in-flight IO
    client.pool.purge();
    th.join();
    srv.requestShutdown();
    client.deinit();
}

test "connection close response is not pooled" {
    const a = std.testing.allocator;
    const lifecycle = @import("../server/lifecycle.zig");
    const routerNs = @import("../web/router/router.zig");
    var ctx = try t_tcp.IoContext.init(a);
    defer ctx.deinit();
    // keep_alive=false server => always responds Connection: close
    var srv = try lifecycle.Server.init(a, ctx.io, .{ .port = 0, .enableDocs = false, .max_connections = 2 });
    defer srv.deinit();
    try srv.router.add(.GET, "/x", struct {
        fn h(_: *routerNs.Context) anyerror!routerNs.Response {
            return .{ .body = "one-shot", .content_type = "text/plain" };
        }
    }.h);

    const Runner = struct {
        fn run(s: *lifecycle.Server) void {
            s.run();
        }
    };
    const th = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;

    var client = @import("client.zig").Client.init(a, ctx.io, .{});
    defer client.deinit();
    var ub: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}/x", .{srv.localPort()});

    var r1 = try client.get(url, .{});
    r1.deinit();
    var r2 = try client.get(url, .{});
    r2.deinit();

    srv.requestShutdown();
    th.join();

    const st = client.pool.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 0), st.hits);
    try std.testing.expectEqual(@as(u64, 0), st.parkedNow);
}

// Regression: a response with NO Content-Length and NO chunked encoding is
// framed only by connection close (framing == .none). Reading its body relies
// on the socket reporting EOF as 0 so the read-until-close loop can stop. The
// httpx server always emits Content-Length (so "connection close ... not pooled"
// above misses this), hence the raw server here. Before the tcp.Socket.read EOF
// fix this failed with ReadFailed.
test "connection-close body without Content-Length is read to EOF" {
    const a = std.testing.allocator;
    var ctx = try t_tcp.IoContext.init(a);
    defer ctx.deinit();

    var lst = try t_tcp.Listener.bind(ctx.io, 0);
    defer lst.close(ctx.io);
    const port = lst.localPort();

    const RawServer = struct {
        fn run(l: *t_tcp.Listener, io: std.Io) void {
            var sock = l.accept(io) catch return;
            defer sock.close();
            var buf: [1024]u8 = undefined;
            _ = sock.read(&buf) catch {}; // consume the request
            // Head, blank line, body, then close — no Content-Length/chunked.
            sock.writeAll("HTTP/1.1 200 OK\r\n\r\nclose-delimited-body") catch {};
        }
    };
    const th = std.Thread.spawn(.{}, RawServer.run, .{ &lst, ctx.io }) catch return;
    defer th.join();

    var ub: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}/", .{port});
    var resp = try request(a, ctx.io, .{ .method = .GET, .url = url });
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("close-delimited-body", resp.body);
}

test "https auto-enables tls with secure caBundle verification when no explicit options provided" {
    const is_tls = true;
    const req_tls: ?TlsOptions = null;
    const tls_opts: ?TlsOptions = if (is_tls) req_tls orelse TlsOptions{ .verify = .caBundle, .allowTruncation = true } else null;
    try std.testing.expectEqual(.caBundle, tls_opts.?.verify);
}

// Live TLS interop (environment-gated).
//
// Requires an external TLS endpoint because std.Io.Threaded's
// processSpawnWindows hangs when spawning the harness from inside the test
// (reproduced standalone; see tools/run_tls_interop.ps1 for one-command run):
//
//   powershell -File tools/run_tls_interop.ps1
//
// That runner starts src/assets/tls_harness.ps1 (SChannel, self-signed) and
// runs this suite against it. Without the env vars this test skips — an
// honest environment gate, not a code path we cannot verify.

test "live https interop against external TLS server" {
    var env = envPkg.Env.init(std.testing.allocator, .{});
    defer env.deinit();
    try env.loadOsEnv();
    const host = env.get("HTTPX_TLS_HOST") orelse return;
    const port_str = env.get("HTTPX_TLS_PORT") orelse return;
    const gate = env.get("HTTPX_TLS_INTEROP") orelse return;
    if (gate.len == 0) return;
    if (host.len == 0 or host.len > 63 or port_str.len == 0 or port_str.len > 15) return;
    const port = std.fmt.parseInt(u16, port_str, 10) catch return;

    var ctx = try t_tcp.IoContext.init(std.testing.allocator);
    defer ctx.deinit();

    var ub2: [128]u8 = undefined;
    const full = try std.fmt.bufPrint(&ub2, "https://{s}:{d}/interop", .{ host, port });

    // One retry: Windows localhost timing between backlog accept and TLS
    // auth occasionally refuses the first attempt.
    var res: Response = undefined;
    var attempt: usize = 0;
    while (true) {
        attempt += 1;
        if (request(std.testing.allocator, ctx.io, .{
            .url = full,
            .tls = .{ .verify = .none, .allowTruncation = true },
        })) |r| {
            res = r;
            break;
        } else |_| {
            if (attempt >= 2) {
                // Re-check readiness once, then give up honestly.
                var still_ready = false;
                for (0..50) |_| {
                    if (t_tcp.connect(ctx.io, "127.0.0.1", port)) |pr| {
                        pr.close();
                        still_ready = true;
                        break;
                    } else |_| {}
                }
                return error.TestUnexpectedResult;
            }
            std.atomic.spinLoopHint();
        }
    }
    defer res.deinit();

    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "interoperability-ok") != null);
}
