//! Server-Sent Events (SSE) Helper Utilities for httpx.zig
//!
//! Implements SSE formatting per W3C Server-Sent Events spec:
//! - Event formatting (`id:`, `event:`, `data:`, `retry:`)
//! - Multi-line data stream serialisation
//! - Streaming SSE writer for server-side event emission
//! - Parser with comment handling and field parsing

const std = @import("std");
const Allocator = std.mem.Allocator;
const list_writer = @import("list_writer.zig");
const dbg = @import("debug.zig");

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

/// Streaming SSE writer that emits events to a writer interface.
/// Useful for server-side SSE endpoints that push events over a connection.
pub fn SseWriter(comptime WriterType: type) type {
    return struct {
        underlying: WriterType,
        last_event_id: ?[]const u8 = null,

        const Self = @This();

        pub fn init(underlying: WriterType) Self {
            return .{ .underlying = underlying };
        }

        /// Sends a single SSE event. The event is formatted and flushed
        /// immediately to the underlying writer.
        pub fn sendEvent(self: *Self, event: Event) !void {
            if (event.id) |id| {
                try self.underlying.print("id: {s}\n", .{id});
                self.last_event_id = id;
            }
            if (event.event) |event_name| {
                try self.underlying.print("event: {s}\n", .{event_name});
            }
            if (event.retry_ms) |ms| {
                try self.underlying.print("retry: {d}\n", .{ms});
            }

            // Multi-line data: each line gets its own "data: " prefix
            var lines = std.mem.splitScalar(u8, event.data, '\n');
            while (lines.next()) |line| {
                try self.underlying.print("data: {s}\n", .{line});
            }
            // Blank line terminates the event
            try self.underlying.writeAll("\n");
        }

        /// Sends a comment line (starts with `:`). Comments are ignored by
        /// clients but can be used as keep-alive signals.
        pub fn sendComment(self: *Self, comment: []const u8) !void {
            try self.underlying.print(": {s}\n\n", .{comment});
        }

        /// Sends a named event with data.
        pub fn sendNamed(self: *Self, name: []const u8, data: []const u8) !void {
            try self.sendEvent(.{ .data = data, .event = name });
        }

        /// Sends a plain data event (no event name).
        pub fn sendData(self: *Self, data: []const u8) !void {
            try self.sendEvent(.{ .data = data });
        }

        /// Sends an event with an ID for Last-Event-ID tracking.
        pub fn sendWithId(self: *Self, data: []const u8, id: []const u8) !void {
            try self.sendEvent(.{ .data = data, .id = id });
        }
    };
}

pub const ParseResult = struct {
    events: []Event,
    /// The last event ID seen, for reconnection.
    last_event_id: ?[]const u8 = null,
};

/// Parses an SSE stream from a byte buffer, returning all complete events.
/// Caller owns the returned slice and each event's data slice.
pub fn parseSseStream(
    allocator: Allocator,
    data: []const u8,
    on_event: *const fn (Event) void,
) usize {
    dbg.entry("SSE", "parseSseStream");
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    var current_event = Event{};
    var data_lines = std.ArrayList(u8).empty;
    defer data_lines.deinit(allocator);

    while (lines.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, &.{ '\r', '\n' });

        if (trimmed.len == 0) {
            if (data_lines.items.len > 0) {
                const owned = allocator.dupe(u8, data_lines.items) catch continue;
                defer allocator.free(owned);
                current_event.data = owned;
                on_event(current_event);
                count += 1;
            }
            current_event = Event{};
            data_lines.clearRetainingCapacity();
        } else if (trimmed[0] == ':') {
            // Comment line — ignore per spec
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
                    current_event.retry_ms = @intCast(@min(ms, std.math.maxInt(u32)));
                } else |_| {}
            }
        }
    }

    // Handle any remaining data (partial event without trailing blank line)
    if (data_lines.items.len > 0) {
        const owned = allocator.dupe(u8, data_lines.items) catch return count;
        defer allocator.free(owned);
        current_event.data = owned;
        on_event(current_event);
        count += 1;
    }

    dbg.exit("SSE", "parseSseStream");
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

test "Event format round-trip" {
    const testing = std.testing;
    const event = Event{
        .data = "line1\nline2",
        .event = "update",
        .id = "42",
        .retry_ms = 3000,
    };
    const formatted = try event.format(testing.allocator);
    defer testing.allocator.free(formatted);

    try testing.expect(std.mem.indexOf(u8, formatted, "id: 42") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "event: update") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "retry: 3000") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "data: line1") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "data: line2") != null);
}

test "parse SSE with comment" {
    const testing = std.testing;
    const data = ": this is a comment\ndata: after comment\n\n";
    const Context = struct {
        var received_data: ?[]const u8 = null;
    };
    Context.received_data = null;
    const on_event = struct {
        fn f(event: Event) void {
            Context.received_data = event.data;
        }
    }.f;
    _ = parseSseStream(testing.allocator, data, &on_event);
    try testing.expect(Context.received_data != null);
    try testing.expectEqualStrings("after comment", Context.received_data.?);
}

test "parse multi-event stream" {
    const testing = std.testing;
    const data = "data: first\n\ndata: second\n\n";
    const Context = struct {
        var count: usize = 0;
    };
    Context.count = 0;
    const on_event = struct {
        fn f(event: Event) void {
            _ = event;
            Context.count += 1;
        }
    }.f;
    const n = parseSseStream(testing.allocator, data, &on_event);
    try testing.expectEqual(@as(usize, 2), n);
}
