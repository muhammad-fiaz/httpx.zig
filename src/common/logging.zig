//! Structured logging — the ONE logging foundation for all of httpx.
//!
//! Design:
//!   * `Logger` is a thin handle; level filtering happens before any work.
//!   * Built-in output goes through `WriterSink` (any `*std.Io.Writer`).
//!   * Custom/external loggers plug in via the `Sink` vtable — implement one
//!     function and hand it to `Logger.custom()`. JSON, syslog, OpenTelemetry,
//!     tint-based color, whatever the application wants.
//!   * Messages are formatted into a stack buffer only AFTER level checks,
//!     so disabled levels cost nothing.
//!   * Header redaction helpers keep secrets out of logs by construction.
//!
//! Nothing here hardcodes stdout/stderr or any external library.
//!
//! References:
//!   - RFC 9110 Section 10.1.1 — Authorization (secret redaction)
//!   - RFC 9110 Section 10.2.3 — Proxy-Authorization (secret redaction)
//!   - RFC 5424 — The Syslog Protocol (severity levels mapping)

const std = @import("std");
const sync = @import("sync.zig");
const tint = @import("loaders").tint;

pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
    fatal = 4,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO ",
            .warn => "WARN ",
            .err => "ERROR",
            .fatal => "FATAL",
        };
    }

    pub fn colorCode(self: Level) []const u8 {
        return switch (self) {
            .debug => tint.fg(.{ .ansi4 = .bright_black }),
            .info => tint.fg(.{ .ansi4 = .green }),
            .warn => tint.fg(.{ .ansi4 = .yellow }),
            .err => tint.fg(.{ .ansi4 = .red }),
            .fatal => tint.fg(.{ .ansi4 = .magenta }),
        };
    }
};

pub const ColorMode = enum { auto, always, never };

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

/// The logging handle used everywhere in httpx.
///
/// Copyable by value; `log()` is safe from multiple threads when the
/// underlying sink is (WriterSink serializes internally).
pub const Logger = struct {
    sink: Sink,
    min_level: Level = .info,
    enabled: bool = true,

    /// Built-in writer-backed logger.
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
        return .{ .sink = .{ .ptr = undefined, .logFn = &noopLog }, .min_level = .debug, .enabled = false };
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

// Built-in sink: writes "[LABEL] [component] message" (+ optional ANSI color)

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

// Secret redaction

/// True for headers whose values must never be logged verbatim.
pub fn isSensitiveHeader(name: []const u8) bool {
    const sensitive = [_][]const u8{
        "authorization", "proxy-authorization", "cookie",
        "set-cookie",    "x-api-key",           "api-key",
        "private-key",   "session-token",       "access-token",
        "x-auth-token",  "x-session-id",
    };
    for (sensitive) |s| {
        if (std.ascii.eqlIgnoreCase(name, s)) return true;
    }
    return false;
}

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
    try std.testing.expect(!isSensitiveHeader("Content-Type"));
    try std.testing.expect(!isSensitiveHeader("Accept"));
}
