//! httpx.zig - Production-Ready HTTP Library for Zig
//!
//! A comprehensive HTTP client and server library with production-ready HTTP/1.x
//! runtime support, high-level HTTP/2 and HTTP/3 client/server runtime support,
//! and HTTP/2/HTTP/3 protocol primitives.
//!
//! ## Important Note
//!
//! **httpx.zig implements HTTP/2 and HTTP/3 from scratch.** Zig's standard library
//! does not provide HTTP/2, HTTP/3, or QUIC support. This library contains complete
//! custom implementations of these protocols:
//!
//! - **HTTP/2**: HPACK header compression (RFC 7541), stream multiplexing, flow control (RFC 7540)
//! - **HTTP/3**: QPACK header compression (RFC 9204), HTTP/3 framing (RFC 9114)
//! - **QUIC**: Transport framing, packet structures, variable-length integers (RFC 9000)
//!
//! ## Supported Protocols
//!
//! - **HTTP/1.0**: Basic request-response semantics
//! - **HTTP/1.1**: Persistent connections, chunked transfer, pipelining
//! - **HTTP/2**: High-level client/server runtime paths plus HPACK/framing primitives
//! - **HTTP/3**: High-level client/server runtime paths plus QPACK/QUIC framing primitives
//!
//! ## Platform Support
//!
//! - Linux (x86, x86_64, aarch64, arm)
//! - Windows (x86, x86_64, aarch64, arm)
//! - macOS (x86, x86_64, aarch64, arm)
//! - FreeBSD, NetBSD, OpenBSD
//!
//! ## Features
//!
//! ### Client Features
//! - Connection pooling with keep-alive
//! - Automatic retry with exponential backoff
//! - Redirect following with configurable policies
//! - Request/response interceptors
//! - Concurrent request execution
//! - TLS/SSL support (HTTPS)
//! - Timeout configuration
//! - Cookie handling
//!
//! ### Server Features
//! - Pattern-based routing with path parameters
//! - Middleware stack (CORS, logging, rate limiting, etc.)
//! - Static file serving
//! - JSON response helpers
//! - Request context with user data
//!
//! ### Protocol Features
//! - HTTP/2 HPACK header compression (RFC 7541)
//! - HTTP/2 stream state machine and flow control
//! - HTTP/3 QPACK header compression (RFC 9204)
//! - QUIC transport framing (RFC 9000)
//!
//! ## Quick Start
//!
//! ```zig
//! const httpx = @import("httpx");
//!
//! // Client usage
//! var client = httpx.Client.init(allocator);
//! defer client.deinit();
//! const response = try client.get("http://httpbun.com/users", .{});
//!
//! // Server usage
//! var server = httpx.Server.init(allocator);
//! try server.get("/hello", helloHandler);
//! try server.listen();
//! ```

const std = @import("std");

pub const types = @import("core/types.zig");
pub const meta = @import("core/meta.zig");
pub const headers = @import("core/headers.zig");
pub const uri = @import("core/uri.zig");
pub const status = @import("core/status.zig");
pub const request = @import("core/request.zig");
pub const response = @import("core/response.zig");

pub const http = @import("protocol/http.zig");
pub const parser = @import("protocol/parser.zig");
pub const hpack = @import("protocol/hpack.zig");
pub const stream = @import("protocol/stream.zig");
pub const qpack = @import("protocol/qpack.zig");
pub const quic = @import("protocol/quic.zig");
pub const websocket = @import("protocol/websocket.zig");

pub const socket = @import("net/socket.zig");
pub const address = @import("net/address.zig");
pub const unix = @import("net/unix.zig");

pub const tls = @import("tls/tls.zig");

pub const client_mod = @import("client/client.zig");
pub const pool = @import("client/pool.zig");

pub const server_mod = @import("server/server.zig");
pub const router = @import("server/router.zig");
pub const middleware = @import("server/middleware.zig");

pub const buffer = @import("util/buffer.zig");
pub const encoding = @import("util/encoding.zig");
pub const json = @import("util/json.zig");
pub const mime = @import("util/mime.zig");
pub const common = @import("util/common.zig");
pub const multipart = @import("util/multipart.zig");
pub const metrics = @import("util/metrics.zig");
pub const session = @import("util/session.zig");
pub const ContentEncoding = @import("util/compression.zig").ContentEncoding;
pub const decompress = @import("util/compression.zig").decompress;
pub const compress = @import("util/compression.zig").compress;
pub const dns = @import("net/dns.zig");
pub const sse = @import("util/sse.zig");
pub const debug = @import("util/debug.zig");
pub const parseSseStream = sse.parseSseStream;

pub const executor = @import("concurrency/executor.zig");
pub const concurrency = @import("concurrency/pool.zig");

pub const RequestSpec = concurrency.RequestSpec;
pub const RequestResult = concurrency.RequestResult;
pub const BatchBuilder = concurrency.BatchBuilder;
pub const ConcurrencyConfig = concurrency.ConcurrencyConfig;
pub const ConcurrencyMode = concurrency.ConcurrencyMode;

pub const Executor = executor.Executor;
pub const Task = executor.Task;
pub const TaskFn = executor.TaskFn;
pub const ExecutorConfig = executor.ExecutorConfig;

pub const Method = types.Method;
pub const Version = types.Version;
pub const HttpError = types.HttpError;
pub const ContentType = types.ContentType;
pub const Timeouts = types.Timeouts;
pub const RetryPolicy = types.RetryPolicy;
pub const RedirectPolicy = types.RedirectPolicy;
pub const Http2Settings = types.Http2Settings;
pub const Http3Settings = types.Http3Settings;
pub const ProxyKind = types.ProxyKind;
pub const Proxy = types.Proxy;

pub const Headers = headers.Headers;
pub const HeaderName = headers.HeaderName;
pub const Header = headers.Header;

pub const Uri = uri.Uri;

pub const Status = status.Status;
pub const StatusCode = status.StatusCode;

pub const Request = request.Request;
pub const RequestBuilder = request.RequestBuilder;

pub const Response = response.Response;
pub const ResponseBuilder = response.ResponseBuilder;

pub const Socket = socket.Socket;
pub const TcpListener = socket.TcpListener;
pub const UdpSocket = socket.UdpSocket;
pub const Address = address.Address;
pub const AddressList = address.AddressList;
pub const ShutdownMode = socket.ShutdownMode;
pub const TcpSocket = Socket;
pub const DatagramSocket = UdpSocket;
pub const netInit = socket.init;
pub const netDeinit = socket.deinit;

pub const Parser = parser.Parser;

pub const Http1Connection = http.Http1Connection;
pub const Http2Connection = http.Http2Connection;
pub const Http2FrameType = http.Http2FrameType;
pub const Http2FrameHeader = http.Http2FrameHeader;
pub const Http2ErrorCode = http.Http2ErrorCode;
pub const Http3FrameType = http.Http3FrameType;
pub const Http3ErrorCode = http.Http3ErrorCode;
pub const AlpnProtocol = http.AlpnProtocol;
pub const NegotiatedProtocol = http.NegotiatedProtocol;

// HTTP/2 HPACK exports
pub const HpackContext = hpack.HpackContext;
pub const HpackStaticTable = hpack.StaticTable;
pub const HpackDynamicTable = hpack.DynamicTable;
pub const encodeHpackHeaders = hpack.encodeHeaders;
pub const decodeHpackHeaders = hpack.decodeHeaders;

// HTTP/2 Stream exports
pub const Stream = stream.Stream;
pub const StreamState = stream.StreamState;
pub const StreamManager = stream.StreamManager;
pub const StreamPriority = stream.StreamPriority;

// HTTP/3 QPACK exports
pub const QpackContext = qpack.QpackContext;
pub const QpackStaticTable = qpack.StaticTable;
pub const encodeQpackHeaders = qpack.encodeHeaders;
pub const decodeQpackHeaders = qpack.decodeHeaders;

// QUIC exports
pub const QuicVersion = quic.Version;
pub const QuicLongHeader = quic.LongHeader;
pub const QuicShortHeader = quic.ShortHeader;
pub const QuicConnectionId = quic.ConnectionId;
pub const QuicFrameType = quic.FrameType;
pub const QuicTransportError = quic.TransportError;
pub const QuicStreamFrame = quic.StreamFrame;
pub const QuicCryptoFrame = quic.CryptoFrame;
pub const QuicAckFrame = quic.AckFrame;
pub const QuicTransportParameters = quic.TransportParameters;

pub const formatRequest = http.formatRequest;
pub const formatResponse = http.formatResponse;
pub const encodeChunkedBody = http.encodeChunkedBody;
pub const negotiateVersion = http.negotiateVersion;

pub const Client = client_mod.Client;
pub const ClientConfig = client_mod.ClientConfig;
pub const RequestOptions = client_mod.RequestOptions;
pub const BasicAuth = client_mod.BasicAuth;
pub const Interceptor = client_mod.Interceptor;
pub const RequestInterceptor = client_mod.RequestInterceptor;
pub const ResponseInterceptor = client_mod.ResponseInterceptor;
pub const JsonBorrowedResult = client_mod.JsonBorrowedResult;

pub const ConnectionPool = pool.ConnectionPool;
pub const PoolConfig = pool.PoolConfig;
pub const Connection = pool.Connection;
pub const PoolStats = pool.PoolStats;

pub const Server = server_mod.Server;
pub const ServerConfig = server_mod.ServerConfig;
pub const LogLevel = server_mod.LogLevel;
pub const LogFn = server_mod.LogFn;
pub const PortConflictStrategy = server_mod.PortConflictStrategy;
pub const Context = server_mod.Context;
pub const Handler = server_mod.Handler;
pub const CookieOptions = server_mod.CookieOptions;
pub const SameSite = server_mod.SameSite;
pub const SseEvent = server_mod.SseEvent;
pub const PreRouteHook = server_mod.PreRouteHook;
pub const FileResponseOptions = server_mod.FileResponseOptions;

pub const Router = router.Router;
pub const RouteGroup = router.RouteGroup;
pub const RouteMatch = router.RouteMatch;

pub const Middleware = middleware.Middleware;
pub const Next = middleware.Next;
pub const cors = middleware.cors;
pub const logger = middleware.logger;
pub const LoggerConfig = middleware.LoggerConfig;
pub const loggerWithConfig = middleware.loggerWithConfig;
pub const compressionMiddleware = middleware.compression;
pub const compressionMiddlewareWithConfig = middleware.compressionMiddlewareWithConfig;
pub const rateLimit = middleware.rateLimit;
pub const basicAuth = middleware.basicAuth;
pub const helmet = middleware.helmet;
pub const reverseProxy = middleware.reverseProxy;
pub const reverseProxyRuntime = middleware.reverseProxyRuntime;
pub const healthCheck = middleware.healthCheck;
pub const readinessProbe = middleware.readinessProbe;
pub const HealthConfig = middleware.HealthConfig;
pub const ReadinessConfig = middleware.ReadinessConfig;
pub const RateLimitConfig = middleware.RateLimitConfig;
pub const CorsConfig = middleware.CorsConfig;

// WebSocket exports (flat API -- no httpx.websocket.WebSocket.X redundancy)
pub const WsOpcode = websocket.WsOpcode;
pub const WsFrame = websocket.WsFrame;
pub const WsCloseCode = websocket.WsCloseCode;
pub const WsDecodeResult = websocket.WsDecodeResult;
pub const WS_GUID = websocket.WS_GUID;
pub const isWebSocketUpgrade = websocket.isWebSocketUpgrade;
pub const wsExtractKey = websocket.wsExtractKey;
pub const wsAcceptKey = websocket.wsAcceptKey;
pub const wsUpgradeHeaders = websocket.wsUpgradeHeaders;
pub const wsEncodeFrame = websocket.wsEncodeFrame;
pub const wsDecodeFrame = websocket.wsDecodeFrame;
pub const wsTextFrame = websocket.wsTextFrame;
pub const wsBinaryFrame = websocket.wsBinaryFrame;
pub const wsPingFrame = websocket.wsPingFrame;
pub const wsPongFrame = websocket.wsPongFrame;
pub const wsCloseFrame = websocket.wsCloseFrame;

// Multipart exports
pub const MultipartBuilder = multipart.MultipartBuilder;
pub const MultipartPart = multipart.Part;
pub const MultipartParsed = multipart.ParsedParts;
pub const extractMultipartBoundary = multipart.extractBoundary;
pub const parseMultipart = multipart.parse;
/// Safe per-part data limit for multipart uploads on Windows (64 KB).
/// See `multipart.MAX_RECOMMENDED_CHUNK` for details.
pub const MultipartMaxChunk = multipart.MAX_RECOMMENDED_CHUNK;

// Metrics exports
pub const Metrics = metrics.Metrics;
pub const MetricsSnapshot = metrics.MetricsSnapshot;
pub const MetricsEvent = metrics.MetricsEvent;
pub const MetricsCallbackFn = metrics.MetricsCallbackFn;

// Session exports
pub const SessionStore = session.SessionStore;
pub const SessionConfig = session.SessionConfig;
pub const SESSION_ID_LEN = session.SESSION_ID_LEN;

// Unix socket exports
pub const UnixSocket = unix.UnixSocket;
pub const UnixListener = unix.UnixListener;
pub const UnixClient = unix.UnixClient;
pub const Buffer = buffer.Buffer;
pub const FixedBuffer = buffer.FixedBuffer;

pub const Base64 = encoding.Base64;
pub const Hex = encoding.Hex;
pub const PercentEncoding = encoding.PercentEncoding;
pub const CookiePair = common.CookiePair;
pub const MimeMapping = mime.MimeMapping;
pub const defaultMimeMappings = mime.default_mappings;
pub const MultipartField = client_mod.MultipartField;
pub const MultipartFile = client_mod.MultipartFile;

pub const TlsConfig = tls.TlsConfig;
pub const TlsSession = tls.TlsSession;

pub const VERSION = meta.version;
pub const DEFAULT_USER_AGENT = meta.default_user_agent;
const default_alias_allocator = std.heap.page_allocator;

/// Resolves a hostname to a network address.
pub const resolveAddress = address.resolve;

/// Parses "host:port" style address strings.
pub const parseHostAndPort = address.parseHostPort;

/// Resolves a hostname to all candidate addresses.
pub const resolveAllAddresses = address.resolveAll;

/// Parses "host:port" and resolves to a concrete address.
pub const parseAndResolveAddress = address.parseAndResolve;

/// Returns true if input is an IPv4/IPv6 literal.
pub const isIpAddress = address.isIpAddress;

/// Returns true if input is an IPv4 literal.
pub const isIp4Address = address.isIp4Address;

/// Returns true if input is an IPv6 literal.
pub const isIp6Address = address.isIp6Address;

/// Returns the canonical `std.Io` for the current execution context.
pub const defaultIo = common.defaultIo;

/// Sleeps for `ms` milliseconds using the canonical IO.
pub const sleepMs = common.sleepMs;
pub const sleepMsI = common.sleepMsI;

/// Returns a query parameter value from a raw query string.
pub const queryValue = common.queryValue;

/// Parses the first name/value pair from a Set-Cookie header value.
pub const parseSetCookiePair = common.parseSetCookiePair;

/// Returns a best-effort MIME type from file extension.
pub const mimeTypeFromPath = common.mimeTypeFromPath;

/// Returns a MIME type from file extension with a custom fallback.
pub const mimeTypeFromPathOr = common.mimeTypeFromPathOr;

/// Returns a MIME type using caller-provided mappings and fallback.
pub const mimeTypeFromPathWith = common.mimeTypeFromPathWith;

/// HTTP/3 varint encode alias.
pub const encodeVarInt = http.encodeVarInt;

/// HTTP/3 varint decode alias.
pub const decodeVarInt = http.decodeVarInt;

/// Executes all requests in parallel and returns a result per request.
pub fn all(allocator: std.mem.Allocator, client: *Client, specs: []const RequestSpec, config: ConcurrencyConfig) ![]RequestResult {
    return concurrency.all(allocator, client, specs, config);
}

/// Executes all requests in parallel and returns the first 2xx response (if any).
pub fn any(allocator: std.mem.Allocator, client: *Client, specs: []const RequestSpec, config: ConcurrencyConfig) !?Response {
    return concurrency.any(allocator, client, specs, config);
}

/// Executes all requests in parallel and returns the first completion (success or error).
pub fn race(allocator: std.mem.Allocator, client: *Client, specs: []const RequestSpec, config: ConcurrencyConfig) !RequestResult {
    return concurrency.race(allocator, client, specs, config);
}

/// Executes all requests in parallel and returns a settled result for each one.
pub fn allSettled(allocator: std.mem.Allocator, client: *Client, specs: []const RequestSpec, config: ConcurrencyConfig) ![]RequestResult {
    return concurrency.allSettled(allocator, client, specs, config);
}

/// Counts successful results returned by all/allSettled.
pub fn successfulCount(results: []const RequestResult) usize {
    return concurrency.successfulCount(results);
}

/// Counts failed results returned by all/allSettled.
pub fn errorCount(results: []const RequestResult) usize {
    return concurrency.errorCount(results);
}

/// Alias for any() for first-success semantics.
pub fn first(allocator: std.mem.Allocator, client: *Client, specs: []const RequestSpec, config: ConcurrencyConfig) !?Response {
    return any(allocator, client, specs, config);
}

/// Alias for race() for first-completion semantics.
pub fn fastest(allocator: std.mem.Allocator, client: *Client, specs: []const RequestSpec, config: ConcurrencyConfig) !RequestResult {
    return race(allocator, client, specs, config);
}

/// Alias for allSettled() returning settled outcomes.
pub fn settled(allocator: std.mem.Allocator, client: *Client, specs: []const RequestSpec, config: ConcurrencyConfig) ![]RequestResult {
    return allSettled(allocator, client, specs, config);
}

/// Convenience function to create a GET request.
pub fn get(url: []const u8, req_options: RequestOptions) !Response {
    return getWithAllocator(default_alias_allocator, url, req_options);
}

/// Convenience function to create a GET request with an explicit allocator.
pub fn getWithAllocator(allocator: std.mem.Allocator, url: []const u8, req_options: RequestOptions) !Response {
    var c = Client.init(allocator);
    defer c.deinit();
    return c.get(url, req_options);
}

/// Convenience alias for GET requests.
pub fn fetch(url: []const u8, req_options: RequestOptions) !Response {
    return get(url, req_options);
}

/// Convenience alias for GET requests with an explicit allocator.
pub fn fetchWithAllocator(allocator: std.mem.Allocator, url: []const u8, req_options: RequestOptions) !Response {
    return getWithAllocator(allocator, url, req_options);
}

/// Convenience function to create a request with an explicit method.
pub fn send(method: Method, url: []const u8, req_options: RequestOptions) !Response {
    return sendWithAllocator(default_alias_allocator, method, url, req_options);
}

/// Convenience function to create a request with an explicit method and allocator.
pub fn sendWithAllocator(
    allocator: std.mem.Allocator,
    method: Method,
    url: []const u8,
    req_options: RequestOptions,
) !Response {
    var c = Client.init(allocator);
    defer c.deinit();
    return c.request(method, url, req_options);
}

/// Convenience function to create a POST request with JSON body.
pub fn postJson(url: []const u8, body: []const u8) !Response {
    return postJsonWithAllocator(default_alias_allocator, url, body);
}

/// Convenience function to create a POST request with JSON body and allocator.
pub fn postJsonWithAllocator(allocator: std.mem.Allocator, url: []const u8, body: []const u8) !Response {
    var c = Client.init(allocator);
    defer c.deinit();
    return c.post(url, .{ .json = body });
}

/// Convenience function to GET a URL and parse the JSON response into type T.
/// Returns both the response and parsed value. Caller deinit's both.
pub fn getJson(comptime T: type, url: []const u8, parse_opts: std.json.ParseOptions) !JsonBorrowedResult(T) {
    return getJsonWithAllocator(default_alias_allocator, T, url, parse_opts);
}

/// Convenience function to GET a URL and parse JSON with an explicit allocator.
pub fn getJsonWithAllocator(allocator: std.mem.Allocator, comptime T: type, url: []const u8, parse_opts: std.json.ParseOptions) !JsonBorrowedResult(T) {
    var c = Client.init(allocator);
    defer c.deinit();
    return c.getJson(T, url, parse_opts);
}

/// Convenience function to POST JSON and parse the response as type T.
/// Returns both the response and parsed value. Caller deinit's both.
pub fn postJsonAndParse(comptime T: type, url: []const u8, body: []const u8, parse_opts: std.json.ParseOptions) !JsonBorrowedResult(T) {
    return postJsonAndParseWithAllocator(default_alias_allocator, T, url, body, parse_opts);
}

/// Convenience function to POST JSON and parse the response with an explicit allocator.
pub fn postJsonAndParseWithAllocator(allocator: std.mem.Allocator, comptime T: type, url: []const u8, body: []const u8, parse_opts: std.json.ParseOptions) !JsonBorrowedResult(T) {
    var c = Client.init(allocator);
    defer c.deinit();
    return c.postJsonAndParse(T, url, body, parse_opts);
}

/// Convenience function to PUT JSON and parse the response as type T.
pub fn putJson(comptime T: type, url: []const u8, body: []const u8, parse_opts: std.json.ParseOptions) !JsonBorrowedResult(T) {
    return putJsonWithAllocator(default_alias_allocator, T, url, body, parse_opts);
}

/// Convenience function to PUT JSON and parse the response with an explicit allocator.
pub fn putJsonWithAllocator(allocator: std.mem.Allocator, comptime T: type, url: []const u8, body: []const u8, parse_opts: std.json.ParseOptions) !JsonBorrowedResult(T) {
    var c = Client.init(allocator);
    defer c.deinit();
    return c.putJson(T, url, body, parse_opts);
}

/// Convenience function to PATCH JSON and parse the response as type T.
pub fn patchJson(comptime T: type, url: []const u8, body: []const u8, parse_opts: std.json.ParseOptions) !JsonBorrowedResult(T) {
    return patchJsonWithAllocator(default_alias_allocator, T, url, body, parse_opts);
}

/// Convenience function to PATCH JSON and parse the response with an explicit allocator.
pub fn patchJsonWithAllocator(allocator: std.mem.Allocator, comptime T: type, url: []const u8, body: []const u8, parse_opts: std.json.ParseOptions) !JsonBorrowedResult(T) {
    var c = Client.init(allocator);
    defer c.deinit();
    return c.patchJson(T, url, body, parse_opts);
}

/// Convenience function to DELETE and parse the JSON response as type T.
pub fn deleteJson(comptime T: type, url: []const u8, parse_opts: std.json.ParseOptions) !JsonBorrowedResult(T) {
    return deleteJsonWithAllocator(default_alias_allocator, T, url, parse_opts);
}

/// Convenience function to DELETE and parse the JSON response with an explicit allocator.
pub fn deleteJsonWithAllocator(allocator: std.mem.Allocator, comptime T: type, url: []const u8, parse_opts: std.json.ParseOptions) !JsonBorrowedResult(T) {
    var c = Client.init(allocator);
    defer c.deinit();
    return c.deleteJson(T, url, parse_opts);
}

/// Zero-copy: GET and parse JSON with strings borrowing from the response body.
/// The response must outlive the parsed value.
pub fn getJsonBorrowed(comptime T: type, url: []const u8) !JsonBorrowedResult(T) {
    return getJsonBorrowedWithAllocator(default_alias_allocator, T, url);
}

/// Zero-copy: GET with explicit allocator.
pub fn getJsonBorrowedWithAllocator(allocator: std.mem.Allocator, comptime T: type, url: []const u8) !JsonBorrowedResult(T) {
    var c = Client.init(allocator);
    defer c.deinit();
    return c.getJsonBorrowed(T, url);
}

/// Zero-copy: POST JSON and parse response with strings borrowing from the body.
pub fn postJsonBorrowed(comptime T: type, url: []const u8, body: []const u8) !JsonBorrowedResult(T) {
    return postJsonBorrowedWithAllocator(default_alias_allocator, T, url, body);
}

/// Zero-copy: POST with explicit allocator.
pub fn postJsonBorrowedWithAllocator(allocator: std.mem.Allocator, comptime T: type, url: []const u8, body: []const u8) !JsonBorrowedResult(T) {
    var c = Client.init(allocator);
    defer c.deinit();
    return c.postJsonBorrowed(T, url, body);
}

/// Convenience function to create a POST request.
pub fn post(url: []const u8, req_options: RequestOptions) !Response {
    return postWithAllocator(default_alias_allocator, url, req_options);
}

/// Convenience function to create a POST request with an explicit allocator.
pub fn postWithAllocator(allocator: std.mem.Allocator, url: []const u8, req_options: RequestOptions) !Response {
    var c = Client.init(allocator);
    defer c.deinit();
    return c.post(url, req_options);
}

/// Convenience function to create a PUT request.
pub fn put(url: []const u8, req_options: RequestOptions) !Response {
    return putWithAllocator(default_alias_allocator, url, req_options);
}

/// Convenience function to create a PUT request with an explicit allocator.
pub fn putWithAllocator(allocator: std.mem.Allocator, url: []const u8, req_options: RequestOptions) !Response {
    var c = Client.init(allocator);
    defer c.deinit();
    return c.put(url, req_options);
}

/// Convenience function to create a DELETE request.
pub fn del(url: []const u8, req_options: RequestOptions) !Response {
    return delWithAllocator(default_alias_allocator, url, req_options);
}

/// Convenience function to create a DELETE request with an explicit allocator.
pub fn delWithAllocator(allocator: std.mem.Allocator, url: []const u8, req_options: RequestOptions) !Response {
    var c = Client.init(allocator);
    defer c.deinit();
    return c.delete(url, req_options);
}

/// Convenience alias for DELETE requests.
pub fn delete(url: []const u8, req_options: RequestOptions) !Response {
    return del(url, req_options);
}

/// Convenience alias for DELETE requests with an explicit allocator.
pub fn deleteWithAllocator(allocator: std.mem.Allocator, url: []const u8, req_options: RequestOptions) !Response {
    return delWithAllocator(allocator, url, req_options);
}

/// Convenience function to create a PATCH request.
pub fn patch(url: []const u8, req_options: RequestOptions) !Response {
    return patchWithAllocator(default_alias_allocator, url, req_options);
}

/// Convenience function to create a PATCH request with an explicit allocator.
pub fn patchWithAllocator(allocator: std.mem.Allocator, url: []const u8, req_options: RequestOptions) !Response {
    var c = Client.init(allocator);
    defer c.deinit();
    return c.patch(url, req_options);
}

/// Convenience function to create a HEAD request.
pub fn head(url: []const u8, req_options: RequestOptions) !Response {
    return headWithAllocator(default_alias_allocator, url, req_options);
}

/// Convenience function to create a HEAD request with an explicit allocator.
pub fn headWithAllocator(allocator: std.mem.Allocator, url: []const u8, req_options: RequestOptions) !Response {
    var c = Client.init(allocator);
    defer c.deinit();
    return c.head(url, req_options);
}

/// Convenience function to create a TRACE request.
pub fn trace(url: []const u8, req_options: RequestOptions) !Response {
    return traceWithAllocator(default_alias_allocator, url, req_options);
}

/// Convenience function to create a TRACE request with an explicit allocator.
pub fn traceWithAllocator(allocator: std.mem.Allocator, url: []const u8, req_options: RequestOptions) !Response {
    var c = Client.init(allocator);
    defer c.deinit();
    return c.trace(url, req_options);
}

/// Convenience function to create a CONNECT request.
pub fn connect(url: []const u8, req_options: RequestOptions) !Response {
    return connectWithAllocator(default_alias_allocator, url, req_options);
}

/// Convenience function to create a CONNECT request with an explicit allocator.
pub fn connectWithAllocator(allocator: std.mem.Allocator, url: []const u8, req_options: RequestOptions) !Response {
    var c = Client.init(allocator);
    defer c.deinit();
    return c.connect(url, req_options);
}

/// Convenience function to create an OPTIONS request.
pub fn options(url: []const u8, options_in: RequestOptions) !Response {
    return optionsWithAllocator(default_alias_allocator, url, options_in);
}

/// Convenience function to create an OPTIONS request with an explicit allocator.
pub fn optionsWithAllocator(allocator: std.mem.Allocator, url: []const u8, options_in: RequestOptions) !Response {
    var c = Client.init(allocator);
    defer c.deinit();
    return c.options(url, options_in);
}

/// Convenience alias for OPTIONS requests.
pub fn opts(url: []const u8, options_in: RequestOptions) !Response {
    return options(url, options_in);
}

/// Convenience alias for OPTIONS requests with an explicit allocator.
pub fn optsWithAllocator(allocator: std.mem.Allocator, url: []const u8, options_in: RequestOptions) !Response {
    return optionsWithAllocator(allocator, url, options_in);
}

test "top-level alias compile checks" {
    const get_ptr: *const fn ([]const u8, RequestOptions) anyerror!Response = get;
    const get_alloc_ptr: *const fn (std.mem.Allocator, []const u8, RequestOptions) anyerror!Response = getWithAllocator;
    const fetch_ptr: *const fn ([]const u8, RequestOptions) anyerror!Response = fetch;
    const fetch_alloc_ptr: *const fn (std.mem.Allocator, []const u8, RequestOptions) anyerror!Response = fetchWithAllocator;
    const post_json_ptr: *const fn ([]const u8, []const u8) anyerror!Response = postJson;
    const post_json_alloc_ptr: *const fn (std.mem.Allocator, []const u8, []const u8) anyerror!Response = postJsonWithAllocator;
    const get_json_ptr = &getJson;
    const get_json_alloc_ptr = &getJsonWithAllocator;
    const post_json_parse_ptr = &postJsonAndParse;
    const post_json_parse_alloc_ptr = &postJsonAndParseWithAllocator;
    const send_ptr: *const fn (Method, []const u8, RequestOptions) anyerror!Response = send;
    const send_alloc_ptr: *const fn (std.mem.Allocator, Method, []const u8, RequestOptions) anyerror!Response = sendWithAllocator;
    const post_ptr: *const fn ([]const u8, RequestOptions) anyerror!Response = post;
    const post_alloc_ptr: *const fn (std.mem.Allocator, []const u8, RequestOptions) anyerror!Response = postWithAllocator;
    const put_ptr: *const fn ([]const u8, RequestOptions) anyerror!Response = put;
    const put_alloc_ptr: *const fn (std.mem.Allocator, []const u8, RequestOptions) anyerror!Response = putWithAllocator;
    const del_ptr: *const fn ([]const u8, RequestOptions) anyerror!Response = del;
    const del_alloc_ptr: *const fn (std.mem.Allocator, []const u8, RequestOptions) anyerror!Response = delWithAllocator;
    const delete_ptr: *const fn ([]const u8, RequestOptions) anyerror!Response = delete;
    const delete_alloc_ptr: *const fn (std.mem.Allocator, []const u8, RequestOptions) anyerror!Response = deleteWithAllocator;
    const patch_ptr: *const fn ([]const u8, RequestOptions) anyerror!Response = patch;
    const patch_alloc_ptr: *const fn (std.mem.Allocator, []const u8, RequestOptions) anyerror!Response = patchWithAllocator;
    const head_ptr: *const fn ([]const u8, RequestOptions) anyerror!Response = head;
    const head_alloc_ptr: *const fn (std.mem.Allocator, []const u8, RequestOptions) anyerror!Response = headWithAllocator;
    const trace_ptr: *const fn ([]const u8, RequestOptions) anyerror!Response = trace;
    const trace_alloc_ptr: *const fn (std.mem.Allocator, []const u8, RequestOptions) anyerror!Response = traceWithAllocator;
    const connect_ptr: *const fn ([]const u8, RequestOptions) anyerror!Response = connect;
    const connect_alloc_ptr: *const fn (std.mem.Allocator, []const u8, RequestOptions) anyerror!Response = connectWithAllocator;
    const options_ptr: *const fn ([]const u8, RequestOptions) anyerror!Response = options;
    const options_alloc_ptr: *const fn (std.mem.Allocator, []const u8, RequestOptions) anyerror!Response = optionsWithAllocator;
    const opts_ptr: *const fn ([]const u8, RequestOptions) anyerror!Response = opts;
    const opts_alloc_ptr: *const fn (std.mem.Allocator, []const u8, RequestOptions) anyerror!Response = optsWithAllocator;
    const first_ptr: *const fn (std.mem.Allocator, *Client, []const RequestSpec, ConcurrencyConfig) anyerror!?Response = first;
    const fastest_ptr: *const fn (std.mem.Allocator, *Client, []const RequestSpec, ConcurrencyConfig) anyerror!RequestResult = fastest;
    const settled_ptr: *const fn (std.mem.Allocator, *Client, []const RequestSpec, ConcurrencyConfig) anyerror![]RequestResult = settled;
    const resolve_addr_ptr: *const fn (std.mem.Allocator, []const u8, u16) anyerror!address.Address = resolveAddress;
    const resolve_all_addr_ptr: *const fn (std.mem.Allocator, []const u8, u16) anyerror![]address.Address = resolveAllAddresses;
    const parse_host_port_ptr = parseHostAndPort;
    const parse_and_resolve_ptr: *const fn (std.mem.Allocator, []const u8, u16) anyerror!address.Address = parseAndResolveAddress;
    const is_ip_ptr: *const fn ([]const u8) bool = isIpAddress;
    const is_ip4_ptr: *const fn ([]const u8) bool = isIp4Address;
    const is_ip6_ptr: *const fn ([]const u8) bool = isIp6Address;
    const mime_ptr: *const fn ([]const u8) []const u8 = mimeTypeFromPath;
    const mime_or_ptr: *const fn ([]const u8, []const u8) []const u8 = mimeTypeFromPathOr;
    const mime_with_ptr: *const fn ([]const u8, []const common.MimeMapping, []const u8) []const u8 = mimeTypeFromPathWith;
    const net_init_ptr: *const fn () anyerror!void = netInit;
    const net_deinit_ptr: *const fn () void = netDeinit;
    _ = get_ptr;
    _ = get_alloc_ptr;
    _ = fetch_ptr;
    _ = fetch_alloc_ptr;
    _ = post_json_ptr;
    _ = post_json_alloc_ptr;
    _ = get_json_ptr;
    _ = get_json_alloc_ptr;
    _ = post_json_parse_ptr;
    _ = post_json_parse_alloc_ptr;
    _ = send_ptr;
    _ = send_alloc_ptr;
    _ = post_ptr;
    _ = post_alloc_ptr;
    _ = put_ptr;
    _ = put_alloc_ptr;
    _ = del_ptr;
    _ = del_alloc_ptr;
    _ = delete_ptr;
    _ = delete_alloc_ptr;
    _ = patch_ptr;
    _ = patch_alloc_ptr;
    _ = head_ptr;
    _ = head_alloc_ptr;
    _ = trace_ptr;
    _ = trace_alloc_ptr;
    _ = connect_ptr;
    _ = connect_alloc_ptr;
    _ = options_ptr;
    _ = options_alloc_ptr;
    _ = opts_ptr;
    _ = opts_alloc_ptr;
    _ = first_ptr;
    _ = fastest_ptr;
    _ = settled_ptr;
    _ = resolve_addr_ptr;
    _ = resolve_all_addr_ptr;
    _ = parse_host_port_ptr;
    _ = parse_and_resolve_ptr;
    _ = is_ip_ptr;
    _ = is_ip4_ptr;
    _ = is_ip6_ptr;
    _ = mime_ptr;
    _ = mime_or_ptr;
    _ = mime_with_ptr;
    _ = net_init_ptr;
    _ = net_deinit_ptr;
}

test "core types" {
    _ = types;
}

test "headers" {
    _ = headers;
}

test "uri" {
    _ = uri;
}

test "status" {
    _ = status;
}

test "request" {
    _ = request;
}

test "response" {
    _ = response;
}

test "http protocol" {
    _ = http;
}

test "hpack" {
    _ = hpack;
}

test "stream" {
    _ = stream;
}

test "qpack" {
    _ = qpack;
}

test "quic" {
    _ = quic;
}

test "parser" {
    _ = parser;
}

test "buffer" {
    _ = buffer;
}

test "encoding" {
    _ = encoding;
}

test "json" {
    _ = json;
}

test "common" {
    _ = common;
}

test "socket" {
    _ = socket;
}

test "address" {
    _ = address;
}
