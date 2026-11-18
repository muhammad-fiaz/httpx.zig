//! POSIX signal backend: `sigaction` + a self-pipe.
//!
//! The asynchronous handler is restricted to async-signal-safe operations:
//! increment an atomic counter and `write(2)` one byte into a self-pipe. The
//! manager's notification thread performs the blocking read and dispatches to
//! subscribers in normal execution context.
//!
//! Previous `SIGINT`/`SIGTERM` dispositions are captured on installation and
//! restored when the last subscription is removed.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

pub const supported = true;

var pipeRead: std.posix.fd_t = -1;
var pipeWrite: std.posix.fd_t = -1;
var installed = false;

var oldInterrupt: std.posix.Sigaction = undefined;
var oldTerminate: std.posix.Sigaction = undefined;

var pendingInterrupt = std.atomic.Value(u32).init(0);
var pendingTerminate = std.atomic.Value(u32).init(0);

pub fn init() !void {
    if (installed) return;
    if (builtin.os.tag == .wasi) return error.SignalsUnsupported;

    var fds: [2]std.posix.fd_t = undefined;
    _ = std.posix.system.pipe(&fds);
    pipeRead = fds[0];
    pipeWrite = fds[1];

    var action: std.posix.Sigaction = std.mem.zeroes(std.posix.Sigaction);
    action.handler = .{ .handler = @ptrCast(&handleSignal) };
    action.mask = std.mem.zeroes(@TypeOf(action.mask));
    action.flags = std.posix.SA.RESTART;

    std.posix.sigaction(std.posix.SIG.INT, &action, &oldInterrupt);
    std.posix.sigaction(std.posix.SIG.TERM, &action, &oldTerminate);
    installed = true;
}

pub fn deinit() void {
    if (!installed) return;
    std.posix.sigaction(std.posix.SIG.INT, &oldInterrupt, null);
    std.posix.sigaction(std.posix.SIG.TERM, &oldTerminate, null);
    _ = std.posix.system.close(pipeRead);
    _ = std.posix.system.close(pipeWrite);
    pipeRead = -1;
    pipeWrite = -1;
    installed = false;
}

pub fn wake() void {
    if (pipeWrite < 0) return;
    const byte = [_]u8{1};
    _ = std.posix.system.write(pipeWrite, &byte, 1);
}

pub fn wait() void {
    if (pipeRead < 0) return;
    var buf: [64]u8 = undefined;
    while (true) {
        const n = std.posix.read(pipeRead, &buf) catch return;
        if (n > 0) return;
    }
}

pub fn take(kind: types.Kind) u32 {
    return switch (kind) {
        .interrupt => pendingInterrupt.swap(0, .monotonic),
        .terminate => pendingTerminate.swap(0, .monotonic),
        else => 0,
    };
}

fn handleSignal(sig: std.posix.SIG) callconv(.c) void {
    if (sig == std.posix.SIG.INT) {
        _ = pendingInterrupt.fetchAdd(1, .monotonic);
    } else if (sig == std.posix.SIG.TERM) {
        _ = pendingTerminate.fetchAdd(1, .monotonic);
    } else {
        return;
    }
    if (pipeWrite >= 0) {
        const byte = [_]u8{1};
        _ = std.posix.system.write(pipeWrite, &byte, 1);
    }
}
