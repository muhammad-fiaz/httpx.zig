const std = @import("std");

pub const ListWriter = struct {
    allocator: std.mem.Allocator,
    list: *std.ArrayList(u8),

    pub fn write(self: ListWriter, bytes: []const u8) !usize {
        try self.writeAll(bytes);
        return bytes.len;
    }

    pub fn writeAll(self: ListWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }

    pub fn writeByte(self: ListWriter, byte: u8) !void {
        try self.list.append(self.allocator, byte);
    }

    pub fn print(self: ListWriter, comptime fmt: []const u8, args: anytype) !void {
        try self.list.print(self.allocator, fmt, args);
    }
};

pub fn init(allocator: std.mem.Allocator, list: *std.ArrayList(u8)) ListWriter {
    return .{
        .allocator = allocator,
        .list = list,
    };
}
