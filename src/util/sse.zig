//! Server-Sent Events (SSE) Helper Utilities for httpx.zig
//!
//! Implements SSE formatting per W3C Server-Sent Events spec:
//! - Event formatting (`id:`, `event:`, `data:`, `retry:`)
//! - Multi-line data stream serialisation

const std = @import("std");
const Allocator = std.mem.Allocator;
const list_writer = @import("list_writer.zig");

pub const Event = struct {
    data: []const u8,
    event: ?[]const u8 = null,
    id: ?[]const u8 = null,
    retry_ms: ?u32 = null,

    /// Serialises this SSE event to wire format string.
    /// Caller owns the returned slice.
    pub fn format(self: Event, allocator: Allocator) ![]u8 {
        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(allocator);
        const writer = list_writer.init(allocator, &payload);

        if (self.id) |id| try writer.print("id: {s}\n", .{id});
        if (self.event) |event_name| try writer.print("event: {s}\n", .{event_name});
        if (self.retry_ms) |ms| try writer.print("retry: {d}\n", .{ms});

        var lines = std.mem.splitScalar(u8, self.data, '\n');
        while (lines.next()) |line| {
            try writer.print("data: {s}\n", .{line});
        }
        try writer.writeAll("\n");

        return payload.toOwnedSlice(allocator);
    }
};
