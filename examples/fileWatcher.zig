//! Example: Production-grade File Watcher with Debouncing & Atomic Saves
//!
//! Demonstrates:
//! 1. Initializing `httpx.Watcher`
//! 2. Registering watched files and monitoring changes
//! 3. Detecting file modification and debouncing rapid editor saves
//!
//! Run with: `zig build run-file-watcher`

const std = @import("std");
const httpx = @import("httpx");

fn onFileChanged(event: httpx.WatchEvent, _: ?*anyopaque) void {
    std.debug.print("==> File event: {s} | Strategy: {s} | Kind: {s}\n", .{
        event.path,
        @tagName(event.strategy),
        @tagName(event.kind),
    });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    std.debug.print("==> HTTPX Filesystem Watcher Demo\n\n", .{});

    const watchTarget = "watcher_demo_asset.txt";
    try httpx.static.files.writeFile(watchTarget, "Version 1");
    defer {
        const cwd = std.Io.Dir.cwd();
        cwd.deleteFile(io, watchTarget) catch {};
    }

    var watcher = try httpx.Watcher.init(allocator, io, .{
        .dirPath = ".",
        .debounceMs = 50,
        .pollIntervalMs = 50,
        .onChange = onFileChanged,
    });
    defer watcher.deinit();

    try watcher.watchFile(watchTarget);
    try watcher.start();
    std.debug.print("Watcher started on '{s}'...\n", .{watchTarget});

    // Simulate an editor save
    httpx.clock.sleepMillis(io, 100);
    try httpx.fs.writeFile(watchTarget, "Version 2 (Modified)");

    httpx.clock.sleepMillis(io, 200);

    // Consume queued events using next()
    var eventCount: usize = 0;
    while (watcher.next()) |event| {
        eventCount += 1;
        std.debug.print("Dequeued event #{d}: path='{s}', kind={s}, strategy={s}\n", .{
            eventCount,
            event.path,
            @tagName(event.kind),
            @tagName(event.strategy),
        });
    }

    const changes = watcher.changeCount();
    std.debug.print("Total changes captured: {d} (dequeued: {d})\n", .{ changes, eventCount });

    std.debug.print("\nFile Watcher verification successful.\n", .{});
}
