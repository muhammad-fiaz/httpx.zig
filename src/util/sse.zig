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

pub fn parseSseStream(
    allocator: Allocator,
    data: []const u8,
    on_event: *const fn (Event) void,
) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    var current_event = Event{};
    var data_lines = std.ArrayList(u8).empty;
    defer data_lines.deinit(allocator);

    while (lines.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, &.{ '\r', '\n' });

        if (trimmed.len == 0) {
            if (data_lines.items.len > 0) {
                current_event.data = data_lines.items;
                on_event(current_event);
                count += 1;
            }
            current_event = Event{};
            data_lines.clearRetainingCapacity();
        } else if (trimmed[0] == ':') {
            // Comment line - ignore
        } else if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon_pos| {
            const field_name = trimmed[0..colon_pos];
            const field_value = if (colon_pos + 1 < trimmed.len)
                std.mem.trimLeft(u8, trimmed[colon_pos + 1 .. trimmed.len], &.{' '})
            else
                "";

            if (std.mem.eql(u8, field_name, "event")) {
                current_event.event = field_value;
            } else if (std.mem.eql(u8, field_name, "data")) {
                if (data_lines.items.len > 0) {
                    data_lines.appendSlice(allocator, "\n") catch continue;
                }
                data_lines.appendSlice(allocator, field_value) catch continue;
            } else if (std.mem.eql(u8, field_name, "id")) {
                current_event.id = field_value;
            } else if (std.mem.eql(u8, field_name, "retry")) {
                if (std.fmt.parseInt(u64, field_value, 10)) |ms| {
                    current_event.retry_ms = @intCast(ms);
                } else |_| {}
            }
        }
    }

    // Handle any remaining data
    if (data_lines.items.len > 0) {
        current_event.data = data_lines.items;
        on_event(current_event);
        count += 1;
    }

    return count;
}

test "sse parse basic event" {
    const testing = std.testing;
    const data = "event: message\ndata: Hello World\n\n";
    const Context = struct {
        var received: bool = false;
    };
    Context.received = false;
    const on_event = struct {
        fn f(event: Event) void {
            _ = event;
            Context.received = true;
        }
    }.f;
    const count = parseSseStream(testing.allocator, data, &on_event);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expect(Context.received);
}
