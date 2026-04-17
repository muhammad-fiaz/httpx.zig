const std = @import("std");

pub const AnyReader = struct {
    context: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, buffer: []u8) anyerror!usize,

    pub fn read(self: AnyReader, buffer: []u8) anyerror!usize {
        return self.readFn(self.context, buffer);
    }

    pub fn readByte(self: AnyReader) anyerror!u8 {
        var one: [1]u8 = undefined;
        const n = try self.read(one[0..]);
        if (n == 0) return error.EndOfStream;
        return one[0];
    }

    pub fn readNoEof(self: AnyReader, out: []u8) anyerror!void {
        var read_count: usize = 0;
        while (read_count < out.len) {
            const n = try self.read(out[read_count..]);
            if (n == 0) return error.EndOfStream;
            read_count += n;
        }
    }
};

pub const AnyWriter = struct {
    context: *anyopaque,
    writeFn: *const fn (ctx: *anyopaque, data: []const u8) anyerror!usize,

    pub fn write(self: AnyWriter, data: []const u8) anyerror!usize {
        return self.writeFn(self.context, data);
    }

    pub fn writeAll(self: AnyWriter, data: []const u8) anyerror!void {
        var sent: usize = 0;
        while (sent < data.len) {
            const n = try self.write(data[sent..]);
            if (n == 0) return error.WriteFailed;
            sent += n;
        }
    }

    pub fn print(self: AnyWriter, comptime fmt: []const u8, args: anytype) anyerror!void {
        var buf: [4096]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, fmt, args);
        try self.writeAll(text);
    }
};
