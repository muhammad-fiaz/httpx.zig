//! Shared library metadata constants.

const std = @import("std");

pub const version = "0.1.6";
pub const user_agent_prefix = "httpx.zig/";
pub const default_user_agent = user_agent_prefix ++ version;

test "default_user_agent is prefix plus version" {
    try std.testing.expect(std.mem.startsWith(u8, default_user_agent, user_agent_prefix));
    try std.testing.expect(std.mem.endsWith(u8, default_user_agent, version));
    try std.testing.expectEqual(user_agent_prefix.len + version.len, default_user_agent.len);
}

test "version has numeric semver core" {
    const parsed = try std.SemanticVersion.parse(version);
    try std.testing.expectEqual(@as(u64, 0), parsed.major);
    try std.testing.expectEqual(@as(u64, 1), parsed.minor);
    try std.testing.expectEqual(@as(u64, 6), parsed.patch);
}
