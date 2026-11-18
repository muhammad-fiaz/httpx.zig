//! Shared signal vocabulary for the process-wide manager.
//!
//! These types are platform-neutral. Backends map their native events onto
//! `Kind` and never call application code directly.

/// A termination-class process event.
pub const Kind = enum {
    /// Ctrl+C / SIGINT.
    interrupt,
    /// SIGTERM. Not available on Windows.
    terminate,
    /// Windows CTRL_CLOSE_EVENT (console window closed).
    close,
    /// Windows CTRL_LOGOFF_EVENT.
    logoff,
    /// Windows CTRL_SHUTDOWN_EVENT.
    shutdown,
};

/// Delivery record handed to a subscriber from normal execution context.
pub const Event = struct {
    kind: Kind,
    /// Number of coalesced deliveries represented by this event.
    count: u32,
};

/// Which events a subscription wants to observe.
///
/// Defaults follow the documented server defaults: interrupt, terminate and
/// the Windows console close/shutdown events are enabled; logoff is opt-in.
pub const Mask = struct {
    interrupt: bool = true,
    terminate: bool = true,
    close: bool = true,
    logoff: bool = false,
    shutdown: bool = true,

    pub fn includes(self: Mask, kind: Kind) bool {
        return switch (kind) {
            .interrupt => self.interrupt,
            .terminate => self.terminate,
            .close => self.close,
            .logoff => self.logoff,
            .shutdown => self.shutdown,
        };
    }

    pub fn matches(self: Mask, other: Mask) bool {
        return (self.interrupt and other.interrupt) or
            (self.terminate and other.terminate) or
            (self.close and other.close) or
            (self.logoff and other.logoff) or
            (self.shutdown and other.shutdown);
    }
};

/// True when the current target has a real signal backend.
pub const supported = switch (@import("builtin").os.tag) {
    .windows, .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};
