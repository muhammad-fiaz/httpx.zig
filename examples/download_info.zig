const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try httpx.Client.init(allocator, .{});
    defer client.deinit();

    const sample_url = "https://ontheline.trincoll.edu/images/bookdown/sample-local-pdf.pdf";
    std.debug.print("==> Inspecting remote file info without downloading: {s}\n", .{sample_url});

    const info = client.lookupFileInfo(sample_url, .{}) catch |err| {
        std.debug.print("Lookup handled: {s}\n", .{@errorName(err)});
        return;
    };

    var size_buf: [32]u8 = undefined;
    std.debug.print("Remote File Metadata:\n", .{});
    std.debug.print("  - Status:           {d}\n", .{info.status});
    std.debug.print("  - File Name:        {s}\n", .{info.fileName()});
    std.debug.print("  - File Size:        {?d} bytes ({s})\n", .{ info.file_size, info.formatSize(&size_buf) });
    std.debug.print("  - Content Type:     {?s}\n", .{info.contentType()});
    std.debug.print("  - Accepts Ranges:   {any}\n", .{info.accepts_ranges});
    std.debug.print("  - ETag:             {?s}\n", .{info.etag()});
    std.debug.print("  - Last-Modified:    {?s}\n", .{info.lastModified()});
}
