//! Server-Sent Events (SSE) stream parser (WHATWG HTML Section 9.2).
//!
//! Parses `text/event-stream` chunks into structured events.
//! Supports:
//!   - `event: <name>` field (default: "message")
//!   - `data: <content>` with multiline newline concatenation
//!   - `id: <value>` persistence across events
//!   - `retry: <ms>` reconnection interval updates
//!   - `:comment` lines (keep-alive heartbeats; ignored for dispatch)
//!   - CRLF, LF, and CR line terminations
//!   - Empty-line event dispatch
//!
//! References:
//!   - WHATWG HTML Spec Section 9.2 — Server-Sent Events

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ParseError = error{
    OutOfMemory,
    InvalidRetryValue,
};

/// A parsed Server-Sent Event.
pub const Event = struct {
    /// Event name from `event: ...`. Default is "message".
    eventType: []const u8 = "message",
    /// Payload from `data: ...` lines. Multiple data lines are joined by `\n`.
    data: []const u8 = "",
    /// Event ID from `id: ...`, or null if not set.
    id: ?[]const u8 = null,
    /// Reconnection time in milliseconds from `retry: ...`, or null.
    retryMs: ?u32 = null,
};

/// Stateful SSE stream parser adhering to the WHATWG event stream processing model.
pub const EventParser = struct {
    allocator: Allocator,
    dataBuf: std.ArrayList(u8),
    eventTypeBuf: std.ArrayList(u8),
    lastIdBuf: std.ArrayList(u8),
    hasId: bool = false,
    retryMs: ?u32 = null,
    lineBuf: std.ArrayList(u8),

    pub fn init(allocator: Allocator) EventParser {
        return .{
            .allocator = allocator,
            .dataBuf = std.ArrayList(u8).empty,
            .eventTypeBuf = std.ArrayList(u8).empty,
            .lastIdBuf = std.ArrayList(u8).empty,
            .lineBuf = std.ArrayList(u8).empty,
        };
    }

    pub fn deinit(self: *EventParser) void {
        self.dataBuf.deinit(self.allocator);
        self.eventTypeBuf.deinit(self.allocator);
        self.lastIdBuf.deinit(self.allocator);
        self.lineBuf.deinit(self.allocator);
    }

    /// Resets per-event data while keeping stream-level state (last_id and retryMs).
    pub fn resetEventData(self: *EventParser) void {
        self.dataBuf.clearRetainingCapacity();
        self.eventTypeBuf.clearRetainingCapacity();
    }

    /// Processes a stream line according to the WHATWG specification.
    /// If the line terminates an event (empty line with buffered data), returns the parsed Event.
    /// The returned Event's slices are valid until the next call to `processLine` or `deinit`.
    pub fn processLine(self: *EventParser, rawLine: []const u8) ParseError!?Event {
        // Strip trailing \r if present (handles CRLF when split on LF)
        const line = if (rawLine.len > 0 and rawLine[rawLine.len - 1] == '\r')
            rawLine[0 .. rawLine.len - 1]
        else
            rawLine;

        // Empty line: dispatch event if data was accumulated
        if (line.len == 0) {
            if (self.dataBuf.items.len > 0) {
                const ev_type = if (self.eventTypeBuf.items.len > 0)
                    self.eventTypeBuf.items
                else
                    "message";

                const ev_id: ?[]const u8 = if (self.hasId)
                    self.lastIdBuf.items
                else
                    null;

                const event = Event{
                    .eventType = ev_type,
                    .data = self.dataBuf.items,
                    .id = ev_id,
                    .retryMs = self.retryMs,
                };
                return event;
            }
            // Empty data: discard event type buffer per spec
            self.eventTypeBuf.clearRetainingCapacity();
            return null;
        }

        // Comment line: starts with ':' -> ignore
        if (line[0] == ':') {
            return null;
        }

        // Field parsing: field: value OR field (no colon)
        const colon_idx = std.mem.indexOfScalar(u8, line, ':');
        const field_name = if (colon_idx) |idx| line[0..idx] else line;
        var field_value = if (colon_idx) |idx| line[idx + 1 ..] else "";

        // If value starts with a single space, remove it per WHATWG spec
        if (field_value.len > 0 and field_value[0] == ' ') {
            field_value = field_value[1..];
        }

        if (std.mem.eql(u8, field_name, "event")) {
            self.eventTypeBuf.clearRetainingCapacity();
            try self.eventTypeBuf.appendSlice(self.allocator, field_value);
        } else if (std.mem.eql(u8, field_name, "data")) {
            if (self.dataBuf.items.len > 0) {
                try self.dataBuf.append(self.allocator, '\n');
            }
            try self.dataBuf.appendSlice(self.allocator, field_value);
        } else if (std.mem.eql(u8, field_name, "id")) {
            // Null characters inside ID are rejected / ignored per spec
            if (std.mem.indexOfScalar(u8, field_value, 0) == null) {
                self.lastIdBuf.clearRetainingCapacity();
                try self.lastIdBuf.appendSlice(self.allocator, field_value);
                self.hasId = true;
            }
        } else if (std.mem.eql(u8, field_name, "retry")) {
            if (std.fmt.parseInt(u32, field_value, 10)) |val| {
                self.retryMs = val;
            } else |_| {}
        }

        return null;
    }

    /// Feeds a chunk of incoming stream data and invokes `callback` for each complete event.
    pub fn feed(
        self: *EventParser,
        chunk: []const u8,
        context: anytype,
        comptime callback: fn (@TypeOf(context), event: Event) void,
    ) ParseError!void {
        var pos: usize = 0;
        while (pos < chunk.len) {
            const next_nl = std.mem.indexOfScalar(u8, chunk[pos..], '\n');
            if (next_nl) |offset| {
                const end = pos + offset;
                const part = chunk[pos..end];
                if (self.lineBuf.items.len > 0) {
                    try self.lineBuf.appendSlice(self.allocator, part);
                    const line = self.lineBuf.items;
                    if (try self.processLine(line)) |ev| {
                        callback(context, ev);
                        self.resetEventData();
                    }
                    self.lineBuf.clearRetainingCapacity();
                } else {
                    if (try self.processLine(part)) |ev| {
                        callback(context, ev);
                        self.resetEventData();
                    }
                }
                pos = end + 1;
            } else {
                try self.lineBuf.appendSlice(self.allocator, chunk[pos..]);
                break;
            }
        }
    }
};

/// Parses all events from an entire SSE stream in memory into an allocated slice.
pub fn parseAll(allocator: Allocator, stream: []const u8) ParseError![]Event {
    var parser = EventParser.init(allocator);
    defer parser.deinit();

    var events = std.ArrayList(Event).empty;
    errdefer {
        for (events.items) |ev| {
            allocator.free(ev.data);
            if (!std.mem.eql(u8, ev.eventType, "message")) allocator.free(ev.eventType);
            if (ev.id) |id| allocator.free(id);
        }
        events.deinit(allocator);
    }

    const Collector = struct {
        a: Allocator,
        list: *std.ArrayList(Event),

        fn onEvent(ctx: *@This(), ev: Event) void {
            const owned_data = ctx.a.dupe(u8, ev.data) catch return;
            const owned_type = if (!std.mem.eql(u8, ev.eventType, "message"))
                ctx.a.dupe(u8, ev.eventType) catch {
                    ctx.a.free(owned_data);
                    return;
                }
            else
                "message";
            const owned_id = if (ev.id) |id| ctx.a.dupe(u8, id) catch null else null;

            ctx.list.append(ctx.a, .{
                .eventType = owned_type,
                .data = owned_data,
                .id = owned_id,
                .retryMs = ev.retryMs,
            }) catch {
                ctx.a.free(owned_data);
                if (!std.mem.eql(u8, owned_type, "message")) ctx.a.free(owned_type);
                if (owned_id) |id| ctx.a.free(id);
            };
        }
    };

    var collector = Collector{ .a = allocator, .list = &events };
    try parser.feed(stream, &collector, Collector.onEvent);

    return events.toOwnedSlice(allocator);
}

/// Frees an array of events produced by `parseAll`.
pub fn freeEvents(allocator: Allocator, events: []Event) void {
    for (events) |ev| {
        allocator.free(ev.data);
        if (!std.mem.eql(u8, ev.eventType, "message")) allocator.free(ev.eventType);
        if (ev.id) |id| allocator.free(id);
    }
    allocator.free(events);
}

// Tests

test "parse single simple sse event" {
    const a = std.testing.allocator;
    const input = "data: hello world\n\n";
    const events = try parseAll(a, input);
    defer freeEvents(a, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("message", events[0].eventType);
    try std.testing.expectEqualStrings("hello world", events[0].data);
    try std.testing.expect(events[0].id == null);
    try std.testing.expect(events[0].retryMs == null);
}

test "parse multiline data sse event" {
    const a = std.testing.allocator;
    const input =
        "data: first line\n" ++
        "data: second line\n" ++
        "data: third line\n\n";
    const events = try parseAll(a, input);
    defer freeEvents(a, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("first line\nsecond line\nthird line", events[0].data);
}

test "parse custom event type and id and retry" {
    const a = std.testing.allocator;
    const input =
        "event: user_join\n" ++
        "id: 42\n" ++
        "retry: 3000\n" ++
        "data: Alice joined\n\n";
    const events = try parseAll(a, input);
    defer freeEvents(a, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("user_join", events[0].eventType);
    try std.testing.expectEqualStrings("Alice joined", events[0].data);
    try std.testing.expectEqualStrings("42", events[0].id.?);
    try std.testing.expectEqual(@as(?u32, 3000), events[0].retryMs);
}

test "parse ignores comments and handles crlf" {
    const a = std.testing.allocator;
    const input =
        ":keep-alive heartbeat\r\n" ++
        "data: test message\r\n\r\n";
    const events = try parseAll(a, input);
    defer freeEvents(a, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("test message", events[0].data);
}

test "parse consecutive events with id persistence" {
    const a = std.testing.allocator;
    const input =
        "id: 101\n" ++
        "data: msg1\n\n" ++
        "data: msg2\n\n";
    const events = try parseAll(a, input);
    defer freeEvents(a, events);

    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("msg1", events[0].data);
    try std.testing.expectEqualStrings("101", events[0].id.?);
    try std.testing.expectEqualStrings("msg2", events[1].data);
    try std.testing.expectEqualStrings("101", events[1].id.?);
}
