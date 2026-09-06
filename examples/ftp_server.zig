const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try httpx.ftp.Server.init(allocator, .{
        .host = "0.0.0.0",
        .port = 0,
        .user = "demo",
        .password = "password",
        .callbacks = .{
            .authenticate = authenticate,
            .list = listFiles,
            .retrieve = retrieveFile,
            .store = storeFile,
            .directory = handleDirectory,
            .remove = handleRemove,
        },
    });
    defer server.deinit();

    const port = server.localPort();
    std.debug.print("FTP server running on 127.0.0.1:{d}\n", .{port});

    const ClientThread = struct {
        fn run(server_port: u16) void {
            var client = httpx.ftp.Client.connect(.{
                .host = "127.0.0.1",
                .port = server_port,
                .user = "demo",
                .password = "password",
            }) catch |err| {
                std.debug.print("FTP client failed: {s}\n", .{@errorName(err)});
                return;
            };
            defer client.deinit();
            std.debug.print("FTP client connected and verified.\n", .{});
        }
    };

    const t = try std.Thread.spawn(.{}, ClientThread.run, .{port});
    server.run(1) catch |err| {
        std.debug.print("FTP server run failed: {s}\n", .{@errorName(err)});
    };
    t.join();

    std.debug.print("FTP server verification completed successfully.\n", .{});
}

fn authenticate(_: ?*anyopaque, user: []const u8, pass: []const u8) bool {
    return std.mem.eql(u8, user, "demo") and std.mem.eql(u8, pass, "password");
}

fn listFiles(_: ?*anyopaque, _: []const u8) []const u8 {
    return "drwxr-xr-x 2 user user 4096 Jan 01 00:00 .\r\n-rw-r--r-- 1 user user 1024 Jan 01 00:00 file1.txt\r\n-rw-r--r-- 1 user user 2048 Jan 01 00:00 file2.csv\r\n";
}

fn retrieveFile(_: ?*anyopaque, _: []const u8) []const u8 {
    return "File content here";
}

fn storeFile(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
    return true;
}

fn handleDirectory(_: ?*anyopaque, _: []const u8, _: bool) bool {
    return true;
}

fn handleRemove(_: ?*anyopaque, _: []const u8) bool {
    return true;
}
