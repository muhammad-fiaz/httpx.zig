const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== HTTPX Native FTP Client ===\n", .{});

    // 1. Configure FTP options
    const ftp_opts: httpx.ftp.Options = .{
        .host = "test.rebex.net",
        .port = 21,
        .user = "demo",
        .password = "password",
        .secure = false, // Set to true for explicit FTPS
    };

    std.debug.print("1. FTP client configuration: {s}:{d}\n", .{ ftp_opts.host, ftp_opts.port });

    // 2. Demonstrate reply parsing
    const sample_reply = "220-Welcome to Rebex FTP Server\r\n220 Service ready for new user.\r\n";
    if (httpx.ftp.parseReplyAt(sample_reply, 0)) |parsed| {
        std.debug.print("2. Parsed server banner: code={d}, message='{s}'\n", .{
            parsed.reply.code,
            parsed.reply.text,
        });
    }

    // 3. Connect via TCP (requires network access)
    var client = httpx.ftp.Client.connect(allocator, ftp_opts) catch |err| {
        std.debug.print("3. FTP connection failed: {s}\n", .{@errorName(err)});
        std.debug.print("   Skipping network tests (server may be unreachable).\n", .{});
        return;
    };
    defer client.deinit();

    std.debug.print("3. Connected to FTP server successfully!\n", .{});

    // 4. Login
    client.login("demo", "password") catch |err| {
        std.debug.print("4. Login failed: {s}\n", .{@errorName(err)});
        return;
    };
    std.debug.print("4. Login successful\n", .{});

    // 5. List files
    const files = client.list("/") catch |err| {
        std.debug.print("5. List files failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(files);
    std.debug.print("5. File listing:\n{s}\n", .{files});

    std.debug.print("FTP client demonstration completed.\n", .{});
}
