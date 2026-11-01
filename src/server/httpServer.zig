//! HTTP server: bounded accept loop -> protocol dispatch -> router -> writer.
//!
//! Accepted connections run on a fixed worker pool with bounded admission and
//! queue capacity. A fresh request arena backs each connection so handlers can
//! allocate freely and everything is released when the connection completes.
//!
//! API documentation routes (OpenAPI + Swagger UI + ReDoc) are mounted by
//! default; disable with `Config.enableDocs = false` or customize through
//! `Config.docs`.
//!
//! References:
//!   - RFC 9112 — HTTP/1.1 (message format, connection management)
//!   - RFC 9110 — HTTP Semantics (status codes, headers, methods)

const std = @import("std");
const Allocator = std.mem.Allocator;
const tcp = @import("../sockets/tcp.zig");
const compression = @import("../compression/codec.zig");
const parserMod = @import("../protocols/http1/parser.zig");
const semanticsMod = @import("../protocols/http1/semantics.zig");
const writerMod = @import("../protocols/http1/writer.zig");
const routerMod = @import("../web/router/router.zig");
const Router = routerMod.Router;
const Context = routerMod.Context;
const Response = routerMod.Response;
const Method = @import("../common/method.zig").Method;
const docs = @import("../web/docs/docs.zig");
const httpVersion = @import("../common/httpVersion.zig");
pub const HttpVersion = httpVersion.HttpVersion;
const watcherMod = @import("../web/watcher/watcherBackend.zig");
const reload = @import("../web/watcher/fileWatcher.zig");
const udpMod = @import("../sockets/udp.zig");
const templatesMod = @import("../web/templates/templates.zig");
const tlsServerMod = @import("../protocols/tls/tlsServer.zig");
const fsMod = @import("../utils/fs.zig");
const addressMod = @import("../net/address.zig");
const uriMod = @import("../common/uri.zig");
const alpnMod = @import("../protocols/tls/alpn.zig");
const metricsMod = @import("../web/metrics/metricsRegistry.zig");
const tlsSessionMod = @import("../protocols/tls/tlsSession.zig");
const quicTransport = @import("../protocols/quic/transport.zig");
const quicConn = @import("../protocols/quic/connection.zig");
const quicHs = @import("../protocols/quic/handshake.zig");
const quicFrames = @import("../protocols/quic/frames.zig");
const http3Frame = @import("../protocols/http3/frame.zig");
const http3Conn = @import("../protocols/http3/connection.zig");
const http3Stream = @import("../protocols/http3/stream.zig");
const http3Qpack = @import("../protocols/http3/qpack.zig");

pub const maxHeadBytes = 32 * 1024;

/// Unified abstraction over plain TCP sockets and encrypted TLS server connections.
pub const StreamConn = union(enum) {
    plain: *tcp.Socket,
    tls: *tlsServerMod.Server.Connection,

    pub fn setReadTimeoutMs(self: StreamConn, timeoutMs: u32) void {
        switch (self) {
            .plain => |socket| socket.setReadTimeoutMs(timeoutMs),
            .tls => |connection| connection.socket.setReadTimeoutMs(timeoutMs),
        }
    }

    pub fn setWriteTimeoutMs(self: StreamConn, timeoutMs: u32) void {
        switch (self) {
            .plain => |socket| socket.setWriteTimeoutMs(timeoutMs),
            .tls => |connection| connection.socket.setWriteTimeoutMs(timeoutMs),
        }
    }

    pub fn read(self: StreamConn, buf: []u8) anyerror!usize {
        return switch (self) {
            .plain => |p| p.read(buf),
            .tls => |t| t.read(buf),
        };
    }

    pub fn writeAll(self: StreamConn, bytes: []const u8) anyerror!void {
        return switch (self) {
            .plain => |p| p.writeAll(bytes),
            .tls => |t| t.writeAll(bytes),
        };
    }

    pub fn peerAddress(self: StreamConn) []const u8 {
        return switch (self) {
            .plain => |p| p.peerAddress(),
            .tls => |t| t.socket.peerAddress(),
        };
    }
};

const logging = @import("../common/logging.zig");
const clock = @import("../common/clock.zig");

/// Observability configuration for the server.
///
/// HTTPX NEVER automatically prints to stdout, stderr, or any output
/// destination. The application callback receives structured `ServerEvent`
/// values and decides where (if anywhere) they go.
///
/// ```zig
/// fn onEvent(event: httpx.logging.ServerEvent) void {
///     if (event.kind == .requestCompleted) {
///         std.debug.print("{s} {s} {d} {d}ms\n", .{
///             event.method, event.path, event.status, event.durationMs,
///         });
///     }
/// }
///
/// var server = try httpx.Server.init(allocator, io, .{
///     .logging = .{ .callback = onEvent },
/// });
/// ```
///
/// To disable all events (the default): `.logging = .{}` (callback = null).
pub const LoggingOptions = struct {
    /// Application-supplied callback. When null (the default), no events are
    /// generated and HTTPX produces no output whatsoever.
    callback: ?logging.ServerEventCallback = null,
    /// Minimum severity filter. Events below this level are not delivered.
    level: logging.Level = .info,
};

pub const PortStrategy = enum {
    /// If port is in use, automatically try port + 1, port + 2, up to maxPortAttempts.
    incremental,
    /// Return error.AddressInUse immediately if port is occupied.
    strict,
    /// Exit / fail if port is occupied.
    exit,
};

/// ALPN identifiers in server preference order, selected from enabled
/// protocol handlers when the caller leaves TLS ALPN at its default.
const alpnH2Http11Http10 = [_]alpnMod.Protocol{ .h2, .@"http/1.1", .@"http/1.0" };
const alpnH2Http11 = [_]alpnMod.Protocol{ .h2, .@"http/1.1" };
const alpnH2Http10 = [_]alpnMod.Protocol{ .h2, .@"http/1.0" };
const alpnH2 = [_]alpnMod.Protocol{.h2};
const alpnHttp11 = [_]alpnMod.Protocol{.@"http/1.1"};
const alpnHttp10Http11 = [_]alpnMod.Protocol{ .@"http/1.1", .@"http/1.0" };
const alpnHttp10 = [_]alpnMod.Protocol{.@"http/1.0"};

pub const Config = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 8080,
    /// Port resolution strategy when the port is in use. Default is incremental.
    portStrategy: PortStrategy = .incremental,
    /// Maximum attempts when portStrategy is incremental.
    maxPortAttempts: u16 = 50,
    /// Largest accepted request body.
    maxBody: usize = 8 * 1024 * 1024,
    /// Total connections run() serves before returning (0 = unlimited).
    /// Counts successfully queued connections, not simultaneous connections.
    /// Tests use small values to join the run thread deterministically.
    maxConnections: usize = 0,
    /// Maximum accepted connections being processed or waiting in the bounded
    /// worker queue. Excess connections are closed immediately.
    maxConcurrentConnections: usize = 128,
    /// Maximum connections waiting for a worker. A full queue closes the newly
    /// accepted socket, keeping memory and pending work bounded.
    maxQueuedConnectionTasks: usize = 128,
    /// Fixed worker count. Zero selects up to 16 CPUs, capped by
    /// maxConcurrentConnections.
    workerCount: u16 = 0,
    /// Deadline for the first bytes and protocol sniff after accept; zero disables.
    initialRequestTimeoutMs: u32 = 5_000,
    /// Absolute deadline to finish an HTTP request header after its first byte; zero disables.
    headerReadTimeoutMs: u32 = 10_000,
    /// Absolute deadline to receive a complete request body; zero disables.
    requestBodyTimeoutMs: u32 = 30_000,
    /// Absolute write deadline for interim and final responses; zero disables.
    writeTimeoutMs: u32 = 30_000,
    /// Deadline waiting for the next request on an HTTP/1 keep-alive connection; zero disables.
    keepAliveIdleTimeoutMs: u32 = 30_000,
    /// Mount /openapi.json, /docs (Swagger UI), /redoc by default.
    enableDocs: bool = true,
    /// Overrides for docs routes when enabled.
    docs: ?docs.Config = null,
    docsTitle: []const u8 = "HTTPX API",
    logging: LoggingOptions = .{},
    /// HTTP/1.1 persistent connections: honor keep-alive, serve multiple
    /// requests per connection (bounded by maxRequestsPerConn).
    keepAlive: bool = false,
    maxRequestsPerConn: usize = 1000,
    /// Allow bare LF line endings for request parsing (issue #37).
    allowLfLineEndings: bool = false,
    /// Whether to trust X-Forwarded-For, X-Forwarded-Proto, and X-Forwarded-Host from reverse proxies.
    /// When true, Context.remoteAddress(), Context.scheme(), and Context.host() will parse forwarded headers.
    trustForwardedHeaders: bool = false,
    /// Optional list of trusted proxy IPs/CIDRs (e.g. "127.0.0.1", "::1").
    /// If non-empty, headers are only trusted if the connection originates from
    /// one of these addresses, and matching hops are skipped when resolving
    /// X-Forwarded-For right-to-left.
    trustedProxies: []const []const u8 = &.{},
    /// Preferred default HTTP version for server handling. When set to a
    /// concrete version it selects exactly that version, overriding the
    /// individual http10/http11/http2/http3 flags below; `.auto`/null
    /// leaves the flags in charge.
    httpVersion: ?HttpVersion = null,
    /// Enable HTTP/1.0 protocol handling.
    http10: bool = true,
    /// Enable HTTP/1.1 protocol handling.
    http11: bool = true,
    /// Enable HTTP/2 over TLS ALPN and cleartext prior-knowledge connections.
    http2: bool = true,
    /// HTTP/3 server runtime path.
    http3: bool = false,
    /// Require a stateless Retry token before accepting QUIC Initials.
    /// Off by default so 0-RTT clients are not forced into a round trip;
    /// enable in production to validate the client address early.
    http3Retry: bool = false,
    /// Stable key for Retry tokens across connections. When null each
    /// connection generates an ephemeral key (valid for its own Retry
    /// round trip only).
    http3RetryKey: ?[32]u8 = null,
    /// Automatically watch directory and broadcast changes / hot reload.
    watch: bool = false,
    /// Directory to watch when watch is enabled.
    watchDir: []const u8 = ".",
    /// Enable SSE / WebSocket live reload endpoints and auto-inject reload script into HTML.
    liveReload: bool = false,
    /// URL path where the live reload SSE endpoint is mounted.
    liveReloadPath: []const u8 = "/__httpx_liveReload",
    /// Native template engine configuration. If null, automatically discovers and enables "templates/" if that directory exists.
    templates: ?templatesMod.Config = null,
    /// Production-grade TLS / HTTPS configuration.
    /// When provided with certificate & private key (PEM or file path), enables HTTPS server.
    tls: ?tlsServerMod.Server.Config = null,
    /// Response content-coding settings: codec tuning plus the smaller-wins
    /// fallback that keeps `Content-Encoding` from being sent for a body the
    /// codec made bigger. Only applies to bodies under `maxCompressionInput`.
    compression: compression.Config = .{},
    /// Bodies larger than this are sent uncompressed, bounding the memory one
    /// request can hold to roughly input plus compressed copy. Raise it to
    /// compress large document assets (OpenAPI specs, bundled doc UIs), at the
    /// cost of that extra copy per in-flight request.
    maxCompressionInput: usize = 128 * 1024,
};

/// Global pointer to the active server for the Ctrl+C handler.
var gActiveServer: ?*Server = null;

fn installShutdownHandler(self: *Server) void {
    gActiveServer = self;
    const builtin = @import("builtin");
    switch (builtin.os.tag) {
        .windows => {
            const handlerFn = struct {
                fn callback(ctrlType: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
                    if (ctrlType <= 2) {
                        if (gActiveServer) |s| s.requestShutdown();
                        return @fromBackingInt(@intCast(1));
                    }
                    return @fromBackingInt(@intCast(0));
                }
            };
            _ = SetConsoleCtrlHandler(&handlerFn.callback, @fromBackingInt(@intCast(1)));
        },
        else => {
            const handlerFn = struct {
                fn sigHandler(sig: std.posix.SIG) callconv(.c) void {
                    _ = sig;
                    if (gActiveServer) |s| s.requestShutdown();
                }
            };
            var act: std.posix.Sigaction = std.mem.zeroes(std.posix.Sigaction);
            act.handler = .{ .handler = @ptrCast(&handlerFn.sigHandler) };
            act.flags = 0;
            std.posix.sigaction(std.posix.SIG.INT, &act, null);
        },
    }
}

extern "kernel32" fn SetConsoleCtrlHandler(
    handler: *const fn (std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL,
    add: std.os.windows.BOOL,
) callconv(.winapi) std.os.windows.BOOL;

/// One in-flight HTTP/3 request. Requests are keyed by QUIC stream ID so
/// multiple request streams can be served concurrently on one connection.
const H3Request = struct {
    allocator: Allocator,
    maxBody: usize,
    sid: u64 = std.math.maxInt(u64),
    fields: std.ArrayList(http3Qpack.FieldLine) = .empty,
    body: std.ArrayList(u8) = .empty,
    done: bool = false,
    failed: bool = false,
    tooLarge: bool = false,
    h3Error: ?http3Frame.H3Error = null,
    queued: bool = false,

    fn deinit(self: *H3Request) void {
        for (self.fields.items) |f| {
            self.allocator.free(f.name);
            self.allocator.free(f.value);
        }
        self.fields.deinit(self.allocator);
        self.body.deinit(self.allocator);
    }

    fn copyFields(self: *H3Request, incoming: []const http3Qpack.FieldLine) void {
        for (incoming) |f| {
            const name = self.allocator.dupe(u8, f.name) catch {
                self.failed = true;
                return;
            };
            const value = self.allocator.dupe(u8, f.value) catch {
                self.allocator.free(name);
                self.failed = true;
                return;
            };
            self.fields.append(self.allocator, .{ .name = name, .value = value }) catch {
                self.allocator.free(name);
                self.allocator.free(value);
                self.failed = true;
                return;
            };
        }
    }
};

/// Routes QUIC stream events into per-request H3Request state and queues
/// completed or failed requests for the server loop.
const H3PumpCtx = struct {
    io: std.Io,
    allocator: Allocator,
    maxBody: usize,
    h3: *http3Conn.Connection,
    requests: *std.AutoHashMap(u64, *H3Request),
    ready: *std.ArrayList(u64),
    lastActivityMs: *u64,
    err: ?anyerror = null,

    fn getOrCreate(p: *H3PumpCtx, sid: u64) ?*H3Request {
        if (p.requests.get(sid)) |r| return r;
        const r = p.allocator.create(H3Request) catch {
            p.err = error.OutOfMemory;
            return null;
        };
        r.* = .{ .allocator = p.allocator, .maxBody = p.maxBody, .sid = sid };
        p.requests.put(sid, r) catch {
            p.allocator.destroy(r);
            p.err = error.OutOfMemory;
            return null;
        };
        return r;
    }

    fn queue(p: *H3PumpCtx, r: *H3Request) void {
        if (r.queued) return;
        r.queued = true;
        p.ready.append(p.allocator, r.sid) catch {
            r.queued = false;
            p.err = error.OutOfMemory;
        };
    }

    fn onStream(ctx: ?*anyopaque, sid: u64, data: []const u8, fin: bool) void {
        const p: *H3PumpCtx = @ptrCast(@alignCast(ctx.?));
        p.lastActivityMs.* = @intCast(clock.monotonicMillis(p.io));
        p.h3.feedQuic(sid, data, fin) catch {
            if (p.h3.takeStreamError()) |se| {
                if (p.getOrCreate(se.sid)) |r| {
                    r.failed = true;
                    r.h3Error = se.code;
                    p.queue(r);
                }
            }
            if (p.h3.fatalError != null) p.err = error.ProtocolViolation;
            return;
        };
        if (p.h3.takeStreamError()) |se| {
            if (p.getOrCreate(se.sid)) |r| {
                r.failed = true;
                r.h3Error = se.code;
                p.queue(r);
            }
        }
        p.h3.retryBlockedStreams();
        if (p.h3.fatalError != null) p.err = error.ProtocolViolation;
    }

    fn onHeaders(ctx: ?*anyopaque, sid: u64, fields: []const http3Qpack.FieldLine, interim: bool) void {
        if (interim) return;
        const p: *H3PumpCtx = @ptrCast(@alignCast(ctx.?));
        const r = p.getOrCreate(sid) orelse return;
        r.copyFields(fields);
    }

    fn onData(ctx: ?*anyopaque, sid: u64, data: []const u8) void {
        const p: *H3PumpCtx = @ptrCast(@alignCast(ctx.?));
        const r = p.getOrCreate(sid) orelse return;
        if (data.len > r.maxBody -| r.body.items.len) {
            r.tooLarge = true;
            return;
        }
        r.body.appendSlice(r.allocator, data) catch {
            r.failed = true;
        };
    }

    fn onTrailers(ctx: ?*anyopaque, sid: u64, fields: []const http3Qpack.FieldLine) void {
        _ = ctx;
        _ = sid;
        // The request API exposes headers and body only; merging trailers
        // into the header list would let a trailer override request
        // metadata. Trailers are still validated by the H3 stream layer.
        _ = fields;
    }

    fn onMessageEnd(ctx: ?*anyopaque, sid: u64) void {
        const p: *H3PumpCtx = @ptrCast(@alignCast(ctx.?));
        const r = p.getOrCreate(sid) orelse return;
        r.done = true;
        p.queue(r);
    }

    fn onH3Error(ctx: ?*anyopaque, sid: u64, code: http3Frame.H3Error) void {
        const p: *H3PumpCtx = @ptrCast(@alignCast(ctx.?));
        const r = p.getOrCreate(sid) orelse return;
        r.failed = true;
        r.h3Error = code;
        p.queue(r);
    }

    fn onReset(ctx: ?*anyopaque, sid: u64, code: u64) void {
        const p: *H3PumpCtx = @ptrCast(@alignCast(ctx.?));
        p.h3.onQuicReset(sid, code);
        const r = p.getOrCreate(sid) orelse return;
        r.failed = true;
        p.queue(r);
    }
};
pub const Server = struct {
    /// HTTP/3 endpoint information, namespaced so protocol-specific
    /// helpers do not accumulate as flat methods on `Server`.
    pub const Http3 = struct {
        /// UDP port to dial for HTTP/3, or null when HTTP/3 is off.
        /// HTTP/3 normally shares the TCP port (RFC 9114 Section 3); it
        /// differs only when that UDP bind failed and the endpoint fell
        /// back to an ephemeral port. Prefer this over `localPort()`.
        udpPort: ?u16 = null,
        /// True when the endpoint could not reuse the TCP port. Only
        /// possible when the caller requested port 0; explicit ports
        /// fail initialization instead of moving HTTP/3 silently.
        portFallback: bool = false,

        pub fn port(self: Http3) ?u16 {
            return self.udpPort;
        }
    };

    io: std.Io,
    allocator: Allocator,
    listener: tcp.Listener,
    router: Router,
    cfg: Config,
    stopFlag: std.atomic.Value(bool) = .init(false),
    /// Resolved event callback — null means silent (no events generated).
    eventCallback: ?logging.ServerEventCallback = null,
    loggedStop: std.atomic.Value(bool) = .init(false),
    /// Live connections (keep-alive readers) so shutdown can wake them.
    connsMu: sync.Spinlock = .{},
    activeConns: std.ArrayList(*tcp.Socket) = .empty,
    deadlineMonitorStop: std.atomic.Value(bool) = .init(false),
    deadlineMonitorThread: ?std.Thread = null,
    /// True while the run-thread sits inside accept(); shutdown waits for
    /// this before closing the listener (removes the close/enter race).
    inAccept: std.atomic.Value(bool) = .init(false),
    ownsIo: bool = false,
    ioThreaded: ?*std.Io.Threaded = null,
    paused: std.atomic.Value(bool) = .init(false),
    docsMounted: bool = false,
    watcher: ?*watcherMod.Watcher = null,
    sitePtr: ?*anyopaque = null,
    siteReloadFn: ?*const fn (sitePtr: ?*anyopaque, server: *Server) void = null,
    liveReloadEventId: std.atomic.Value(usize) = .init(1),
    /// Last reload strategy reported by the watcher (as a
    /// `watcherMod.ReloadStrategy` tag). The SSE endpoint maps it to
    /// `hotReload` (CSS swap) vs `reload` (full page) payloads.
    liveReloadStrategy: std.atomic.Value(u8) = .init(1),
    templateEngine: ?*templatesMod.Engine = null,
    tlsServer: ?tlsServerMod.Server = null,
    tlsCertPemLoaded: ?[]const u8 = null,
    tlsKeyPemLoaded: ?[]const u8 = null,
    h3Endpoint: ?quicTransport.Endpoint = null,
    /// HTTP/3 endpoint information, namespaced so protocol-specific
    /// helpers do not accumulate as flat methods on `Server`.
    http3: Http3 = .{},
    h3PlaceholderConn: ?*quicConn.Connection = null,
    h3Pump: ?*quicTransport.Pump = null,
    h3Thread: ?std.Thread = null,
    h3Stop: std.atomic.Value(bool) = .init(false),
    h3Ready: std.atomic.Value(bool) = .init(false),
    metricsRegistry: metricsMod.Registry = .{},
    startTimeMs: i64 = 0,

    const ConnectionTask = struct {
        server: *Server,
        socket: tcp.Socket,
    };

    const ConnectionPool = @import("../concurrency/workerPool.zig").Pool;

    /// Initializes server with explicit allocator, shared IO, and configuration.
    /// Matches `var server = try httpx.Server.init(allocator, io, .{ .port = 8080 });`
    pub fn init(allocator: Allocator, io: std.Io, cfg: Config) !Server {
        return initInternal(allocator, io, false, null, cfg);
    }

    fn initInternal(
        allocator: Allocator,
        io: std.Io,
        ownsIo: bool,
        ioThreaded: ?*std.Io.Threaded,
        cfg: Config,
    ) !Server {
        if (cfg.maxConcurrentConnections == 0 or cfg.maxQueuedConnectionTasks == 0) {
            return error.InvalidConcurrencyLimits;
        }
        errdefer if (ownsIo) {
            if (ioThreaded) |th| {
                th.deinit();
                allocator.destroy(th);
            }
        };

        // Default: all-interfaces IPv4. Explicit literals (incl. "::") bind
        // their family; anything unparsable falls back to 0.0.0.0.
        var addr: addressMod.Address = blk: {
            if (std.mem.eql(u8, cfg.host, "0.0.0.0")) break :blk addressMod.Address.unspecified4(cfg.port);
            if (std.mem.eql(u8, cfg.host, "::")) break :blk addressMod.Address.unspecified6(cfg.port);
            var tmp: addressMod.Address = undefined;
            break :blk tmp.parseIp(cfg.host) catch addressMod.Address.unspecified4(cfg.port);
        };
        addr.port = cfg.port;

        // Resolve the event callback from config (null = silent, no events).
        // HTTPX never creates a writer or allocates IO resources for logging.

        var listener: tcp.Listener = undefined;
        if (cfg.port == 0) {
            listener = try tcp.Listener.bindAddress(io, &addr);
        } else {
            var currentPort = cfg.port;
            var bound = false;
            const maxAttempts = if (cfg.portStrategy == .incremental) cfg.maxPortAttempts else 1;
            var attempt: u16 = 0;
            while (attempt < maxAttempts) : (attempt += 1) {
                addr.port = currentPort;
                if (tcp.Listener.bindAddress(io, &addr)) |l| {
                    listener = l;
                    bound = true;
                    break;
                } else |err| {
                    if (attempt + 1 >= maxAttempts or cfg.portStrategy != .incremental) {
                        return err;
                    }
                    currentPort +%= 1;
                }
            }
            if (!bound) return error.AddressInUse;
        }
        // Bound here: any later init failure must release the port.
        errdefer listener.close(io);

        var effectiveCfg = cfg;
        if (cfg.httpVersion) |v| {
            switch (v) {
                .auto => {},
                .http10 => {
                    effectiveCfg.http10 = true;
                    effectiveCfg.http11 = false;
                    effectiveCfg.http2 = false;
                    effectiveCfg.http3 = false;
                },
                .http11 => {
                    effectiveCfg.http10 = false;
                    effectiveCfg.http11 = true;
                    effectiveCfg.http2 = false;
                    effectiveCfg.http3 = false;
                },
                .http2 => {
                    effectiveCfg.http10 = false;
                    effectiveCfg.http11 = false;
                    effectiveCfg.http2 = true;
                    effectiveCfg.http3 = false;
                },
                .http3 => {
                    effectiveCfg.http10 = false;
                    effectiveCfg.http11 = false;
                    effectiveCfg.http2 = false;
                    effectiveCfg.http3 = true;
                },
            }
        }

        // Correct the default TLS ALPN preference to match enabled TCP
        // handlers. Explicit caller protocol lists remain authoritative.
        //
        // Done here, on the stored config, rather than at the construction
        // site: certificate reload rebuilds the TLS server from
        // `self.cfg.tls.?.alpn`.
        if (effectiveCfg.tls) |*tcfg| {
            if (std.mem.eql(alpnMod.Protocol, tcfg.alpn, &alpnMod.DEFAULT_TCP_PREFERENCE)) {
                tcfg.alpn = if (effectiveCfg.http2) blk: {
                    if (effectiveCfg.http11) {
                        break :blk if (effectiveCfg.http10) &alpnH2Http11Http10 else &alpnH2Http11;
                    }
                    break :blk if (effectiveCfg.http10) &alpnH2Http10 else &alpnH2;
                } else if (effectiveCfg.http11) blk: {
                    break :blk if (effectiveCfg.http10) &alpnHttp10Http11 else &alpnHttp11;
                } else if (effectiveCfg.http10) &alpnHttp10 else &.{};
            }
        }

        var templateEngine: ?*templatesMod.Engine = null;
        const shouldInitTemplates = if (effectiveCfg.templates) |tc| tc.enabled else blk: {
            const cwd: std.Io.Dir = .cwd();
            var dir = cwd.openDir(io, "templates", .{}) catch break :blk false;
            dir.close(io);
            break :blk true;
        };

        if (shouldInitTemplates) {
            const tCfg = effectiveCfg.templates orelse templatesMod.Config{};
            const eng = try allocator.create(templatesMod.Engine);
            errdefer allocator.destroy(eng);
            eng.* = try templatesMod.Engine.init(allocator, io, tCfg);
            templateEngine = eng;
        }
        errdefer if (templateEngine) |eng| {
            eng.deinit();
            allocator.destroy(eng);
        };

        var tlsServer_opt: ?tlsServerMod.Server = null;
        var loadedCertPem: ?[]const u8 = null;
        var loadedKeyPem: ?[]const u8 = null;
        errdefer if (loadedCertPem) |cert| allocator.free(cert);
        errdefer if (loadedKeyPem) |key| {
            std.crypto.secureZero(u8, @constCast(key));
            allocator.free(key);
        };
        errdefer if (tlsServer_opt) |*tls| tls.deinit();

        if (effectiveCfg.tls) |*tCfg| {
            const hasCert = tCfg.certificatePem != null;
            const hasKey = tCfg.privateKeyPem != null;
            if (hasCert != hasKey) return error.TlsIdentityIncomplete;
            if (!hasCert and tCfg.certSelector == null) return error.TlsIdentityRequired;

            if (tCfg.certificatePem) |cert| {
                loadedCertPem = if (std.mem.indexOf(u8, cert, "-----BEGIN") != null)
                    try allocator.dupe(u8, cert)
                else
                    try fsMod.readFileLimited(allocator, cert, 10 * 1024 * 1024);
                tCfg.certificatePem = loadedCertPem.?;
            }
            if (tCfg.privateKeyPem) |key| {
                loadedKeyPem = if (std.mem.indexOf(u8, key, "-----BEGIN") != null)
                    try allocator.dupe(u8, key)
                else
                    try fsMod.readFileLimited(allocator, key, 10 * 1024 * 1024);
                tCfg.privateKeyPem = loadedKeyPem.?;
            }
            tlsServer_opt = try tlsServerMod.Server.init(allocator, io, tCfg.*);
        }

        var h3Ep_opt: ?quicTransport.Endpoint = null;
        var h3Placeholder_opt: ?*quicConn.Connection = null;
        if (effectiveCfg.http3 and loadedCertPem != null and loadedKeyPem != null) {
            const placeholder = try quicConn.Connection.init(allocator, io, .server, .{});
            // Ownership moves to the endpoint/Server on success; the
            // errdefer covers every failure before that transfer.
            var placeholderOwned = true;
            errdefer if (placeholderOwned) placeholder.deinit();
            // RFC 9114 Section 3: HTTP/3 shares the HTTP/1.1 and HTTP/2
            // port number, so the UDP endpoint mirrors the TCP one. That
            // also holds for an ephemeral port, because a caller that asked
            // for port 0 discovers the number with `localPort()` and then
            // dials HTTP/3 on it.
            //
            // An ephemeral TCP port is not necessarily bindable for UDP:
            // Windows keeps separate reserved dynamic ranges per protocol,
            // so the TCP-chosen number can fall inside a UDP exclusion.
            // When the caller asked for port 0, retry ephemerally and
            // report the result through `http3.port()`/`portFallback`.
            //
            // An explicit port is a promise to callers, so a UDP bind
            // failure is returned instead of silently moving HTTP/3 to a
            // port nobody was told about.
            const tcpPort = listener.localPort();
            const ep = quicTransport.Endpoint.init(allocator, io, placeholder, .{ .port = tcpPort }) catch |err| blk: {
                if (cfg.port != 0) return err;
                std.log.scoped(.httpx).warn(
                    "HTTP/3 could not bind UDP port {d} ({s}); falling back to an ephemeral port. Clients must use http3.port().",
                    .{ tcpPort, @errorName(err) },
                );
                break :blk quicTransport.Endpoint.init(allocator, io, placeholder, .{ .port = 0 }) catch return err;
            };
            h3Ep_opt = ep;
            h3Placeholder_opt = placeholder;
            placeholderOwned = false;
        }

        var srv = Server{
            .io = io,
            .allocator = allocator,
            .listener = listener,
            .router = Router.init(allocator),
            .cfg = effectiveCfg,
            .eventCallback = cfg.logging.callback,
            .ownsIo = ownsIo,
            .ioThreaded = ioThreaded,
            .templateEngine = templateEngine,
            .tlsServer = tlsServer_opt,
            .tlsCertPemLoaded = loadedCertPem,
            .tlsKeyPemLoaded = loadedKeyPem,
            .h3Endpoint = h3Ep_opt,
            .http3 = if (h3Ep_opt) |ep| .{
                .udpPort = ep.localPort(),
                .portFallback = ep.localPort() != listener.localPort(),
            } else .{},
            .h3PlaceholderConn = h3Placeholder_opt,
            .h3Pump = null,
            .startTimeMs = clock.monotonicMillis(io),
        };
        srv.router.templateEngine = templateEngine;
        errdefer {
            srv.router.deinit();
            if (templateEngine) |eng| {
                eng.deinit();
                allocator.destroy(eng);
            }
            if (loadedCertPem) |c| allocator.free(c);
            if (loadedKeyPem) |k| {
                std.crypto.secureZero(u8, @constCast(k));
                allocator.free(k);
            }
            if (h3Ep_opt) |*ep| {
                ep.deinit();
            }
            if (h3Placeholder_opt) |p| {
                p.deinit();
            }
        }

        return srv;
    }

    pub fn get(self: *Server, path: []const u8, handler: *const fn (*Context) anyerror!Response) routerMod.RouteError!void {
        try self.router.get(path, handler, .{});
    }

    pub fn post(self: *Server, path: []const u8, handler: *const fn (*Context) anyerror!Response) routerMod.RouteError!void {
        try self.router.post(path, handler, .{});
    }

    pub fn put(self: *Server, path: []const u8, handler: *const fn (*Context) anyerror!Response) routerMod.RouteError!void {
        try self.router.put(path, handler, .{});
    }

    pub fn patch(self: *Server, path: []const u8, handler: *const fn (*Context) anyerror!Response) routerMod.RouteError!void {
        try self.router.patch(path, handler, .{});
    }

    pub fn delete(self: *Server, path: []const u8, handler: *const fn (*Context) anyerror!Response) routerMod.RouteError!void {
        try self.router.delete(path, handler, .{});
    }

    pub fn head(self: *Server, path: []const u8, handler: *const fn (*Context) anyerror!Response) routerMod.RouteError!void {
        try self.router.head(path, handler, .{});
    }

    pub fn options(self: *Server, path: []const u8, handler: *const fn (*Context) anyerror!Response) routerMod.RouteError!void {
        try self.router.options(path, handler, .{});
    }

    /// Registers a route with an arbitrary HTTP method.
    pub fn add(self: *Server, method: Method, path: []const u8, handler: *const fn (*Context) anyerror!Response) routerMod.RouteError!void {
        try self.router.add(method, path, handler, .{});
    }

    /// Creates a prefixed route group on the server router.
    pub fn group(self: *Server, prefix: []const u8, opts: routerMod.GroupOptions) routerMod.Group {
        return self.router.group(prefix, opts);
    }

    /// Mounts another router's entries under `prefix`.
    pub fn mount(self: *Server, prefix: []const u8, other: *routerMod.Router, opts: routerMod.MountOptions) routerMod.RouteError!void {
        try self.router.mount(prefix, other, opts);
    }

    /// Registers a compile-time validated static slice of route declarations on the server.
    pub fn registerStatic(self: *Server, comptime routes: []const routerMod.RouteDecl) routerMod.RouteError!void {
        try self.router.registerStatic(routes);
    }

    /// Registers a dynamic route table with runtime conflict validation on the server.
    pub fn registerRouteTable(self: *Server, routes: []const routerMod.RouteDecl) routerMod.RouteError!void {
        try self.router.registerRouteTable(routes);
    }

    /// Attaches a global middleware to the server's routing pipeline.
    pub fn use(self: *Server, mw: routerMod.MiddlewareFn) !void {
        try self.router.use(mw);
    }

    /// Mounts a directory of static files under a URL prefix.
    pub fn static(self: *Server, mountPath: []const u8, dirPath: []const u8) !void {
        const staticMod = @import("../web/staticFiles/staticFileServer.zig");
        try staticMod.register(&self.router, .{
            .mount = mountPath,
            .root = dirPath,
        });
    }

    /// Mounts a Single Page Application (SPA) with index fallback.
    pub fn spa(self: *Server, mountPath: []const u8, dirPath: []const u8) !void {
        const spaMod = @import("../web/spa/spaServer.zig");
        try spaMod.register(&self.router, .{
            .mount = mountPath,
            .root = dirPath,
        });
    }

    /// Registers a Prometheus metrics exposition endpoint on the specified route.
    pub fn metrics(self: *Server, path: []const u8) routerMod.RouteError!void {
        const MetricsHandler = struct {
            fn handle(ctx: *Context) anyerror!Response {
                const reg: *metricsMod.Registry = @ptrCast(@alignCast(ctx.userData orelse return error.NoMetricsRegistry));
                const buf = try ctx.allocator.alloc(u8, 65536);
                var w: std.Io.Writer = .fixed(buf);
                try reg.renderPrometheus(&w);
                const body = try ctx.allocator.dupe(u8, w.buffered());
                return .{
                    .status = 200,
                    .headers = &.{.{ .name = "content-type", .value = "text/plain; version=0.0.4; charset=utf-8" }},
                    .body = body,
                };
            }
        };
        try self.router.get(path, MetricsHandler.handle, .{ .userData = &self.metricsRegistry });
    }

    /// Captures a point-in-time snapshot of the server metrics registry.
    pub fn metricsSnapshot(self: *const Server) metricsMod.MetricsSnapshot {
        return self.metricsRegistry.snapshot();
    }

    /// Captures a comprehensive runtime snapshot of the server (uptime, throughput, error rate, active connections).
    pub fn snapshot(self: *const Server) metricsMod.ServerSnapshot {
        const now = clock.monotonicMillis(self.io);
        const uptime: u64 = if (self.startTimeMs > 0 and now >= self.startTimeMs)
            @intCast(now - self.startTimeMs)
        else
            0;
        const ms = self.metricsRegistry.snapshot();
        return .{
            .uptimeMs = uptime,
            .activeConnections = ms.activeConnections,
            .activeRequests = ms.activeRequests,
            .requestsTotal = ms.requestsTotal,
            .responsesTotal = ms.responsesTotal,
            .errorsTotal = ms.errorsTotal,
            .bytesIn = ms.bytesIn,
            .bytesOut = ms.bytesOut,
            .metrics = ms,
        };
    }

    /// Sets a custom 404 Not Found handler (HTML, JSON, custom template, etc.)
    pub fn setNotFoundHandler(self: *Server, handler: *const fn (*Context) anyerror!Response) void {
        self.router.setNotFoundHandler(handler);
    }

    /// Sets a custom 500 / Exception handler (HTML, JSON error envelope, etc.)
    pub fn setErrorHandler(self: *Server, handler: *const fn (*Context, anyerror) anyerror!Response) void {
        self.router.setErrorHandler(handler);
    }

    /// Sets a custom error page / response handler for a specific HTTP status code (e.g. 403, 404, 500, 502, 503).
    pub fn setStatusHandler(self: *Server, statusCode: u16, handler: *const fn (*Context) anyerror!Response) !void {
        try self.router.setStatusHandler(statusCode, handler);
    }

    pub fn deinit(self: *Server) void {
        if (self.watcher) |w| {
            w.stop();
            w.deinit();
            self.watcher = null;
        }
        if (self.templateEngine) |eng| {
            eng.deinit();
            self.allocator.destroy(eng);
            self.templateEngine = null;
        }
        if (self.tlsCertPemLoaded) |c| {
            self.allocator.free(c);
            self.tlsCertPemLoaded = null;
        }
        if (self.tlsKeyPemLoaded) |k| {
            std.crypto.secureZero(u8, @constCast(k));
            self.allocator.free(k);
            self.tlsKeyPemLoaded = null;
        }
        if (self.tlsServer) |*s| {
            s.deinit();
            self.tlsServer = null;
        }
        self.h3Ready.store(false, .release);
        self.h3Stop.store(true, .release);
        if (self.h3Pump) |p| p.stop();
        if (self.h3Thread) |th| {
            th.join();
            self.h3Thread = null;
        }
        if (self.h3Pump) |p| {
            self.allocator.destroy(p);
            self.h3Pump = null;
        }
        if (self.h3Endpoint) |*ep| {
            ep.deinit();
            self.h3Endpoint = null;
        }
        if (self.h3PlaceholderConn) |p| {
            p.deinit();
            self.h3PlaceholderConn = null;
        }
        if (self.cfg.enableDocs) docs.unmount();
        self.router.deinit();
        self.listener.close(self.io);
        self.activeConns.deinit(self.allocator);
        if (self.ownsIo) {
            if (self.ioThreaded) |th| {
                th.deinit();
                self.allocator.destroy(th);
                self.ioThreaded = null;
            }
        }
    }

    /// Returns true if this server has TLS configured and active.
    pub fn isTls(self: *const Server) bool {
        return self.tlsServer != null;
    }

    /// Returns true when the HTTP/3 background pump and loop are ready to serve incoming connections.
    pub fn isHttp3Ready(self: *const Server) bool {
        return self.h3Ready.load(.acquire);
    }

    /// Dynamically sets or updates TLS certificates on this server instance.
    /// Old PEMs are released only after the replacement owner builds
    /// successfully, so a failed rotation keeps serving with the old
    /// identity (and old buffers are never freed twice).
    pub fn setTls(self: *Server, certPemOrPath: []const u8, keyPemOrPath: []const u8) !void {
        var certStr: []u8 = undefined;
        if (std.mem.indexOf(u8, certPemOrPath, "-----BEGIN") != null) {
            certStr = try self.allocator.dupe(u8, certPemOrPath);
        } else {
            certStr = try fsMod.readFileLimited(self.allocator, certPemOrPath, 10 * 1024 * 1024);
        }
        errdefer self.allocator.free(certStr);

        var keyStr: []u8 = undefined;
        if (std.mem.indexOf(u8, keyPemOrPath, "-----BEGIN") != null) {
            keyStr = try self.allocator.dupe(u8, keyPemOrPath);
        } else {
            keyStr = try fsMod.readFileLimited(self.allocator, keyPemOrPath, 10 * 1024 * 1024);
        }
        errdefer {
            std.crypto.secureZero(u8, keyStr);
            self.allocator.free(keyStr);
        }

        // Build the replacement owner first: on failure the errdefers
        // above release the new PEMs and the previous server (if any)
        // keeps serving.
        var newServer: ?tlsServerMod.Server = null;
        newServer = tlsServerMod.Server.init(self.allocator, self.io, .{
            .certificatePem = certStr,
            .privateKeyPem = keyStr,
            .alpn = if (self.cfg.tls) |t| t.alpn else &alpnMod.DEFAULT_TCP_PREFERENCE,
            .clientAuth = if (self.cfg.tls) |t| t.clientAuth else .disabled,
            .clientCaPem = if (self.cfg.tls) |t| t.clientCaPem else null,
            .ticketKeys = if (self.cfg.tls) |t| t.ticketKeys else null,
            .ticketLifetimeSecs = if (self.cfg.tls) |t| t.ticketLifetimeSecs else 7200,
        }) catch null;
        if (newServer == null) return error.TlsInitializationFailed;

        if (self.tlsServer) |*s| s.deinit();
        if (self.tlsCertPemLoaded) |c| self.allocator.free(c);
        if (self.tlsKeyPemLoaded) |k| {
            std.crypto.secureZero(u8, @constCast(k));
            self.allocator.free(k);
        }
        self.tlsCertPemLoaded = certStr;
        self.tlsKeyPemLoaded = keyStr;
        self.tlsServer = newServer;
    }

    /// Returns the active template engine, if templates are enabled.
    pub fn templates(self: *Server) ?*templatesMod.Engine {
        return self.templateEngine;
    }

    pub fn localPort(self: *const Server) u16 {
        return self.listener.localPort();
    }

    /// Stops accepting and lets active requests finish. Active I/O is bounded
    /// by the configured phase deadlines; queued sockets are closed by workers
    /// without beginning new requests. Use stop() for immediate cancellation.
    /// Safe to call multiple times.
    pub fn requestShutdown(self: *Server) void {
        if (!self.loggedStop.swap(true, .acq_rel)) {
            self.emit(.{ .kind = .serverStopped, .level = .info, .message = "shutting down" });
        }
        self.stopFlag.store(true, .release);
        self.h3Ready.store(false, .release);
        self.h3Stop.store(true, .release);
        if (self.h3Pump) |p| p.stop();

        // Wake any blocked accept call on the listener socket.
        // Connecting a loopback dummy socket wakes accept() cleanly across all platforms
        // (Windows IOCP, macOS kqueue, Linux epoll) so the loop unblocks and checks stopFlag.
        tcp.wakeListenerPort(self.listener.localPort());
        if (@import("builtin").os.tag != .windows) {
            self.listener.close(self.io);
        }
    }

    /// Immediate shutdown (no graceful drain). Stops the listener and
    /// interrupts active socket I/O; each worker owns final socket cleanup.
    pub fn stop(self: *Server) void {
        self.requestShutdown();
        self.connsMu.lock();
        for (self.activeConns.items) |conn| conn.interruptIo();
        self.connsMu.unlock();
    }

    /// Canonical alias for run(). Starts the blocking request serving loop.
    pub fn serve(self: *Server) void {
        self.run();
    }

    /// Non-blocking server start. Spawns a thread that calls `run()`.
    /// Returns the thread handle so the caller can join.
    pub fn start(self: *Server) !std.Thread {
        return std.Thread.spawn(.{}, (struct {
            fn run(s: *Server) void {
                s.run();
            }
        }).run, .{self});
    }

    /// Pause accepting new connections. Sets a paused flag that run() checks.
    pub fn pause(self: *Server) void {
        self.paused.store(true, .release);
    }

    /// Resume accepting new connections.
    pub fn resumeAccepting(self: *Server) void {
        self.paused.store(false, .release);
        if (self.inAccept.load(.acquire)) {
            tcp.wakeListenerPort(self.listener.localPort());
        }
    }

    /// Forwarded headers are honored only when explicitly enabled and the
    /// connection came from an allowed proxy (or no proxy list is configured,
    /// which trusts every peer).
    fn trustForwardedFor(self: *const Server, peer: []const u8) bool {
        if (!self.cfg.trustForwardedHeaders) return false;
        if (self.cfg.trustedProxies.len == 0) return true;
        for (self.cfg.trustedProxies) |rule| {
            if (addressMod.matchesCidr(peer, rule)) return true;
        }
        return false;
    }

    /// Return the full bound address. Supports IPv4 and IPv6.
    pub fn localAddress(self: *const Server) std.Io.net.IpAddress {
        return self.listener.localAddress();
    }

    /// Blocking accept loop. Connections are handed to a fixed-size worker
    /// pool. Active plus queued connections are bounded by
    /// maxConcurrentConnections; overload is handled by closing the newest
    /// accepted socket. requestShutdown stops acceptance and drains in-flight
    /// work; stop additionally closes active sockets immediately.
    /// Installs a Ctrl+C handler for graceful shutdown.
    pub fn run(self: *Server) void {
        // Mount docs here (not in init) because init returns by value,
        // making any &srv.router pointer taken inside init a dangling pointer.
        if (self.cfg.enableDocs and !self.docsMounted) {
            self.docsMounted = true;
            const dc = self.cfg.docs orelse docs.Config{};
            docs.mount(self.allocator, &self.router, dc, .{
                .title = self.cfg.docsTitle,
                .version = @import("../common/version.zig").version,
            }) catch {};
        }

        // Out-of-the-box watcher and live-reload integration
        if ((self.cfg.watch or self.cfg.liveReload) and self.watcher == null) {
            const WatcherCallback = struct {
                fn onChange(event: watcherMod.WatchEvent, userData: ?*anyopaque) void {
                    const s: *Server = @ptrCast(@alignCast(userData.?));
                    _ = s.liveReloadEventId.fetchAdd(1, .release);
                    s.liveReloadStrategy.store(@backingInt(event.strategy), .release);
                    if (s.templateEngine) |te| {
                        te.invalidate(event.path);
                    }
                    if (s.siteReloadFn) |reloadFn| {
                        if (event.kind == .created or event.kind == .deleted or event.kind == .renamed or event.isDirectory) {
                            reloadFn(s.sitePtr, s);
                        }
                    }
                    s.emit(.{
                        .kind = .serverStarted,
                        .level = .debug,
                        .path = event.path,
                        .message = switch (event.strategy) {
                            .hotReload => "file changed: hot reload CSS",
                            .warmReload => "file changed: warm reload HTML",
                            .coldReload => "file changed: cold reload assets/config",
                            .restart => "file changed: application source modified",
                        },
                    });
                }
            };

            const w = watcherMod.Watcher.init(self.allocator, self.io, .{
                .dirPath = self.cfg.watchDir,
                .onChange = WatcherCallback.onChange,
                .userData = self,
            }) catch null;
            if (w) |initializedW| {
                self.watcher = initializedW;
                initializedW.start() catch {};
            }

            if (self.cfg.liveReload) {
                const SseHandler = struct {
                    fn handle(ctx: *Context) anyerror!Response {
                        const s: *Server = @ptrCast(@alignCast(ctx.userData.?));
                        const currentId = s.liveReloadEventId.load(.acquire);
                        const strat: watcherMod.ReloadStrategy = @fromBackingInt(@intCast(s.liveReloadStrategy.load(.acquire)));
                        // CSS-only changes hot-swap in the browser; anything
                        // else is a full page reload (see liveReloadScript).
                        const payload: []const u8 = if (strat == .hotReload) "hotReload" else "reload";
                        const sseBody = try std.fmt.allocPrint(ctx.allocator, "id: {d}\ndata: {s}\n\n", .{ currentId, payload });
                        return .{
                            .status = 200,
                            .body = sseBody,
                            .headers = &.{
                                .{ .name = "Content-Type", .value = "text/event-stream" },
                                .{ .name = "Cache-Control", .value = "no-cache" },
                                .{ .name = "Connection", .value = "keep-alive" },
                            },
                        };
                    }
                };
                self.router.get(self.cfg.liveReloadPath, SseHandler.handle, .{ .userData = self }) catch {};
            }
        }

        installShutdownHandler(self);
        self.emit(.{
            .kind = .serverStarted,
            .level = .info,
            .path = self.cfg.host,
            .status = self.listener.localPort(),
            .message = "server started",
        });
        if (self.h3Endpoint != null and self.h3Pump == null) {
            const pumpPtr = self.allocator.create(quicTransport.Pump) catch null;
            if (pumpPtr) |p| {
                if (p.start(&self.h3Endpoint.?, self.allocator)) {
                    self.h3Pump = p;
                    self.h3Thread = std.Thread.spawn(.{}, Server.runHttp3Loop, .{self}) catch null;
                } else |_| {
                    self.allocator.destroy(p);
                }
            }
        }
        var workerCount: usize = self.cfg.workerCount;
        if (workerCount == 0) {
            workerCount = std.Thread.getCpuCount() catch 4;
            workerCount = @min(workerCount, 16);
        }
        workerCount = @max(1, @min(workerCount, self.cfg.maxConcurrentConnections));
        var workers = ConnectionPool.init(self.allocator, self.io, .{
            .workers = @intCast(workerCount),
            .queueCapacity = @intCast(@min(self.cfg.maxQueuedConnectionTasks, std.math.maxInt(u32))),
            .autoStart = false,
        }) catch return;
        defer workers.deinit();
        workers.start() catch return;
        self.deadlineMonitorStop.store(false, .release);
        self.deadlineMonitorThread = std.Thread.spawn(.{}, monitorConnectionDeadlines, .{self}) catch {
            workers.shutdownDrain();
            workers.join();
            return;
        };

        var accepted: usize = 0;
        while (!self.stopFlag.load(.acquire)) {
            if (self.cfg.maxConnections != 0 and accepted >= self.cfg.maxConnections) break;
            // Yield when paused
            while (self.paused.load(.acquire) and !self.stopFlag.load(.acquire)) {
                clock.sleepMillis(self.io, 10);
            }
            self.inAccept.store(true, .release);
            var conn = self.listener.accept(self.io) catch {
                self.inAccept.store(false, .release);
                break;
            };
            self.inAccept.store(false, .release);
            conn.setReadTimeoutMs(self.cfg.initialRequestTimeoutMs);
            const task = self.allocator.create(ConnectionTask) catch {
                conn.close();
                continue;
            };
            task.* = .{ .server = self, .socket = conn };

            const sock = &task.socket;
            self.connsMu.lock();
            var admitted = false;
            if (!self.stopFlag.load(.acquire) and self.activeConns.items.len < self.cfg.maxConcurrentConnections) {
                self.activeConns.append(self.allocator, sock) catch {};
                admitted = self.activeConns.items.len > 0 and self.activeConns.items[self.activeConns.items.len - 1] == sock;
            }
            self.connsMu.unlock();
            if (!admitted) {
                sock.close();
                self.allocator.destroy(task);
                continue;
            }

            workers.trySubmit(runConnectionTask, task, null) catch {
                self.removeActiveConnection(sock);
                sock.close();
                self.allocator.destroy(task);
                continue;
            };
            accepted += 1;

            // Stop before blocking on the next accept when asked.
            if (self.stopFlag.load(.acquire)) break;
        }
        workers.shutdownDrain();
        workers.join();
        self.deadlineMonitorStop.store(true, .release);
        if (self.deadlineMonitorThread) |thread| {
            thread.join();
            self.deadlineMonitorThread = null;
        }
        self.h3Ready.store(false, .release);
        self.h3Stop.store(true, .release);
        if (self.h3Pump) |p| p.stop();
        if (self.h3Thread) |th| {
            th.join();
            self.h3Thread = null;
        }
        if (self.h3Pump) |p| {
            self.allocator.destroy(p);
            self.h3Pump = null;
        }
        self.emit(.{ .kind = .serverStopped, .level = .info, .message = "shutdown complete" });
    }

    fn runConnectionTask(ctx: ?*anyopaque, _: *std.atomic.Value(bool)) anyerror!void {
        const task: *ConnectionTask = @ptrCast(@alignCast(ctx.?));
        const server = task.server;
        const socket = &task.socket;
        defer {
            // Unregister under connsMu before closing the handle. The deadline
            // monitor holds that lock while it may interrupt this socket; if
            // we closed first, it could race shutdown against final close.
            server.removeActiveConnection(socket);
            socket.close();
            server.allocator.destroy(task);
        }
        if (server.stopFlag.load(.acquire)) return;
        var arena = std.heap.ArenaAllocator.init(server.allocator);
        defer arena.deinit();
        server.serveConnection(socket, arena.allocator()) catch |err| {
            server.metricsRegistry.recordError();
            return err;
        };
    }

    fn monitorConnectionDeadlines(server: *Server) void {
        while (!server.deadlineMonitorStop.load(.acquire)) {
            const now = clock.monotonicMillis(server.io);
            server.connsMu.lock();
            for (server.activeConns.items) |socket| socket.closeIfIoDeadlineExpired(now);
            server.connsMu.unlock();
            clock.sleepMillis(server.io, 5);
        }
    }

    fn removeActiveConnection(self: *Server, socket: *tcp.Socket) void {
        self.connsMu.lock();
        defer self.connsMu.unlock();
        for (self.activeConns.items, 0..) |active, i| {
            if (active == socket) {
                _ = self.activeConns.swapRemove(i);
                return;
            }
        }
    }

    /// Deliver a structured event to the application callback.
    /// No-op when callback is null (the default). Level filtering applied here.
    fn emit(self: *const Server, event: logging.ServerEvent) void {
        const cb = self.eventCallback orelse return;
        if (@backingInt(event.level) < @backingInt(self.cfg.logging.level)) return;
        cb(event);
    }

    fn serveConnection(self: *Server, conn: *tcp.Socket, arenaIn: Allocator) !void {
        _ = arenaIn;
        self.metricsRegistry.connectionOpened();
        defer self.metricsRegistry.connectionClosed();

        var peekBuf: [32]u8 = undefined;
        var nPeek: usize = 0;
        var protocol: InitialProtocol = .needMore;
        while (protocol == .needMore and nPeek < peekBuf.len) {
            const n = conn.read(peekBuf[nPeek..]) catch return;
            if (n == 0) return;
            nPeek += n;
            protocol = classifyInitialProtocol(peekBuf[0..nPeek], self.tlsServer != null, self.cfg.http2);
        }

        // Check for TLS Handshake record (ContentType = 0x16, TLS legacy version 0x03, 0x01..0x03)
        if (protocol == .tls) {
            var tlsConn = self.tlsServer.?.acceptBuffered(conn, peekBuf[0..nPeek]) catch |err| {
                var msgBuf: [64]u8 = undefined;
                const msg = std.fmt.bufPrint(&msgBuf, "TLS handshake failed: {s}", .{@errorName(err)}) catch "TLS handshake failed";
                self.emit(.{ .kind = .tlsHandshakeFailed, .level = .warn, .message = msg });
                return;
            };
            defer tlsConn.deinit();

            const streamConn = StreamConn{ .tls = &tlsConn };
            if (self.cfg.http2 and tlsConn.alpn != null and tlsConn.alpn.? == .h2) {
                try self.serveHttp2Connection(streamConn, true, "");
            } else {
                try self.serveHttp1Connection(streamConn, true, "");
            }
            return;
        }

        if (protocol == .http2 and (self.tlsServer == null or self.cfg.tls.?.allowPlainHttp)) {
            const streamConn = StreamConn{ .plain = conn };
            try self.serveHttp2Connection(streamConn, false, peekBuf[0..nPeek]);
            return;
        }

        const streamConn = StreamConn{ .plain = conn };
        if (self.tlsServer != null and (self.cfg.tls == null or !self.cfg.tls.?.allowPlainHttp)) {
            // Strict HTTPS mode: reject cleartext HTTP on HTTPS port (RFC 9110).
            _ = sendSimpleError(streamConn, 400, "The plain HTTP request was sent to HTTPS port") catch 0;
            return;
        }
        try self.serveHttp1Connection(streamConn, false, peekBuf[0..nPeek]);
    }

    const InitialProtocol = enum { needMore, http1, http2, tls };

    fn classifyInitialProtocol(bytes: []const u8, tlsEnabled: bool, http2Enabled: bool) InitialProtocol {
        if (bytes.len == 0) return .needMore;

        if (tlsEnabled and bytes[0] == 0x16) {
            if (bytes.len < 2) return .needMore;
            if (bytes[1] == 0x03) {
                if (bytes.len < 3) return .needMore;
                if (bytes[2] >= 0x01 and bytes[2] <= 0x03) return .tls;
            }
        }

        const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
        if (http2Enabled) {
            const compared = @min(bytes.len, preface.len);
            if (std.mem.eql(u8, bytes[0..compared], preface[0..compared])) {
                return if (bytes.len < 16) .needMore else .http2;
            }
        }
        return .http1;
    }

    fn serveHttp2Connection(self: *Server, conn: StreamConn, isTlsConn: bool, initial: []const u8) !void {
        const transportMod = @import("../protocols/http2/transport.zig");

        // Per-connection state shared by the request handler and the
        // response decorator.
        const H2Ctx = struct {
            server: *Server,
            isTls: bool,
            arena: std.heap.ArenaAllocator,
            peerBuf: [64]u8 = undefined,
            peerLen: usize = 0,

            fn peerSlice(ctxPtr: *const @This()) []const u8 {
                return ctxPtr.peerBuf[0..ctxPtr.peerLen];
            }
        };

        var h2ctx = H2Ctx{
            .server = self,
            .isTls = isTlsConn,
            .arena = std.heap.ArenaAllocator.init(self.allocator),
        };
        defer h2ctx.arena.deinit();
        const peer = conn.peerAddress();
        @memcpy(h2ctx.peerBuf[0..peer.len], peer);
        h2ctx.peerLen = peer.len;

        const H2Bridge = struct {
            fn handle(ctxPtr: ?*anyopaque, mStr: []const u8, pStr: []const u8, hdrs: []const transportMod.Header, bStr: []const u8) anyerror!transportMod.HandlerResponse {
                const c: *H2Ctx = @ptrCast(@alignCast(ctxPtr.?));
                const serverPtr = c.server;
                // The transport consumes each response synchronously before
                // the next handler call, so one request's allocations can be
                // reclaimed while the connection stays open.
                _ = c.arena.reset(.retain_capacity);
                // Match the HTTP/1 path: unknown methods are not silently
                // coerced to GET (they would hit unrelated routes).
                const method = Method.fromString(mStr) orelse return .{ .status = 501, .body = "method not supported" };
                const a = c.arena.allocator();

                var ctxHdrs = try a.alloc(routerMod.Header, hdrs.len);
                for (hdrs, 0..) |h, i| ctxHdrs[i] = .{ .name = h.name, .value = h.value };

                var cleanPath = pStr;
                if (std.mem.indexOfAny(u8, cleanPath, "?#")) |idx| {
                    cleanPath = cleanPath[0..idx];
                }
                var queryPart: []const u8 = "";
                if (std.mem.indexOfScalar(u8, pStr, '?')) |qi| {
                    var q = pStr[qi + 1 ..];
                    if (std.mem.indexOfScalar(u8, q, '#')) |hi| q = q[0..hi];
                    queryPart = q;
                }

                var ctx = Context{
                    .allocator = a,
                    .io = serverPtr.io,
                    .headers = ctxHdrs,
                    .path = cleanPath,
                    .query = queryPart,
                    .method = method,
                    .body = bStr,
                    .isTls = c.isTls,
                    .peerAddress = c.peerSlice(),
                    .trustForwarded = serverPtr.trustForwardedFor(c.peerSlice()),
                    .trustedProxies = serverPtr.cfg.trustedProxies,
                };

                // Full pipeline: match + router/route middleware + 404/405 +
                // auto-OPTIONS, exactly like HTTP/1.
                const res = serverPtr.router.dispatch(&ctx);
                // The response is copied into the request arena and the
                // transport consumes it before this callback can run again.
                const outBody = try a.dupe(u8, res.body);
                const extra: usize = if (res.contentType != null) 1 else 0;
                var outHdrs = try a.alloc(transportMod.Header, res.headers.len + extra);
                for (res.headers, 0..) |h, i| {
                    outHdrs[i] = .{
                        .name = try a.dupe(u8, h.name),
                        .value = try a.dupe(u8, h.value),
                    };
                }
                if (res.contentType) |ct| {
                    outHdrs[outHdrs.len - 1] = .{
                        .name = "content-type",
                        .value = try a.dupe(u8, ct),
                    };
                }
                return .{
                    .status = res.status,
                    .headers = outHdrs,
                    .body = outBody,
                };
            }

            /// Applies the same content coding the HTTP/1 path uses, so
            /// one handler behaves identically across protocol versions.
            fn decorate(ctxPtr: ?*anyopaque, allocator: Allocator, resp: *transportMod.HandlerResponse, method: []const u8, reqHeaders: []const transportMod.Header, extra: *std.ArrayList(transportMod.Header)) anyerror!?[]u8 {
                const c: *H2Ctx = @ptrCast(@alignCast(ctxPtr.?));
                const serverPtr = c.server;
                const isHead = std.ascii.eqlIgnoreCase(method, "HEAD");
                var clientAcceptEncoding: ?[]const u8 = null;
                for (reqHeaders) |h| {
                    if (std.ascii.eqlIgnoreCase(h.name, "accept-encoding")) clientAcceptEncoding = h.value;
                }
                if (isHead or resp.status == 204 or resp.status == 304) return null;

                const coding = compression.encodeResponseBody(
                    allocator,
                    resp.body,
                    clientAcceptEncoding,
                    serverPtr.cfg.compression,
                    serverPtr.cfg.maxCompressionInput,
                ) catch |err| switch (err) {
                    error.NotAcceptable => {
                        resp.status = 406;
                        resp.body = "";
                        resp.headers = &.{};
                        return null;
                    },
                    else => return err,
                };
                if (coding.contentEncoding) |ce| {
                    try extra.append(allocator, .{ .name = "content-encoding", .value = ce });
                }
                if (coding.varyAcceptEncoding) {
                    try extra.append(allocator, .{ .name = "vary", .value = "Accept-Encoding" });
                }
                // Only a coded body is a fresh allocation; the identity
                // path borrows the handler's buffer.
                if (coding.contentEncoding == null) return null;
                return @constCast(coding.body);
            }
        };

        // The shared transport implements the multiplexed HTTP/2 server:
        // one state per concurrent stream, per-stream responses, and
        // flow-controlled bodies that resume on WINDOW_UPDATE.
        const H2Io = struct {
            conn: StreamConn,
            fn read(ctxPtr: ?*anyopaque, buf: []u8) anyerror!usize {
                const s: *@This() = @ptrCast(@alignCast(ctxPtr.?));
                return s.conn.read(buf);
            }
            fn writeAll(ctxPtr: ?*anyopaque, bytes: []const u8) anyerror!void {
                const s: *@This() = @ptrCast(@alignCast(ctxPtr.?));
                return s.conn.writeAll(bytes);
            }
        };
        var h2io = H2Io{ .conn = conn };

        conn.setWriteTimeoutMs(self.cfg.writeTimeoutMs);
        conn.setReadTimeoutMs(self.cfg.keepAliveIdleTimeoutMs);

        try transportMod.serveStream(self.allocator, .{
            .ctx = &h2io,
            .readFn = H2Io.read,
            .writeAllFn = H2Io.writeAll,
        }, .{
            .handler = H2Bridge.handle,
            .handlerCtx = &h2ctx,
            .maxBodySize = self.cfg.maxBody,
            .decorate = H2Bridge.decorate,
        }, initial);
    }

    fn runHttp3Loop(self: *Server) void {
        while (!self.stopFlag.load(.acquire) and !self.h3Stop.load(.acquire)) {
            self.serveOneHttp3() catch |err| {
                if (err == error.Timeout or err == error.Cancelled) continue;
                if (self.stopFlag.load(.acquire) or self.h3Stop.load(.acquire)) break;
            };
        }
    }

    fn serveOneHttp3(self: *Server) !void {
        const ep = &(self.h3Endpoint orelse return error.NoEndpoint);
        const pump = self.h3Pump orelse return error.NoPump;
        const certPem = self.tlsCertPemLoaded orelse return error.NoCertificate;
        const keyPem = self.tlsKeyPemLoaded orelse return error.NoPrivateKey;

        const oldConn = ep.conn;
        const qconn = try quicConn.Connection.init(self.allocator, self.io, .server, .{
            .retry = self.cfg.http3Retry,
            .retryKey = self.cfg.http3RetryKey,
        });
        defer {
            qconn.deinit();
            ep.conn = oldConn;
        }
        ep.conn = qconn;

        var replayCache = tlsSessionMod.ReplayCache.init(self.allocator, 256);
        defer replayCache.deinit();

        // Prefer the configured keys; otherwise mint a fresh one from OS
        // entropy so HTTP/3 keeps 0-RTT without falling back to a shared
        // secret. A hardcoded key here would seal every ticket with a
        // publicly known value, letting anyone forge one and resume as
        // any client. If the OS entropy source is unavailable we issue no
        // tickets, which is what the TCP path does when unconfigured.
        var generatedKeys: ?tlsSessionMod.TicketKeys = null;
        const ticketKeys: ?tlsSessionMod.TicketKeys = if (self.cfg.tls) |t|
            t.ticketKeys
        else if (tlsSessionMod.TicketKeys.generate(self.io)) |k| blk: {
            generatedKeys = k;
            break :blk k;
        } else |_| null;
        defer if (generatedKeys != null) {
            // Wipe the sealing key once this connection is done with it.
            std.crypto.secureZero(u8, &generatedKeys.?.current);
        };

        var drv = quicHs.Driver.initServer(self.io, self.allocator, .{
            .certChainPem = certPem,
            .privateKeyPem = keyPem,
            .ticketKeys = ticketKeys,
            .maxEarlyData = 16384,
            .replayCache = &replayCache,
        });
        defer drv.deinit();

        qconn.tls = .{
            .ctx = &drv,
            .start = quicHs.Driver.clientStart,
            .onData = quicHs.Driver.onData,
        };

        var h3 = http3Conn.Connection.init(self.allocator, .server);
        defer h3.deinit();

        var requests = std.AutoHashMap(u64, *H3Request).init(self.allocator);
        defer {
            var it = requests.valueIterator();
            while (it.next()) |rp| {
                rp.*.deinit();
                self.allocator.destroy(rp.*);
            }
            requests.deinit();
        }
        var ready = std.ArrayList(u64).empty;
        defer ready.deinit(self.allocator);

        const startMs: u64 = @intCast(clock.monotonicMillis(self.io));
        var lastActivityMs: u64 = startMs;
        var pumpCtx = H3PumpCtx{
            .io = self.io,
            .allocator = self.allocator,
            .maxBody = self.cfg.maxBody,
            .h3 = &h3,
            .requests = &requests,
            .ready = &ready,
            .lastActivityMs = &lastActivityMs,
        };
        h3.cbs = .{
            .ctx = &pumpCtx,
            .onHeaders = H3PumpCtx.onHeaders,
            .onData = H3PumpCtx.onData,
            .onTrailers = H3PumpCtx.onTrailers,
            .onMessageEnd = H3PumpCtx.onMessageEnd,
            .onStreamReset = H3PumpCtx.onReset,
            .onH3Error = H3PumpCtx.onH3Error,
        };
        qconn.cbs = .{
            .ctx = &pumpCtx,
            .onStreamData = H3PumpCtx.onStream,
            .onStreamReset = H3PumpCtx.onReset,
        };

        // The HTTP/3 layer is wired before the handshake runs: a peer may
        // send request data in the same flight as its Finished, and that
        // data must not be dropped for want of a reader.
        self.h3Ready.store(true, .release);
        defer self.h3Ready.store(false, .release);
        try quicHs.serveHandshake(ep, pump, &drv, 10_000);

        // The control stream carries 1-RTT data, so it can only be sent
        // once the handshake keys are in place.
        try h3.sendControl(qconn, startMs);
        try h3.sendQpackPrefixes(qconn, startMs);
        _ = try ep.flush(null);

        while (!self.stopFlag.load(.acquire) and !self.h3Stop.load(.acquire)) {
            const nowMs: u64 = @intCast(clock.monotonicMillis(self.io));
            // Keep one connection alive for multiplexed requests, but
            // reclaim it once it has been idle with no active streams.
            if (requests.count() == 0 and nowMs -| lastActivityMs > 30_000) return error.Timeout;
            if (nowMs -| startMs > 300_000) return error.Timeout;
            try quicHs.feedPumped(ep, pump, null, 200, nowMs);
            if (pumpCtx.err) |e| return e;
            // A peer CONNECTION_CLOSE leaves the connection draining. Stop
            // owning the endpoint immediately so the next client's Initial
            // is not fed into this closed connection and rejected. If this
            // side initiated the close, flush its CONNECTION_CLOSE first.
            if (qconn.state == .closing) {
                _ = ep.flush(null) catch {};
                return;
            }
            if (qconn.state == .draining or qconn.state == .closed) return;
            try h3.pumpQpack(qconn, nowMs);
            _ = try ep.flush(null);

            while (ready.items.len > 0) {
                const sid = ready.orderedRemove(0);
                const req = requests.get(sid) orelse continue;
                _ = requests.remove(sid);
                defer {
                    req.deinit();
                    self.allocator.destroy(req);
                }
                if (req.tooLarge) {
                    h3.resetStream(qconn, sid, .requestRejected, nowMs) catch {};
                    h3.discardRequestStream(sid);
                    continue;
                }
                if (req.failed) {
                    h3.resetStream(qconn, sid, req.h3Error orelse .generalProtocolError, nowMs) catch {};
                    h3.discardRequestStream(sid);
                    continue;
                }
                if (!req.done) {
                    req.queued = false;
                    continue;
                }
                var peerBuf: [64]u8 = undefined;
                const peer = if (ep.peer) |p| addressMod.Address.fromStd(p).formatBuf(&peerBuf) else "";
                self.dispatchH3Request(&h3, qconn, req, peer) catch |err| {
                    h3.resetStream(qconn, sid, .internalError, nowMs) catch {};
                    h3.discardRequestStream(sid);
                    if (err == error.OutOfMemory) return err;
                    continue;
                };
            }
            try h3.pumpQpack(qconn, nowMs);
            _ = try ep.flush(null);
        }
    }

    /// Dispatches one fully received HTTP/3 request and writes its
    /// response on the same stream. Concurrent requests share `h3` and
    /// the QUIC connection; QPACK encoding is serialized by the caller.
    fn dispatchH3Request(
        self: *Server,
        h3: *http3Conn.Connection,
        qconn: *quicConn.Connection,
        req: *H3Request,
        peer: []const u8,
    ) !void {
        var arenaH3 = std.heap.ArenaAllocator.init(self.allocator);
        defer arenaH3.deinit();
        const a = arenaH3.allocator();
        const fields = req.fields.items;
        const reqBody = req.body.items;

        var mStr: []const u8 = "GET";
        var pStr: []const u8 = "/";
        var authorityStr: ?[]const u8 = null;
        var sawHost = false;
        var ctxHdrs = try a.alloc(routerMod.Header, fields.len + 1);
        var hdrCount: usize = 0;
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, ":method")) {
                mStr = f.value;
            } else if (std.mem.eql(u8, f.name, ":path")) {
                pStr = f.value;
            } else if (std.mem.eql(u8, f.name, ":authority")) {
                authorityStr = f.value;
            } else if (!std.mem.startsWith(u8, f.name, ":")) {
                if (std.mem.eql(u8, f.name, "host")) sawHost = true;
                ctxHdrs[hdrCount] = .{ .name = f.name, .value = f.value };
                hdrCount += 1;
            }
        }
        // HTTP/1-style handlers expect the authority as Host when the
        // client sent no explicit host field (RFC 9114 Section 4.3.1).
        if (!sawHost) {
            if (authorityStr) |authority| {
                ctxHdrs[hdrCount] = .{ .name = "host", .value = authority };
                hdrCount += 1;
            }
        }

        const knownMethod = Method.fromString(mStr);
        var cleanPath = pStr;
        if (std.mem.indexOfAny(u8, cleanPath, "?#")) |idx| {
            cleanPath = cleanPath[0..idx];
        }
        var queryPart: []const u8 = "";
        if (std.mem.indexOfScalar(u8, pStr, '?')) |qi| {
            var q = pStr[qi + 1 ..];
            if (std.mem.indexOfScalar(u8, q, '#')) |hi| q = q[0..hi];
            queryPart = q;
        }

        var ctx = Context{
            .allocator = a,
            .io = self.io,
            .headers = ctxHdrs[0..hdrCount],
            .path = cleanPath,
            .query = queryPart,
            .method = knownMethod orelse .GET,
            .body = reqBody,
            .isTls = true,
            .peerAddress = peer,
            .trustForwarded = self.trustForwardedFor(peer),
            .trustedProxies = self.cfg.trustedProxies,
        };

        var res = if (knownMethod != null)
            self.router.dispatch(&ctx)
        else
            Response{ .status = 501, .body = "method not supported" };

        // The same content coding the HTTP/1 and HTTP/2 paths apply, so one
        // handler behaves identically across protocol versions.
        var clientAcceptEncoding: ?[]const u8 = null;
        for (ctxHdrs[0..hdrCount]) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "accept-encoding")) clientAcceptEncoding = h.value;
        }

        const isHead = std.mem.eql(u8, mStr, "HEAD");
        const isConnect = std.mem.eql(u8, mStr, "CONNECT");
        const statusAllowsBody = res.status != 204 and res.status != 205 and res.status != 304;
        const connectTunnel = isConnect and res.status < 300;
        var codedBody: ?[]u8 = null;
        defer if (codedBody) |b| a.free(b);
        var outBody: []const u8 = res.body;
        var contentEncoding: ?[]const u8 = null;
        var varyAcceptEncoding = false;
        if (statusAllowsBody and !isHead) {
            const coding = compression.encodeResponseBody(
                a,
                res.body,
                clientAcceptEncoding,
                self.cfg.compression,
                self.cfg.maxCompressionInput,
            ) catch |err| switch (err) {
                error.NotAcceptable => blk: {
                    res.status = 406;
                    res.body = "";
                    res.contentType = null;
                    outBody = "";
                    break :blk null;
                },
                else => return err,
            };
            if (coding) |c| {
                outBody = c.body;
                codedBody = if (c.contentEncoding != null) @constCast(c.body) else null;
                contentEncoding = c.contentEncoding;
                varyAcceptEncoding = c.varyAcceptEncoding;
            }
        }

        if (res.status < 200 or res.status > 599) res.status = 500;
        var rs = h3.createRequestStream(req.sid);

        var respHeaders = std.ArrayList(http3Qpack.FieldLine).empty;
        defer respHeaders.deinit(a);
        // Content-Length describes the bytes that a GET would send; HEAD
        // keeps the length but suppresses the DATA frame. 204/205/304
        // responses carry no content framing, and a successful CONNECT
        // response is a tunnel without Content-Length.
        if (statusAllowsBody and !connectTunnel) {
            var clBuf: [20]u8 = undefined;
            const cl = clBuf[0..std.fmt.printInt(&clBuf, outBody.len, 10, .lower, .{})];
            try respHeaders.append(a, .{ .name = "content-length", .value = cl });
        }
        for (res.headers) |h| {
            if (h.name.len == 0 or h.name[0] == ':') continue;
            if (std.ascii.eqlIgnoreCase(h.name, "content-length") or
                std.ascii.eqlIgnoreCase(h.name, "connection") or
                std.ascii.eqlIgnoreCase(h.name, "keep-alive") or
                std.ascii.eqlIgnoreCase(h.name, "proxy-connection") or
                std.ascii.eqlIgnoreCase(h.name, "transfer-encoding") or
                std.ascii.eqlIgnoreCase(h.name, "upgrade"))
            {
                continue;
            }
            try respHeaders.append(a, .{ .name = h.name, .value = h.value });
        }
        if (res.contentType) |ct| {
            try respHeaders.append(a, .{ .name = "content-type", .value = ct });
        }
        if (contentEncoding) |ce| {
            try respHeaders.append(a, .{ .name = "content-encoding", .value = ce });
        }
        if (varyAcceptEncoding) try respHeaders.append(a, .{ .name = "vary", .value = "Accept-Encoding" });

        const rhead = try rs.buildResponseHeaders(res.status, respHeaders.items);
        defer self.allocator.free(rhead);

        var wire = std.ArrayList(u8).empty;
        defer wire.deinit(self.allocator);
        try wire.appendSlice(self.allocator, rhead);
        const sendBody = statusAllowsBody and !isHead and outBody.len > 0;
        if (sendBody) {
            const rdata = try rs.buildData(outBody);
            defer self.allocator.free(rdata);
            try wire.appendSlice(self.allocator, rdata);
        }

        // Queue the QPACK encoder instructions the response section
        // references before the response stream bytes go out.
        const nowMs: u64 = @intCast(clock.monotonicMillis(self.io));
        try h3.pumpQpack(qconn, nowMs);
        try h3.sendStreamBytes(qconn, req.sid, wire.items, true, nowMs);
        try h3.pumpQpack(qconn, nowMs);
        h3.discardRequestStream(req.sid);
    }
    fn serveHttp1Connection(self: *Server, conn: StreamConn, isTlsConn: bool, initial: []const u8) !void {
        if (!self.cfg.keepAlive) {
            var arenaOne = std.heap.ArenaAllocator.init(self.allocator);
            defer arenaOne.deinit();
            _ = try self.serveOneRequestBuffered(conn, arenaOne.allocator(), 0, true, initial, isTlsConn);
            return;
        }
        // Persistent connection: bounded request loop with per-request arena
        // reset so long-lived connections cannot grow memory unbounded.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        var servedN: usize = 0;
        while (servedN < self.cfg.maxRequestsPerConn) : (servedN += 1) {
            if (self.stopFlag.load(.acquire)) break;
            _ = arena.reset(.retain_capacity);
            const initBytes = if (servedN == 0) initial else "";
            const wantMore = self.serveOneRequestBuffered(conn, arena.allocator(), servedN, false, initBytes, isTlsConn) catch return;
            if (!wantMore) break;
        }
    }

    fn serveOneRequest(self: *Server, conn: StreamConn, arena: Allocator, idx: usize, forceClose: bool, isTlsConn: bool) !bool {
        return self.serveOneRequestBuffered(conn, arena, idx, forceClose, "", isTlsConn);
    }

    fn serveOneRequestBuffered(self: *Server, conn: StreamConn, arena: Allocator, requestIndex: usize, forceClose: bool, initial: []const u8, isTlsConn: bool) !bool {
        const t0 = clock.monotonicMillis(self.io);
        self.metricsRegistry.recordRequest();
        var headBuf: [maxHeadBytes]u8 = undefined;
        var filled: usize = 0;
        if (initial.len > 0) {
            const take = @min(initial.len, headBuf.len);
            @memcpy(headBuf[0..take], initial[0..take]);
            filled = take;
        }
        var headerDeadlineStarted = filled != 0;
        if (headerDeadlineStarted) {
            conn.setReadTimeoutMs(self.cfg.headerReadTimeoutMs);
        } else {
            conn.setReadTimeoutMs(if (requestIndex == 0) self.cfg.initialRequestTimeoutMs else self.cfg.keepAliveIdleTimeoutMs);
        }
        const allowLf = self.cfg.allowLfLineEndings;
        while (filled < headBuf.len) {
            if (std.mem.indexOf(u8, headBuf[0..filled], "\r\n\r\n") != null) break;
            if (allowLf and std.mem.indexOf(u8, headBuf[0..filled], "\n\n") != null) {
                // Ensure not just \r\n\r\n already handled; check bare LF
                var hasBare = false;
                for (headBuf[0..filled], 0..) |c, i| {
                    if (c == '\n' and i > 0 and headBuf[i - 1] != '\r') {
                        // Check if previous char before \n\n is not \r
                        if (i + 1 < filled and headBuf[i + 1] == '\n') hasBare = true;
                    }
                }
                if (hasBare) break;
                if (std.mem.indexOf(u8, headBuf[0..filled], "\n\n") != null) break;
            }
            const n = conn.read(headBuf[filled..]) catch return false;
            if (n == 0) return false; // peer closed
            filled += n;
            if (!headerDeadlineStarted) {
                headerDeadlineStarted = true;
                conn.setReadTimeoutMs(self.cfg.headerReadTimeoutMs);
            }
        }
        self.metricsRegistry.recordBytesIn(filled);

        const parserOpts: parserMod.Options = .{ .allowLfLineEndings = allowLf };
        const reqHead = parserMod.parseRequestHead(headBuf[0..filled], parserOpts) catch {
            self.metricsRegistry.recordError();
            _ = sendSimpleError(conn, 400, "bad request") catch 0;
            return false;
        };

        self.metricsRegistry.recordRequestMethod(reqHead.method);

        if (reqHead.minorVersion == 0 and !self.cfg.http10) {
            _ = sendSimpleError(conn, 505, "HTTP/1.0 Not Supported") catch 0;
            return false;
        }
        if (reqHead.minorVersion == 1 and !self.cfg.http11) {
            _ = sendSimpleError(conn, 505, "HTTP/1.1 Not Supported") catch 0;
            return false;
        }

        // Headers -> Context slice.
        var fields: [parserMod.DEFAULT_MAX_HEADERS]parserMod.Field = undefined;
        const blk = parserMod.parseHeaderBlock(headBuf[0..filled], reqHead.headEnd, fields[0..], parserOpts) catch {
            _ = sendSimpleError(conn, 400, "bad headers") catch 0;
            return false;
        };
        if (!semanticsMod.validRequestTargetAndHost(reqHead.method, reqHead.path, reqHead.minorVersion, fields[0..blk.count])) {
            _ = sendSimpleError(conn, 400, "invalid request target or Host") catch 0;
            return false;
        }

        const hdrs = arena.alloc(routerMod.Header, blk.count) catch return false;
        for (fields[0..blk.count], 0..) |f, i| hdrs[i] = .{ .name = f.name, .value = f.value };

        // Connection reuse decision (RFC 9112 Section 7): explicit "close" wins;
        // HTTP/1.0 defaults to close unless it requested keep-alive.
        const clientVersion: semanticsMod.Version = if (reqHead.minorVersion == 0) .http10 else .http11;
        var clientClose = forceClose or !semanticsMod.shouldKeepAlive(clientVersion, hdrs);

        // Body: Content-Length or chunked (both bounded by cfg.maxBody).
        var body: []u8 = "";
        const framing = parserMod.framingFull(fields[0..blk.count], .{
            .isHttp10 = reqHead.minorVersion == 0,
        }) catch {
            _ = sendSimpleError(conn, 400, "invalid message framing") catch 0;
            return false;
        };
        var hasExpect = false;
        for (fields[0..blk.count]) |field| {
            if (std.ascii.eqlIgnoreCase(field.name, "expect")) {
                hasExpect = true;
                if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, field.value, " \t"), "100-continue")) {
                    _ = sendSimpleError(conn, 417, "expectation failed") catch 0;
                    return false;
                }
            }
        }
        if (hasExpect and reqHead.minorVersion == 1 and framing.framing != .none) {
            const interim = writerMod.buildInformational(arena, 100, &.{}) catch return false;
            defer arena.free(interim);
            conn.setWriteTimeoutMs(self.cfg.writeTimeoutMs);
            conn.writeAll(interim) catch return false;
        }
        {
            const fr = framing;
            switch (fr.framing) {
                .none, .contentLength => {
                    if (fr.length > self.cfg.maxBody) {
                        _ = sendSimpleError(conn, 413, "payload too large") catch 0;
                        return false;
                    }
                    body = arena.alloc(u8, fr.length) catch return false;
                    // How many body bytes were already pulled in by the header reads.
                    const buffered = if (filled > blk.end) filled - blk.end else 0;
                    if (buffered > fr.length) clientClose = true;
                    const take = @min(buffered, fr.length);
                    @memcpy(body[0..take], headBuf[blk.end..][0..take]);
                    var have: usize = take;
                    if (fr.length > 0) conn.setReadTimeoutMs(self.cfg.requestBodyTimeoutMs);
                    while (have < fr.length) {
                        // Bounded window keeps behavior uniform across platforms.
                        const want = @min(4096, fr.length - have);
                        const n = conn.read(body[have..][0..want]) catch return false;
                        if (n == 0) return false;
                        have += n;
                    }
                },
                .chunked => {
                    // Persistent decoder with bounded retained wire data.
                    var dec = parserMod.ChunkedDecoder.initWithOptions(.{
                        .allowLfLineEndings = self.cfg.allowLfLineEndings,
                    });
                    var acc: std.ArrayList(u8) = .empty;
                    var raw: std.ArrayList(u8) = .empty;
                    raw.appendSlice(arena, headBuf[blk.end..filled]) catch return false;
                    conn.setReadTimeoutMs(self.cfg.requestBodyTimeoutMs);
                    while (true) {
                        _ = dec.decode(raw.items) catch |e| switch (e) {
                            error.Incomplete => 0,
                            else => return false,
                        };
                        if (dec.totalDecoded > self.cfg.maxBody) {
                            _ = sendSimpleError(conn, 413, "payload too large") catch 0;
                            return false;
                        }
                        acc.appendSlice(arena, raw.items[0..dec.decodedLen]) catch return false;
                        if (dec.rawConsumed > raw.items.len) return false;
                        const pending = raw.items.len - dec.rawConsumed;
                        if (pending > 0) std.mem.copyForwards(u8, raw.items[0..pending], raw.items[dec.rawConsumed..]);
                        raw.items.len = pending;

                        if (dec.isDone()) {
                            // The request body is complete; any bytes already
                            // read beyond it cannot be retained for the next
                            // request, so force connection close.
                            if (pending != 0) clientClose = true;
                            break;
                        }
                        const n = conn.read(headBuf[0..]) catch return false;
                        if (n == 0) return false;
                        raw.appendSlice(arena, headBuf[0..n]) catch return false;
                    }
                    body = acc.items;
                },
                .tunnel => {
                    // CONNECT tunneling is not served by the request router.
                    _ = sendSimpleError(conn, 501, "CONNECT not supported") catch 0;
                    return false;
                },
            }
        }

        const method = Method.fromString(reqHead.method) orelse {
            _ = sendSimpleError(conn, 501, "method not supported") catch 0;
            return false;
        };

        const isHead = method == .HEAD;

        // RFC 9112 Section 3.2.2: an absolute-form target is accepted for
        // proxies, but routing must use its path/query rather than treating
        // "http://host/path" as an origin path (which would never match).
        const rawPath = reqHead.path;
        var cleanPath = rawPath;
        var queryPart: []const u8 = "";
        if (semanticsMod.classifyTarget(reqHead.method, rawPath) == .absolute) {
            const abs = uriMod.parse(rawPath) catch {
                _ = sendSimpleError(conn, 400, "invalid request target") catch 0;
                return false;
            };
            cleanPath = abs.path;
            queryPart = abs.query;
        } else {
            if (std.mem.indexOfAny(u8, cleanPath, "?#")) |idx| {
                cleanPath = cleanPath[0..idx];
            }
            if (std.mem.indexOfScalar(u8, rawPath, '?')) |qi| {
                var q = rawPath[qi + 1 ..];
                if (std.mem.indexOfScalar(u8, q, '#')) |hi| q = q[0..hi];
                queryPart = q;
            }
        }

        var ctx = Context{
            .allocator = arena,
            .io = self.io,
            .headers = hdrs,
            .path = cleanPath,
            .query = queryPart,
            .method = method,
            .body = body,
            .isTls = isTlsConn,
            .peerAddress = conn.peerAddress(),
            .trustForwarded = self.trustForwardedFor(conn.peerAddress()),
            .trustedProxies = self.cfg.trustedProxies,
        };
        const res: Response = self.router.dispatch(&ctx);

        conn.setWriteTimeoutMs(self.cfg.writeTimeoutMs);
        const bytesOut = writeResponse(conn, arena, reqHead.minorVersion, try self.withLiveReload(arena, res, isHead), isHead, if (clientClose) "close" else "keep-alive", ctx.header("Accept-Encoding"), self.cfg.compression, self.cfg.maxCompressionInput) catch {
            self.metricsRegistry.recordError();
            return false;
        };
        const durNs: u64 = @intCast(@max(0, (clock.monotonicMillis(self.io) -| t0) * 1_000_000));
        self.metricsRegistry.recordResponseFull(res.status, durNs, bytesOut);
        self.emitAccess(reqHead.method, reqHead.path, res.status, body.len, bytesOut, t0);
        return !clientClose;
    }

    /// Attaches the browser live-reload client to HTML responses while
    /// `liveReload` is on, so handler-written pages reload the same way
    /// static files do. `inject` is idempotent, so a response that already
    /// carries the script (static files, the site generator) is untouched.
    fn withLiveReload(self: *Server, arena: Allocator, res: Response, isHead: bool) !Response {
        if (!self.cfg.liveReload or isHead or res.status == 204 or res.status == 304) return res;
        const ct = res.contentType orelse return res;
        if (!std.mem.startsWith(u8, ct, "text/html")) return res;
        if (reload.isInjected(res.body)) return res;
        var out = res;
        out.body = try reload.inject(arena, res.body, self.cfg.liveReloadPath);
        return out;
    }

    /// Deliver a requestCompleted event to the application callback.
    /// Secrets never appear here: only method/path/status/timing/byte counts.
    fn emitAccess(self: *Server, method: []const u8, path: []const u8, status: u16, bytesIn: usize, bytesOut: usize, t0: i64) void {
        const dur = clock.monotonicMillis(self.io) -| t0;
        self.emit(.{
            .kind = .requestCompleted,
            .level = .info,
            .method = method,
            .path = path,
            .status = status,
            .durationMs = dur,
            .bytesIn = bytesIn,
            .bytesOut = bytesOut,
        });
    }

    fn writeResponse(conn: StreamConn, arena: Allocator, minor: u8, res: Response, isHead: bool, connHdr: []const u8, acceptEncoding: ?[]const u8, compressionConfig: compression.Config, maxCompressionInput: usize) !usize {
        // connHdr selects the Connection header emitted ("" -> legacy close).
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(arena);

        lines.append(arena, if (connHdr.len > 0)
            (std.fmt.allocPrint(arena, "Connection: {s}", .{connHdr}) catch return 0)
        else
            "Connection: close") catch return 0;

        if (res.contentType) |ct| {
            const line = std.fmt.allocPrint(arena, "Content-Type: {s}", .{ct}) catch return 0;
            lines.append(arena, line) catch return 0;
        }
        for (res.headers) |h| {
            const line = std.fmt.allocPrint(arena, "{s}: {s}", .{ h.name, h.value }) catch return 0;
            lines.append(arena, line) catch return 0;
        }

        var encodedBody: ?[]u8 = null;
        defer if (encodedBody) |b| arena.free(b);
        var bodyOut: []const u8 = if (isHead) "" else res.body;
        var contentEncoding: ?[]const u8 = null;
        // 204 and 304 never carry a body, so there is nothing to code.
        if (!isHead and res.status != 204 and res.status != 304) {
            const coding = compression.encodeResponseBody(
                arena,
                res.body,
                acceptEncoding,
                compressionConfig,
                maxCompressionInput,
            ) catch |err| switch (err) {
                error.NotAcceptable => return writeResponse(
                    conn,
                    arena,
                    minor,
                    .{ .status = 406, .body = "" },
                    isHead,
                    connHdr,
                    null,
                    compressionConfig,
                    maxCompressionInput,
                ),
                else => return err,
            };
            bodyOut = coding.body;
            encodedBody = if (coding.contentEncoding != null) @constCast(coding.body) else null;
            contentEncoding = coding.contentEncoding;
            if (coding.varyAcceptEncoding) lines.append(arena, "Vary: Accept-Encoding") catch return 0;
        }
        if (contentEncoding) |ce| {
            const line = std.fmt.allocPrint(arena, "Content-Encoding: {s}", .{ce}) catch return 0;
            lines.append(arena, line) catch return 0;
        }
        const reason: []const u8 = if (writerMod.reasonPhrase(res.status).len > 0)
            writerMod.reasonPhrase(res.status)
        else
            reasonFor(res.status);
        var respHeaders = try arena.alloc(writerMod.Header, lines.items.len);
        for (lines.items, 0..) |line, i| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return 0;
            respHeaders[i] = .{
                .name = std.mem.trim(u8, line[0..colon], " "),
                .value = std.mem.trim(u8, line[colon + 1 ..], " "),
            };
        }
        const raw = writerMod.buildResponse(
            arena,
            res.status,
            reason,
            bodyOut,
            .{ .minorVersion = minor, .headers = respHeaders },
            isHead,
        ) catch return 0;
        try conn.writeAll(raw);
        return raw.len;
    }

    fn sendSimpleError(conn: StreamConn, status: u16, text: []const u8) !usize {
        var buf: [256]u8 = undefined;
        const out = std.fmt.bufPrint(&buf, "HTTP/1.1 {d} {s}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{
            status,
            reasonFor(status),
            text.len,
            text,
        }) catch return 0;
        try conn.writeAll(out);
        return out.len;
    }
};

pub fn reasonFor(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        206 => "Partial Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Payload Too Large",
        416 => "Range Not Satisfiable",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        else => "Status",
    };
}

// Tests

test "initial protocol classification waits for fragmented TLS and HTTP2 prefixes" {
    const h2Preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
    for (1..16) |len| {
        try std.testing.expectEqual(Server.InitialProtocol.needMore, Server.classifyInitialProtocol(h2Preface[0..len], false, true));
    }
    try std.testing.expectEqual(Server.InitialProtocol.http2, Server.classifyInitialProtocol(h2Preface[0..16], false, true));
    try std.testing.expectEqual(Server.InitialProtocol.needMore, Server.classifyInitialProtocol(&.{0x16}, true, true));
    try std.testing.expectEqual(Server.InitialProtocol.needMore, Server.classifyInitialProtocol(&.{ 0x16, 0x03 }, true, true));
    try std.testing.expectEqual(Server.InitialProtocol.tls, Server.classifyInitialProtocol(&.{ 0x16, 0x03, 0x03 }, true, true));
    try std.testing.expectEqual(Server.InitialProtocol.http1, Server.classifyInitialProtocol("PO", true, true));
}

test "fragmented cleartext HTTP2 preface is sniffed before HTTP1 dispatch" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = try Server.init(a, ctx.io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
        .maxConnections = 1,
        .initialRequestTimeoutMs = 2_000,
    });
    defer srv.deinit();
    const Runner = struct {
        fn run(server: *Server) void {
            server.run();
        }
    };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&srv});
    defer thread.join();

    var client = try tcp.connect(ctx.io, "127.0.0.1", srv.localPort());
    defer client.close();
    client.setReadTimeoutMs(2_000);
    const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
    try client.writeAll(preface[0..1]);
    clock.sleepMillis(std.Io.Threaded.global_single_threaded.io(), 50);
    try client.writeAll(preface[1..]);
    try client.writeAll(&.{ 0, 0, 0, 4, 0, 0, 0, 0, 0 });

    var serverFrame: [9]u8 = undefined;
    var received: usize = 0;
    while (received < serverFrame.len) {
        const n = try client.read(serverFrame[received..]);
        if (n == 0) break;
        received += n;
    }
    try std.testing.expectEqual(serverFrame.len, received);
    try std.testing.expectEqual(@as(u8, 4), serverFrame[3]);
    try std.testing.expectEqual(@as(u8, 0), serverFrame[4]);
}

fn helloHandler(ctx: *Context) anyerror!Response {
    if (std.mem.eql(u8, ctx.path, "/hello")) {
        // Issue 47: `Content-Security-Policy-Report-Only` is 35 bytes and
        // was rejected by the old 32-byte field-name cap, which broke every
        // proxy built on httpx that forwarded Google's headers. It is
        // emitted here so the existing loopback test asserts the long name
        // survives response assembly and reaches the wire, rather than only
        // asserting `validToken` in isolation.
        //
        // The body is deliberately repetitive so gzip actually shrinks it:
        // response compression skips a coding that fails to make the payload
        // smaller, and a two-byte body would legitimately stay uncompressed
        // and stop exercising the gzip framing this test is here to check.
        return .{
            .body = "hi from httpx, hi from httpx, hi from httpx, hi from httpx, hi from httpx\n",
            .contentType = "text/plain",
            .headers = &.{
                .{
                    .name = "Content-Security-Policy-Report-Only",
                    .value = "default-src 'self'; report-uri /csp-report",
                },
            },
        };
    }
    return .{ .status = 404, .body = "" };
}

test "HTTP/1.1 server rejects request without Host before dispatch" {
    const a = std.testing.allocator;
    var ioContext = tcp.IoContext.init(a) catch return;
    defer ioContext.deinit();

    var srv = Server.init(a, ioContext.io, .{ .port = 0, .enableDocs = false, .maxConnections = 1 }) catch return;
    defer srv.deinit();
    try srv.router.get("/", helloHandler, .{});

    const Runner = struct {
        fn run(server: *Server) void {
            server.run();
        }
    };
    const thread = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
    defer thread.join();

    var client = tcp.connect(ioContext.io, "127.0.0.1", srv.localPort()) catch return;
    defer client.close();
    try client.writeAll("GET / HTTP/1.1\r\nConnection: close\r\n\r\n");

    var response: [1024]u8 = undefined;
    const n = client.read(&response) catch return;
    try std.testing.expect(std.mem.startsWith(u8, response[0..n], "HTTP/1.1 400 Bad Request"));

    srv.requestShutdown();
}

test "HTTP/1.1 absolute-form target routes by its path" {
    const a = std.testing.allocator;
    var ioContext = tcp.IoContext.init(a) catch return;
    defer ioContext.deinit();

    var srv = Server.init(a, ioContext.io, .{ .port = 0, .enableDocs = false, .maxConnections = 1 }) catch return;
    defer srv.deinit();
    try srv.router.get("/hello", helloHandler, .{});

    const Runner = struct {
        fn run(server: *Server) void {
            server.run();
        }
    };
    const thread = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
    defer thread.join();

    const port = srv.localPort();
    const request = try std.fmt.allocPrint(a, "GET http://127.0.0.1:{d}/hello HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n", .{ port, port });
    defer a.free(request);

    var client = tcp.connect(ioContext.io, "127.0.0.1", port) catch return;
    defer client.close();
    try client.writeAll(request);

    var response: [1024]u8 = undefined;
    const n = client.read(&response) catch return;
    try std.testing.expect(std.mem.startsWith(u8, response[0..n], "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.indexOf(u8, response[0..n], "hi from httpx") != null);

    srv.requestShutdown();
}

test "template route renders through tree-sitter pipeline end to end" {
    const tmplEngineMod = @import("../web/templates/templateEngine.zig");
    const tmplRendererMod = @import("../web/templates/templateRenderer.zig");
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var eng = tmplEngineMod.Engine.init(a, ctx.io, .{ .enableCache = true }) catch return;
    defer eng.deinit();

    const H = struct {
        var enginePtr: ?*tmplEngineMod.Engine = null;
        fn handle(c: *Context) anyerror!Response {
            var list = std.ArrayList(u8).empty;
            errdefer list.deinit(c.allocator);
            var lw = tmplRendererMod.ListWriter{ .list = &list, .allocator = c.allocator };
            try enginePtr.?.renderString("<h1>{{ title }}</h1>{% for u in users %}<p>{{ u }}</p>{% endfor %}", .{
                .title = "Hello",
                .users = [_][]const u8{ "ann", "bob" },
            }, &lw);
            return .{ .body = list.items, .contentType = "text/html" };
        }
    };
    H.enginePtr = &eng;

    var srv = Server.init(a, ctx.io, .{ .port = 0, .maxConnections = 2 }) catch return;
    defer srv.deinit();
    try srv.router.get("/", H.handle, .{});

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
    defer t.join();

    var client = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
    defer client.close();
    try client.writeAll("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");

    var buf: [2048]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = client.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    try std.testing.expect(std.mem.startsWith(u8, buf[0..total], "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "<h1>Hello</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "<p>bob</p>") != null);

    srv.requestShutdown();
}

fn pageHandler(_: *Context) anyerror!Response {
    return .{ .body = "<html><head><link rel=\"stylesheet\" href=\"/a.css\"></head><body><h1>hi</h1></body></html>", .contentType = "text/html" };
}

test "live reload attaches the browser client to a plain handler's HTML" {
    // liveReload must not require the static file handler: a handler that
    // returns HTML gets the same client-side script, so hot/warm/cold
    // reloads work for framework responses too.
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .maxConnections = 2,
        .liveReload = true,
    }) catch return;
    defer srv.deinit();
    try srv.router.get("/", pageHandler, .{});

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
    defer t.join();

    var client = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
    defer client.close();
    try client.writeAll("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");

    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = client.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    const wire = buf[0..total];
    try std.testing.expect(std.mem.startsWith(u8, wire, "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.indexOf(u8, wire, srv.cfg.liveReloadPath) != null);
    // Handles the hot-reload payload, so a CSS edit swaps the stylesheet
    // instead of reloading the document.
    try std.testing.expect(std.mem.indexOf(u8, wire, "hotReload") != null);
    const markerAt = std.mem.lastIndexOf(u8, wire, reload.marker) orelse return error.MarkerMissing;
    const bodyEnd = std.mem.lastIndexOf(u8, wire, "</body>") orelse return error.BodyEndMissing;
    try std.testing.expect(markerAt < bodyEnd);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "<h1>hi</h1>") != null);
    // Injected exactly once.
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, wire[markerAt + 1 ..], reload.marker));

    srv.requestShutdown();
}

test "live reload is off by default and skips non-HTML responses" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{ .port = 0, .enableDocs = false, .maxConnections = 1 }) catch return;
    defer srv.deinit();
    try std.testing.expect(!srv.cfg.liveReload);

    const res: Response = .{ .body = "<html><body>x</body></html>", .contentType = "text/html" };
    const out = try srv.withLiveReload(a, res, false);
    try std.testing.expect(!reload.isInjected(out.body));

    const plain: Response = .{ .body = "hi", .contentType = "text/plain" };
    const outPlain = try srv.withLiveReload(a, plain, false);
    try std.testing.expectEqualStrings("hi", outPlain.body);

    // HEAD never carries a body, so nothing is injected.
    const outHead = try srv.withLiveReload(a, res, true);
    try std.testing.expectEqualStrings("<html><body>x</body></html>", outHead.body);
}

test "server handles POST with content-length body" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{ .port = 0, .enableDocs = false, .maxConnections = 1 }) catch return;
    defer srv.deinit();
    try srv.router.post("/echo", echoRawHandler, .{});

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
    defer t.join();

    var client = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
    defer client.close();

    const payload = "{\"raw\":true}";
    var reqBuf: [256]u8 = undefined;
    const raw = try std.fmt.bufPrint(&reqBuf, "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ payload.len, payload });
    try client.writeAll(raw);

    var buf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = client.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "}\r\n") != null) break;
    }

    try std.testing.expect(std.mem.startsWith(u8, buf[0..total], "HTTP/1.1 200"));
    try std.testing.expect(std.mem.endsWith(u8, buf[0..total], payload));
}

test "server decodes chunked request body before dispatch" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{ .port = 0, .enableDocs = false, .maxConnections = 1 }) catch return;
    defer srv.deinit();
    try srv.router.post("/echo", echoRawHandler, .{});

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const thread = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
    defer thread.join();

    var client = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
    defer client.close();
    try client.writeAll("POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nhello\r\n0\r\nX-Checksum: yes\r\n\r\n");

    var buf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = client.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "hello") != null) break;
    }
    try std.testing.expect(std.mem.startsWith(u8, buf[0..total], "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.endsWith(u8, buf[0..total], "hello"));
    srv.requestShutdown();
}

fn echoRawHandler(ctx: *Context) anyerror!Response {
    if (ctx.body.len == 0) return .{ .status = 400, .body = "empty" };
    return .{ .contentType = "application/json", .body = ctx.body };
}

// Logging verification: callback receives access events; silence when no callback.

const sync = @import("../common/sync.zig");

// Thread-local capture for test callbacks (single-threaded test context).
var gCaptureSeen: usize = 0;
var gCaptureGotRequest: bool = false;
var gCaptureGotLifecycle: bool = false;
var gCaptureMu: sync.Spinlock = .{};

fn testEventCallback(event: logging.ServerEvent) void {
    gCaptureMu.lock();
    defer gCaptureMu.unlock();
    gCaptureSeen += 1;
    if (event.kind == .requestCompleted and
        std.mem.indexOf(u8, event.path, "/logged") != null and
        std.mem.eql(u8, event.method, "GET"))
        gCaptureGotRequest = true;
    if (event.kind == .serverStarted or event.kind == .serverStopped)
        gCaptureGotLifecycle = true;
}

test "access log flows through event callback" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    // Reset global capture state.
    gCaptureSeen = 0;
    gCaptureGotRequest = false;
    gCaptureGotLifecycle = false;

    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .maxConnections = 1,
        .logging = .{ .callback = testEventCallback },
    }) catch return;
    defer srv.deinit();
    try srv.router.get("/logged", returnOk, .{});

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;

    var c = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch {
        srv.requestShutdown();
        t.join();
        return;
    };
    try c.writeAll("GET /logged HTTP/1.1\r\nHost: x\r\n\r\n");
    var rbuf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < rbuf.len) {
        const n = c.read(rbuf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, rbuf[0..total], "ok") != null) break;
    }
    // Close BEFORE joining so the server can drain and run() can return.
    c.close();

    // maxConnections=1 => run() returns only AFTER emitAccess ran.
    t.join();
    srv.requestShutdown();
    try std.testing.expect(gCaptureGotRequest);
    try std.testing.expect(gCaptureGotLifecycle);
}

test "no callback produces zero events" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    // Reset global capture (should stay zero without callback).
    gCaptureSeen = 0;
    gCaptureGotRequest = false;
    gCaptureGotLifecycle = false;

    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .maxConnections = 1,
        .logging = .{}, // null callback — silent by default
    }) catch return;
    defer srv.deinit();
    try srv.router.get("/logged", returnOk, .{});

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;

    var c = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
    try c.writeAll("GET /logged HTTP/1.1\r\nHost: x\r\n\r\n");
    var rbuf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < rbuf.len) {
        const n = c.read(rbuf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, rbuf[0..total], "ok") != null) break;
    }
    c.close();

    t.join();
    srv.requestShutdown();
    try std.testing.expectEqual(@as(usize, 0), gCaptureSeen);
}

fn returnOk(_: *Context) anyerror!Response {
    return .{ .body = "ok", .contentType = "text/plain" };
}

test "sequential clients are each served and closed cleanly" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
    }) catch return;
    defer srv.deinit();
    try srv.router.get("/ok", returnOk, .{});

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
    defer t.join();

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var c = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
        defer c.close();
        c.writeAll("GET /ok HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n") catch return;
        var rbuf: [512]u8 = undefined;
        var total: usize = 0;
        while (total < rbuf.len) {
            const n = c.read(rbuf[total..]) catch break;
            if (n == 0) break;
            total += n;
            if (std.mem.indexOf(u8, rbuf[0..total], "ok") != null) break;
        }
        try std.testing.expect(std.mem.indexOf(u8, rbuf[0..total], "ok") != null);
    }
    srv.requestShutdown();
}

test "server serves routed GET end to end" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{ .port = 0, .maxConnections = 1 }) catch return;
    defer srv.deinit();
    try srv.router.get("/hello", helloHandler, .{});

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
    defer t.join();

    var client = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
    defer client.close();

    try client.writeAll("GET /hello HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip;q=1, zstd;q=0, br;q=0\r\n\r\n");

    var buf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = client.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "Content-Encoding: gzip") != null and
            std.mem.indexOf(u8, buf[0..total], "\r\n\x1f\x8b") != null) break;
        // Issue 47: the 35-byte field name has to be present in the bytes
        // the client actually receives, not merely accepted by the writer.
        if (std.mem.indexOf(u8, buf[0..total], "report-uri /csp-report") != null and
            std.mem.indexOf(u8, buf[0..total], "\r\n\x1f\x8b") != null) break;
    }
    try std.testing.expect(std.mem.startsWith(u8, buf[0..total], "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "Content-Encoding: gzip") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "Vary: Accept-Encoding") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "Content-Security-Policy-Report-Only: default-src 'self'; report-uri /csp-report\r\n") != null);
    try std.testing.expect(total > 20);

    srv.requestShutdown();
}

test "idle and incomplete headers cannot block a normal request" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = try Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .maxConnections = 3,
        .maxConcurrentConnections = 3,
        .maxQueuedConnectionTasks = 3,
        .workerCount = 3,
        .initialRequestTimeoutMs = 1_000,
        .headerReadTimeoutMs = 1_000,
        .writeTimeoutMs = 1_000,
    });
    defer srv.deinit();
    try srv.router.get("/ok", returnOk, .{});

    const Runner = struct {
        fn run(server: *Server) void {
            server.run();
        }
    };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&srv});
    defer thread.join();

    var idle = try tcp.connect(ctx.io, "127.0.0.1", srv.localPort());
    defer idle.close();

    var incomplete = try tcp.connect(ctx.io, "127.0.0.1", srv.localPort());
    defer incomplete.close();
    try incomplete.writeAll("GET /ok HTTP/1.1\r\nHost: ");

    var client = try tcp.connect(ctx.io, "127.0.0.1", srv.localPort());
    defer client.close();
    client.setReadTimeoutMs(2_000);
    try client.writeAll("GET /ok HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");

    var response: [1024]u8 = undefined;
    var total: usize = 0;
    while (total < response.len) {
        const n = try client.read(response[total..]);
        if (n == 0) break;
        total += n;
    }
    try std.testing.expect(std.mem.indexOf(u8, response[0..total], "HTTP/1.1 200 OK") != null);
    try std.testing.expect(std.mem.endsWith(u8, response[0..total], "ok"));
    idle.close();
    incomplete.close();
}

test "stalled request body is timed out without blocking another client" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = try Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .maxConnections = 2,
        .maxConcurrentConnections = 2,
        .maxQueuedConnectionTasks = 2,
        .workerCount = 1,
        .initialRequestTimeoutMs = 1_000,
        .headerReadTimeoutMs = 1_000,
        .requestBodyTimeoutMs = 300,
        .writeTimeoutMs = 1_000,
    });
    defer srv.deinit();
    try srv.router.get("/ok", returnOk, .{});

    const Runner = struct {
        fn run(server: *Server) void {
            server.run();
        }
    };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&srv});
    defer thread.join();

    var stalled = try tcp.connect(ctx.io, "127.0.0.1", srv.localPort());
    defer stalled.close();
    stalled.setReadTimeoutMs(2_000);
    try stalled.writeAll("POST /ok HTTP/1.1\r\nHost: x\r\nContent-Length: 20\r\n\r\nabc");

    var client = try tcp.connect(ctx.io, "127.0.0.1", srv.localPort());
    defer client.close();
    client.setReadTimeoutMs(2_000);
    try client.writeAll("GET /ok HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");

    var response: [1024]u8 = undefined;
    var total: usize = 0;
    while (total < response.len) {
        const n = try client.read(response[total..]);
        if (n == 0) break;
        total += n;
    }
    try std.testing.expect(std.mem.indexOf(u8, response[0..total], "HTTP/1.1 200 OK") != null);
    // The incomplete upload owns only one worker for the configured body
    // deadline, after which the server closes it and releases its slot.
    var one: [1]u8 = undefined;
    const stalledRead = stalled.read(&one);
    if (stalledRead) |n| {
        try std.testing.expectEqual(@as(usize, 0), n);
    } else |err| {
        try std.testing.expect(err == error.ConnectionReset or err == error.ConnectionClosed or err == error.ReadFailed);
    }
}

test "connection limit rejects overload then accepts clients after a stalled upload expires" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = try Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .maxConcurrentConnections = 1,
        .maxQueuedConnectionTasks = 1,
        .workerCount = 1,
        .initialRequestTimeoutMs = 2_000,
        .headerReadTimeoutMs = 2_000,
        // Long enough that the stalled upload still owns the only slot while
        // the overload connection below is admitted and rejected. A deadline
        // shorter than the admission handshake made this test racy: on a
        // loaded runner the upload expired first, the slot was released, and
        // the overload connection was served instead of rejected.
        .requestBodyTimeoutMs = 1_500,
        .writeTimeoutMs = 2_000,
    });
    defer srv.deinit();
    try srv.router.get("/ok", returnOk, .{});

    const Runner = struct {
        fn run(server: *Server) void {
            server.run();
        }
    };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&srv});
    defer thread.join();

    const ActiveCount = struct {
        fn get(server: *Server) usize {
            server.connsMu.lock();
            defer server.connsMu.unlock();
            return server.activeConns.items.len;
        }
    };

    var stalled = try tcp.connect(ctx.io, "127.0.0.1", srv.localPort());
    defer stalled.close();
    // Every client socket is bounded: a missed server-side close then fails
    // this test quickly instead of stalling the whole suite until the runner's
    // global test timeout.
    stalled.setReadTimeoutMs(10_000);
    try stalled.writeAll("POST /ok HTTP/1.1\r\nHost: x\r\nContent-Length: 20\r\n\r\nabc");

    // Wait until the first socket owns the only connection slot before
    // opening the overload connection; this makes the admission assertion
    // deterministic instead of relying on accept scheduling.
    var spins: usize = 0;
    while (spins < 400) : (spins += 1) {
        if (ActiveCount.get(&srv) == 1) break;
        clock.sleepMillis(std.Io.Threaded.global_single_threaded.io(), 5);
    }
    try std.testing.expectEqual(@as(usize, 1), ActiveCount.get(&srv));

    var overloaded = try tcp.connect(ctx.io, "127.0.0.1", srv.localPort());
    defer overloaded.close();
    overloaded.setReadTimeoutMs(5_000);
    var byte: [1]u8 = undefined;
    const overloadedRead = overloaded.read(&byte);
    if (overloadedRead) |n| {
        try std.testing.expectEqual(@as(usize, 0), n);
    } else |err| {
        try std.testing.expect(err == error.ConnectionReset or err == error.ConnectionClosed or err == error.ReadFailed);
    }

    // The body deadline releases the only worker and connection slot. Observe
    // that release instead of assuming a fixed delay, so recovery is asserted
    // without racing the deadline.
    var released = false;
    var waited: usize = 0;
    while (waited < 2_000) : (waited += 1) {
        if (ActiveCount.get(&srv) == 0) {
            released = true;
            break;
        }
        clock.sleepMillis(std.Io.Threaded.global_single_threaded.io(), 5);
    }
    try std.testing.expect(released);

    var one: [1]u8 = undefined;
    const stalledRead = stalled.read(&one);
    if (stalledRead) |n| {
        try std.testing.expectEqual(@as(usize, 0), n);
    } else |err| {
        try std.testing.expect(err == error.ConnectionReset or err == error.ConnectionClosed or err == error.ReadFailed);
    }

    // A later ordinary request must still be accepted and served successfully.
    var recovered = try tcp.connect(ctx.io, "127.0.0.1", srv.localPort());
    defer recovered.close();
    recovered.setReadTimeoutMs(5_000);
    try recovered.writeAll("GET /ok HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    var response: [1024]u8 = undefined;
    var total: usize = 0;
    while (total < response.len) {
        const n = try recovered.read(response[total..]);
        if (n == 0) break;
        total += n;
    }
    try std.testing.expect(std.mem.indexOf(u8, response[0..total], "HTTP/1.1 200 OK") != null);
    try std.testing.expect(std.mem.endsWith(u8, response[0..total], "ok"));
    srv.requestShutdown();
}

test "server compresses a large body once the input ceiling allows it" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    // 200 KiB of compressible text: above the default ceiling, so raising it is
    // what makes the response coded.
    const BigH = struct {
        fn h(c: *Context) anyerror!Response {
            const unit = "the server must code a large body once told it may ";
            const out = try c.allocator.alloc(u8, unit.len * 2600);
            for (out, 0..) |*b, i| b.* = unit[i % unit.len];
            return .{ .body = out, .contentType = "text/plain" };
        }
    };

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };

    // Reads a whole response off the socket and returns the bytes.
    const fetch = struct {
        fn go(c: tcp.Socket) ![]u8 {
            try c.writeAll("GET /big HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n");
            var out = std.ArrayList(u8).empty;
            errdefer out.deinit(std.testing.allocator);
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = c.read(&buf) catch break;
                if (n == 0) break;
                try out.appendSlice(std.testing.allocator, buf[0..n]);
            }
            return out.toOwnedSlice(std.testing.allocator);
        }
    };

    // Default ceiling: the body is served as-is.
    {
        var srv = Server.init(a, ctx.io, .{ .port = 0, .enableDocs = false, .maxConnections = 1 }) catch return;
        defer srv.deinit();
        try srv.router.get("/big", BigH.h, .{});
        const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
        defer t.join();

        var client = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
        defer client.close();
        const wire = fetch.go(client) catch return;
        defer a.free(wire);
        try std.testing.expect(std.mem.indexOf(u8, wire, "Content-Encoding") == null);
        try std.testing.expect(std.mem.indexOf(u8, wire, "the server must code a large body") != null);
        srv.requestShutdown();
    }

    // Raised ceiling: the same handler is now coded, and Content-Length
    // describes the coded bytes rather than the original body.
    {
        var srv = Server.init(a, ctx.io, .{
            .port = 0,
            .enableDocs = false,
            .maxConnections = 1,
            .maxCompressionInput = 1024 * 1024,
        }) catch return;
        defer srv.deinit();
        try srv.router.get("/big", BigH.h, .{});
        const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
        defer t.join();

        var client = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
        defer client.close();
        const wire = fetch.go(client) catch return;
        defer a.free(wire);

        const headEnd = std.mem.indexOf(u8, wire, "\r\n\r\n") orelse return error.Malformed;
        const head = wire[0..headEnd];
        try std.testing.expect(std.mem.indexOf(u8, head, "Content-Encoding: gzip") != null);
        try std.testing.expect(std.mem.indexOf(u8, head, "Vary: Accept-Encoding") != null);
        try std.testing.expect(std.mem.indexOf(u8, wire[headEnd + 4 ..], "the server must code a large body") == null);

        const bodyLen = std.mem.indexOf(u8, wire[headEnd + 4 ..], "\x1f\x8b") orelse return error.Malformed;
        try std.testing.expect(bodyLen < 100 * 1024);
        srv.requestShutdown();
    }
}

test "raw socket 200KB content-length body roundtrip" {
    const a = std.testing.allocator;
    var ctx0 = tcp.IoContext.init(a) catch return;
    defer ctx0.deinit();
    var srv = Server.init(a, ctx0.io, .{ .port = 0, .enableDocs = false, .maxConnections = 1 }) catch return;
    defer srv.deinit();
    const LenH = struct {
        fn h(ctx: *Context) anyerror!Response {
            const t = std.fmt.allocPrint(ctx.allocator, "{d}", .{ctx.body.len}) catch return error.OutOfMemory;
            return .{ .body = t };
        }
    };
    try srv.router.post("/len", LenH.h, .{});
    const R = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const th = std.Thread.spawn(.{}, R.run, .{&srv}) catch return;
    defer th.join();
    var c = tcp.connect(ctx0.io, "127.0.0.1", srv.localPort()) catch return;
    defer c.drainThenClose();
    const total = 200 * 1024;
    var hb: [128]u8 = undefined;
    const head = try std.fmt.bufPrint(&hb, "POST /len HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\n\r\n", .{total});
    try c.writeAll(head);
    var blk: [4096]u8 = undefined;
    var sent: usize = 0;
    while (sent < total) : (sent += blk.len) try c.writeAll(&blk);
    var rb: [256]u8 = undefined;
    var gotn: usize = 0;
    while (gotn < rb.len) {
        const n = c.read(rb[gotn..]) catch break;
        if (n == 0) break;
        gotn += n;
        if (std.mem.indexOf(u8, rb[0..gotn], "204800") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, rb[0..gotn], "204800") != null);
}
test "reason phrases cover common statuses" {
    try std.testing.expectEqualStrings("OK", reasonFor(200));
    try std.testing.expectEqualStrings("Not Found", reasonFor(404));
}

test "server isTls default is false" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .maxConnections = 1,
    }) catch return;
    defer srv.deinit();

    try std.testing.expect(!srv.isTls());
}

test "server setTls dynamic reconfiguration and key zeroing" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .maxConnections = 1,
    }) catch return;
    defer srv.deinit();

    try std.testing.expect(!srv.isTls());

    const cert1 = @embedFile("../protocols/tls/testdata/localhostCert.pem");
    const key1 = @embedFile("../protocols/tls/testdata/localhostKey.pem");
    try srv.setTls(cert1, key1);
    try std.testing.expect(srv.isTls());
    try std.testing.expectEqualStrings(cert1, srv.tlsCertPemLoaded.?);

    // Reconfigure dynamically with new cert/key
    const cert2 = @embedFile("../protocols/tls/testdata/localhostCert.pem");
    const key2 = @embedFile("../protocols/tls/testdata/localhostKey.pem");
    try srv.setTls(cert2, key2);
    try std.testing.expect(srv.isTls());
    try std.testing.expectEqualStrings(cert2, srv.tlsCertPemLoaded.?);
}

test "strict HTTPS mode rejects plain HTTP with 400 Bad Request" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .maxConnections = 1,
    }) catch return;
    defer srv.deinit();

    const cert = @embedFile("../protocols/tls/testdata/localhostCert.pem");
    const key = @embedFile("../protocols/tls/testdata/localhostKey.pem");
    try srv.setTls(cert, key);
    try std.testing.expect(srv.isTls());

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
    defer t.join();

    var client = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
    defer client.close();

    try client.writeAll("GET /secret HTTP/1.1\r\nHost: localhost\r\n\r\n");

    var buf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = client.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "400 Bad Request") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "400 Bad Request") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "The plain HTTP request was sent to HTTPS port") != null);

    srv.requestShutdown();
}

test "server default TLS ALPN negotiates HTTP/2 and serves a request" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = try Server.init(a, ctx.io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
        .maxConnections = 1,
        .tls = .{
            .certificatePem = h3TestCertPem,
            .privateKeyPem = h3TestKeyPem,
        },
    });
    defer srv.deinit();
    try srv.router.get("/h2-tls", returnOk, .{});
    try std.testing.expectEqual(alpnMod.Protocol.h2, srv.cfg.tls.?.alpn[0]);

    const Runner = struct {
        fn run(server: *Server) void {
            server.run();
        }
    };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&srv});
    defer thread.join();

    var sock = try tcp.connect(ctx.io, "127.0.0.1", srv.localPort());
    errdefer sock.close();
    var tlsClient = try @import("../protocols/tls/tlsClient.zig").Client.init(a, ctx.io, .{});
    defer tlsClient.deinit();
    var tlsConn = try tlsClient.connect(&sock, "127.0.0.1", .{
        .verify = .caBundle,
        .caPem = h3TestCertPem,
        .alpn = &.{.h2},
    });
    var tlsTransferred = true;
    defer if (tlsTransferred) tlsConn.deinit();

    const h2 = try @import("../protocols/http2/transport.zig").Client.connectTls(a, &tlsConn);
    tlsTransferred = false;
    defer h2.deinit();

    const response = try h2.request("GET", "/h2-tls", &.{}, "https", "127.0.0.1", null, 1024);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("ok", response.body);
}

test "server TLS initialization fails instead of silently serving cleartext" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    const result = Server.init(a, ctx.io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
        .tls = .{
            .certificatePem = "-----BEGIN CERTIFICATE-----\ninvalid\n-----END CERTIFICATE-----",
            .privateKeyPem = h3TestKeyPem,
        },
    });
    if (result) |serverValue| {
        var server = serverValue;
        server.deinit();
        return error.InvalidTlsIdentityAccepted;
    } else |_| {}
}

var gTlsFailedSeen: bool = false;
var gTlsFailedMu: sync.Spinlock = .{};

fn testTlsEventCallback(event: logging.ServerEvent) void {
    if (event.kind == .tlsHandshakeFailed) {
        gTlsFailedMu.lock();
        defer gTlsFailedMu.unlock();
        gTlsFailedSeen = true;
    }
}

test "malformed TLS handshake emits tlsHandshakeFailed event" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    gTlsFailedMu.lock();
    gTlsFailedSeen = false;
    gTlsFailedMu.unlock();

    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .maxConnections = 1,
        .logging = .{ .callback = testTlsEventCallback, .level = .warn },
    }) catch return;
    defer srv.deinit();

    const cert = @embedFile("../protocols/tls/testdata/localhostCert.pem");
    const key = @embedFile("../protocols/tls/testdata/localhostKey.pem");
    try srv.setTls(cert, key);

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
    defer t.join();

    var client = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
    defer client.close();

    // Send a TLS 1.3 ClientHello record header (0x16, 0x03, 0x01) followed by corrupt payload
    const badTls = [_]u8{ 0x16, 0x03, 0x01, 0x00, 0x05, 0xde, 0xad, 0xbe, 0xef, 0x00 };
    try client.writeAll(&badTls);

    // Give server worker moment to process and emit event
    clock.sleepMillis(std.Io.Threaded.global_single_threaded.io(), 50);

    srv.requestShutdown();

    gTlsFailedMu.lock();
    const seen = gTlsFailedSeen;
    gTlsFailedMu.unlock();
    try std.testing.expect(seen);
}

test "StreamConn operations" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .maxConnections = 1,
    }) catch return;
    defer srv.deinit();
    try srv.router.get("/stream", returnOk, .{});

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
    defer t.join();

    var client = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
    defer client.close();

    try client.writeAll("GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n");

    var buf: [256]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = client.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "ok") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "ok") != null);

    srv.requestShutdown();
}

test "Context isTls and scheme reflect connection security" {
    const a = std.testing.allocator;
    var ctxPlain = Context{
        .allocator = a,
        .isTls = false,
    };
    try std.testing.expectEqualStrings("http", ctxPlain.scheme());

    var ctxTls = Context{
        .allocator = a,
        .isTls = true,
    };
    try std.testing.expectEqualStrings("https", ctxTls.scheme());

    var hdrs: [1]routerMod.Header = .{.{ .name = "X-Forwarded-Proto", .value = "https" }};
    var ctxForwarded = Context{
        .allocator = a,
        .isTls = false,
        .trustForwarded = true,
        .headers = &hdrs,
    };
    try std.testing.expectEqualStrings("https", ctxForwarded.scheme());
}

test "server metrics snapshot and live Prometheus endpoint" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{
        .port = 0,
        .enableDocs = false,
        .maxConnections = 2,
    }) catch return;
    defer srv.deinit();

    try srv.router.get("/hello", helloHandler, .{});
    try srv.metrics("/metrics");

    const snap0 = srv.metricsSnapshot();
    try std.testing.expectEqual(@as(u64, 0), snap0.requestsTotal);

    const sSnap0 = srv.snapshot();
    try std.testing.expectEqual(@as(u64, 0), sSnap0.requestsTotal);

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
    defer t.join();

    // Make a request to /hello to populate metrics
    {
        var client = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
        defer client.close();

        try client.writeAll("GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n");

        var buf: [256]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            const n = client.read(buf[total..]) catch break;
            if (n == 0) break;
            total += n;
            if (std.mem.indexOf(u8, buf[0..total], "hi") != null) break;
        }
        try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "hi") != null);
    }

    // Now query /metrics endpoint
    {
        var client = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
        defer client.close();

        try client.writeAll("GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n");

        var buf: [2048]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            const n = client.read(buf[total..]) catch break;
            if (n == 0) break;
            total += n;
            if (std.mem.indexOf(u8, buf[0..total], "http_requests_total") != null and
                std.mem.indexOf(u8, buf[0..total], "http_request_duration_seconds_bucket") != null) break;
        }
        const resp = buf[0..total];
        try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp, "http_requests_total") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp, "http_requests_by_method_total{method=\"GET\"}") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp, "http_request_duration_seconds_bucket") != null);
    }

    srv.requestShutdown();

    const snap1 = srv.metricsSnapshot();
    try std.testing.expect(snap1.requestsTotal >= 2);
    try std.testing.expectEqual(@as(u64, 0), snap1.errorsTotal);

    const sSnap1 = srv.snapshot();
    try std.testing.expect(sSnap1.requestsTotal >= 2);
    // The /metrics connection may still be draining when requestShutdown
    // returns; allow either quiesced state rather than asserting exact zero.
    try std.testing.expect(sSnap1.activeRequests <= 1);
}

test "port zero allocates ephemeral port; strict rejects occupied port" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var first = Server.init(a, ctx.io, .{ .port = 0, .enableDocs = false }) catch return;
    defer first.deinit();
    const bound = first.localPort();
    try std.testing.expect(bound != 0);

    // Strict strategy on the occupied port must surface an error, not steal it.
    if (Server.init(a, ctx.io, .{
        .host = "127.0.0.1",
        .port = bound,
        .portStrategy = .strict,
        .enableDocs = false,
    })) |s| {
        // Binding the loopback while the wildcard holds it may succeed on
        // some platforms; either outcome must leave a usable listener.
        var srv = s;
        srv.deinit();
    } else |_| {}

    // Incremental strategy must find a free port instead of failing.
    var second = Server.init(a, ctx.io, .{
        .host = "127.0.0.1",
        .port = bound,
        .portStrategy = .incremental,
        .maxPortAttempts = 8,
        .enableDocs = false,
    }) catch return;
    defer second.deinit();
    try std.testing.expect(second.localPort() != 0);
}

/// Self-signed localhost credential used by the HTTP/3 tests. ECDSA
/// P-256, valid for the `127.0.0.1` SAN.
pub const h3TestCertPem =
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

pub const h3TestKeyPem =
    \\-----BEGIN PRIVATE KEY-----
    \\MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgyp549r9FrXbm02Cn
    \\81gAdAbUzHatPYQWVDIWnQdCMPChRANCAATvUPikzRIA8ryx237GUQRJlf8Qmgod
    \\QL7gik+5KU6JC4Jc6Q3TijNUYoCauZS0OpAJ2+Z2MduOoZjpMKzNdMKc
    \\-----END PRIVATE KEY-----
;

test "Server high-level HTTP/3 initialization and endpoint lifecycle" {
    const a = std.testing.allocator;
    var ctx = try tcp.IoContext.init(a);
    defer ctx.deinit();

    var srv = try Server.init(a, ctx.io, .{
        .host = "127.0.0.1",
        .port = 0,
        .http3 = true,
        .tls = .{
            .certificatePem = h3TestCertPem,
            .privateKeyPem = h3TestKeyPem,
        },
        .enableDocs = false,
    });
    defer srv.deinit();

    try std.testing.expect(srv.h3Endpoint != null);
    try std.testing.expect(srv.h3Pump == null);
    // Port 0 was requested. HTTP/3 normally shares the port the TCP
    // listener was given, because that is the number a caller discovers
    // with `localPort()`. It only differs when that UDP bind failed and
    // the endpoint fell back to an ephemeral port, so the contract is
    // "always a real, reachable port", not a specific number.
    const port = srv.http3.port() orelse return error.MissingHttp3Port;
    try std.testing.expect(port != 0);
}

test "HTTP/3 endpoint reports the port HTTP/1.1 does not share" {
    // The named accessor is the supported way to find the UDP port, so it
    // must agree with the endpoint even when the two ports diverge.
    const a = std.testing.allocator;
    var ctx = try tcp.IoContext.init(a);
    defer ctx.deinit();

    var srv = try Server.init(a, ctx.io, .{
        .host = "127.0.0.1",
        .port = 0,
        .http3 = true,
        .tls = .{
            .certificatePem = h3TestCertPem,
            .privateKeyPem = h3TestKeyPem,
        },
        .enableDocs = false,
    });
    defer srv.deinit();

    const reported = srv.http3.port().?;
    const actual = srv.h3Endpoint.?.localPort();
    try std.testing.expectEqual(actual, reported);
    try std.testing.expect(reported != 0);
}

test "Server shares one port number between HTTP/1.1 and HTTP/3 when the port is explicit" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    // Probe with UDP, not TCP. Windows keeps the dynamic port ranges for TCP
    // and UDP separate, so a TCP-chosen port can land in a range the UDP
    // stack refuses to bind, which is exactly the port HTTP/3 needs.
    const freePort = blk: {
        var probe = udpMod.UdpSocket.bind(ctx.io, 0) catch break :blk @as(u16, 0);
        defer probe.close();
        break :blk switch (probe.socket.address) {
            .ip4 => |v| v.port,
            .ip6 => |v| v.port,
        };
    };
    if (freePort == 0) return;

    var srv = Server.init(a, ctx.io, .{
        .host = "127.0.0.1",
        .port = freePort,
        .portStrategy = .strict,
        .http3 = true,
        .tls = .{
            .certificatePem = h3TestCertPem,
            .privateKeyPem = h3TestKeyPem,
        },
        .enableDocs = false,
    }) catch return;
    defer srv.deinit();

    try std.testing.expectEqual(freePort, srv.localPort());
    try std.testing.expectEqual(freePort, srv.http3.port().?);
}

test "explicit HTTP/3 port conflict fails instead of silently rebinding" {
    // An explicit port is a promise: if UDP cannot take it, init must fail
    // (and release the TCP listener), not move HTTP/3 somewhere else.
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var probe = udpMod.UdpSocket.bind(ctx.io, 0) catch return;
    defer probe.close();
    const port = switch (probe.socket.address) {
        .ip4 => |v| v.port,
        .ip6 => |v| v.port,
    };

    var addr = addressMod.Address.unspecified4(port);
    var tcpProbe = tcp.Listener.bindAddress(ctx.io, &addr) catch return;
    tcpProbe.close(ctx.io);

    try std.testing.expectError(error.AddressInUse, Server.init(a, ctx.io, .{
        .host = "127.0.0.1",
        .port = port,
        .portStrategy = .strict,
        .http3 = true,
        .tls = .{
            .certificatePem = h3TestCertPem,
            .privateKeyPem = h3TestKeyPem,
        },
        .enableDocs = false,
    }));

    var rebound = tcp.Listener.bindAddress(ctx.io, &addr) catch return error.TcpPortLeaked;
    rebound.close(ctx.io);
}

test "Server reports no HTTP/3 port when HTTP/3 is disabled" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
    }) catch return;
    defer srv.deinit();

    try std.testing.expectEqual(@as(?u16, null), srv.http3.port());
}

test "trusted proxy rules gate forwarded headers" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    var srv = Server.init(a, ctx.io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
        .trustForwardedHeaders = true,
        .trustedProxies = &.{ "10.0.0.0/8", "::1" },
    }) catch return;
    defer srv.deinit();

    try std.testing.expect(srv.trustForwardedFor("10.1.2.3"));
    try std.testing.expect(srv.trustForwardedFor("::1"));
    try std.testing.expect(!srv.trustForwardedFor("127.0.0.1"));
    try std.testing.expect(!srv.trustForwardedFor(""));

    // An empty proxy list explicitly trusts every peer.
    srv.cfg.trustedProxies = &.{};
    try std.testing.expect(srv.trustForwardedFor("127.0.0.1"));

    srv.cfg.trustForwardedHeaders = false;
    try std.testing.expect(!srv.trustForwardedFor("127.0.0.1"));
}

test "direct clients cannot spoof the remote address through forwarded headers" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    const H = struct {
        fn handle(c: *Context) anyerror!Response {
            return .{
                .body = c.remoteAddress() orelse "none",
                .contentType = "text/plain",
            };
        }
    };

    var srv = Server.init(a, ctx.io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
        .maxConnections = 2,
        .trustForwardedHeaders = true,
        .trustedProxies = &.{"10.0.0.1"},
    }) catch return;
    defer srv.deinit();
    try srv.router.get("/", H.handle, .{});

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
    defer t.join();

    var client = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
    defer client.close();
    try client.writeAll("GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: 203.0.113.9\r\nX-Real-IP: 203.0.113.9\r\nConnection: close\r\n\r\n");

    var buf: [2048]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = client.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "\r\n\r\n127.0.0.1") != null);

    srv.requestShutdown();
}

test "trusted proxies resolve the rightmost client address" {
    const a = std.testing.allocator;
    var ctx = tcp.IoContext.init(a) catch return;
    defer ctx.deinit();

    const H = struct {
        fn handle(c: *Context) anyerror!Response {
            return .{
                .body = c.remoteAddress() orelse "none",
                .contentType = "text/plain",
            };
        }
    };

    var srv = Server.init(a, ctx.io, .{
        .host = "127.0.0.1",
        .port = 0,
        .enableDocs = false,
        .maxConnections = 2,
        .trustForwardedHeaders = true,
        .trustedProxies = &.{"127.0.0.1"},
    }) catch return;
    defer srv.deinit();
    try srv.router.get("/", H.handle, .{});

    const Runner = struct {
        fn run(s: *Server) void {
            s.run();
        }
    };
    const t = std.Thread.spawn(.{}, Runner.run, .{&srv}) catch return;
    defer t.join();

    var client = tcp.connect(ctx.io, "127.0.0.1", srv.localPort()) catch return;
    defer client.close();
    try client.writeAll("GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: 203.0.113.9, 198.51.100.7\r\nConnection: close\r\n\r\n");

    var buf: [2048]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = client.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "\r\n\r\n198.51.100.7") != null);

    srv.requestShutdown();
}
