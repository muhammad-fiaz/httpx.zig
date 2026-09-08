const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    const sampleUrl = "https://ontheline.trincoll.edu/images/bookdown/sample-local-pdf.pdf";
    std.debug.print("==> Downloading {s} with Range resume policy (.resumePartial)...\n", .{sampleUrl});

    // Uses .resumePartial (short canonical resume policy)
    const result = client.download(
        sampleUrl,
        "downloads/resumable-sample.pdf",
        .{
            .existing = .resumePartial,
            .progress = .auto,
            .maxRetries = 3,
            .createDirs = true,
        },
    ) catch |err| {
        std.debug.print("Resume download handled: {s}\n", .{@errorName(err)});
        return;
    };

    std.debug.print("Download status: resumed={any}, downloaded={d} bytes to {s}\n", .{
        result.resumed,
        result.downloadedBytes,
        result.destination,
    });
}
