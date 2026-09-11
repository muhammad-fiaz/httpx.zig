//! httpx.zig - Batteries-included native Zig networking library.
//!
//! One library. One coherent API.
//!
//! Layers (bottom -> top):
//!   common/     - shared primitives (errors, status, headers, URI, methods, logging)
//!   sockets/    - TCP + UDP wrappers (std.Io based)
//!   net/        - addresses (IPv4+IPv6), DNS, SOCKS5
//!   protocols/  - HTTP/1.x parser+serializer, HTTP/2 engine, HTTP/3+QUIC,
//!                 TLS with custom ALPN, FTP
//!   compression/- gzip/deflate/zstd/brotli codecs + content negotiation
//!   web/        - router, middleware, SSE, WebSocket, docs, SPA, health,
//!                 metrics, multipart, cookies, auth, static files, openapi
//!   server/     - server lifecycle, connections, request context
//!   client/     - request engine, connection pool, cookie jar, zero-config

const std = @import("std");

// External dependencies
pub const tint = @import("loaders").tint;
pub const loaders = @import("loaders");
pub const brotli = @import("brotli");
pub const zstd = @import("zstd");
pub const env = @import("env");

// Common primitives
pub const ioCtx = @import("common/io.zig");
pub const IoContext = ioCtx.IoContext;
pub const versionInfo = @import("common/version.zig");
pub const name = versionInfo.name;
pub const version = versionInfo.version;
pub const errors = @import("common/errors.zig");
pub const status = @import("common/status.zig");
pub const headers = @import("common/headers.zig");
pub const uri = @import("common/uri.zig");
pub const method = @import("common/method.zig");
pub const httpVersion = @import("common/http_version.zig");
pub const HttpVersion = httpVersion.HttpVersion;
pub const common = struct {
    pub const clock = @import("common/clock.zig");
    pub const sync = @import("common/sync.zig");
    pub const version = @import("common/version.zig");
    pub const httpVersion = @import("common/http_version.zig");
    pub const io = @import("common/io.zig");
};
pub const clock = common.clock;
pub const sync = common.sync;
pub const concurrency = struct {
    pub const queue = @import("concurrency/queue.zig");
    pub const Queue = @import("concurrency/queue.zig").BoundedQueue;
    pub const workerPool = @import("concurrency/worker_pool.zig");
    pub const WorkerPool = @import("concurrency/worker_pool.zig").Pool;
    pub const Pool = @import("concurrency/worker_pool.zig").Pool;
};
pub const workerPool = concurrency.workerPool;
pub const WorkerPool = concurrency.WorkerPool;
pub const Queue = concurrency.Queue;
pub const logging = @import("common/logging.zig");

// Sockets
pub const tcp = @import("sockets/tcp.zig");
/// Raw socket syscall layer: exhaustive platform error mapping (Phase 2).
pub const sys = @import("sockets/sys.zig");
pub const udp = @import("sockets/udp.zig");

// Network layer
pub const address = @import("net/address.zig");
pub const dns = @import("net/dns.zig");
pub const resolve = @import("net/resolve.zig");
pub const connectivity = @import("net/connectivity.zig");
pub const socks5 = @import("net/socks5.zig");
pub const socks4 = @import("net/socks4.zig");
pub const proxy = @import("net/proxy.zig");

// Compression
pub const compression = @import("compression/codec.zig");

// Protocol engines
/// Shared low-level protocol primitives (prefix integers, Huffman code).
pub const proto = struct {
    pub const common = struct {
        pub const integer = @import("protocols/common/integer.zig");
        pub const huffman = @import("protocols/common/huffman.zig");
    };
};
pub const http1 = struct {
    pub const parser = @import("protocols/http1/parser.zig");
    pub const writer = @import("protocols/http1/writer.zig");
    pub const semantics = @import("protocols/http1/semantics.zig");
    pub const fuzz = @import("protocols/http1/fuzz.zig");
};
pub const http2 = struct {
    pub const frame = @import("protocols/http2/frame.zig");
    pub const hpack = @import("protocols/http2/hpack.zig");
    pub const stream = @import("protocols/http2/stream.zig");
    pub const connection = @import("protocols/http2/connection.zig");
    pub const Session = connection.Session;
    pub const Stream = stream.Stream;
    pub const ErrorCode = stream.ErrorCode;
    pub const Frame = frame.Frame;
    pub const FrameHeader = frame.FrameHeader;
    pub const transport = @import("protocols/http2/transport.zig");
    pub const Client = transport.Client;
};
pub const quic = struct {
    pub const varint = @import("protocols/quic/varint.zig");
    pub const packet = @import("protocols/quic/packet.zig");
    pub const crypto = @import("protocols/quic/crypto.zig");
    pub const protect = @import("protocols/quic/protect.zig");
    pub const frames = @import("protocols/quic/frames.zig");
    pub const acktr = @import("protocols/quic/acktr.zig");
    pub const loss = @import("protocols/quic/loss.zig");
    pub const cc = @import("protocols/quic/cc.zig");
    pub const params = @import("protocols/quic/params.zig");
    pub const stream = @import("protocols/quic/stream.zig");
    pub const Stream = stream.Stream;
    pub const connection = @import("protocols/quic/connection.zig");
    pub const Connection = connection.Connection;
    pub const connectionId = @import("protocols/quic/connection_id.zig");
    pub const path = @import("protocols/quic/path.zig");
    pub const transport = @import("protocols/quic/transport.zig");
    pub const Endpoint = transport.Endpoint;
    pub const Pump = transport.Pump;
    pub const handshake = @import("protocols/quic/handshake.zig");
    pub const HandshakeDriver = handshake.Driver;

    pub fn encodeFrame(allocator: std.mem.Allocator, f: frames.Frame) !std.ArrayList(u8) {
        var out = std.ArrayList(u8).empty;
        try frames.encode(&out, allocator, f);
        return out;
    }
};
pub const http3 = struct {
    pub const frame = @import("protocols/http3/frame.zig");
    pub const FrameHeader = frame.FrameHeader;
    pub const ParsedFrame = frame.ParsedFrame;
    pub const qpack = @import("protocols/http3/qpack.zig");
    pub const connection = @import("protocols/http3/connection.zig");
    pub const Connection = connection.Connection;
    pub const RequestStream = connection.RequestStream;
    pub const Settings = connection.Settings;
    pub const transport = @import("protocols/http3/transport.zig");
    pub const Client = transport.Client;
};
pub const tls = @import("protocols/tls/tls.zig");

// Web framework
pub const router = struct {
    pub const Router = @import("web/router/router.zig").Router;
    pub const Context = @import("web/router/router.zig").Context;
    pub const Response = @import("web/router/router.zig").Response;
    pub const Header = @import("web/router/router.zig").Header;
    pub const HandlerFn = @import("web/router/router.zig").HandlerFn;
    pub const NextFn = @import("web/router/router.zig").NextFn;
    pub const MiddlewareFn = @import("web/router/router.zig").MiddlewareFn;
    pub const pattern = @import("web/router/pattern.zig");
    pub const metadata = @import("web/router/metadata.zig");
};
pub const sse = struct {
    pub const Writer = @import("web/sse/writer.zig");
    pub const Parser = @import("web/sse/parser.zig");
    pub const EventWriter = @import("web/sse/writer.zig").EventWriter;
    pub const Event = @import("web/sse/parser.zig").Event;
    pub const EventParser = @import("web/sse/parser.zig").EventParser;
};
pub const websocket = struct {
    pub const Handshake = @import("web/websocket/handshake.zig");
    pub const Frame = @import("web/websocket/frame.zig");
    pub const computeAccept = Handshake.computeAccept;
    pub const buildUpgradeRequest = Handshake.buildUpgradeRequest;
};

// Native Template Engine
pub const templates = @import("web/templates/templates.zig");
pub const TemplateEngine = templates.Engine;
pub const TemplateConfig = templates.Config;
pub const assets = @import("web/assets.zig");
pub const site = @import("web/site/site.zig");
pub const Site = site.Site;
pub const static = struct {
    pub const files = @import("web/static_files/serve.zig");
    pub const spa = @import("web/spa/serve.zig");
    pub const watcher = @import("web/watcher/backend.zig");
    pub const Watcher = watcher.Watcher;
    pub const ReloadStrategy = watcher.ReloadStrategy;
    pub const WatchEvent = watcher.WatchEvent;
    pub const WatchEventKind = watcher.WatchEventKind;
    pub const WatcherConfig = watcher.WatcherConfig;
    pub const events = @import("web/watcher/events.zig");
    pub const backend = @import("web/watcher/backend.zig");
    pub const dependency = @import("web/watcher/dependency.zig");
    pub const reload = @import("web/watcher/reload.zig");
};
pub const Watcher = static.Watcher;
pub const ReloadStrategy = static.ReloadStrategy;
pub const WatchEvent = static.WatchEvent;
pub const WatchEventKind = static.WatchEventKind;
pub const health = @import("web/health/endpoints.zig");
pub const metrics = @import("web/metrics/registry.zig");
pub const mime = @import("utils/mime.zig");
pub const fs = @import("utils/fs.zig");
pub const openapi = @import("web/openapi/spec.zig");
pub const docs = @import("web/docs/docs.zig");
pub const graphql = @import("web/graphql/graphql.zig");
pub const auth = struct {
    pub const basic = @import("web/auth/basic.zig");
    pub const bearer = @import("web/auth/bearer.zig");
};
pub const multipart = struct {
    pub const encoder = @import("web/multipart/encoder.zig");
    pub const parser = @import("web/multipart/parser.zig");
};

// Middleware
pub const middleware = struct {
    const sec = @import("web/middleware/security.zig");
    pub const cors = sec.corsMiddleware;
    pub const CorsConfig = sec.CorsConfig;
    pub const helmet = sec.securityHeadersMiddleware;
    pub const recovery = sec.recoveryMiddleware;
    pub const logging = sec.loggingMiddleware;
    pub const RateLimiter = sec.RateLimiter;
    pub const RateLimitPolicy = sec.RateLimitPolicy;
    pub const RateLimitResult = sec.RateLimitResult;
    pub const RateLimitDimension = sec.RateLimitDimension;
    pub const generateCsrfToken = sec.generateCsrfToken;
    pub const verifyCsrfToken = sec.verifyCsrfToken;
    pub const CSRF_TOKEN_LEN = sec.CSRF_TOKEN_LEN;
};

// Web framework facade
pub const web = struct {
    pub const router = @import("web/router/router.zig");
    pub const static = @import("web/static_files/serve.zig");
    pub const spa = @import("web/spa/serve.zig");
    pub const watcher = @import("web/watcher/backend.zig");
    pub const watcherEvents = @import("web/watcher/events.zig");
    pub const watcherDependency = @import("web/watcher/dependency.zig");
    pub const watcherReload = @import("web/watcher/reload.zig");
    pub const templates = @import("web/templates/templates.zig");
    pub const TemplateEngine = @import("web/templates/templates.zig").Engine;
    pub const assets = @import("web/assets.zig");
    pub const site = @import("web/site/site.zig");
    pub const sse = struct {
        pub const Writer = @import("web/sse/writer.zig");
        pub const Parser = @import("web/sse/parser.zig");
        pub const EventWriter = @import("web/sse/writer.zig").EventWriter;
        pub const Event = @import("web/sse/parser.zig").Event;
        pub const EventParser = @import("web/sse/parser.zig").EventParser;
    };
    pub const websocket = struct {
        pub const Handshake = @import("web/websocket/handshake.zig");
        pub const Frame = @import("web/websocket/frame.zig");
        pub const computeAccept = Handshake.computeAccept;
        pub const buildUpgradeRequest = Handshake.buildUpgradeRequest;
    };
    pub const health = @import("web/health/endpoints.zig");
    pub const metrics = @import("web/metrics/registry.zig");
    pub const openapi = @import("web/openapi/spec.zig");
    pub const docs = @import("web/docs/docs.zig");
    pub const graphql = @import("web/graphql/graphql.zig");
    pub const auth = struct {
        pub const basic = @import("web/auth/basic.zig");
        pub const bearer = @import("web/auth/bearer.zig");
    };
    pub const multipart = struct {
        pub const encoder = @import("web/multipart/encoder.zig");
        pub const parser = @import("web/multipart/parser.zig");
    };
    pub const middleware = struct {
        const sec = @import("web/middleware/security.zig");
        pub const cors = sec.corsMiddleware;
        pub const helmet = sec.securityHeadersMiddleware;
        pub const recovery = sec.recoveryMiddleware;
        pub const logging = sec.loggingMiddleware;
        pub const RateLimiter = sec.RateLimiter;
    };
};

// Client API (canonical paths live at the root: httpx.Client,
// httpx.ClientConfig, httpx.RequestOptions, httpx.get, ...).
pub const cookies = @import("client/cookies.zig");
pub const pool = @import("client/pool.zig");
pub const Client = @import("client/client.zig").Client;
pub const ClientConfig = @import("client/client.zig").Config;
pub const RequestOptions = @import("client/client.zig").RequestOptions;
pub const ClientResponse = @import("client/request.zig").Response;
pub const Header = @import("client/request.zig").Header;
pub const TlsOptions = @import("client/request.zig").TlsOptions;
pub const Headers = headers.Headers;
pub const CookieJar = cookies.Jar;
pub const ConnectionPool = pool.Pool;
pub const PoolConfig = pool.PoolConfig;

// Zero-config client functions & canonical HTTP verbs
pub const fetch = @import("client/client.zig").globalFetch;
pub const request = @import("client/client.zig").globalRequest;
pub const get = @import("client/client.zig").globalGet;
pub const post = @import("client/client.zig").globalPost;
pub const put = @import("client/client.zig").globalPut;
pub const patch = @import("client/client.zig").globalPatch;
pub const delete = @import("client/client.zig").globalDelete;
pub const head = @import("client/client.zig").globalHead;
pub const options = @import("client/client.zig").globalOptions;
pub const trace = @import("client/client.zig").globalTrace;
pub const connect = @import("client/client.zig").globalConnect;
pub const getAll = @import("client/client.zig").globalGetAll;
pub const requestAll = @import("client/client.zig").globalRequestAll;
// Namespaced operations (not root globals): client.download,
// client.graphql, client.lookupFileInfo, client.updateFile,
// Download.verifyFile / parseChecksumFile, client.fetchSitemap,
// client.resolve / client.resolveUrl. See Client and Download.
pub const isOnline = @import("client/client.zig").globalIsOnline;
pub const checkConnectivity = @import("client/client.zig").globalCheckConnectivity;
pub const ResolveOptions = @import("client/client.zig").ResolveOptions;
pub const ResolvedAddresses = @import("client/client.zig").ResolvedAddresses;
pub const AddressFamilyPreference = @import("client/client.zig").AddressFamilyPreference;

// Download & Progress types
pub const Download = @import("client/download.zig");
pub const DownloadOptions = Download.DownloadOptions;
pub const DownloadResult = Download.DownloadResult;
pub const DownloadError = Download.DownloadError;
pub const DownloadTask = struct { url: []const u8, dest: []const u8 };
pub const RemoteFileInfo = Download.RemoteFileInfo;
pub const ProgressInfo = Download.ProgressInfo;
pub const ProgressState = Download.ProgressState;
pub const ProgressMode = Download.ProgressMode;
pub const ExistingFilePolicy = Download.ExistingFilePolicy;
pub const VerifyOptions = Download.VerifyOptions;
pub const UpdateOptions = Download.UpdateOptions;
pub const parseChecksumFile = Download.parseChecksumFile;
pub const ConnectivityOptions = connectivity.ConnectivityOptions;
pub const ConnectivityResult = connectivity.ConnectivityResult;

// Parsing & inspection subsystem
/// Native HTML, XML, RSS/Atom/JSON feeds, robots.txt, and sitemap parsing engine.
pub const Parser = @import("parsing/document.zig").Parser;
pub const ParserConfig = @import("parsing/document.zig").ParserConfig;
pub const Document = @import("parsing/document.zig").Document;
pub const NodeHandle = @import("parsing/document.zig").NodeHandle;
pub const NodeList = @import("parsing/document.zig").NodeList;
pub const ContentKind = @import("parsing/document.zig").ContentKind;

pub const parsing = struct {
    pub const dom = @import("parsing/dom.zig");
    pub const html = @import("parsing/html.zig");
    pub const xml = @import("parsing/xml.zig");
    pub const selector = @import("parsing/selector.zig");
    pub const extract = @import("parsing/extract.zig");
    pub const feed = @import("parsing/feed.zig");
    pub const robots = @import("parsing/robots.zig");
    pub const sitemap = @import("parsing/sitemap.zig");
    pub const document = @import("parsing/document.zig");
    // NOTE: Tree-sitter is used directly inside the parsing modules above
    // (html/xml/feed/document) and web/templates/parser; it is intentionally
    // not re-exported here.
    // Re-export the Document and Parser types at this level
    pub const Document = document.Document;
    pub const Parser = document.Parser;
    pub const ParserConfig = document.ParserConfig;
    pub const NodeHandle = document.NodeHandle;
    pub const NodeList = document.NodeList;
    pub const ContentKind = document.ContentKind;
    pub const Metadata = extract.Metadata;
    pub const Link = extract.Link;
    pub const Form = extract.Form;
    pub const FormField = extract.FormField;
    pub const Image = extract.Image;
    pub const ScriptRef = extract.ScriptRef;
    pub const StyleRef = extract.StyleRef;
    pub const Feed = feed.Feed;
    pub const FeedKind = feed.FeedKind;
    pub const FeedEntry = feed.FeedEntry;
    pub const RobotsFile = robots.RobotsFile;
    pub const Sitemap = sitemap.Sitemap;
    pub const SitemapUrl = sitemap.SitemapUrl;
    pub const ChangeFreq = sitemap.ChangeFreq;
    pub const ParsedSelector = selector.ParsedSelector;
    // Unified Parser constructor with allocator and optional options
    pub fn init(allocator: std.mem.Allocator, config: document.ParserConfig) document.Parser {
        return document.Parser.init(allocator, config);
    }
    pub const detectKind = document.detectKind;
};

// Server API
pub const server = @import("server/lifecycle.zig");
pub const Server = server.Server;
pub const ServerConfig = server.Config;
pub const PortStrategy = server.PortStrategy;
pub const StreamConn = server.StreamConn;
pub const Router = router.Router;
pub const Context = router.Context;
pub const Response = router.Response;
pub const TlsServer = tls.TlsServer;
pub const TlsServerConn = tls.TlsServerConn;
pub const TlsServerConfig = tls.TlsServerConfig;
pub const TlsConfig = tls.ServerConfig;
pub const TlsClientConfig = tls.ClientConfig;

// Concurrency & Utilities
pub const WorkerPoolConfig = @import("concurrency/worker_pool.zig").Config;
pub const RateLimiter = @import("web/middleware/rate_limit.zig").RateLimiter;
pub const RateLimitPolicy = @import("web/middleware/rate_limit.zig").RateLimitPolicy;
pub const RateLimitResult = @import("web/middleware/rate_limit.zig").RateLimitResult;
pub const RateLimitDimension = @import("web/middleware/rate_limit.zig").RateLimitDimension;
pub const Metrics = metrics.Registry;
pub const Counter = metrics.Counter;
pub const Gauge = metrics.Gauge;
pub const Histogram = metrics.Histogram;
pub const MetricsSnapshot = metrics.MetricsSnapshot;
pub const ServerSnapshot = metrics.ServerSnapshot;
pub const ClientSnapshot = metrics.ClientSnapshot;
pub const Logger = logging.Logger;
pub const LogLevel = logging.Level;
pub const LogSink = logging.Sink;
pub const LogRecord = logging.Record;
pub const LogField = logging.Field;
pub const WriterSink = logging.WriterSink;
pub const ServerEvent = logging.ServerEvent;
pub const ServerEventKind = logging.ServerEventKind;

// Networking & Protocol Types
pub const Address = address.Address;
pub const Uri = uri.Uri;
pub const Method = method.Method;
pub const Status = status.Status;
pub const Http1Parser = http1.parser.Http1Parser;
pub const ChunkedDecoder = http1.parser.ChunkedDecoder;
pub const H2Session = http2.connection.Session;
pub const AlpnProtocol = tls.alpn.Protocol;

// FTP (isolated protocol subsystem)
pub const ftp = struct {
    const ftpClientMod = @import("protocols/ftp/client.zig");
    pub const Client = ftpClientMod.Client;
    pub const Options = ftpClientMod.Options;
    pub const Reply = ftpClientMod.Reply;
    pub const FtpError = ftpClientMod.FtpError;
    const ftpServer = @import("protocols/ftp/server.zig");
    pub const Server = ftpServer.Server;
    pub const Config = ftpServer.Config;
    pub const Callbacks = ftpServer.Callbacks;
    pub const download = @import("client/download.zig").ftpDownload;
    pub const DownloadOptions = @import("client/download.zig").FtpDownloadOptions;
};

// Tests
test {
    _ = @import("common/errors.zig");
    _ = @import("common/status.zig");
    _ = @import("common/headers.zig");
    _ = @import("common/uri.zig");
    _ = @import("common/method.zig");
    _ = @import("common/version.zig");
    _ = @import("common/http_version.zig");
    _ = @import("common/io.zig");
    _ = @import("common/sync.zig");
    _ = @import("concurrency/queue.zig");
    _ = @import("concurrency/worker_pool.zig");
    _ = @import("common/logging.zig");
    _ = @import("sockets/tcp.zig");
    _ = @import("sockets/sys.zig");
    _ = @import("sockets/udp.zig");
    _ = @import("net/address.zig");
    _ = @import("net/dns.zig");
    _ = @import("net/dns/cache.zig");
    _ = @import("net/resolve.zig");
    _ = @import("net/socks5.zig");
    _ = @import("net/socks4.zig");
    _ = @import("net/proxy.zig");
    _ = @import("compression/codec.zig");
    _ = @import("protocols/http1/parser.zig");
    _ = @import("protocols/http1/writer.zig");
    _ = @import("protocols/http1/semantics.zig");
    _ = @import("protocols/http1/fuzz.zig");
    _ = @import("protocols/common/integer.zig");
    _ = @import("protocols/common/huffman.zig");
    _ = @import("protocols/common/huffman_table.zig");
    _ = @import("protocols/http2/frame.zig");
    _ = @import("protocols/http2/hpack.zig");
    _ = @import("protocols/http2/stream.zig");
    _ = @import("protocols/http2/connection.zig");
    _ = @import("protocols/quic/varint.zig");
    _ = @import("protocols/quic/packet.zig");
    _ = @import("protocols/quic/crypto.zig");
    _ = @import("protocols/quic/protect.zig");
    _ = @import("protocols/quic/frames.zig");
    _ = @import("protocols/quic/acktr.zig");
    _ = @import("protocols/quic/loss.zig");
    _ = @import("protocols/quic/cc.zig");
    _ = @import("protocols/quic/params.zig");
    _ = @import("protocols/quic/stream.zig");
    _ = @import("protocols/quic/connection.zig");
    _ = @import("protocols/quic/connection_id.zig");
    _ = @import("protocols/quic/path.zig");
    _ = @import("protocols/quic/transport.zig");
    _ = @import("protocols/tls/quicTls.zig");
    _ = @import("protocols/http3/frame.zig");
    _ = @import("protocols/http3/qpack.zig");
    _ = @import("protocols/http3/connection.zig");
    _ = @import("protocols/http3/transport.zig");
    _ = @import("protocols/quic/handshake.zig");
    _ = @import("protocols/tls/alpn.zig");
    _ = @import("protocols/tls/config.zig");
    _ = @import("protocols/tls/record.zig");
    _ = @import("protocols/tls/handshake.zig");
    _ = @import("protocols/tls/engine.zig");
    _ = @import("protocols/tls/quicTls.zig");
    _ = @import("protocols/tls/tcpTls.zig");
    _ = @import("protocols/tls/tcpClient.zig");
    _ = @import("protocols/tls/session.zig");
    _ = @import("protocols/tls/tls.zig");
    _ = @import("protocols/tls/transport.zig");
    _ = @import("web/router/pattern.zig");
    _ = @import("web/router/metadata.zig");
    _ = @import("web/router/router.zig");
    _ = @import("web/sse/writer.zig");
    _ = @import("web/sse/parser.zig");
    _ = @import("web/websocket/handshake.zig");
    _ = @import("web/websocket/frame.zig");
    _ = @import("web/middleware/security.zig");
    _ = @import("web/middleware/rate_limit.zig");
    _ = @import("web/docs/docs.zig");
    _ = @import("web/graphql/graphql.zig");
    _ = @import("web/openapi/spec.zig");
    _ = @import("web/static_files/serve.zig");
    _ = @import("web/watcher/backend.zig");
    _ = @import("web/watcher/events.zig");
    _ = @import("web/watcher/dependency.zig");
    _ = @import("web/watcher/reload.zig");
    _ = @import("web/spa/serve.zig");
    _ = @import("web/site/routes.zig");
    _ = @import("web/site/site.zig");
    _ = @import("web/health/endpoints.zig");
    _ = @import("web/metrics/registry.zig");
    _ = @import("utils/mime.zig");
    _ = @import("utils/fs.zig");
    _ = @import("web/auth/basic.zig");
    _ = @import("web/auth/bearer.zig");
    _ = @import("web/multipart/encoder.zig");
    _ = @import("web/multipart/parser.zig");
    _ = @import("client/request.zig");
    _ = @import("client/client.zig");
    _ = @import("client/cookies.zig");
    _ = @import("client/pool.zig");
    _ = @import("protocols/ftp/client.zig");
    _ = @import("protocols/ftp/server.zig");
    _ = @import("protocols/http2/transport.zig");
    _ = @import("server/lifecycle.zig");
    _ = @import("parsing/dom.zig");
    _ = @import("parsing/html.zig");
    _ = @import("parsing/xml.zig");
    _ = @import("parsing/selector.zig");
    _ = @import("parsing/extract.zig");
    _ = @import("parsing/feed.zig");
    _ = @import("parsing/robots.zig");
    _ = @import("parsing/sitemap.zig");
    _ = @import("parsing/document.zig");
    _ = @import("web/templates/error.zig");
    _ = @import("web/templates/context.zig");
    _ = @import("web/templates/parser.zig");
    _ = @import("web/templates/renderer.zig");
    _ = @import("web/templates/loader.zig");
    _ = @import("web/templates/cache.zig");
    _ = @import("web/templates/engine.zig");
    _ = @import("web/templates/templates.zig");
}

test "Full template engine integration: variables, loops, conditionals, and raw HTML" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var engine = try templates.Engine.init(alloc, undefined, .{
        .enableCache = true,
    });
    defer engine.deinit();

    const template_src =
        \\<h1>{{ title }}</h1>
        \\{% if show_admin %}
        \\  <p>Welcome, {{ user.name }} ({{ user.role }})</p>
        \\{% else %}
        \\  <p>Guest</p>
        \\{% endif %}
        \\<ul>
        \\{% for item in items %}
        \\  <li>#{{ loop.index }}: {{ item }}</li>
        \\{% endfor %}
        \\</ul>
        \\<div>{{ safeFooter }}</div>
    ;

    var list = std.ArrayList(u8).empty;
    defer list.deinit(alloc);

    var lw = templates.renderer.ListWriter{ .list = &list, .allocator = alloc };
    try engine.renderString(template_src, .{
        .title = "HTTPX Web Framework",
        .show_admin = true,
        .user = .{
            .name = "Muhammad",
            .role = "Architect",
        },
        .items = [_][]const u8{ "Engine", "Watcher", "LiveReload" },
        .safeFooter = templates.raw("<small>&copy; 2026 HTTPX</small>"),
    }, &lw);

    const out = list.items;
    try testing.expect(std.mem.indexOf(u8, out, "<h1>HTTPX Web Framework</h1>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Welcome, Muhammad (Architect)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<li>#1: Engine</li>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<li>#2: Watcher</li>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<li>#3: LiveReload</li>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<small>&copy; 2026 HTTPX</small>") != null);
}
