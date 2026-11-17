//! Library identity and default documentation metadata.
//!
//! One zigantic schema is the single source of truth: the OpenAPI document,
//! the `Server` header, and the client `User-Agent` all read the same values,
//! so the library can never advertise two different versions.

const std = @import("std");
const z = @import("zigantic");

/// Default metadata for generated API documentation, the `Server` header,
/// and the client `User-Agent`.
const InfoSchema = z.objectOf(.{
    .title = z.withDefault(z.string(.{ .min = 1 }), "HTTPX API"),
    .version = z.withDefault(z.string(.{ .min = 1 }), "0.2.4"),
    .description = z.withDefault(z.string(.{}), "A Fast, High-Performance HTTP Client and Server Library for Zig."),
}, .{});
pub const Info = InfoSchema.Value;

/// The schema defaults, used wherever the library identifies itself.
pub const defaultInfo: Info = .{};

test "version identity" {
    try std.testing.expectEqualStrings("HTTPX API", defaultInfo.title);
    try std.testing.expectEqualStrings("0.2.4", defaultInfo.version);
}
