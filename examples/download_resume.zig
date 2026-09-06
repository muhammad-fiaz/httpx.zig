const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try httpx.Client.init(allocator, .{});
    defer client.deinit();

    const sample_url = "https://ontheline.trincoll.edu/images/bookdown/sample-local-pdf.pdf";
    std.debug.print("==> Downloading {s} with Range resume policy (.resume_download / .continue_partial)...\n", .{sample_url});

    // Uses .resume_download (clean non-reserved keyword name)
    const result = client.download(
        sample_url,
        "downloads/resumable-sample.pdf",
        .{
            .existing = .resume_download,
            .progress = .auto,
            .max_retries = 3,
            .create_dirs = true,
        },
    ) catch |err| {
        std.debug.print("Resume download handled: {s}\n", .{@errorName(err)});
        return;
    };

    std.debug.print("Download status: resumed={any}, downloaded={d} bytes to {s}\n", .{
        result.resumed,
        result.downloaded_bytes,
        result.destination,
    });
}
