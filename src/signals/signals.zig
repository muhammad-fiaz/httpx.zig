//! Public signal-handling surface.
//!
//! Servers use this module automatically; applications that own their process
//! lifecycle can use `register` directly or disable the server integration
//! with `.signals = .{ .enabled = false }`.

pub const manager = @import("manager.zig");
pub const Kind = manager.Kind;
pub const Event = manager.Event;
pub const Mask = manager.Mask;
pub const Subscription = manager.Subscription;
pub const register = manager.register;
pub const supported = manager.supported;
pub const Error = manager.Error;
