//! Native TLS 1.3 client transport over an existing socket handle.
//!
//! Wraps `std.crypto.tls.Client` using the buffer layout from std.http
//! (stream-writer ciphertext, stream-reader ciphertext, combined plaintext
//! read staging), exposing Socket-like `read`/`writeAll` so the HTTP request
//! engine treats plain and TLS connections uniformly.
//!
//! Thread-safety: thread-confined — one connection, one user.
//!
//! References:
//!   - RFC 8446 — The Transport Layer Security (TLS) Protocol Version 1.3

const std = @import("std");
const Allocator = std.mem.Allocator;
const sync = @import("../../common/sync.zig");

pub const tls = std.crypto.tls;
const max_cipher = tls.max_ciphertext_record_len;

/// How server certificates are verified.
pub const VerifyMode = enum {
    /// Verify against a caller-supplied CA bundle.
    caBundle,
    /// Accept any valid self-signed certificate (no trust anchor).
    selfSigned,
    /// Skip verification entirely. INSECURE — tests/debug only.
    none,
};

pub const ConnectionOptions = struct {
    /// Allow peer FIN without TLS close_notify to end the stream. INSECURE
    /// unless the application layer verifies completeness itself (HTTP
    /// Content-Length / chunked framing does). Default: false.
    allowTruncation: bool = false,
};

pub const InitError = error{
    TlsInitializationFailed,
    TlsCaUnavailable,
    OutOfMemory,
    CertificateExpired,
    CertificateHostMismatch,
    CertificateIssuerMismatch,
    CertificateNotYetValid,
    CertificateSignatureInvalid,
    TlsCertificateNotVerified,
    TlsAlert,
    TlsDecodeError,
};

pub const Connection = struct {
    client: tls.Client,
    allowTruncation: bool,

    // Heap-owned buffers (freed in destroy).
    bufStreamWriter: []u8,
    bufStreamReader: []u8,
    bufTlsRead: []u8,
    bufPlainWrite: []u8,

    streamWriter: std.Io.net.Stream.Writer,
    streamReader: std.Io.net.Stream.Reader,
    io: std.Io,
    socketHandle: std.Io.net.Socket.Handle,

    pub const ReadError = error{ ReadFailed, OutOfMemory };
    pub const WriteError = error{WriteFailed};

    var g_ca_lock: std.Io.RwLock = .init;
    var g_system_bundle: std.crypto.Certificate.Bundle = .empty;
    var g_system_bundle_loaded: bool = false;
    var g_system_bundle_lock: sync.Spinlock = .{};

    // Process-lifetime system CA cache. Backed by the untracked page
    // allocator on purpose: the bundle lives until process exit (freed by
    // the OS), so routing it through a caller's tracked allocator (e.g. a
    // DebugAllocator) would report a false leak at shutdown.
    fn getOrLoadSystemBundle(io: std.Io) !*std.crypto.Certificate.Bundle {
        g_system_bundle_lock.lock();
        defer g_system_bundle_lock.unlock();

        if (!g_system_bundle_loaded) {
            const now = std.Io.Timestamp.now(io, .awake);
            g_system_bundle.rescan(std.heap.page_allocator, io, now) catch return error.TlsCaUnavailable;
            g_system_bundle_loaded = true;
        }
        return &g_system_bundle;
    }

    pub const Config = struct {
        socketHandle: std.Io.net.Socket.Handle,
        host: []const u8 = "",
        verify: VerifyMode = .caBundle,
        caBundle: ?*std.crypto.Certificate.Bundle = null,
        allowTruncation: bool = false,
        io: ?std.Io = null,
    };

    /// Handshakes synchronously. Returns a HEAP pointer because tls.Client
    /// captures addresses of our reader/writer interfaces — this struct must
    /// never move after init. Free with `destroy()`.
    pub fn init(allocator: Allocator, config: anytype) InitError!*Connection {
        const conf: Config = if (@TypeOf(config) == Config) config else blk: {
            var c = Config{
                .socketHandle = if (@hasField(@TypeOf(config), "socketHandle")) config.socketHandle else if (@hasField(@TypeOf(config), "socket")) config.socket.netSocketHandle() else undefined,
            };
            if (@hasField(@TypeOf(config), "host")) c.host = config.host;
            if (@hasField(@TypeOf(config), "verify")) c.verify = config.verify;
            if (@hasField(@TypeOf(config), "caBundle")) c.caBundle = config.caBundle;
            if (@hasField(@TypeOf(config), "allowTruncation")) c.allowTruncation = config.allowTruncation;
            if (@hasField(@TypeOf(config), "io")) c.io = config.io;
            break :blk c;
        };

        const io = conf.io orelse std.Io.Threaded.global_single_threaded.io();
        var active_bundle: ?*std.crypto.Certificate.Bundle = conf.caBundle;
        if (conf.verify == .caBundle and active_bundle == null) {
            active_bundle = getOrLoadSystemBundle(io) catch null;
            if (active_bundle == null) return error.TlsCaUnavailable;
        }

        const self = allocator.create(Connection) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);

        const bufs_rw = allocator.alloc(u8, max_cipher) catch return error.OutOfMemory;
        errdefer allocator.free(bufs_rw);
        const bufs_rr = allocator.alloc(u8, max_cipher) catch return error.OutOfMemory;
        errdefer allocator.free(bufs_rr);
        // Combined plaintext-in staging (cipher window + plaintext window).
        const bufs_tr = allocator.alloc(u8, max_cipher + 16384) catch return error.OutOfMemory;
        errdefer allocator.free(bufs_tr);
        const bufs_pw = allocator.alloc(u8, 16384) catch return error.OutOfMemory;
        errdefer allocator.free(bufs_pw);
        // Initialize EVERYTHING in place on the heap object. tls.Client
        // stores pointers into our reader/writer interfaces; any move of
        // this struct after init would dangle them.
        self.* = .{
            .client = undefined,
            .allowTruncation = conf.allowTruncation,
            .bufStreamWriter = bufs_rw,
            .bufStreamReader = bufs_rr,
            .bufTlsRead = bufs_tr,
            .bufPlainWrite = bufs_pw,
            .streamWriter = undefined,
            .streamReader = undefined,
            .io = io,
            .socketHandle = conf.socketHandle,
        };

        self.streamWriter = .init(
            .{ .socket = .{ .handle = conf.socketHandle, .address = undefined } },
            io,
            self.bufStreamWriter,
        );
        self.streamReader = .init(
            .{ .socket = .{ .handle = conf.socketHandle, .address = undefined } },
            io,
            self.bufStreamReader,
        );

        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&entropy);

        // SNI handling: virtual-hosted HTTPS servers abort the handshake
        // (TlsAlert) when no serverName is sent. std's `no_verification`
        // sends no SNI, so `verify=none` debug mode would always fail against
        // such hosts. When the peer is a DNS name (not a literal IP), always
        // offer it as SNI via `explicit` — chain verification is still
        // skipped for `none` (ca=no_verification), so clock/CA issues stay
        // bypassed; only the SAN hostname check remains (no time involved).
        // Literal IPs never send SNI per RFC 6066.
        const send_sni = conf.host.len > 0 and !isIpLiteral(conf.host);
        const host_opt: @TypeOf(@as(tls.Client.Options, undefined).host) =
            if (send_sni) .{ .explicit = conf.host } else .no_verification;
        const ca_opt: @TypeOf(@as(tls.Client.Options, undefined).ca) = switch (conf.verify) {
            .none => .no_verification,
            .selfSigned => .self_signed,
            .caBundle => .{ .bundle = .{
                .gpa = allocator,
                .io = io,
                .lock = &g_ca_lock,
                .bundle = active_bundle.?,
            } },
        };

        self.client = tls.Client.init(
            &self.streamReader.interface,
            &self.streamWriter.interface,
            .{
                .host = host_opt,
                .ca = ca_opt,
                .read_buffer = self.bufTlsRead,
                .write_buffer = self.bufPlainWrite,
                .entropy = &entropy,
                .realtime_now = std.Io.Clock.now(.real, io),
                .allow_truncation_attacks = conf.allowTruncation,
            },
        ) catch |err| switch (err) {
            error.CertificateExpired => return error.CertificateExpired,
            error.CertificateHostMismatch => return error.CertificateHostMismatch,
            error.CertificateIssuerMismatch => return error.CertificateIssuerMismatch,
            error.CertificateNotYetValid => return error.CertificateNotYetValid,
            error.CertificateSignatureInvalid => return error.CertificateSignatureInvalid,
            error.TlsCertificateNotVerified => return error.TlsCertificateNotVerified,
            error.TlsAlert => return error.TlsAlert,
            error.TlsDecodeError => return error.TlsDecodeError,
            else => return error.TlsInitializationFailed,
        };
        return self;
    }

    pub fn destroy(self: *Connection, allocator: Allocator) void {
        // In truncation-tolerant mode there is no close_notify contract;
        // attempting the write against a vanished peer only risks RST noise.
        if (!self.allowTruncation) self.client.end() catch {};
        var stream = std.Io.net.Stream{ .socket = .{ .handle = self.socketHandle, .address = undefined } };
        stream.close(self.io);
        allocator.free(self.bufStreamWriter);
        allocator.free(self.bufStreamReader);
        allocator.free(self.bufTlsRead);
        allocator.free(self.bufPlainWrite);
        allocator.destroy(self);
    }

    /// Plaintext write; encrypts, then pushes ciphertext to the socket.
    pub fn writeAll(self: *Connection, bytes: []const u8) WriteError!void {
        self.client.writer.writeAll(bytes) catch return error.WriteFailed;
        self.client.writer.flush() catch return error.WriteFailed;
        // The TLS writer drains into the stream writer's own ciphertext
        // buffer; that one needs its own flush to reach the wire.
        self.streamWriter.interface.flush() catch return error.WriteFailed;
    }

    /// Plaintext read; returns 0 on clean TLS EOF (close_notify) or, when
    /// truncation-tolerant, on raw FIN.
    pub fn read(self: *Connection, buffer: []u8) ReadError!usize {
        if (buffer.len == 0) return 0;
        if (self.client.eof()) return 0;
        // readSliceShort maps EndOfStream internally: 0 == TLS EOF.
        return self.client.reader.readSliceShort(buffer) catch error.ReadFailed;
    }
};

/// True for IPv4/IPv6 literals (no SNI per RFC 6066 Section 3).
fn isIpLiteral(host: []const u8) bool {
    // Strip brackets for "[::1]" style literals.
    var h = host;
    if (h.len >= 2 and h[0] == '[' and h[h.len - 1] == ']') h = h[1 .. h.len - 1];
    // Strip zone id ("fe80::1%eth0").
    if (std.mem.indexOfScalar(u8, h, '%')) |zi| h = h[0..zi];
    if (std.Io.net.IpAddress.parseLiteral(h)) |_| {
        return true;
    } else |_| {
        return false;
    }
}
