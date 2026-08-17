const std = @import("std");
const tint = @import("tint");

pub var enabled = std.atomic.Value(bool).init(false);

pub fn enable() void {
    enabled.store(true, .monotonic);
}

pub fn disable() void {
    enabled.store(false, .monotonic);
}

pub inline fn isEnabled() bool {
    return enabled.load(.monotonic);
}

// tint.zig style definitions for httpx debug output
const tag_style = tint.style(.{ .fg = .{ .ansi4 = .cyan }, .bold = true });
const entry_style = tint.style(.{ .fg = .{ .ansi4 = .green } });
const exit_style = tint.style(.{ .fg = .{ .ansi4 = .bright_cyan } });
const error_style = tint.style(.{ .fg = .{ .ansi4 = .bright_red }, .bold = true });
const warn_style = tint.style(.{ .fg = .{ .ansi4 = .bright_yellow } });
const info_style = tint.style(.{ .fg = .{ .ansi4 = .bright_blue } });
const dim_style = tint.style(.{ .fg = .{ .ansi4 = .bright_black }, .dim = true });
const data_style = tint.style(.{ .fg = .{ .ansi4 = .white } });

pub fn log(comptime tag: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!isEnabled()) return;
    std.debug.print(
        "{s}[{s}]{s} " ++ fmt ++ "\n",
        .{ tag_style.toAnsi(), tag, tint.reset } ++ args,
    );
}

pub fn logErr(comptime tag: []const u8, comptime ctx: []const u8, err: anyerror) void {
    if (!isEnabled()) return;
    std.debug.print(
        "{s}[{s}]{s} {s}ERROR{s} in {s}{s}{s}: {s}{s}{s}\n",
        .{ tag_style.toAnsi(), tag, tint.reset, error_style.toAnsi(), tint.reset, data_style.toAnsi(), ctx, tint.reset, error_style.toAnsi(), @errorName(err), tint.reset },
    );
}

pub fn entry(comptime tag: []const u8, comptime func: []const u8) void {
    if (!isEnabled()) return;
    std.debug.print(
        "{s}{s}>>{s} {s}{s}{s} {s}{s}{s}\n",
        .{ entry_style.toAnsi(), tag_style.toAnsi(), tint.reset, entry_style.toAnsi(), func, tint.reset, entry_style.toAnsi(), tag, tint.reset },
    );
}

pub fn exit(comptime tag: []const u8, comptime func: []const u8) void {
    if (!isEnabled()) return;
    std.debug.print(
        "{s}{s}<<{s} {s}{s}{s} {s}{s}{s}\n",
        .{ exit_style.toAnsi(), tag_style.toAnsi(), tint.reset, exit_style.toAnsi(), func, tint.reset, exit_style.toAnsi(), tag, tint.reset },
    );
}

pub fn exitErr(comptime tag: []const u8, comptime func: []const u8, err: anyerror) void {
    if (!isEnabled()) return;
    std.debug.print(
        "{s}[{s}]{s} {s}<<{s} {s}{s}{s} {s}FAILED{s} {s}{s}{s}\n",
        .{ tag_style.toAnsi(), tag, tint.reset, error_style.toAnsi(), tint.reset, error_style.toAnsi(), func, tint.reset, error_style.toAnsi(), tint.reset, error_style.toAnsi(), @errorName(err), tint.reset },
    );
}

pub fn hexDump(comptime tag: []const u8, comptime label: []const u8, data: []const u8, max_bytes: usize) void {
    if (!isEnabled()) return;
    const len = @min(data.len, max_bytes);
    std.debug.print("{s}[{s}]{s} {s}{s}{s} ({d} bytes):\n", .{ dim_style.toAnsi(), tag, tint.reset, data_style.toAnsi(), label, tint.reset, data.len });
    var i: usize = 0;
    while (i < len) : (i += 16) {
        std.debug.print("  ", .{});
        var j: usize = 0;
        while (j < 16 and i + j < len) : (j += 1) {
            std.debug.print("{s}{x:0>2}{s} ", .{ dim_style.toAnsi(), data[i + j], tint.reset });
        }
        while (j < 16) : (j += 1) {
            std.debug.print("   ", .{});
        }
        std.debug.print(" |", .{});
        j = 0;
        while (j < 16 and i + j < len) : (j += 1) {
            const c = data[i + j];
            if (c >= 0x20 and c < 0x7f) {
                std.debug.print("{s}{c}{s}", .{ data_style.toAnsi(), c, tint.reset });
            } else {
                std.debug.print(".", .{});
            }
        }
        std.debug.print("|\n", .{});
    }
}

pub fn logSocketState(comptime tag: []const u8, comptime label: []const u8, fd: anytype) void {
    if (!isEnabled()) return;
    std.debug.print(
        "{s}[{s}]{s} {s}{s}{s} socket fd={s}{any}{s}\n",
        .{ tag_style.toAnsi(), tag, tint.reset, dim_style.toAnsi(), label, tint.reset, dim_style.toAnsi(), fd, tint.reset },
    );
}

pub fn logTimeout(comptime tag: []const u8, comptime label: []const u8, ms: u64) void {
    if (!isEnabled()) return;
    std.debug.print(
        "{s}[{s}]{s} {s}{s}{s} timeout={s}{d}ms{s}\n",
        .{ tag_style.toAnsi(), tag, tint.reset, warn_style.toAnsi(), label, tint.reset, warn_style.toAnsi(), ms, tint.reset },
    );
}

pub fn logUrl(comptime tag: []const u8, comptime label: []const u8, url: []const u8) void {
    if (!isEnabled()) return;
    std.debug.print(
        "{s}[{s}]{s} {s}{s}{s} {s}{s}{s}\n",
        .{ tag_style.toAnsi(), tag, tint.reset, info_style.toAnsi(), label, tint.reset, info_style.toAnsi(), url, tint.reset },
    );
}

pub fn logConnState(comptime tag: []const u8, comptime label: []const u8, host: []const u8, port: u16, state: []const u8) void {
    if (!isEnabled()) return;
    std.debug.print(
        "{s}[{s}]{s} {s}{s}{s} {s}{s}:{d}{s} -> {s}{s}{s}\n",
        .{ tag_style.toAnsi(), tag, tint.reset, data_style.toAnsi(), label, tint.reset, data_style.toAnsi(), host, port, tint.reset, data_style.toAnsi(), state, tint.reset },
    );
}

pub fn logBytes(comptime tag: []const u8, comptime label: []const u8, n: usize) void {
    if (!isEnabled()) return;
    std.debug.print(
        "{s}[{s}]{s} {s}{s}{s} {s}{d} bytes{s}\n",
        .{ tag_style.toAnsi(), tag, tint.reset, dim_style.toAnsi(), label, tint.reset, dim_style.toAnsi(), n, tint.reset },
    );
}

pub fn logState(comptime tag: []const u8, comptime label: []const u8, state: []const u8) void {
    if (!isEnabled()) return;
    std.debug.print(
        "{s}[{s}]{s} {s}{s}{s} -> {s}{s}{s}\n",
        .{ tag_style.toAnsi(), tag, tint.reset, info_style.toAnsi(), label, tint.reset, info_style.toAnsi(), state, tint.reset },
    );
}
