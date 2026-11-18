//! Windows console-control backend.
//!
//! `SetConsoleCtrlHandler` callbacks run on a system-created thread with the
//! same restrictions as an asynchronous signal handler: no allocation, no
//! locks, no application callbacks. The handler only bumps atomic counters and
//! signals a manual-reset event. The notification thread waits on that event
//! and dispatches to subscribers in normal execution context.

const std = @import("std");
const types = @import("types.zig");

pub const supported = true;

const HANDLE = *anyopaque;
const BOOL = i32;
const DWORD = u32;
const INFINITE: DWORD = 0xFFFFFFFF;

const CTRL_C_EVENT: DWORD = 0;
const CTRL_BREAK_EVENT: DWORD = 1;
const CTRL_CLOSE_EVENT: DWORD = 2;
const CTRL_LOGOFF_EVENT: DWORD = 5;
const CTRL_SHUTDOWN_EVENT: DWORD = 6;

extern "kernel32" fn CreateEventW(
    attributes: ?*anyopaque,
    manualReset: BOOL,
    initialState: BOOL,
    name: ?[*:0]const u16,
) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetEvent(handle: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn ResetEvent(handle: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(handle: HANDLE, milliseconds: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn SetConsoleCtrlHandler(
    handler: ?*const fn (DWORD) callconv(.winapi) BOOL,
    add: BOOL,
) callconv(.winapi) BOOL;

var event: ?HANDLE = null;
var installed = false;

var pendingInterrupt = std.atomic.Value(u32).init(0);
var pendingClose = std.atomic.Value(u32).init(0);
var pendingLogoff = std.atomic.Value(u32).init(0);
var pendingShutdown = std.atomic.Value(u32).init(0);

pub fn init() !void {
    if (installed) return;
    const ev = CreateEventW(null, 1, 0, null) orelse return error.SignalsUnsupported;
    event = ev;
    if (SetConsoleCtrlHandler(&handleControl, 1) == 0) {
        _ = CloseHandle(ev);
        event = null;
        return error.SignalsUnsupported;
    }
    installed = true;
}

pub fn deinit() void {
    if (!installed) return;
    _ = SetConsoleCtrlHandler(&handleControl, 0);
    if (event) |ev| _ = CloseHandle(ev);
    event = null;
    installed = false;
}

pub fn wake() void {
    if (event) |ev| _ = SetEvent(ev);
}

pub fn wait() void {
    if (event) |ev| {
        _ = WaitForSingleObject(ev, INFINITE);
        _ = ResetEvent(ev);
    }
}

pub fn take(kind: types.Kind) u32 {
    return switch (kind) {
        .interrupt => pendingInterrupt.swap(0, .monotonic),
        .terminate => pendingInterrupt.swap(0, .monotonic),
        .close => pendingClose.swap(0, .monotonic),
        .logoff => pendingLogoff.swap(0, .monotonic),
        .shutdown => pendingShutdown.swap(0, .monotonic),
    };
}

fn handleControl(ctrlType: DWORD) callconv(.winapi) BOOL {
    switch (ctrlType) {
        CTRL_C_EVENT, CTRL_BREAK_EVENT => _ = pendingInterrupt.fetchAdd(1, .monotonic),
        CTRL_CLOSE_EVENT => _ = pendingClose.fetchAdd(1, .monotonic),
        CTRL_LOGOFF_EVENT => _ = pendingLogoff.fetchAdd(1, .monotonic),
        CTRL_SHUTDOWN_EVENT => _ = pendingShutdown.fetchAdd(1, .monotonic),
        else => return 0,
    }
    if (event) |ev| _ = SetEvent(ev);
    return 1;
}
