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
const z = @import("zigantic");

const ConfigSchema = z.objectOf(.{}, .{});
pub const Config = ConfigSchema.Value;

const EventConfigSchema = z.objectOf(.{
    .event = z.optional(z.string(.{})),
    .id = z.optional(z.nonNegativeInt(u64, .{})),
    .retryMs = z.optional(z.nonNegativeInt(u32, .{})),
}, .{});
pub const EventConfig = EventConfigSchema.Value;

pub const Error = error{
    OutOfMemory,
    InvalidField,
};

/// Serializes SSE events into an output list.
pub const EventWriter = struct {
    allocator: Allocator,
    io: std.Io,
    out: std.ArrayList(u8) = .empty,

    pub fn init(allocator: Allocator, io: std.Io, comptime cfg: Config) EventWriter {
        comptime {
            _ = cfg;
        }
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *EventWriter) void {
        self.out.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn buffered(self: *const EventWriter) []const u8 {
        return self.out.items;
    }

    /// Serializes one event block.
    pub fn writeEvent(
        self: *EventWriter,
        dataLines: []const []const u8,
        cfg: EventConfig,
    ) Error!void {
        var scratch: [1024]u8 = undefined;
        if (z.checkFirst(EventConfigSchema, cfg, &scratch, .{}) catch return error.InvalidField) |issue| {
            _ = issue;
            return error.InvalidField;
        }
        if (cfg.retryMs) |r| {
            var buf: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "retry:{d}\n", .{r}) catch return;
            try self.out.appendSlice(self.allocator, s);
        }
        if (cfg.id) |id| {
            var buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "id:{d}\n", .{id}) catch return;
            try self.out.appendSlice(self.allocator, s);
        }
        if (cfg.event) |t| {
            // Event type must not contain newline (would forge fields)
            if (std.mem.indexOfAny(u8, t, "\r\n") != null) return error.InvalidField;
            try self.out.appendSlice(self.allocator, "event:");
            try self.out.appendSlice(self.allocator, t);
            try self.out.appendSlice(self.allocator, "\n");
        }
        for (dataLines) |line| {
            try self.out.appendSlice(self.allocator, "data:");
            try self.out.appendSlice(self.allocator, line);
            try self.out.appendSlice(self.allocator, "\n");
        }
        try self.out.appendSlice(self.allocator, "\n");
    }

    /// Comment keep-alive frame (":" prefix). Clients ignore payload.
    pub fn writeComment(self: *EventWriter, comment: []const u8) !void {
        try self.out.appendSlice(self.allocator, ":");
        try self.out.appendSlice(self.allocator, comment);
        try self.out.appendSlice(self.allocator, "\n\n");
    }
};

test "writer produces canonical output" {
    const a = std.testing.allocator;
    var w = EventWriter.init(a, std.Io.Threaded.global_single_threaded.io(), .{});
    defer w.deinit();

    try w.writeEvent(&.{ "hello", "world" }, .{ .event = "greeting", .id = 42, .retryMs = 3000 });

    const expected = "retry:3000\nid:42\nevent:greeting\ndata:hello\ndata:world\n\n";
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "writer rejects newline in event type" {
    const a = std.testing.allocator;
    var w = EventWriter.init(a, std.Io.Threaded.global_single_threaded.io(), .{});
    defer w.deinit();

    try std.testing.expectError(Error.InvalidField, w.writeEvent(&.{"x"}, .{ .event = "bad\ntype" }));
}

test "comment keepalive format" {
    const a = std.testing.allocator;
    var w = EventWriter.init(a, std.Io.Threaded.global_single_threaded.io(), .{});
    defer w.deinit();

    try w.writeComment("keep-alive");
    try std.testing.expectEqualStrings(":keep-alive\n\n", w.buffered());
}
