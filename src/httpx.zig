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
pub const errors = @import("common/errors.zig");
pub const status = @import("common/status.zig");
pub const headers = @import("common/headers.zig");
pub const headers_mod = headers;
pub const uri = @import("common/uri.zig");
pub const uri_mod = uri;
pub const method = @import("common/method.zig");
pub const method_mod = method;
pub const common = struct {
    pub const clock = @import("common/clock.zig");
    pub const sync = @import("common/sync.zig");
};
pub const clock = common.clock;
pub const sync = common.sync;
pub const concurrency = struct {
    pub const queue = @import("concurrency/queue.zig");
    pub const worker_pool = @import("concurrency/worker_pool.zig");
};
pub const logging = @import("common/logging.zig");
pub const tint = @import("tint");

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
pub const proto_common = struct {
    pub const integer = @import("protocols/common/integer.zig");
    pub const huffman = @import("protocols/common/huffman.zig");
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
    pub const connection_id = @import("protocols/quic/connection_id.zig");
    pub const path = @import("protocols/quic/path.zig");
    pub const transport = @import("protocols/quic/transport.zig");
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
    pub const quic_tls = @import("protocols/tls/quic_tls.zig");
    pub const tcp_tls = @import("protocols/tls/tcp_tls.zig");
    pub const transport = @import("protocols/tls/transport.zig");
    pub const tls_server = @import("protocols/tls/tls_server.zig");
};
pub const tls_mod = tls;

// Web framework
pub const router = @import("web/router/router.zig");
pub const router_mod = router;
pub const router_pattern = @import("web/router/pattern.zig");
pub const route_meta = @import("web/router/metadata.zig");
pub const sse_writer = @import("web/sse/writer.zig");
pub const sse_parser = @import("web/sse/parser.zig");
pub const ws_handshake = @import("web/websocket/handshake.zig");
pub const ws_frame = @import("web/websocket/frame.zig");
pub const docs_mod = @import("web/docs/docs.zig");

// Web subsystems
pub const static_files = @import("web/static_files/serve.zig");
pub const spa = @import("web/spa/serve.zig");
pub const watcher = @import("web/watcher/watcher.zig");
pub const Watcher = watcher.Watcher;
pub const health = @import("web/health/endpoints.zig");
pub const metrics = @import("web/metrics/registry.zig");
pub const mime = @import("utils/mime.zig");
pub const openapi = @import("web/openapi/spec.zig");
pub const openapi_spec = openapi;
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

// Client
pub const Client = @import("client/client.zig").Client;
pub const ClientResponse = @import("client/request.zig").Response;
pub const client_request = @import("client/request.zig");
pub const cookies = @import("client/cookies.zig");
pub const pool = @import("client/pool.zig");

/// Legacy low-level client (requires explicit allocator + io).
pub const client = client_request;

/// Top-level zero-config client aliases (all HTTP methods + fetch/request).
pub const get = @import("client/client.zig").globalGet;
pub const post = @import("client/client.zig").globalPost;
pub const put = @import("client/client.zig").globalPut;
pub const patch = @import("client/client.zig").globalPatch;
pub const delete = @import("client/client.zig").globalDelete;
pub const head = @import("client/client.zig").globalHead;
pub const options = @import("client/client.zig").globalOptions;
pub const trace = @import("client/client.zig").globalTrace;
pub const connect = @import("client/client.zig").globalConnect;
pub const fetch = @import("client/client.zig").globalFetch;
pub const send = @import("client/client.zig").globalSend;
pub const request = @import("client/client.zig").globalRequest;
pub const getAll = @import("client/client.zig").globalGetAll;
pub const requestAll = @import("client/client.zig").globalRequestAll;

// Server
pub const server_lifecycle = @import("server/lifecycle.zig");
pub const server_context = @import("server/context.zig");
pub const Server = server_lifecycle.Server;
pub const TlsListener = tls_mod.tls_server.TlsListener;
pub const TlsListenerConfig = tls_mod.tls_server.ListenerConfig;
pub const TlsConfig = tls_mod.config.ServerConfig;
pub const TlsClientConfig = tls_mod.config.ClientConfig;

// FTP / FTPS
pub const ftp = @import("protocols/ftp/client.zig");
pub const ftp_server = @import("protocols/ftp/server.zig");

// Re-exports for convenience
pub const Headers = headers_mod.Headers;
pub const Header = client_request.Header;
pub const Uri = uri_mod.Uri;
pub const Method = method_mod.Method;
pub const Status = status.Status;
pub const Router = router_mod.Router;
pub const Context = router_mod.Context;
pub const Response = router_mod.Response;

pub const Address = address.Address;
pub const Http1Parser = http1.parser.Http1Parser;
pub const ChunkedDecoder = http1.parser.ChunkedDecoder;
pub const H2Session = http2.connection.Session;
pub const AlpnProtocol = tls_mod.alpn.Protocol;
pub const ApplicationProtocol = tls_mod.alpn.Protocol;

pub const Logger = logging.Logger;
pub const LogLevel = logging.Level;
/// Custom logger integration: implement Sink.logFn (ptr + callback) to
/// bridge ANY external logging library — your formatting, your colors.
pub const LogSink = logging.Sink;
pub const LogRecord = logging.Record;
pub const LogField = logging.Field;
pub const WriterSink = logging.WriterSink;
pub const Metrics = metrics.Registry;
pub const CookieJar = cookies.Jar;
pub const ConnectionPool = pool.Pool;
pub const PoolConfig = pool.PoolConfig;
pub const ClientConfig = @import("client/client.zig").Config;
pub const RequestOptions = @import("client/client.zig").RequestOptions;

pub const name = @import("common/version.zig").name;
pub const version = @import("common/version.zig").version;

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
    _ = @import("integration/http_stack.zig");
    _ = @import("integration/tls_integration.zig");
    _ = @import("integration/client_server_integration.zig");
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
    _ = @import("server/context.zig");
}
