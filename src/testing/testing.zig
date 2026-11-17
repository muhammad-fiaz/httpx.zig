//! Local testing server and response helpers.
//!
//! ```zig
//! var server = try httpx.testing.Server.init(allocator, io, .{});
//! defer server.deinit();
//!
//! try server.route("/get", .{ .body = "Hello from Httpx" });
//! try server.start();
//!
//! const url = try server.url("/get");
//! defer allocator.free(url);
//! ```
//!
//! The server is the production `httpx.Server` with loopback/ephemeral-port
//! defaults, request capture, and concise route registration. It uses real
//! sockets and the normal `httpx.Client` transport.

const response = @import("response.zig");

pub const Server = @import("server.zig").Server;
pub const Config = @import("server.zig").Config;
pub const RouteOptions = @import("server.zig").RouteOptions;
pub const CaptureConfig = @import("server.zig").CaptureConfig;
pub const CapturedRequest = @import("server.zig").CapturedRequest;
pub const Method = @import("server.zig").Method;
pub const Header = @import("server.zig").Header;
pub const Handler = @import("handler.zig").Handler;
pub const echo = @import("handler.zig").echo;

/// Response fixtures for concise route registration.
pub const text = response.text;
pub const json = response.json;
pub const html = response.html;
pub const binary = response.binary;
pub const empty = response.empty;
pub const redirect = response.redirect;
pub const delayed = response.delayed;

/// Releases a snapshot slice returned by `Server.requests`.
pub const freeCaptured = @import("request.zig").freeCaptured;

pub const expectStatus = @import("assertions.zig").expectStatus;
pub const expectBody = @import("assertions.zig").expectBody;
pub const expectBodyContains = @import("assertions.zig").expectBodyContains;
pub const expectHeader = @import("assertions.zig").expectHeader;
pub const expectNoHeader = @import("assertions.zig").expectNoHeader;
pub const expectJsonBody = @import("assertions.zig").expectJsonBody;
