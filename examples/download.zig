const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try httpx.Client.init(allocator, .{});
    defer client.deinit();

    // Use httpbun.com /bytes/90 (or /payload) endpoint (default limit on httpbun.com is 90 bytes, or payload endpoint)
    const sample_url = "https://httpbun.com/bytes/90";
    std.debug.print("==> Downloading {s} with zero-config progress bar...\n", .{sample_url});


    // 1. Download to a specific directory (automatically uses URL basename "1048576")
    const result1 = client.download(
        sample_url,
        "downloads/",
        .{
            .progress = .enabled,
            .existing = .overwrite,
            .create_dirs = true,
        },
    ) catch |err| {
        std.debug.print("Download to directory handled: {s}\n", .{@errorName(err)});
        return;
    };

    std.debug.print("Downloaded with auto filename: {s} ({d} bytes in {d} ms)\n", .{
        result1.destinationPath(),
        result1.downloaded_bytes,
        result1.elapsed_ms,
    });

    // 2. Download with explicit custom destination filename
    const result2 = client.download(
        sample_url,
        "downloads/custom_named_doc.bin",
        .{
            .progress = .enabled,
            .existing = .overwrite,
            .create_dirs = true,
        },
    ) catch |err| {
        std.debug.print("Download with explicit name handled: {s}\n", .{@errorName(err)});
        return;
    };

    std.debug.print("Downloaded with explicit filename: {s} ({d} bytes)\n", .{
        result2.destinationPath(),
        result2.downloaded_bytes,
    });
}

