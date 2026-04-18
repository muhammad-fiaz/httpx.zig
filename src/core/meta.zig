//! Shared library metadata constants.

const std = @import("std");

pub const version = "0.1.0";
pub const user_agent_prefix = "httpx.zig/";
pub const default_user_agent = user_agent_prefix ++ version;

test "default_user_agent is prefix plus version" {
    try std.testing.expect(std.mem.startsWith(u8, default_user_agent, user_agent_prefix));
    try std.testing.expect(std.mem.endsWith(u8, default_user_agent, version));
    try std.testing.expectEqual(user_agent_prefix.len + version.len, default_user_agent.len);
}

test "version has numeric semver core" {
    var it = std.mem.splitScalar(u8, version, '.');
    var part_count: usize = 0;

    while (it.next()) |part| {
        part_count += 1;
        try std.testing.expect(part.len > 0);
        _ = try std.fmt.parseUnsigned(u32, part, 10);
    }

    try std.testing.expectEqual(@as(usize, 3), part_count);
}
