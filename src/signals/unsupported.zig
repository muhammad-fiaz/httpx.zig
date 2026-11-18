//! Backend for targets without process signals.
//!
//! No fake handlers are installed. `init` fails explicitly so callers can
//! report an unsupported capability instead of silently doing nothing.

const std = @import("std");
const types = @import("types.zig");

pub const supported = false;

pub fn init() !void {
    return error.SignalsUnsupported;
}

pub fn deinit() void {}

pub fn wake() void {}

pub fn wait() void {}

pub fn take(_: types.Kind) u32 {
    return 0;
}

comptime {
    _ = std;
}
