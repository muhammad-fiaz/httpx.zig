//! Server-Sent Events (SSE) Helper Utilities for httpx.zig
//!
//! Implements SSE formatting per W3C Server-Sent Events spec:
//! - Event formatting (`id:`, `event:`, `data:`, `retry:`)
//! - Multi-line data stream serialisation
//! - Streaming SSE writer for server-side event emission
//! - Parser with comment handling and field parsing

const std = @import("std");
const Allocator = std.mem.Allocator;
const list_writer = @import("../io/list_writer.zig");

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
pub fn SSEWriter(comptime WriterType: type) type {
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
pub fn parseSSEStream(
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

    return count;
}

/// Incremental SSE parser for streaming data.
/// Maintains state between calls, allowing you to feed data as it arrives.
/// Call `feed()` with new chunks as they come in; the parser will invoke
/// `on_event` for each complete event it discovers.
pub const StreamingSSEParser = struct {
    buffer: std.ArrayList(u8),
    current_event: Event,
    data_lines: std.ArrayList(u8),
    allocator: Allocator,
    max_buffer_size: usize,

    /// Default maximum buffer size (1 MB) to prevent OOM from malicious streams.
    pub const DEFAULT_MAX_BUFFER_SIZE: usize = 1 * 1024 * 1024;

    pub fn init(allocator: Allocator) StreamingSSEParser {
        return .{
            .buffer = std.ArrayList(u8).empty,
            .current_event = Event{},
            .data_lines = std.ArrayList(u8).empty,
            .allocator = allocator,
            .max_buffer_size = DEFAULT_MAX_BUFFER_SIZE,
        };
    }

    pub fn initWithLimit(allocator: Allocator, max_buffer_size: usize) StreamingSSEParser {
        return .{
            .buffer = std.ArrayList(u8).empty,
            .current_event = Event{},
            .data_lines = std.ArrayList(u8).empty,
            .allocator = allocator,
            .max_buffer_size = max_buffer_size,
        };
    }

    pub fn deinit(self: *StreamingSSEParser) void {
        self.buffer.deinit(self.allocator);
        self.data_lines.deinit(self.allocator);
    }

    /// Feeds new data into the parser. Calls `on_event` for each complete event.
    /// Returns the number of complete events found.
    /// Automatically strips UTF-8 BOM if present at the start of the stream.
    /// Returns error.BufferTooLarge if the internal buffer exceeds max_buffer_size.
    pub fn feed(self: *StreamingSSEParser, data: []const u8, on_event: *const fn (Event) void) !usize {
        // Strip UTF-8 BOM (0xEF 0xBB 0xBF) if present at the start of the stream.
        var trimmed_data = data;
        if (self.buffer.items.len == 0 and data.len >= 3) {
            if (data[0] == 0xEF and data[1] == 0xBB and data[2] == 0xBF) {
                trimmed_data = data[3..];
            }
        }
        try self.buffer.appendSlice(self.allocator, trimmed_data);

        // Enforce buffer size limit to prevent OOM from malicious streams
        if (self.buffer.items.len > self.max_buffer_size) {
            return error.BufferTooLarge;
        }

        var count: usize = 0;

        // Process complete lines from the buffer
        while (std.mem.indexOfScalar(u8, self.buffer.items, '\n')) |newline_pos| {
            const line = self.buffer.items[0..newline_pos];
            // Remove the processed line from the buffer
            const remaining = self.buffer.items[newline_pos + 1 ..];
            std.mem.copyForwards(u8, self.buffer.items, remaining);
            self.buffer.shrinkRetainingCapacity(remaining.len);

            const trimmed = std.mem.trimRight(u8, line, &.{ '\r', '\n' });

            if (trimmed.len == 0) {
                // Empty line = dispatch event
                if (self.data_lines.items.len > 0) {
                    const owned = try self.allocator.dupe(u8, self.data_lines.items);
                    defer self.allocator.free(owned);
                    self.current_event.data = owned;
                    on_event(self.current_event);
                    count += 1;
                }
                self.current_event = Event{};
                self.data_lines.clearRetainingCapacity();
            } else if (trimmed[0] == ':') {
                // Comment line — ignore per spec
            } else if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon_pos| {
                const field_name = trimmed[0..colon_pos];
                const field_value = if (colon_pos + 1 < trimmed.len)
                    std.mem.trimLeft(u8, trimmed[colon_pos + 1 .. trimmed.len], &.{' '})
                else
                    "";

                if (std.mem.eql(u8, field_name, "event")) {
                    self.current_event.event = field_value;
                } else if (std.mem.eql(u8, field_name, "data")) {
                    if (self.data_lines.items.len > 0) {
                        try self.data_lines.appendSlice(self.allocator, "\n");
                    }
                    try self.data_lines.appendSlice(self.allocator, field_value);
                } else if (std.mem.eql(u8, field_name, "id")) {
                    self.current_event.id = field_value;
                } else if (std.mem.eql(u8, field_name, "retry")) {
                    if (std.fmt.parseInt(u64, field_value, 10)) |ms| {
                        self.current_event.retry_ms = @intCast(@min(ms, std.math.maxInt(u32)));
                    } else |_| {}
                }
            }
        }

        return count;
    }

    /// Flushes any remaining buffered data as a final event.
    pub fn flush(self: *StreamingSSEParser, on_event: *const fn (Event) void) void {
        if (self.data_lines.items.len > 0) {
            const owned = self.allocator.dupe(u8, self.data_lines.items) catch return;
            defer self.allocator.free(owned);
            self.current_event.data = owned;
            on_event(self.current_event);
        }
        self.current_event = Event{};
        self.data_lines.clearRetainingCapacity();
    }
};

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
    const count = parseSSEStream(testing.allocator, data, &on_event);
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
    _ = parseSSEStream(testing.allocator, data, &on_event);
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
    const n = parseSSEStream(testing.allocator, data, &on_event);
    try testing.expectEqual(@as(usize, 2), n);
}

test "StreamingSSEParser incremental feed" {
    const testing = std.testing;
    var parser = StreamingSSEParser.init(testing.allocator);
    defer parser.deinit();

    const Context = struct {
        var count: usize = 0;
        var last_data: []const u8 = "";
    };
    Context.count = 0;
    const on_event = struct {
        fn f(event: Event) void {
            Context.count += 1;
            Context.last_data = event.data;
        }
    }.f;

    // Feed partial data
    const n1 = try parser.feed("data: Hello", &on_event);
    try testing.expectEqual(@as(usize, 0), n1);

    // Feed the rest to complete the event
    const n2 = try parser.feed(" World\n\n", &on_event);
    try testing.expectEqual(@as(usize, 1), n2);
    try testing.expectEqualStrings("Hello World", Context.last_data);
}

test "StreamingSSEParser multiple events across chunks" {
    const testing = std.testing;
    var parser = StreamingSSEParser.init(testing.allocator);
    defer parser.deinit();

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

    // Feed data that spans multiple events across chunks
    _ = try parser.feed("data: first\n\ndata: sec", &on_event);
    try testing.expectEqual(@as(usize, 1), Context.count);

    _ = try parser.feed("ond\n\n", &on_event);
    try testing.expectEqual(@as(usize, 2), Context.count);
}

test "StreamingSSEParser with event type and id" {
    const testing = std.testing;
    var parser = StreamingSSEParser.init(testing.allocator);
    defer parser.deinit();

    const Context = struct {
        var received_event: Event = .{};
    };
    const on_event = struct {
        fn f(event: Event) void {
            Context.received_event = event;
        }
    }.f;

    _ = try parser.feed("event: message\nid: 42\ndata: payload\n\n", &on_event);
    try testing.expectEqualStrings("message", Context.received_event.event.?);
    try testing.expectEqualStrings("42", Context.received_event.id.?);
    try testing.expectEqualStrings("payload", Context.received_event.data);
}
