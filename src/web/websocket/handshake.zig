// WebSocket handshake (RFC 6455 section 4): HTTP/1.1 Upgrade exchange,
// Sec-WebSocket-Accept computation, client request building, server validation.

const std = @import("std");
const Allocator = std.mem.Allocator;
pub const frame = @import("frame.zig");

/// Magic GUID from RFC 6455 section 1.3 used in Sec-WebSocket-Accept.
pub const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// Handshake

/// Computes Sec-WebSocket-Accept from the client's Sec-WebSocket-Key.
pub fn computeAccept(key: []const u8, out: *[28]u8) void {
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update(GUID);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    _ = std.base64.standard.Encoder.encode(out, &digest);
}

/// Builds a client handshake request head (without leading CRLF).
pub fn buildUpgradeRequest(
    allocator: Allocator,
    host: []const u8,
    path: []const u8,
    key_b64: []const u8,
    extra_headers: []const []const u8,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const w = Writer{ .list = &out, .allocator = allocator };

    try w.print("GET {s} HTTP/1.1\r\n", .{path});
    try w.print("Host: {s}\r\n", .{host});
    try w.writeAll("Upgrade: websocket\r\n");
    try w.writeAll("Connection: Upgrade\r\n");
    try w.print("Sec-WebSocket-Key: {s}\r\n", .{key_b64});
    try w.writeAll("Sec-WebSocket-Version: 13\r\n");
    for (extra_headers) |h| {
        try w.print("{s}\r\n", .{h});
    }
    try w.writeAll("\r\n");
    return out.toOwnedSlice(allocator);
}

/// Validates server's 101 response head. Returns true if upgrade accepted.
pub fn validateUpgradeResponse(response_head: []const u8, expected_accept: *const [28]u8) bool {
    if (!std.mem.startsWith(u8, response_head, "HTTP/1.1 101 ")) return false;
    if (!hasHeaderToken(response_head, "Upgrade", "websocket")) return false;
    if (!hasHeaderToken(response_head, "Connection", "Upgrade")) return false;

    // Find Sec-WebSocket-Accept value
    const needle = "sec-websocket-accept:";
    const idx = std.ascii.indexOfIgnoreCase(response_head, needle) orelse return false;
    const line_end = std.mem.indexOfPos(u8, response_head, idx, "\r\n") orelse return false;
    const value = std.mem.trim(u8, response_head[idx + needle.len .. line_end], " \t");
    return std.mem.eql(u8, value, expected_accept);
}

/// Finds a header and verifies one comma-separated token, case-insensitively.
/// WebSocket handshake headers use token lists rather than exact whole-value
/// matching because intermediaries may append connection options.
fn hasHeaderToken(head: []const u8, name: []const u8, wanted: []const u8) bool {
    var pos: usize = 0;
    while (pos < head.len) {
        const end = std.mem.indexOfPos(u8, head, pos, "\r\n") orelse return false;
        const line = head[pos..end];
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            const field_name = std.mem.trim(u8, line[0..colon], " \t");
            if (std.ascii.eqlIgnoreCase(field_name, name)) {
                var tokens = std.mem.splitScalar(u8, line[colon + 1 ..], ',');
                while (tokens.next()) |token| {
                    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, token, " \t"), wanted)) return true;
                }
            }
        }
        pos = end + 2;
    }
    return false;
}

const Writer = struct {
    list: *std.ArrayList(u8),
    allocator: Allocator,

    fn print(self: *const Writer, comptime fmt: []const u8, args: anytype) !void {
        var buf: [1024]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, fmt, args);
        try self.list.appendSlice(self.allocator, s);
    }

    fn writeAll(self: *const Writer, data: []const u8) !void {
        try self.list.appendSlice(self.allocator, data);
    }
};

test "accept computation matches RFC example" {
    // RFC 6455 section 1.3 example
    var accept: [28]u8 = undefined;
    computeAccept("dGhlIHNhbXBsZSBub25jZQ==", &accept);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &accept);
}

test "upgrade request contains required headers" {
    const a = std.testing.allocator;
    const req = try buildUpgradeRequest(a, "srv.example.com", "/chat", "dGhlIHNhbXBsZSBub25jZQ==", &.{});
    defer a.free(req);

    try std.testing.expect(std.mem.indexOf(u8, req, "GET /chat HTTP/1.1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Upgrade: websocket\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Sec-WebSocket-Version: 13\r\n") != null);
}

test "validate upgrade response accepts correct accept" {
    const resp = "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
        "\r\n";
    try std.testing.expect(validateUpgradeResponse(resp, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="));
    try std.testing.expect(!validateUpgradeResponse(resp, "AAAAAAAAAAAAAAAAAAAAAAAAAAA="));
}

test "upgrade response requires protocol-switch headers" {
    const resp = "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n";
    try std.testing.expect(!validateUpgradeResponse(resp, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="));
}
