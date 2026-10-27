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
//!   client/     - request engine, connection pool, cookie jar

const std = @import("std");

// External dependencies
pub const tint = @import("tint");
pub const loaders = @import("loaders");
pub const brotli = @import("brotli");
pub const zstd = @import("zstd");
pub const env = @import("common/env.zig");
pub const regex = @import("regex");

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
pub const parse = @import("common/parse.zig");
pub const httpVersion = @import("common/httpVersion.zig");
pub const HttpVersion = httpVersion.HttpVersion;
pub const common = struct {
    pub const clock = @import("common/clock.zig");
    pub const sync = @import("common/sync.zig");
    pub const version = @import("common/version.zig");
    pub const httpVersion = @import("common/httpVersion.zig");
    pub const io = @import("common/io.zig");
    pub const parse = @import("common/parse.zig");
    pub const bodySource = @import("common/bodySource.zig");
    pub const env = @import("common/env.zig");
    pub const BodySource = bodySource.BodySource;
    pub const SliceReader = bodySource.SliceReader;
    pub const CallbackReader = bodySource.CallbackReader;
};
pub const BodySource = common.BodySource;
pub const SliceReader = common.SliceReader;
pub const CallbackReader = common.CallbackReader;
pub const clock = common.clock;
pub const sync = common.sync;
pub const concurrency = struct {
    pub const queue = @import("concurrency/queue.zig");
    pub const Queue = @import("concurrency/queue.zig").BoundedQueue;
    pub const workerPool = @import("concurrency/workerPool.zig");
    pub const Pool = @import("concurrency/workerPool.zig").Pool;
};
pub const logging = @import("common/logging.zig");

// Sockets
pub const tcp = @import("sockets/tcp.zig");
/// Raw socket syscall layer: exhaustive platform error mapping (Phase 2).
pub const sys = @import("sockets/sys.zig");
pub const udp = @import("sockets/udp.zig");

// Network layer
pub const net = struct {
    pub const address = @import("net/address.zig");
    pub const dns = @import("net/dns/dnsResolver.zig");
    pub const dnsCache = @import("net/dns/dnsCache.zig");
    pub const resolve = @import("net/resolve.zig");
    pub const connectivity = @import("net/connectivity.zig");
    pub const socks5 = @import("net/socks5.zig");
    pub const socks4 = @import("net/socks4.zig");
    pub const proxy = @import("net/proxy.zig");
};

// Compression
pub const compression = @import("compression/codec.zig");

// Protocol implementations are reachable through one coherent namespace.
pub const protocols = struct {
    pub const common = struct {
        pub const integer = @import("protocols/common/integer.zig");
        pub const huffman = @import("protocols/common/huffman.zig");
        pub const huffmanTable = @import("protocols/common/huffmanTable.zig");
    };
    pub const http1 = struct {
        pub const parser = @import("protocols/http1/parser.zig");
        pub const writer = @import("protocols/http1/writer.zig");
        pub const semantics = @import("protocols/http1/semantics.zig");
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
    pub const http3 = struct {
        pub const frame = @import("protocols/http3/frame.zig");
        pub const FrameHeader = frame.FrameHeader;
        pub const ParsedFrame = frame.ParsedFrame;
        pub const qpack = @import("protocols/http3/qpack.zig");
        pub const connection = @import("protocols/http3/connection.zig");
        pub const Connection = connection.Connection;
        pub const RequestStream = connection.RequestStream;
        pub const Settings = connection.Settings;
        pub const stream = @import("protocols/http3/stream.zig");
        pub const Stream = stream.Stream;
        pub const transport = @import("protocols/http3/transport.zig");
        pub const Client = transport.Client;
    };
    pub const quic = struct {
        pub const varint = @import("protocols/quic/varint.zig");
        pub const packet = @import("protocols/quic/packet.zig");
        pub const crypto = @import("protocols/quic/crypto.zig");
        pub const packetProtection = @import("protocols/quic/packetProtection.zig");
        pub const frames = @import("protocols/quic/frames.zig");
        pub const ackTracker = @import("protocols/quic/ackTracker.zig");
        pub const lossRecovery = @import("protocols/quic/lossRecovery.zig");
        pub const congestionControl = @import("protocols/quic/congestionControl.zig");
        pub const transportParameters = @import("protocols/quic/transportParameters.zig");
        pub const stream = @import("protocols/quic/stream.zig");
        pub const Stream = stream.Stream;
        pub const connection = @import("protocols/quic/connection.zig");
        pub const Connection = connection.Connection;
        pub const connectionId = @import("protocols/quic/connectionId.zig");
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
    pub const tls = @import("protocols/tls/tls.zig");
    pub const ftp = struct {
        const clientModule = @import("protocols/ftp/ftpClient.zig");
        pub const Client = clientModule.Client;
        pub const Options = clientModule.Options;
        pub const Reply = clientModule.Reply;
        pub const FtpError = clientModule.FtpError;
        const serverModule = @import("protocols/ftp/ftpServer.zig");
        pub const Server = serverModule.Server;
        pub const Config = serverModule.Config;
        pub const Callbacks = serverModule.Callbacks;
    };
};

// Canonical protocol namespaces directly under root
pub const http1 = protocols.http1;
pub const http2 = protocols.http2;
pub const http3 = protocols.http3;
pub const quic = protocols.quic;
pub const tls = protocols.tls;

// Canonical router exports
pub const router = @import("web/router/router.zig");
pub const Router = router.Router;

// Canonical root types
pub const Client = @import("client/httpClient.zig").Client;
pub const Server = server.Server;
pub const Response = @import("client/requestBuilder.zig").Response;
pub const Headers = headers.Headers;
pub const Method = method.Method;
pub const Status = status.Status;
pub const Uri = uri.Uri;
pub const Downloader = @import("client/downloadManager.zig").Downloader;
pub const DownloadOptions = @import("client/downloadManager.zig").DownloadOptions;
pub const DownloadResult = @import("client/downloadManager.zig").DownloadResult;
pub const DownloadTask = @import("client/downloadManager.zig").DownloadTask;
pub const download = @import("client/downloadManager.zig");

// Web framework
pub const sse = struct {
    pub const Event = @import("web/sse/sseParser.zig").Event;
    pub const ParseError = @import("web/sse/sseParser.zig").ParseError;
    pub const parseAll = @import("web/sse/sseParser.zig").parseAll;
    pub const freeEvents = @import("web/sse/sseParser.zig").freeEvents;
    pub const Writer = @import("web/sse/sseWriter.zig").EventWriter;
    pub const Parser = @import("web/sse/sseParser.zig").EventParser;
};
pub const websocket = struct {
    pub const Handshake = @import("web/websocket/websocketHandshake.zig");
    pub const Frame = @import("web/websocket/websocketFrame.zig");
    pub const deflate = @import("web/websocket/websocketDeflate.zig");
    pub const computeAccept = Handshake.computeAccept;
    pub const buildUpgradeRequest = Handshake.buildUpgradeRequest;
};

// Native Template Engine
pub const templates = @import("web/templates/templates.zig");
pub const TemplateEngine = templates.Engine;
pub const TemplateConfig = templates.Config;
pub const assets = @import("web/assets/assetStore.zig");
pub const site = @import("web/site/siteServer.zig");
pub const siteRoutes = @import("web/site/siteRoutes.zig");
pub const Site = site.Site;
pub const static = struct {
    pub const files = @import("web/staticFiles/staticFileServer.zig");
    pub const safeJoin = files.safeJoin;
    pub const shouldSpaFallback = files.shouldSpaFallback;
    pub const spa = @import("web/spa/spaServer.zig");
    pub const watcher = @import("web/watcher/watcherBackend.zig");
    pub const Watcher = watcher.Watcher;
    pub const ReloadStrategy = watcher.ReloadStrategy;
    pub const WatchEvent = watcher.WatchEvent;
    pub const WatchEventKind = watcher.WatchEventKind;
    pub const WatcherConfig = watcher.WatcherConfig;
    pub const BackendMode = watcher.BackendMode;
    pub const BackendKind = watcher.BackendKind;
    pub const BackendCapabilities = watcher.BackendCapabilities;
    pub const WatcherStatus = watcher.WatcherStatus;
    pub const events = @import("web/watcher/watcherEvents.zig");
    pub const dependency = @import("web/watcher/watcherDependency.zig");
    /// Browser-side live reload: the script served into HTML pages plus the
    /// idempotent injection helper.
    pub const reload = @import("web/watcher/fileWatcher.zig");
};
pub const Watcher = static.Watcher;
pub const ReloadStrategy = static.ReloadStrategy;
pub const WatchEvent = static.WatchEvent;
pub const WatchEventKind = static.WatchEventKind;
pub const BackendMode = static.BackendMode;
pub const BackendKind = static.BackendKind;
pub const BackendCapabilities = static.BackendCapabilities;
pub const WatcherStatus = static.WatcherStatus;
pub const health = @import("web/health/healthEndpoints.zig");
pub const metrics = @import("web/metrics/metricsRegistry.zig");
pub const mime = @import("utils/mime.zig");
pub const fs = @import("utils/fs.zig");
pub const rest = @import("web/rest/restApi.zig");
pub const Rest = rest.Rest;
pub const ApiResult = rest.ApiResult;
pub const app = @import("web/app.zig");
pub const App = app.App;
pub const openapi = @import("web/openApi/openApiSpec.zig");
pub const docs = @import("web/docs/docs.zig");
pub const graphql = @import("web/graphql/graphql.zig");
pub const auth = struct {
    pub const basic = @import("web/auth/basicAuth.zig");
    pub const bearer = @import("web/auth/bearerAuth.zig");
    pub const digest = @import("web/auth/digestAuth.zig");
};
pub const multipart = struct {
    pub const encoder = @import("web/multipart/multipartEncoder.zig");
    pub const parser = @import("web/multipart/multipartParser.zig");
    pub const server = @import("web/multipart/multipartServer.zig");
};

// Middleware
pub const middleware = struct {
    const sec = @import("web/middleware/securityHeaders.zig");
    pub const cors = sec.corsMiddleware;
    pub const helmet = sec.securityHeadersMiddleware;
    pub const recovery = sec.recoveryMiddleware;
    pub const logging = sec.loggingMiddleware;
    pub const csrf = sec.csrfMiddleware;
    pub const RateLimiter = sec.RateLimiter;
    pub const rateLimit = @import("web/middleware/rateLimiter.zig");
    pub const RateLimitPolicy = rateLimit.RateLimitPolicy;
    pub const RateLimitResult = rateLimit.RateLimitResult;
    pub const RateLimitDimension = rateLimit.RateLimitDimension;
    pub const generateCsrfToken = sec.generateCsrfToken;
    pub const verifyCsrfToken = sec.verifyCsrfToken;
    pub const CSRF_TOKEN_LEN = sec.CSRF_TOKEN_LEN;
};

// Web framework facade
pub const web = struct {
    pub const router = @import("web/router/router.zig");
    pub const static = @import("web/staticFiles/staticFileServer.zig");
    pub const spa = @import("web/spa/spaServer.zig");
    pub const watcher = @import("web/watcher/watcherBackend.zig");
    pub const watcherEvents = @import("web/watcher/watcherEvents.zig");
    pub const watcherDependency = @import("web/watcher/watcherDependency.zig");
    pub const reload = @import("web/watcher/fileWatcher.zig");
    pub const templates = @import("web/templates/templates.zig");
    pub const TemplateEngine = @import("web/templates/templates.zig").Engine;
    pub const assets = @import("web/assets/assetStore.zig");
    pub const site = @import("web/site/siteServer.zig");
    pub const websocket = struct {
        pub const Handshake = @import("web/websocket/websocketHandshake.zig");
        pub const Frame = @import("web/websocket/websocketFrame.zig");
        pub const deflate = @import("web/websocket/websocketDeflate.zig");
        pub const computeAccept = Handshake.computeAccept;
        pub const buildUpgradeRequest = Handshake.buildUpgradeRequest;
    };
    pub const health = @import("web/health/healthEndpoints.zig");
    pub const metrics = @import("web/metrics/metricsRegistry.zig");
    pub const rest = @import("web/rest/restApi.zig");
    pub const app = @import("web/app.zig");
    pub const openapi = @import("web/openApi/openApiSpec.zig");
    pub const docs = @import("web/docs/docs.zig");
    pub const graphql = @import("web/graphql/graphql.zig");
    pub const auth = struct {
        pub const basic = @import("web/auth/basicAuth.zig");
        pub const bearer = @import("web/auth/bearerAuth.zig");
        pub const digest = @import("web/auth/digestAuth.zig");
    };
    pub const multipart = struct {
        pub const encoder = @import("web/multipart/multipartEncoder.zig");
        pub const parser = @import("web/multipart/multipartParser.zig");
        pub const server = @import("web/multipart/multipartServer.zig");
    };
    pub const middleware = struct {
        const sec = @import("web/middleware/securityHeaders.zig");
        pub const cors = sec.corsMiddleware;
        pub const helmet = sec.securityHeadersMiddleware;
        pub const recovery = sec.recoveryMiddleware;
        pub const logging = sec.loggingMiddleware;
        pub const csrf = sec.csrfMiddleware;
        pub const RateLimiter = sec.RateLimiter;
    };
};

// Client API. Shallow, concise, camelCase public paths with zero semantic repetition.
pub const client = struct {
    const httpClientMod = @import("client/httpClient.zig");
    const requestBuilderMod = @import("client/requestBuilder.zig");
    const poolMod = @import("client/connectionPool.zig");
    const cookieMod = @import("client/cookieJar.zig");
    const downloadMod = @import("client/downloadManager.zig");

    // Client errors & resolution
    pub const Error = httpClientMod.Error;
    pub const ResolvedAddresses = httpClientMod.ResolvedAddresses;
    pub const AddressFamilyPreference = httpClientMod.AddressFamilyPreference;

    // Request construction: httpx.client.requestBuilder
    pub const requestBuilder = httpClientMod.Client.RequestBuilder;
    pub const requestPayload = requestBuilderMod.Request;

    // Body sources: httpx.client.bodySource, sliceReader, callbackReader
    pub const bodySource = requestBuilderMod.BodySource;
    pub const sliceReader = requestBuilderMod.SliceReader;
    pub const callbackReader = requestBuilderMod.CallbackReader;
    pub const header = requestBuilderMod.Header;
    pub const bodyKind = requestBuilderMod.BodyKind;

    // Connection pool: httpx.client.connectionPool
    pub const connectionPool = poolMod.Pool;
    pub const poolStats = poolMod.Stats;
    pub const poolSnapshot = poolMod.Snapshot;

    // Cookie jar: httpx.client.cookieJar, cookie
    pub const cookieJar = cookieMod.Jar;
    pub const cookie = cookieMod.Cookie;
    pub const sameSite = cookieMod.Cookie.SameSite;

    // Download manager: httpx.client.download
    pub const Downloader = downloadMod.Downloader;
    pub const DownloadOptions = downloadMod.DownloadOptions;
    pub const DownloadResult = downloadMod.DownloadResult;
    pub const DownloadTask = downloadMod.DownloadTask;
    pub const DownloadError = downloadMod.DownloadError;
    pub const download = downloadMod.Downloader;
    pub const downloadResult = downloadMod.DownloadResult;
    pub const downloadTask = downloadMod.DownloadTask;
    pub const downloadError = downloadMod.DownloadError;
    pub const remoteFileInfo = downloadMod.RemoteFileInfo;
    pub const progressState = downloadMod.ProgressState;
    pub const progressInfo = downloadMod.ProgressInfo;
    pub const progressMode = downloadMod.ProgressMode;
    pub const checksumAlgorithm = downloadMod.ChecksumAlgorithm;
    pub const ftpDownload = downloadMod.ftpDownload;
    pub const parseChecksumFile = downloadMod.parseChecksumFile;
    pub const lookupFileInfo = downloadMod.lookupFileInfo;
    pub const updateFile = downloadMod.updateFile;

    // Response streaming: httpx.client.responseStream
    pub const responseStream = requestBuilderMod.ResponseStream;
    pub const sessionPolicyFingerprint = requestBuilderMod.sessionPolicyFingerprint;

    // Worker pool: httpx.client.workerPool
    pub const workerPool = @import("concurrency/workerPool.zig").Pool;
};

// Parsing & inspection subsystem
/// Native HTML, XML, RSS/Atom/JSON feeds, robots.txt, and sitemap parsing engine.
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
const server = @import("server/httpServer.zig");

// Concurrency & Utilities
const rateLimitMod = @import("web/middleware/rateLimiter.zig");
pub const RateLimiter = rateLimitMod.RateLimiter;
pub const RateLimitPolicy = rateLimitMod.RateLimitPolicy;
pub const RateLimitResult = rateLimitMod.RateLimitResult;
pub const RateLimitDimension = rateLimitMod.RateLimitDimension;
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
pub const Address = net.address.Address;
// HTTP and TLS implementation types remain in `protocols`.

// Tests
test {
    // Referencing a module (not just its namespace) is what makes
    // `zig build test` discover the tests inside it. Each entry below is
    // a module reachable from the declarations above, so the whole suite
    // stays one list with no duplicated import paths.
    _ = common.clock;
    _ = common.sync;
    _ = common.io;
    _ = errors;
    _ = status;
    _ = headers;
    _ = uri;
    _ = method;
    _ = versionInfo;
    _ = httpVersion;
    _ = logging;
    _ = concurrency.queue;
    _ = concurrency.workerPool;
    _ = tcp;
    _ = sys;
    _ = udp;
    _ = net.address;
    _ = net.dns;
    _ = net.dnsCache;
    _ = net.resolve;
    _ = net.socks5;
    _ = net.socks4;
    _ = net.proxy;
    _ = net.connectivity;
    _ = compression;
    _ = protocols.common.integer;
    _ = protocols.common.huffman;
    _ = protocols.common.huffmanTable;
    _ = protocols.http1.parser;
    _ = protocols.http1.writer;
    _ = protocols.http1.semantics;
    _ = protocols.http2.frame;
    _ = protocols.http2.hpack;
    _ = protocols.http2.stream;
    _ = protocols.http2.connection;
    _ = protocols.http2.transport;
    _ = protocols.http3.frame;
    _ = protocols.http3.qpack;
    _ = protocols.http3.connection;
    _ = protocols.http3.stream;
    _ = protocols.http3.transport;
    _ = protocols.quic.varint;
    _ = protocols.quic.packet;
    _ = protocols.quic.crypto;
    _ = protocols.quic.packetProtection;
    _ = protocols.quic.frames;
    _ = protocols.quic.ackTracker;
    _ = protocols.quic.lossRecovery;
    _ = protocols.quic.congestionControl;
    _ = protocols.quic.transportParameters;
    _ = protocols.quic.stream;
    _ = protocols.quic.connection;
    _ = protocols.quic.connectionId;
    _ = protocols.quic.path;
    _ = protocols.quic.transport;
    _ = protocols.quic.handshake;
    _ = protocols.tls.alpn;
    _ = protocols.tls.certificate;
    _ = protocols.tls.config;
    _ = protocols.tls.engine;
    _ = protocols.tls.errors;
    _ = protocols.tls.handshake;
    _ = protocols.tls.key;
    _ = protocols.tls.quicTls;
    _ = protocols.tls.record;
    _ = protocols.tls.session;
    _ = protocols.tls.transport;
    _ = protocols.tls.trustStore;
    _ = protocols.tls.verify;
    _ = protocols.tls.Client;
    _ = protocols.tls.Server;
    _ = @import("common/env.zig");
    _ = router;
    _ = router.pattern;
    _ = router.metadata;
    _ = @import("web/sse/sseWriter.zig");
    _ = @import("web/sse/sseParser.zig");
    _ = websocket.Handshake;
    _ = websocket.Frame;
    _ = middleware.rateLimit;
    _ = middleware.cors;
    _ = middleware.helmet;
    _ = middleware.recovery;
    _ = static.files;
    _ = static.spa;
    _ = static.watcher;
    _ = static.events;
    _ = static.dependency;
    _ = static.reload;
    _ = site;
    _ = siteRoutes;
    _ = assets;
    _ = health;
    _ = metrics;
    _ = rest;
    _ = app;
    _ = openapi;
    _ = docs;
    _ = graphql;
    _ = auth.basic;
    _ = auth.bearer;
    _ = auth.digest;
    _ = multipart.encoder;
    _ = multipart.parser;
    _ = multipart.server;
    _ = templates.engine;
    _ = templates.context;
    _ = templates.parser;
    _ = templates.renderer;
    _ = templates.loader;
    _ = templates.cache;
    _ = templates.errors;
    _ = parsing.dom;
    _ = parsing.html;
    _ = parsing.xml;
    _ = parsing.selector;
    _ = parsing.extract;
    _ = parsing.feed;
    _ = parsing.robots;
    _ = parsing.sitemap;
    _ = parsing.document;
    _ = protocols.ftp.Client;
    _ = protocols.ftp.Server;
    _ = server.Server;
    _ = @import("client/cookieJar.zig");
    _ = @import("client/connectionPool.zig");
    _ = @import("client/httpClient.zig");
    _ = @import("client/requestBuilder.zig");
    _ = @import("client/downloadManager.zig");
}

test "tint is wired directly and independently of loaders" {
    const testing = std.testing;
    // The tint package is a direct dependency: this uses its namespaced
    // API without going through loaders.
    try testing.expectEqualStrings("\x1b[31m", tint.color.ansi4.red.fg().slice());
    try testing.expectEqualStrings("\x1b[32m", tint.color.ansi4.green.fg().slice());
    try testing.expectEqualStrings("\x1b[0m", tint.ansi.reset.all);
    try testing.expectEqualStrings("0.0.2", tint.version);
}

test "Full template engine integration: variables, loops, conditionals, and raw HTML" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var engine = try templates.Engine.init(alloc, undefined, .{
        .enableCache = true,
    });
    defer engine.deinit();

    const templateSrc =
        \\<h1>{{ title }}</h1>
        \\{% if showAdmin %}
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
    try engine.renderString(templateSrc, .{
        .title = "HTTPX Web Framework",
        .showAdmin = true,
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

test "public facade exposes non-redundant canonical namespaces and types" {
    const testing = std.testing;
    const a = testing.allocator;

    // Root types
    try testing.expect(@sizeOf(Client) > 0);
    try testing.expect(@sizeOf(Server) > 0);
    try testing.expect(@sizeOf(Response) > 0);
    try testing.expect(@sizeOf(Headers) > 0);
    try testing.expect(@sizeOf(Method) > 0);
    try testing.expect(@sizeOf(Status) > 0);
    try testing.expect(@sizeOf(Uri) > 0);

    // Shallow, non-redundant camelCase client APIs
    try testing.expect(@sizeOf(client.requestBuilder) > 0);
    try testing.expect(@sizeOf(client.connectionPool) > 0);
    try testing.expect(@sizeOf(client.cookieJar) > 0);
    try testing.expect(@sizeOf(client.cookie) > 0);
    try testing.expect(@sizeOf(client.download) > 0);
    try testing.expect(@sizeOf(client.responseStream) > 0);
    try testing.expect(@sizeOf(client.workerPool) > 0);

    // Root namespaces
    try testing.expect(@sizeOf(http1.parser.Options) > 0);
    try testing.expect(@sizeOf(http2.connection.Session) > 0);
    try testing.expect(@sizeOf(http3.connection.Connection) > 0);
    try testing.expect(@sizeOf(quic.connection.Connection) > 0);
    try testing.expect(@sizeOf(tls.Client) > 0);
    try testing.expect(@sizeOf(Router) > 0);
    try testing.expect(@sizeOf(net.address.Address) > 0);

    // Test defaultable options with .{}
    var hdrs = Headers.init(a);
    defer hdrs.deinit();
    try testing.expectEqual(@as(usize, 0), hdrs.entries.items.len);

    // Cookie jar operations via canonical client.cookieJar
    const io = std.Io.Threaded.global_single_threaded.io();
    var jar = client.cookieJar.init(a, io);
    defer jar.deinit();
    jar.setFromHeader("session=token123; Path=/; HttpOnly", "example.com");
    var cbuf: [128]u8 = undefined;
    const cookieHdr = jar.cookieHeader("example.com", "/dashboard", false, &cbuf);
    try testing.expect(cookieHdr != null);
    try testing.expectEqualStrings("session=token123", cookieHdr.?);
}
