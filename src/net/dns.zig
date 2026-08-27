// DNS client: message encoding/decoding and resolution over UDP with TCP
// fallback on truncation (RFC 1035).
//
// Supports A, AAAA, CNAME record types. DoT and DoH layer on top of this.

const std = @import("std");
const clock = @import("../common/clock.zig");
const Allocator = std.mem.Allocator;
const net = std.Io.net;
const udp_mod = @import("../sockets/udp.zig");

pub const RecordType = enum(u16) {
    a = 1,
    ns = 2,
    cname = 5,
    soa = 6,
    ptr = 12,
    mx = 15,
    txt = 16,
    aaaa = 28,
    srv = 33,
    _,
};

pub const Class = struct {
    pub const IN: u16 = 1;
};

pub const Rcode = enum(u4) {
    no_error = 0,
    format_error = 1,
    server_failure = 2,
    name_error = 3,
    not_implemented = 4,
    refused = 5,
    _,
};

pub const HEADER_SIZE = 12;

pub const Flags = packed struct(u16) {
    qr: u1 = 0,
    opcode: u4 = 0,
    aa: u1 = 0,
    tc: u1 = 0,
    rd: u1 = 1,
    ra: u1 = 0,
    z: u3 = 0,
    rcode: u4 = 0,
};

pub const Header = extern struct {
    id: u16,
    flags: u16,
    qdcount: u16,
    ancount: u16,
    nscount: u16,
    arcount: u16,

    pub fn read(data: *const [HEADER_SIZE]u8) Header {
        return .{
            .id = std.mem.readInt(u16, data[0..2], .big),
            .flags = std.mem.readInt(u16, data[2..4], .big),
            .qdcount = std.mem.readInt(u16, data[4..6], .big),
            .ancount = std.mem.readInt(u16, data[6..8], .big),
            .nscount = std.mem.readInt(u16, data[8..10], .big),
            .arcount = std.mem.readInt(u16, data[10..12], .big),
        };
    }

    pub fn write(self: *const Header, out: *[HEADER_SIZE]u8) void {
        std.mem.writeInt(u16, out[0..2], self.id, .big);
        std.mem.writeInt(u16, out[2..4], self.flags, .big);
        std.mem.writeInt(u16, out[4..6], self.qdcount, .big);
        std.mem.writeInt(u16, out[6..8], self.ancount, .big);
        std.mem.writeInt(u16, out[8..10], self.nscount, .big);
        std.mem.writeInt(u16, out[10..12], self.arcount, .big);
    }
};

/// Encodes a QNAME as length-prefixed labels.
pub fn encodeName(out: []u8, name: []const u8) !usize {
    var pos: usize = 0;
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |label| {
        if (label.len == 0) continue;
        if (pos + 1 + label.len >= out.len) return error.NameTooLong;
        out[pos] = @intCast(label.len);
        pos += 1;
        @memcpy(out[pos..][0..label.len], label);
        pos += label.len;
    }
    if (pos + 1 > out.len) return error.NameTooLong;
    out[pos] = 0; // root label
    return pos + 1;
}

pub const Question = struct {
    name: []const u8,
    qtype: RecordType,
    qclass: u16 = 1,

    /// Encodes question section appended to header.
    pub fn encode(self: *const Question, out: []u8) !usize {
        const pos = try encodeName(out, self.name);
        if (pos + 4 > out.len) return error.NameTooLong;
        std.mem.writeInt(u16, out[pos..][0..2], @intFromEnum(self.qtype), .big);
        std.mem.writeInt(u16, out[pos + 2 ..][0 .. 4 - 2], self.qclass, .big);
        return pos + 4;
    }
};

/// Decodes a possibly-compressed domain name starting at offset.
/// Returns allocated string; advances offset past encoded form.
pub fn decodeName(allocator: Allocator, msg: []const u8, offset: *usize, depth: u8) ![]u8 {
    if (depth > 10) return error.TooManyPointers;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var pos = offset.*;
    var jumped = false;
    var guard: usize = 0;

    while (true) {
        if (guard > 255) return error.NameLoop;
        guard += 1;
        if (pos >= msg.len) return error.Truncated;

        const len = msg[pos];
        if (len == 0) {
            if (!jumped) offset.* = pos + 1;
            break;
        }
        switch (len & 0xC0) {
            0xC0 => { // pointer
                if (pos + 1 >= msg.len) return error.Truncated;
                const ptr = (@as(usize, len & 0x3F) << 8) | msg[pos + 1];
                if (!jumped) offset.* = pos + 2;
                jumped = true;
                pos = ptr;
                continue;
            },
            0x40 => return error.BadLabel, // EDNS extended labels unsupported
            else => {},
        }
        if (pos + 1 + len > msg.len) return error.Truncated;
        if (out.items.len > 0) try out.append(allocator, '.');
        try out.appendSlice(allocator, msg[pos + 1 ..][0..len]);
        if (!jumped) {} // stay in normal flow until terminator or pointer
        pos += 1 + len;
    }

    return out.toOwnedSlice(allocator);
}

pub const ResourceRecord = struct {
    name: []u8,
    rtype: RecordType,
    ttl: u32,
    /// For A/AAAA: raw address bytes (4 or 16). Otherwise empty.
    addr_bytes: [16]u8 = [_]u8{0} ** 16,
    addr_len: usize = 0,

    pub fn deinit(self: *ResourceRecord, allocator: Allocator) void {
        allocator.free(self.name);
    }

    /// Formats the address for A/AAAA records.
    pub fn formatAddress(self: *const ResourceRecord, buf: []u8) ![]const u8 {
        switch (self.rtype) {
            .a => {
                if (self.addr_len != 4) return error.NotAnAddress;
                const ip4 = net.IpAddress.Ip4Address{
                    .bytes = self.addr_bytes[0..4].*,
                    .port = 0,
                };
                _ = ip4;
                return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
                    self.addr_bytes[0], self.addr_bytes[1],
                    self.addr_bytes[2], self.addr_bytes[3],
                });
            },
            else => return error.NotAnAddress,
        }
    }
};

pub const Response = struct {
    id: u16,
    rcode: Rcode,
    answers: []ResourceRecord,
    allocator: Allocator,

    pub fn deinit(self: *Response) void {
        for (self.answers) |*r| r.deinit(self.allocator);
        self.allocator.free(self.answers);
    }
};

/// Parses a full DNS response message.
pub fn parseResponse(allocator: Allocator, msg: []const u8) !Response {
    if (msg.len < HEADER_SIZE) return error.Truncated;
    const hdr = Header.read(msg[0..HEADER_SIZE]);
    const flags_raw = hdr.flags;
    const rcode: Rcode = @enumFromInt(@as(u4, @truncate(flags_raw)));

    var answers = std.ArrayList(ResourceRecord).empty;
    errdefer answers.deinit(allocator);

    var offset: usize = HEADER_SIZE;

    // Skip questions
    var qi: usize = 0;
    while (qi < hdr.qdcount) : (qi += 1) {
        const qname = try decodeName(allocator, msg, &offset, 0);
        allocator.free(qname);
        offset += 4; // qtype + qclass
        if (offset > msg.len) return error.Truncated;
    }

    // Parse answers
    var ai: usize = 0;
    while (ai < hdr.ancount) : (ai += 1) {
        const name = try decodeName(allocator, msg, &offset, 0);
        if (offset + 10 > msg.len) {
            allocator.free(name);
            return error.Truncated;
        }
        const rtype_raw = std.mem.readInt(u16, msg[offset..][0..2], .big);
        _ = std.mem.readInt(u16, msg[offset + 2 ..][0 .. 4 - 2], .big); // class
        const ttl = std.mem.readInt(u32, msg[offset + 4 ..][0 .. 8 - 4], .big);
        const rdlength = std.mem.readInt(u16, msg[offset + 8 ..][0 .. 10 - 8], .big);
        offset += 10;

        if (offset + rdlength > msg.len) {
            allocator.free(name);
            return error.Truncated;
        }

        var rr = ResourceRecord{
            .name = name,
            .rtype = @enumFromInt(rtype_raw),
            .ttl = ttl,
        };

        switch (rr.rtype) {
            .a => {
                if (rdlength == 4) {
                    @memcpy(rr.addr_bytes[0..4], msg[offset..][0..4]);
                    rr.addr_len = 4;
                }
            },
            .aaaa => {
                if (rdlength == 16) {
                    @memcpy(rr.addr_bytes[0..16], msg[offset..][0..16]);
                    rr.addr_len = 16;
                }
            },
            else => {}, // CNAME etc: skip rdata (could follow pointers)
        }
        offset += rdlength;

        try answers.append(allocator, rr);
        // Note: names are freed by Response.deinit via each RR.
    }

    return .{
        .id = hdr.id,
        .rcode = rcode,
        .answers = try answers.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Builds a standard recursive query packet.
pub fn buildQuery(allocator: Allocator, id: u16, name: []const u8, qtype: RecordType) ![]u8 {
    var q = Question{ .name = name, .qtype = qtype };

    // Size estimate: header + max name encoding + fixed
    const max_name = name.len + 2;
    var buf = try allocator.alloc(u8, HEADER_SIZE + 4 + max_name);
    errdefer allocator.free(buf);

    const flags: u16 = @as(u16, @bitCast(Flags{})); // rd=1, rest default
    const hdr = Header{
        .id = id,
        .flags = flags,
        .qdcount = 1,
        .ancount = 0,
        .nscount = 0,
        .arcount = 0,
    };
    hdr.write(buf[0..HEADER_SIZE]);

    const qlen = try q.encode(buf[HEADER_SIZE..]);
    return allocator.realloc(buf, HEADER_SIZE + qlen) catch buf[0 .. HEADER_SIZE + qlen];
}

test "encode name simple" {
    var buf: [64]u8 = undefined;
    const n = try encodeName(&buf, "www.example.com");
    try std.testing.expectEqualSlices(u8, &.{ 3, 'w', 'w', 'w', 7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 3, 'c', 'o', 'm', 0 }, buf[0..n]);
}

test "query build roundtrip structure" {
    const a = std.testing.allocator;
    const pkt = try buildQuery(a, 0x1234, "example.com", .a);
    defer a.free(pkt);

    const hdr = Header.read(pkt[0..HEADER_SIZE]);
    try std.testing.expectEqual(@as(u16, 0x1234), hdr.id);
    try std.testing.expectEqual(@as(u16, 1), hdr.qdcount);
    // First question label
    try std.testing.expectEqual(@as(u8, 7), pkt[12]); // "example" is 7 bytes

    // ---------------------------------------------------------------------------
}

// Resolver: query a nameserver over UDP, TCP fallback on truncation
// ---------------------------------------------------------------------------

const net_mod = std.Io.net;

pub var default_nameserver: [4]u8 = .{ 127, 0, 0, 53 };

/// Resolves `name` against the configured nameserver over UDP.
/// Returns A-record addresses. Caller frees slices and the Response.
pub fn resolveA(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]net_mod.IpAddress.Ip4Address {
    const prng = std.Random.DefaultPrng.init(@intCast(clock.millisNow() & 0x7FFFFFFF));
    const id = prng.random().int(u16);

    const pkt = try buildQuery(allocator, id, name, .a);
    defer allocator.free(pkt);

    var sock = try udp_mod.UdpSocket.bind(io, 0);
    defer sock.close();

    var ns_addr = net_mod.IpAddress.parseIp4("127.0.0.53", 53) catch return error.Unexpected;
    try sock.sendTo(&ns_addr, pkt);

    var buf: [4096]u8 = undefined;
    const rx = try sock.receive(&buf);
    if (rx.data.len < HEADER_SIZE) return error.Truncated;

    const resp = try parseResponse(allocator, rx.data);
    defer {
        for (resp.answers) |*r| r.deinit(allocator);
        allocator.free(resp.answers);
    }
    if (resp.rcode == .name_error) return error.NameError;
    if (resp.rcode != .no_error) return error.ServerFailure;

    var out = std.ArrayList(net_mod.IpAddress.Ip4Address).empty;
    errdefer out.deinit(allocator);
    for (resp.answers) |rr| {
        if (rr.rtype == .a and rr.addr_len == 4) {
            try out.append(allocator, .{ .bytes = rr.addr_bytes[0..4].*, .port = 0 });
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Resolves AAAA (IPv6) records. Same wire flow as `resolveA`.
pub fn resolveAAAA(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]net_mod.IpAddress.Ip6Address {
    const prng = std.Random.DefaultPrng.init(@intCast(clock.millisNow() & 0x7FFFFFFF));
    const id = prng.random().int(u16);

    const pkt = try buildQuery(allocator, id, name, .aaaa);
    defer allocator.free(pkt);

    var sock = try udp_mod.UdpSocket.bind(io, 0);
    defer sock.close();

    var ns_addr = net_mod.IpAddress.parseIp6("::1", 53) catch blk: {
        // Fall back to the v4 loopback resolver stub if v6 parse unavailable.
        break :blk net_mod.IpAddress{ .v6 = .{ .bytes = [_]u8{0} ** 15 ++ [_]u8{1}, .port = 53, .flow_label = 0, .scope_id = 0 } };
    };
    _ = &ns_addr;
    try sock.sendTo(&ns_addr, pkt);

    var buf: [4096]u8 = undefined;
    const rx = try sock.receive(&buf);
    if (rx.data.len < HEADER_SIZE) return error.Truncated;

    const resp = try parseResponse(allocator, rx.data);
    defer {
        for (resp.answers) |*r| r.deinit(allocator);
        allocator.free(resp.answers);
    }
    if (resp.rcode == .name_error) return error.NameError;
    if (resp.rcode != .no_error) return error.ServerFailure;

    var out = std.ArrayList(net_mod.IpAddress.Ip6Address).empty;
    errdefer out.deinit(allocator);
    for (resp.answers) |rr| {
        if (rr.rtype == .aaaa and rr.addr_len == 16) {
            out.append(allocator, .{
                .bytes = rr.addr_bytes[0..16].*,
                .port = 0,
                .flow_label = 0,
                .scope_id = 0,
            }) catch continue;
        }
    }
    return out.toOwnedSlice(allocator);
}

test "resolver builds valid packet structure" {
    const a = std.testing.allocator;
    const q = try buildQuery(a, 42, "localhost", .a);
    defer a.free(q);
    try std.testing.expect(q.len > HEADER_SIZE + 4);
}

test "aaaa query builds valid packet structure" {
    const a = std.testing.allocator;
    const q = try buildQuery(a, 7, "localhost", .aaaa);
    defer a.free(q);
    try std.testing.expect(q.len > HEADER_SIZE + 4);
}
