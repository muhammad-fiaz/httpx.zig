const std = @import("std");
const httpx = @import("httpx");

pub fn main() void {
    std.debug.print("httpx {s}\n", .{httpx.version});
}
