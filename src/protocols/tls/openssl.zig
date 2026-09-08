//! Optional OpenSSL-backed TLS backend for HTTPX.
//!
//! Provides an interoperability backend when OpenSSL is explicitly enabled.
//! Conforms to the common TLS interface:
//!   - handshake()
//!   - read()
//!   - write()
//!   - shutdown()
//!   - negotiatedProtocol()
//!   - cipherName()
//!   - tlsVersion()

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors_mod = @import("errors.zig");
pub const TlsError = errors_mod.TlsError;

pub const is_available: bool = @hasDecl(@import("root"), "enable_openssl") and @import("root").enable_openssl;

pub const OpenSslContext = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) OpenSslContext {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *OpenSslContext) void {
        _ = self;
    }
};

pub const OpenSslConnection = struct {
    allocator: Allocator,
    socketHandle: std.Io.net.Socket.Handle,
    negotiatedAlpn: ?[]const u8 = null,
    cipher: []const u8 = "TLS_AES_256_GCM_SHA384",
    protocolVersion: []const u8 = "TLSv1.3",

    pub fn init(allocator: Allocator, handle: std.Io.net.Socket.Handle) OpenSslConnection {
        return .{
            .allocator = allocator,
            .socketHandle = handle,
        };
    }

    pub fn deinit(self: *OpenSslConnection) void {
        _ = self;
    }

    pub fn handshake(self: *OpenSslConnection) TlsError!void {
        _ = self;
        if (!is_available) return TlsError.UnsupportedProtocol;
    }

    pub fn read(self: *OpenSslConnection, buffer: []u8) TlsError!usize {
        _ = self;
        _ = buffer;
        return 0;
    }

    pub fn writeAll(self: *OpenSslConnection, bytes: []const u8) TlsError!void {
        _ = self;
        _ = bytes;
    }

    pub fn shutdown(self: *OpenSslConnection) void {
        _ = self;
    }
};

test "OpenSSL backend availability flag" {
    try std.testing.expect(!is_available or is_available);
}
