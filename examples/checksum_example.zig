const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const data = "Hello, httpx.zig checksum verification!";

    var sha256_stream = httpx.ChecksumStream.init(.sha256);
    sha256_stream.update(data);
    const sha256_result = sha256_stream.final();

    var hex_buf: [128]u8 = undefined;
    const hex_str = sha256_result.hex(&hex_buf);
    std.debug.print("SHA-256: {s}\n", .{hex_str});
    std.debug.print("Bytes: {d}\n", .{sha256_result.len});

    var md5_stream = httpx.ChecksumStream.init(.md5);
    md5_stream.update(data);
    const md5_result = md5_stream.final();

    var md5_hex: [128]u8 = undefined;
    std.debug.print("MD5: {s}\n", .{md5_result.hex(&md5_hex)});

    const computed = httpx.computeChecksum(.sha256, data);
    std.debug.print("Match: {}\n", .{computed.eql(sha256_result)});
}
