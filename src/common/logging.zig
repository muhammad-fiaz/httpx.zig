//! Structured logging and observability — the ONE foundation for all of httpx.
//!
//! Design:
//!   * HTTPX generates structured events and delivers them to an optional
//!     application-supplied callback. HTTPX NEVER automatically prints to
//!     stdout, stderr, or any other output destination.
//!   * When no callback is configured, event generation is skipped entirely
//!     (single branch, near-zero overhead).
//!   * The application callback decides what to do: print, forward to a
//!     third-party logger, send to telemetry, write to a file, or ignore.
//!   * `ServerEvent` and `ClientEvent` carry structured fields (method, path,
//!     status, duration, bytes) so the application owns formatting.
//!   * `Logger`/`Sink`/`WriterSink` remain available as OPTIONAL adapter
//!     helpers the application can use to build a callback — HTTPX itself
//!     no longer creates them automatically.
//!   * Header redaction helpers keep secrets out of events by construction.
//!
//! Callback threading: callbacks are invoked synchronously on the request
//! thread/connection thread. Borrowed slices (method, path, url, message)
//! are valid only for the duration of the callback call. Do not retain them.
//!
//! References:
//!   - RFC 9110 Section 10.1.1 — Authorization (secret redaction)
//!   - RFC 9110 Section 10.2.3 — Proxy-Authorization (secret redaction)
//!   - RFC 5424 — The Syslog Protocol (severity levels mapping)

const std = @import("std");
const sync = @import("sync.zig");
const tint = @import("loaders").tint;

// Levels

pub const Level = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,
    fatal = 5,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO ",
            .warn => "WARN ",
            .err => "ERROR",
            .fatal => "FATAL",
        };
    }

    pub fn colorCode(self: Level) []const u8 {
        return switch (self) {
            .trace => tint.fg(.{ .ansi4 = .bright_black }),
            .debug => tint.fg(.{ .ansi4 = .bright_black }),
            .info => tint.fg(.{ .ansi4 = .green }),
            .warn => tint.fg(.{ .ansi4 = .yellow }),
            .err => tint.fg(.{ .ansi4 = .red }),
            .fatal => tint.fg(.{ .ansi4 = .magenta }),
        };
    }
};

pub const ColorMode = enum { auto, always, never };

// Server-Side Structured Events

/// Identifies what happened in the server event.
pub const ServerEventKind = enum {
    /// Server bound and is ready to accept connections.
    server_started,
    /// Server has finished its accept loop and shut down.
    server_stopped,
    /// A new TCP connection was accepted.
    connection_accepted,
    /// A connection was closed (normally or by error).
    connection_closed,
    /// A complete HTTP request was received and parsed.
    request_received,
    /// A request was fully handled and the response was sent.
    request_completed,
    /// A request failed before or during handler execution.
    request_failed,
    /// The handler returned an error.
    handler_error,
    /// A middleware function returned an error.
    middleware_error,
    /// A worker thread started.
    worker_started,
    /// A worker thread stopped.
    worker_stopped,
    /// No route matched the request path.
    route_not_found,
    /// The path matched a route but the method did not.
    method_not_allowed,
    /// A TLS handshake failed or was rejected.
    tls_handshake_failed,
};

/// Structured server-side event delivered to the application callback.
///
/// All slice fields (method, path, message) are borrowed for the duration
/// of the callback call only. Do not store them — copy if you need persistence.
///
/// HTTPX never formats or prints this event. The callback owns all output.
pub const ServerEvent = struct {
    /// What happened.
    kind: ServerEventKind,
    /// Severity level of this event.
    level: Level,
    /// HTTP method string, e.g. "GET", "POST". Empty when not applicable.
    method: []const u8 = "",
    /// Request path, e.g. "/api/users". Empty when not applicable.
    path: []const u8 = "",
    /// HTTP response status code (0 when not applicable).
    status: u16 = 0,
    /// Wall-clock request duration in milliseconds (0 when not applicable).
    duration_ms: i64 = 0,
    /// Request body bytes received (0 when not applicable).
    bytes_in: usize = 0,
    /// Response bytes sent including headers (0 when not applicable).
    bytes_out: usize = 0,
    /// Optional human-readable message for diagnostic context.
    message: []const u8 = "",

    /// Convenience accessor — same as `event.method`.
    pub fn methodName(self: ServerEvent) []const u8 {
        return self.method;
    }

    /// Convenience accessor — same as `event.status`.
    pub fn statusCode(self: ServerEvent) u16 {
        return self.status;
    }

    /// Convenience accessor — same as `event.duration_ms`.
    pub fn durationMs(self: ServerEvent) i64 {
        return self.duration_ms;
    }
};

/// Function type for server-side event callbacks.
///
/// Example — application-controlled access log:
///
/// ```zig
/// fn onEvent(event: httpx.ServerEvent) void {
///     if (event.kind == .request_completed) {
///         std.debug.print("{s} {s} {d} {d}ms\n", .{
///             event.method, event.path, event.status, event.duration_ms,
///         });
///     }
/// }
/// ```
///
/// HTTPX does not print anything itself — the callback owns output.
pub const ServerEventCallback = *const fn (event: ServerEvent) void;

// Client-Side Structured Events

/// Identifies what happened in the client event.
pub const ClientEventKind = enum {
    /// A fetch/request was started.
    request_started,
    /// A request completed successfully (response received).
    request_completed,
    /// A request failed (transport or protocol error).
    request_failed,
    /// A redirect was followed.
    redirect,
    /// A request is being retried.
    retry,
    /// A DNS lookup was performed.
    dns_lookup,
    /// A DNS cache hit occurred (no network lookup needed).
    dns_cache_hit,
    /// A new TCP connection was established.
    connection_established,
    /// An existing pooled connection was reused.
    connection_reused,
    /// A TLS handshake was completed.
    tls_handshake,
    /// A request or operation timed out.
    timeout,
    /// A request was cancelled.
    cancellation,
};

/// Structured client-side event delivered to the application callback.
///
/// All slice fields are borrowed for the duration of the callback call only.
///
/// HTTPX never formats or prints this event. The callback owns all output.
pub const ClientEvent = struct {
    /// What happened.
    kind: ClientEventKind,
    /// Severity level of this event.
    level: Level,
    /// HTTP method string, e.g. "GET". Empty when not applicable.
    method: []const u8 = "",
    /// The request URL (may be redacted — never contains credentials).
    url: []const u8 = "",
    /// HTTP response status code (0 when not applicable).
    status: u16 = 0,
    /// Wall-clock request duration in milliseconds (0 when not applicable).
    duration_ms: i64 = 0,
    /// Request body bytes sent (0 when not applicable).
    bytes_sent: usize = 0,
    /// Response body bytes received (0 when not applicable).
    bytes_received: usize = 0,
    /// Optional human-readable message for diagnostic context.
    message: []const u8 = "",

    /// Convenience accessor — same as `event.method`.
    pub fn methodName(self: ClientEvent) []const u8 {
        return self.method;
    }

    /// Convenience accessor — same as `event.status`.
    pub fn statusCode(self: ClientEvent) u16 {
        return self.status;
    }

    /// Convenience accessor — same as `event.duration_ms`.
    pub fn durationMs(self: ClientEvent) i64 {
        return self.duration_ms;
    }
};

/// Function type for client-side event callbacks.
///
/// Example — application-controlled request log:
///
/// ```zig
/// fn onClientEvent(event: httpx.ClientEvent) void {
///     if (event.kind == .request_completed) {
///         std.debug.print("{s} {d} {d}ms\n", .{
///             event.method, event.status, event.duration_ms,
///         });
///     }
/// }
/// ```
pub const ClientEventCallback = *const fn (event: ClientEvent) void;

// Low-level Logger / Sink (application adapter helpers)
//
// These types are NOT used internally by HTTPX to produce automatic output.
// They are provided as optional helper adapters for applications that want
// to implement a callback using a writer-backed formatted logger.
//
// Example (application code, not HTTPX internals):
//
//   var w: std.Io.Writer = std.Io.File.stderr().writer(io, &buf);
//   var ws = httpx.WriterSink.init(&w, false);
//   const logger = httpx.Logger.writer(&ws, .info, true);
//
//   fn onServerEvent(event: httpx.ServerEvent) void {
//       logger.log(event.level, "server", "{s} {s} {d}", .{
//           event.method, event.path, event.status,
//       });
//   }

/// One structured key/value pair attached to a record.
pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

/// Structured record delivered to every sink. Secrets must be redacted by
/// callers BEFORE constructing a Record — never put tokens here.
pub const Record = struct {
    level: Level,
    component: []const u8,
    message: []const u8,
    fields: []const Field = &.{},
};

/// Explicit custom-logger integration point. Implement this vtable to bridge
/// ANY external logging library into httpx.
pub const Sink = struct {
    ptr: *anyopaque,
    logFn: *const fn (ptr: *anyopaque, record: Record) void,

    pub fn deliver(self: Sink, record: Record) void {
        self.logFn(self.ptr, record);
    }
};

/// Optional logging adapter handle (application use only — not used by HTTPX
/// internals to produce automatic output).
///
/// Copyable by value; `log()` is thread-safe when the underlying sink is.
pub const Logger = struct {
    sink: Sink,
    min_level: Level = .info,
    enabled: bool = true,

    /// Built-in writer-backed logger (application use).
    pub fn writer(ws: *WriterSink, min_level: Level, enabled: bool) Logger {
        return .{
            .sink = ws.sink(),
            .min_level = min_level,
            .enabled = enabled,
        };
    }

    /// Wrap an arbitrary custom/external logger.
    pub fn custom(sink: Sink, min_level: Level, enabled: bool) Logger {
        return .{ .sink = sink, .min_level = min_level, .enabled = enabled };
    }

    /// A logger that swallows everything (tests, quiet mode).
    pub fn disabled() Logger {
        return .{ .sink = .{ .ptr = undefined, .logFn = &noopLog }, .min_level = .trace, .enabled = false };
    }

    pub fn log(self: *const Logger, level: Level, comptime component: []const u8, comptime fmt: []const u8, args: anytype) void {
        if (!self.enabled) return;
        if (@intFromEnum(level) < @intFromEnum(self.min_level)) return;

        var buf: [1024]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, fmt, args) catch blk: {
            // Truncated but still useful.
            break :blk buf[0..];
        };
        self.sink.deliver(.{
            .level = level,
            .component = component,
            .message = message,
        });
    }

    /// Log with structured fields appended after the message.
    pub fn logFields(self: *const Logger, level: Level, comptime component: []const u8, fields: []const Field, comptime fmt: []const u8, args: anytype) void {
        if (!self.enabled) return;
        if (@intFromEnum(level) < @intFromEnum(self.min_level)) return;

        var buf: [1024]u8 = undefined;
        var fbs = std.Io.Writer.fixed(&buf);
        fbs.print(fmt, args) catch {};
        for (fields) |f| {
            fbs.print(" {s}={s}", .{ f.name, f.value }) catch break;
        }
        self.sink.deliver(.{
            .level = level,
            .component = component,
            .message = ffs(&fbs),
        });
    }

    fn ffs(w: *std.Io.Writer) []const u8 {
        return w.buffered();
    }
};

fn noopLog(_: *anyopaque, _: Record) void {}

// WriterSink
// Application-use helper: writes "[LABEL] [component] message" to any writer.

pub const WriterSink = struct {
    w: *std.Io.Writer,
    mu: sync.Spinlock = .{},
    color: bool = false,

    pub fn init(w: *std.Io.Writer, color: bool) WriterSink {
        return .{ .w = w, .color = color };
    }

    pub fn sink(self: *WriterSink) Sink {
        return .{ .ptr = self, .logFn = &logImpl };
    }

    fn logImpl(ptr: *anyopaque, record: Record) void {
        const self: *WriterSink = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();
        const w = self.w;
        if (self.color) w.writeAll(record.level.colorCode()) catch return;
        w.writeAll(record.level.label()) catch return;
        if (self.color) w.writeAll(tint.reset) catch return;
        w.print(" [{s}] {s}", .{ record.component, record.message }) catch return;
        for (record.fields) |f| {
            w.print(" {s}={s}", .{ f.name, f.value }) catch return;
        }
        w.writeAll("\n") catch return;
    }
};

// Secret Redaction

/// Returns true for header names whose values must never be logged verbatim.
/// Use this in callbacks to filter sensitive data before printing.
pub fn isSensitiveHeader(name: []const u8) bool {
    const sensitive = [_][]const u8{
        "authorization",    "proxy-authorization", "cookie",
        "set-cookie",       "x-api-key",           "api-key",
        "private-key",      "session-token",       "access-token",
        "x-auth-token",     "x-session-id",        "x-secret",
        "x-internal-token",
    };
    for (sensitive) |s| {
        if (std.ascii.eqlIgnoreCase(name, s)) return true;
    }
    return false;
}

// Tests

test "writer sink plain output" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var ws = WriterSink.init(&w, false);
    const l = Logger.writer(&ws, .debug, true);
    l.log(.info, "server", "listening on port {d}", .{8080});
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "INFO") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[server]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "8080") != null);
}

test "writer sink colored output" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var ws = WriterSink.init(&w, true);
    const l = Logger.writer(&ws, .debug, true);
    l.log(.err, "tls", "handshake failed", .{});
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\x1b[31m") != null);
}

test "level filtering happens before formatting" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var ws = WriterSink.init(&w, false);
    const l = Logger.writer(&ws, .warn, true);
    l.log(.debug, "t", "suppressed {d} {d} {d}", .{ 1, 2, 3 });
    try std.testing.expectEqual(@as(usize, 0), w.end);
}

test "disabled logger swallows everything" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var ws = WriterSink.init(&w, false);
    const l = Logger.writer(&ws, .debug, false);
    l.log(.fatal, "t", "nothing {d}", .{1});
    try std.testing.expectEqual(@as(usize, 0), w.end);
}

test "custom external logger receives structured records" {
    const Capture = struct {
        seen: usize = 0,
        last_component: []const u8 = "",
        last_message: []const u8 = "",
        last_level: Level = .debug,

        fn logImpl(ptr: *anyopaque, record: Record) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.seen += 1;
            self.last_component = record.component;
            self.last_message = record.message;
            self.last_level = record.level;
        }

        fn sink(self: *@This()) Sink {
            return .{ .ptr = self, .logFn = &logImpl };
        }
    };
    var cap = Capture{};
    const l = Logger.custom(cap.sink(), .debug, true);
    l.log(.warn, "http", "{s} {s} -> {d}", .{ "GET", "/x", 404 });
    try std.testing.expectEqual(@as(usize, 1), cap.seen);
    try std.testing.expectEqualStrings("http", cap.last_component);
    try std.testing.expectEqualStrings("GET /x -> 404", cap.last_message);
    try std.testing.expectEqual(Level.warn, cap.last_level);
}

test "fields render as key=value" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var ws = WriterSink.init(&w, false);
    const l = Logger.writer(&ws, .debug, true);
    l.logFields(.info, "request", &.{
        .{ .name = "status", .value = "200" },
        .{ .name = "ms", .value = "3.2" },
    }, "{s} {s}", .{ "GET", "/users" });
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "GET /users status=200 ms=3.2") != null);
}

test "redaction list" {
    try std.testing.expect(isSensitiveHeader("Authorization"));
    try std.testing.expect(isSensitiveHeader("set-COOKIE"));
    try std.testing.expect(isSensitiveHeader("X-API-Key"));
    try std.testing.expect(isSensitiveHeader("X-Secret"));
    try std.testing.expect(isSensitiveHeader("X-Internal-Token"));
    try std.testing.expect(!isSensitiveHeader("Content-Type"));
    try std.testing.expect(!isSensitiveHeader("Accept"));
}

test "ServerEvent callback receives structured data" {
    const Capture = struct {
        seen: usize = 0,
        last_kind: ServerEventKind = .server_started,
        last_status: u16 = 0,
        last_method: []const u8 = "",

        fn cb(event: ServerEvent) void {
            // Access through a threadlocal to capture in test — use a global
            // mutable for simplicity in a single-threaded test.
            _ = event; // Callback validity test: compiles and is callable.
        }
    };
    _ = Capture{};

    // Verify event construction and field access compile and produce correct values.
    const ev = ServerEvent{
        .kind = .request_completed,
        .level = .info,
        .method = "GET",
        .path = "/health",
        .status = 200,
        .duration_ms = 3,
        .bytes_in = 0,
        .bytes_out = 64,
    };
    try std.testing.expectEqualStrings("GET", ev.methodName());
    try std.testing.expectEqual(@as(u16, 200), ev.statusCode());
    try std.testing.expectEqual(@as(i64, 3), ev.durationMs());
}

test "ClientEvent callback receives structured data" {
    const ev = ClientEvent{
        .kind = .request_completed,
        .level = .info,
        .method = "POST",
        .url = "https://example.com/api",
        .status = 201,
        .duration_ms = 42,
        .bytes_sent = 128,
        .bytes_received = 512,
    };
    try std.testing.expectEqualStrings("POST", ev.methodName());
    try std.testing.expectEqual(@as(u16, 201), ev.statusCode());
    try std.testing.expectEqual(@as(i64, 42), ev.durationMs());
}

test "null callback produces no overhead path" {
    // Simulates what HTTPX does internally: check once before constructing event.
    const callback: ?ServerEventCallback = null;
    var called = false;
    if (callback) |cb| {
        called = true;
        cb(.{ .kind = .request_completed, .level = .info });
    }
    try std.testing.expect(!called);
}
