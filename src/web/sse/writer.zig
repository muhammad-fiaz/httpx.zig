//! Server-side SSE event serialization (text/event-stream).
//!
//! Wire format per WHATWG HTML spec section 9.2:
//!   field:value\n  repeated fields, terminated by a blank line.
//!   Fields: event, data (repeatable), id, retry. Lines starting with ':'
//!   are comments used as keep-alives.
//!
//! References:
//!   - WHATWG HTML Spec Section 9.2 — Server-Sent Events

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    OutOfMemory,
    InvalidField,
};

/// Serializes SSE events into an output list.
pub const EventWriter = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) EventWriter {
        return .{ .allocator = allocator };
    }

    /// Serializes one event block.
    pub fn writeEvent(
        self: *EventWriter,
        out: *std.ArrayList(u8),
        data_lines: []const []const u8,
        event_type: ?[]const u8,
        last_event_id: ?u64,
        retry_ms: ?u32,
    ) Error!void {
        if (retry_ms) |r| {
            var buf: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "retry:{d}\n", .{r}) catch return;
            try out.appendSlice(self.allocator, s);
        }
        if (last_event_id) |id| {
            var buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "id:{d}\n", .{id}) catch return;
            try out.appendSlice(self.allocator, s);
        }
        if (event_type) |t| {
            // Event type must not contain newline (would forge fields)
            if (std.mem.indexOfAny(u8, t, "\r\n") != null) return error.InvalidField;
            try out.appendSlice(self.allocator, "event:");
            try out.appendSlice(self.allocator, t);
            try out.appendSlice(self.allocator, "\n");
        }
        for (data_lines) |line| {
            try out.appendSlice(self.allocator, "data:");
            try out.appendSlice(self.allocator, line);
            try out.appendSlice(self.allocator, "\n");
        }
        try out.appendSlice(self.allocator, "\n");
    }

    /// Comment keep-alive frame (":" prefix). Clients ignore payload.
    pub fn writeComment(self: *EventWriter, out: *std.ArrayList(u8), comment: []const u8) !void {
        try out.appendSlice(self.allocator, ":");
        try out.appendSlice(self.allocator, comment);
        try out.appendSlice(self.allocator, "\n\n");
    }
};

test "writer produces canonical output" {
    const a = std.testing.allocator;
    var w = EventWriter.init(a);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);

    try w.writeEvent(&out, &.{ "hello", "world" }, "greeting", 42, 3000);

    const expected = "retry:3000\nid:42\nevent:greeting\ndata:hello\ndata:world\n\n";
    try std.testing.expectEqualStrings(expected, out.items);
}

test "writer rejects newline in event type" {
    const a = std.testing.allocator;
    var w = EventWriter.init(a);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);

    try std.testing.expectError(Error.InvalidField, w.writeEvent(&out, &.{"x"}, "bad\ntype", null, null));
}

test "comment keepalive format" {
    const a = std.testing.allocator;
    var w = EventWriter.init(a);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);

    try w.writeComment(&out, "keep-alive");
    try std.testing.expectEqualStrings(":keep-alive\n\n", out.items);
}
