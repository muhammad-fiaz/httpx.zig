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

// Common primitives
pub const version_info = @import("common/version.zig");
pub const name = version_info.name;
pub const version = version_info.version;
pub const errors = @import("common/errors.zig");
pub const status = @import("common/status.zig");
pub const headers = @import("common/headers.zig");
pub const uri = @import("common/uri.zig");
pub const method = @import("common/method.zig");
pub const common = struct {
    pub const clock = @import("common/clock.zig");
    pub const sync = @import("common/sync.zig");
    pub const version = @import("common/version.zig");
};
pub const clock = common.clock;
pub const sync = common.sync;
pub const concurrency = struct {
    pub const queue = @import("concurrency/queue.zig");
    pub const Queue = @import("concurrency/queue.zig").BoundedQueue;
    pub const workerPool = @import("concurrency/worker_pool.zig");
    pub const WorkerPool = @import("concurrency/worker_pool.zig").Pool;
    pub const Pool = @import("concurrency/worker_pool.zig").Pool;
    pub const worker_pool = @import("concurrency/worker_pool.zig");
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
pub const socks5 = @import("net/socks5.zig");
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
    pub const connection = @import("protocols/quic/connection.zig");
    pub const Connection = connection.Connection;
    pub const connectionId = @import("protocols/quic/connection_id.zig");
    pub const path = @import("protocols/quic/path.zig");
    pub const transport = @import("protocols/quic/transport.zig");

    pub fn encodeFrame(allocator: std.mem.Allocator, f: frames.Frame) !std.ArrayList(u8) {
        var out = std.ArrayList(u8).empty;
        try frames.encode(&out, allocator, f);
        return out;
    }
};
pub const http3 = struct {
    pub const frame = @import("protocols/http3/frame.zig");
    pub const qpack = @import("protocols/http3/qpack.zig");
    pub const connection = @import("protocols/http3/connection.zig");
    pub const Connection = connection.Connection;
    pub const RequestStream = connection.RequestStream;
    pub const Settings = connection.Settings;
};
pub const tls = struct {
    pub const alpn = @import("protocols/tls/alpn.zig");
    pub const config = @import("protocols/tls/config.zig");
    pub const record = @import("protocols/tls/record.zig");
    pub const handshake = @import("protocols/tls/handshake.zig");
    pub const engine = @import("protocols/tls/engine.zig");
    pub const quicTls = @import("protocols/tls/quic_tls.zig");
    pub const tcpTls = @import("protocols/tls/tcp_tls.zig");
    pub const transport = @import("protocols/tls/transport.zig");
    const tls_server = @import("protocols/tls/tls_server.zig");
    pub const TlsListener = tls_server.TlsListener;
    pub const Listener = tls_server.TlsListener;
    pub const ListenerConfig = tls_server.ListenerConfig;
    pub const ServerConfig = config.ServerConfig;
    pub const ClientConfig = config.ClientConfig;
    pub const HttpRequest = tls_server.HttpRequest;
    pub const HttpResponse = tls_server.HttpResponse;
    pub const HandlerFn = tls_server.HandlerFn;
    pub const Handler = tls_server.HandlerFn;
    pub const Header = tls_server.Header;
};

// Web framework
pub const router = struct {
    pub const Router = @import("web/router/router.zig").Router;
    pub const Context = @import("web/router/router.zig").Context;
    pub const Response = @import("web/router/router.zig").Response;
    pub const Header = @import("web/router/router.zig").Header;
    pub const HandlerFn = @import("web/router/router.zig").HandlerFn;
    pub const pattern = @import("web/router/pattern.zig");
    pub const metadata = @import("web/router/metadata.zig");
};
pub const sse = struct {
    pub const Writer = @import("web/sse/writer.zig");
    pub const Parser = @import("web/sse/parser.zig");
};
pub const ws = struct {
    pub const Handshake = @import("web/websocket/handshake.zig");
    pub const Frame = @import("web/websocket/frame.zig");
};

// Web subsystems
pub const static = struct {
    pub const files = @import("web/static_files/serve.zig");
    pub const spa = @import("web/spa/serve.zig");
    pub const watcher = @import("web/watcher/watcher.zig");
    pub const Watcher = watcher.Watcher;
};
pub const health = @import("web/health/endpoints.zig");
pub const metrics = @import("web/metrics/registry.zig");
pub const mime = @import("utils/mime.zig");
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

// Client API
pub const client = @import("client/request.zig");
pub const cookies = @import("client/cookies.zig");
pub const pool = @import("client/pool.zig");
pub const Client = @import("client/client.zig").Client;
pub const ClientConfig = @import("client/client.zig").Config;
pub const RequestOptions = @import("client/client.zig").RequestOptions;
pub const ClientResponse = client.Response;
pub const Header = client.Header;
pub const Headers = headers.Headers;
pub const CookieJar = cookies.Jar;
pub const ConnectionPool = pool.Pool;
pub const PoolConfig = pool.PoolConfig;

// Zero-config client functions & ubiquitous verb aliases
pub const fetch = @import("client/client.zig").globalFetch;
pub const request = @import("client/client.zig").globalRequest;
pub const send = @import("client/client.zig").globalSend;
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
pub const download = @import("client/client.zig").globalDownload;
pub const lookupFileInfo = @import("client/client.zig").globalLookupFileInfo;
pub const updateFile = @import("client/client.zig").globalUpdateFile;
pub const verifyFile = @import("client/client.zig").globalVerifyFile;
pub const ftpDownload = @import("client/download.zig").ftpDownload;

// Download & Progress types
pub const download_pkg = @import("client/download.zig");
pub const DownloadOptions = download_pkg.DownloadOptions;
pub const DownloadResult = download_pkg.DownloadResult;
pub const DownloadError = download_pkg.DownloadError;
pub const DownloadTask = struct { url: []const u8, dest: []const u8 };
pub const RemoteFileInfo = download_pkg.RemoteFileInfo;
pub const ProgressInfo = download_pkg.ProgressInfo;
pub const ProgressState = download_pkg.ProgressState;
pub const ProgressMode = download_pkg.ProgressMode;
pub const ExistingFilePolicy = download_pkg.ExistingFilePolicy;
pub const VerifyOptions = download_pkg.VerifyOptions;
pub const UpdateOptions = download_pkg.UpdateOptions;
pub const FtpDownloadOptions = download_pkg.FtpDownloadOptions;



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
    pub fn init(allocator: std.mem.Allocator, config: document.ParserConfig) Parser {
        return Parser.init(allocator, config);
    }
    pub const detectKind = document.detectKind;
};



// Server API
pub const server = @import("server/lifecycle.zig");
pub const Server = server.Server;
pub const ServerConfig = server.Config;
pub const PortStrategy = server.PortStrategy;
pub const Router = router.Router;
pub const Context = router.Context;
pub const Response = router.Response;
pub const ServerResponse = router.Response;
pub const TlsListener = tls.TlsListener;
pub const TlsListenerConfig = tls.ListenerConfig;
pub const TlsConfig = tls.ServerConfig;
pub const TlsClientConfig = tls.ClientConfig;
pub const TlsRequest = tls.HttpRequest;
pub const TlsResponse = tls.HttpResponse;
pub const TlsHandler = tls.HandlerFn;

// Concurrency & Utilities
pub const WorkerPoolConfig = @import("concurrency/worker_pool.zig").Config;
pub const RateLimiter = @import("web/middleware/security.zig").RateLimiter;
pub const Metrics = metrics.Registry;
pub const Logger = logging.Logger;
pub const LogLevel = logging.Level;
pub const LogSink = logging.Sink;
pub const LogRecord = logging.Record;
pub const LogField = logging.Field;
pub const WriterSink = logging.WriterSink;

// Networking & Protocol Types
pub const Address = address.Address;
pub const Uri = uri.Uri;
pub const Method = method.Method;
pub const Status = status.Status;
pub const Http1Parser = http1.parser.Http1Parser;
pub const ChunkedDecoder = http1.parser.ChunkedDecoder;
pub const H2Session = http2.connection.Session;
pub const AlpnProtocol = tls.alpn.Protocol;
pub const ApplicationProtocol = tls.alpn.Protocol;

// FTP
pub const ftp = struct {
    const ftp_client = @import("protocols/ftp/client.zig");
    pub const Client = ftp_client.Client;
    pub const Options = ftp_client.Options;
    pub const parseReplyAt = ftp_client.parseReplyAt;
    pub const parsePasive = ftp_client.parsePasive;
    pub const parseEpsv = ftp_client.parseEpsv;
    const ftp_server = @import("protocols/ftp/server.zig");
    pub const Server = ftp_server.Server;
    pub const FtpConfig = ftp_server.Config;
    pub const Callbacks = ftp_server.Callbacks;
};


// Tests
test {
    _ = @import("common/errors.zig");
    _ = @import("common/status.zig");
    _ = @import("common/headers.zig");
    _ = @import("common/uri.zig");
    _ = @import("common/method.zig");
    _ = @import("common/version.zig");
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
    _ = @import("protocols/tls/quic_tls.zig");
    _ = @import("protocols/http3/frame.zig");
    _ = @import("protocols/http3/qpack.zig");
    _ = @import("protocols/http3/connection.zig");
    _ = @import("protocols/tls/alpn.zig");
    _ = @import("protocols/tls/config.zig");
    _ = @import("protocols/tls/record.zig");
    _ = @import("protocols/tls/handshake.zig");
    _ = @import("protocols/tls/engine.zig");
    _ = @import("protocols/tls/quic_tls.zig");
    _ = @import("protocols/tls/tcp_tls.zig");
    _ = @import("protocols/tls/tls_server.zig");
    _ = @import("protocols/tls/transport.zig");
    _ = @import("web/router/pattern.zig");
    _ = @import("web/router/metadata.zig");
    _ = @import("web/router/router.zig");
    _ = @import("web/sse/writer.zig");
    _ = @import("web/sse/parser.zig");
    _ = @import("web/websocket/handshake.zig");
    _ = @import("web/websocket/frame.zig");
    _ = @import("web/middleware/security.zig");
    _ = @import("web/docs/docs.zig");
    _ = @import("web/graphql/graphql.zig");
    _ = @import("web/openapi/spec.zig");
    _ = @import("web/static_files/serve.zig");
    _ = @import("web/spa/serve.zig");
    _ = @import("web/health/endpoints.zig");
    _ = @import("web/metrics/registry.zig");
    _ = @import("utils/mime.zig");
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
}
