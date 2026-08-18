const std = @import("std");
const Allocator = std.mem.Allocator;
const net = @import("compat.zig");
const address_mod = @import("address.zig");
const common = @import("../data/common.zig");
const socket_mod = @import("socket.zig");

const posix = std.posix;

pub const AddressFamily = enum {
    any,
    ipv4_only,
    ipv6_only,
};

pub const AddressOrder = enum {
    system,
    ipv4_preferred,
    ipv6_preferred,
};

pub const DnsRecordType = enum(u16) {
    A = 1,
    NS = 2,
    CNAME = 5,
    SOA = 6,
    MX = 15,
    TXT = 16,
    AAAA = 28,
    _,
};

pub const DnsRecordClass = enum(u16) {
    IN = 1,
    CS = 2,
    CH = 3,
    HS = 4,
    ANY = 255,
    _,
};

pub const DnsServer = struct {
    ip: []const u8,
    port: u16 = 53,
};

pub const DNSConfig = struct {
    positive_ttl_ms: i64 = 60_000,
    negative_ttl_ms: i64 = 5_000,
    max_cache_entries: u32 = 1024,
    address_family: AddressFamily = .any,
    address_order: AddressOrder = .system,
    cache_enabled: bool = true,
    dedup_enabled: bool = true,
    dns_servers: []const DnsServer = &.{
        .{ .ip = "8.8.8.8" },
        .{ .ip = "8.8.4.4" },
        .{ .ip = "1.1.1.1" },
    },
    udp_timeout_ms: u64 = 3000,
    tcp_timeout_ms: u64 = 5000,
};

pub const DNSResolution = struct {
    hostname: []const u8,
    addresses: []net.Address,
    failed: bool = false,
    allocator: Allocator,

    pub fn deinit(self: *DNSResolution) void {
        self.allocator.free(self.addresses);
        self.* = undefined;
    }

    pub fn ok(self: *const DNSResolution) bool {
        return !self.failed and self.addresses.len > 0;
    }
};

pub const DNSStats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    failures: u64 = 0,
    evictions: u64 = 0,
    negative_hits: u64 = 0,
    dedup_hits: u64 = 0,
    literal_hits: u64 = 0,
    total_lookups: u64 = 0,
    udp_queries: u64 = 0,
    tcp_queries: u64 = 0,

    pub fn hitRate(self: DNSStats) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }
};

fn putU16(buf: []u8, val: u16) void {
    buf[0] = @intCast(val >> 8);
    buf[1] = @intCast(val & 0xFF);
}

fn putU32(buf: []u8, val: u32) void {
    buf[0] = @intCast(val >> 24);
    buf[1] = @intCast((val >> 16) & 0xFF);
    buf[2] = @intCast((val >> 8) & 0xFF);
    buf[3] = @intCast(val & 0xFF);
}

fn getU16(buf: []const u8) u16 {
    return (@as(u16, buf[0]) << 8) | @as(u16, buf[1]);
}

fn getU32(buf: []const u8) u32 {
    return (@as(u32, buf[0]) << 24) | (@as(u32, buf[1]) << 16) | (@as(u32, buf[2]) << 8) | @as(u32, buf[3]);
}

const DnsHeader = extern struct {
    id: u16,
    flags: u16,
    qdcount: u16,
    ancount: u16,
    nscount: u16,
    arcount: u16,

    const Self = @This();

    pub fn flags_Query(recursion_desired: bool) u16 {
        var f: u16 = 0;
        if (recursion_desired) f |= 1 << 8;
        return f;
    }

    pub fn isResponse(self: Self) bool {
        return (self.flags & 0x8000) != 0;
    }

    pub fn rcode(self: Self) u4 {
        return @intCast(self.flags & 0x000F);
    }

    pub fn isTruncated(self: Self) bool {
        return (self.flags & 0x0200) != 0;
    }
};

const DnsQuestion = struct {
    name: []const u8,
    qtype: DnsRecordType,
    qclass: DnsRecordClass,
};

const DnsRecord = struct {
    name: []const u8,
    record_type: DnsRecordType,
    record_class: DnsRecordClass,
    ttl: i32,
    rdata: []const u8,
};

const DnsMessage = struct {
    header: DnsHeader,
    questions: []DnsQuestion,
    answers: []DnsRecord,
    allocator: Allocator,

    pub fn deinit(self: *DnsMessage) void {
        for (self.questions) |q| {
            self.allocator.free(q.name);
        }
        self.allocator.free(self.questions);
        for (self.answers) |a| {
            self.allocator.free(a.name);
            self.allocator.free(a.rdata);
        }
        self.allocator.free(self.answers);
    }
};

fn encodeDnsName(name: []const u8, buf: []u8) !struct { len: usize } {
    var pos: usize = 0;
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |label| {
        if (label.len > 63) return error.NameLabelTooLong;
        if (pos + 1 + label.len > buf.len) return error.NameTooLong;
        buf[pos] = @intCast(label.len);
        pos += 1;
        @memcpy(buf[pos .. pos + label.len], label);
        pos += label.len;
    }
    if (pos < buf.len) {
        buf[pos] = 0;
        pos += 1;
    }
    return .{ .len = pos };
}

fn decodeDnsName(data: []const u8, offset: *usize, out_buf: []u8) !usize {
    var name_len: usize = 0;
    var jumped = false;
    var original_offset = offset.*;

    var pos = offset.*;
    var jump_count: u8 = 0;

    while (pos < data.len) {
        const label_len = data[pos];

        if (label_len == 0) {
            pos += 1;
            if (!jumped) offset.* = pos;
            break;
        }

        if ((label_len & 0xC0) == 0xC0) {
            if (pos + 1 >= data.len) return error.InvalidDnsName;
            if (!jumped) original_offset = pos + 2;
            const ptr = @as(u16, label_len & 0x3F) << 8 | @as(u16, data[pos + 1]);
            pos = ptr;
            jumped = true;
            jump_count += 1;
            if (jump_count > 64) return error.DnsNameLoop;
            continue;
        }

        if (label_len > 63) return error.InvalidLabelLength;
        pos += 1;
        if (pos + label_len > data.len) return error.NameTruncated;
        if (name_len > 0) {
            if (name_len + 1 >= out_buf.len) return error.NameTooLong;
            out_buf[name_len] = '.';
            name_len += 1;
        }
        if (name_len + label_len >= out_buf.len) return error.NameTooLong;
        @memcpy(out_buf[name_len .. name_len + label_len], data[pos .. pos + label_len]);
        name_len += label_len;
        pos += label_len;
    }

    if (!jumped) offset.* = pos;
    return name_len;
}

fn encodeQuestion(q: DnsQuestion, buf: []u8) !usize {
    const name_result = try encodeDnsName(q.name, buf);
    var pos = name_result.len;

    if (pos + 4 > buf.len) return error.BufferTooSmall;
    putU16(buf[pos..], @intFromEnum(q.qtype));
    putU16(buf[pos + 2 ..], @intFromEnum(q.qclass));
    pos += 4;

    return pos;
}

fn parseDnsMessage(data: []const u8, allocator: Allocator) !DnsMessage {
    if (data.len < 12) return error.DnsMessageTooShort;

    const header = DnsHeader{
        .id = getU16(data[0..2]),
        .flags = getU16(data[2..4]),
        .qdcount = getU16(data[4..6]),
        .ancount = getU16(data[6..8]),
        .nscount = getU16(data[8..10]),
        .arcount = getU16(data[10..12]),
    };

    var offset: usize = 12;
    var name_buf: [256]u8 = undefined;

    const questions = try allocator.alloc(DnsQuestion, header.qdcount);
    errdefer {
        for (questions) |q| allocator.free(q.name);
        allocator.free(questions);
    }

    for (questions) |*q| {
        const name_len = try decodeDnsName(data, &offset, &name_buf);
        q.name = try allocator.dupe(u8, name_buf[0..name_len]);
        if (offset + 4 > data.len) return error.DnsMessageTruncated;
        q.qtype = @enumFromInt(getU16(data[offset..]));
        q.qclass = @enumFromInt(getU16(data[offset + 2 ..]));
        offset += 4;
    }

    const answers = try allocator.alloc(DnsRecord, header.ancount);
    errdefer {
        for (answers) |a| {
            allocator.free(a.name);
            allocator.free(a.rdata);
        }
        allocator.free(answers);
    }

    for (answers) |*a| {
        const name_len = try decodeDnsName(data, &offset, &name_buf);
        a.name = try allocator.dupe(u8, name_buf[0..name_len]);
        if (offset + 10 > data.len) return error.DnsMessageTruncated;
        a.record_type = @enumFromInt(getU16(data[offset..]));
        a.record_class = @enumFromInt(getU16(data[offset + 2 ..]));
        a.ttl = @bitCast(getU32(data[offset + 4 ..]));
        const rdlength = getU16(data[offset + 8 ..]);
        offset += 10;

        if (offset + rdlength > data.len) return error.DnsMessageTruncated;
        a.rdata = try allocator.dupe(u8, data[offset .. offset + rdlength]);
        offset += rdlength;
    }

    return DnsMessage{
        .header = header,
        .questions = questions,
        .answers = answers,
        .allocator = allocator,
    };
}

fn buildDnsQuery(name: []const u8, qtype: DnsRecordType, use_edns: bool, buf: []u8) !usize {
    var id_bytes: [2]u8 = undefined;
    common.threadIo().random(&id_bytes);
    const id = getU16(&id_bytes);

    var pos: usize = 0;
    putU16(buf[pos..], id);
    pos += 2;

    var flags: u16 = 0;
    flags |= 1 << 8; // RD
    putU16(buf[pos..], flags);
    pos += 2;

    putU16(buf[pos..], 1); // QDCOUNT
    pos += 2;
    putU16(buf[pos..], 0); // ANCOUNT
    pos += 2;
    putU16(buf[pos..], 0); // NSCOUNT
    pos += 2;

    if (use_edns) {
        putU16(buf[pos..], 1); // ARCOUNT
    } else {
        putU16(buf[pos..], 0); // ARCOUNT
    }
    pos += 2;

    const name_result = try encodeDnsName(name, buf[pos..]);
    pos += name_result.len;

    putU16(buf[pos..], @intFromEnum(qtype));
    pos += 2;
    putU16(buf[pos..], @intFromEnum(DnsRecordClass.IN));
    pos += 4;

    if (use_edns) {
        pos += 1; // root label
        putU16(buf[pos..], 41); // OPT record type
        pos += 2;
        putU16(buf[pos..], 4096); // UDP payload size
        pos += 2;
        buf[pos] = 0;
        pos += 1;
        buf[pos] = 0;
        pos += 1;
        putU16(buf[pos..], 0); // Z
        pos += 2;
    }

    return pos;
}

fn queryViaUdp(server: DnsServer, name: []const u8, qtype: DnsRecordType, timeout_ms: u64, allocator: Allocator) !DnsMessage {
    var buf: [4096]u8 = undefined;
    const query_len = try buildDnsQuery(name, qtype, true, &buf);

    const server_addr = try net.Address.parseIp(server.ip, server.port);
    var sock = socket_mod.UdpSocket.createForAddress(server_addr) catch return error.DnsUdpSocketFailed;
    defer sock.close();

    sock.setRecvTimeout(timeout_ms) catch {};

    _ = sock.sendTo(server_addr, buf[0..query_len]) catch return error.DnsUdpSendFailed;

    var resp_buf: [4096]u8 = undefined;
    const n = sock.recv(&resp_buf) catch return error.DnsUdpRecvFailed;

    var msg = try parseDnsMessage(resp_buf[0..n], allocator);

    if (msg.header.isTruncated()) {
        msg.deinit();
        return error.DnsUdpTruncated;
    }

    return msg;
}

fn queryViaTcp(server: DnsServer, name: []const u8, qtype: DnsRecordType, timeout_ms: u64, allocator: Allocator) !DnsMessage {
    var buf: [4096]u8 = undefined;
    const query_len = try buildDnsQuery(name, qtype, false, &buf);

    const server_addr = try net.Address.parseIp(server.ip, server.port);
    var sock = socket_mod.Socket.createForAddress(server_addr) catch return error.DnsTcpSocketFailed;
    defer sock.close();

    sock.connectWithTimeout(server_addr, timeout_ms) catch return error.DnsTcpConnectFailed;

    var tcp_buf: [4098]u8 = undefined;
    putU16(tcp_buf[0..], @intCast(query_len));
    @memcpy(tcp_buf[2 .. 2 + query_len], buf[0..query_len]);

    sock.sendAll(tcp_buf[0 .. 2 + query_len]) catch return error.DnsTcpSendFailed;

    var len_buf: [2]u8 = undefined;
    var read: usize = 0;
    while (read < 2) {
        const n = sock.recv(len_buf[read..]) catch return error.DnsTcpRecvFailed;
        if (n == 0) return error.DnsTcpConnectionClosed;
        read += n;
    }

    const resp_len = getU16(&len_buf);
    if (resp_len == 0 or resp_len > 4096) return error.DnsTcpInvalidLength;

    var resp_buf: [4096]u8 = undefined;
    read = 0;
    while (read < resp_len) {
        const n = sock.recv(resp_buf[read..resp_len]) catch return error.DnsTcpRecvFailed;
        if (n == 0) return error.DnsTcpConnectionClosed;
        read += n;
    }

    return parseDnsMessage(resp_buf[0..resp_len], allocator);
}

fn queryDns(servers: []const DnsServer, name: []const u8, qtype: DnsRecordType, udp_timeout_ms: u64, tcp_timeout_ms: u64, allocator: Allocator) !DnsMessage {
    for (servers) |server| {
        if (queryViaUdp(server, name, qtype, udp_timeout_ms, allocator)) |msg| {
            return msg;
        } else |_| {
            if (queryViaTcp(server, name, qtype, tcp_timeout_ms, allocator)) |msg| {
                return msg;
            } else |_| {}
        }
    }
    return error.DnsAllServersFailed;
}

fn extractIpv4Addresses(msg: *DnsMessage, hostname: []const u8, allocator: Allocator) ![]net.Address {
    var addrs = std.ArrayList(net.Address).empty;
    errdefer addrs.deinit(allocator);

    for (msg.answers) |answer| {
        if (answer.record_type == .A and answer.record_class == .IN and answer.rdata.len == 4) {
            const addr = net.Address.initIp4(.{ answer.rdata[0], answer.rdata[1], answer.rdata[2], answer.rdata[3] }, 0);
            try addrs.append(allocator, addr);
        }
    }

    _ = hostname;
    return addrs.toOwnedSlice(allocator);
}

fn extractIpv6Addresses(msg: *DnsMessage, hostname: []const u8, allocator: Allocator) ![]net.Address {
    var addrs = std.ArrayList(net.Address).empty;
    errdefer addrs.deinit(allocator);

    for (msg.answers) |answer| {
        if (answer.record_type == .AAAA and answer.record_class == .IN and answer.rdata.len == 16) {
            const addr = net.Address.initIp6(answer.rdata[0..16].*, 0, 0, 0);
            try addrs.append(allocator, addr);
        }
    }

    _ = hostname;
    return addrs.toOwnedSlice(allocator);
}

const CacheEntry = struct {
    addresses: []net.Address,
    created_at_ms: i64,
    ttl_ms: i64,
};

const NegativeEntry = struct {
    created_at_ms: i64,
    ttl_ms: i64,
};

const InFlight = struct {
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    addresses: []net.Address = &.{},
    failed: bool = false,
    allocator: Allocator,

    fn incRef(self: *InFlight) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    fn decRef(self: *InFlight) void {
        if (self.ref_count.fetchSub(1, .release) == 1) {
            _ = self.ref_count.load(.acquire);
            self.allocator.free(self.addresses);
            self.allocator.destroy(self);
        }
    }
};

pub const DNSCache = struct {
    allocator: Allocator,
    entries: std.StringHashMapUnmanaged(CacheEntry) = .{},
    negative: std.StringHashMapUnmanaged(NegativeEntry) = .{},
    lru_order: std.ArrayListUnmanaged([]const u8) = .{ .items = &.{}, .capacity = 0 },
    in_flight: std.StringHashMapUnmanaged(*InFlight) = .{},
    lock: std.Io.Mutex = .init,
    config: DNSConfig,
    stats: DNSStats = .{},

    const Self = @This();

    pub fn init(allocator: Allocator, config: DNSConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        {
            self.lock.lock(common.threadIo()) catch {};
            defer self.lock.unlock(common.threadIo());

            var it = self.entries.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*.addresses);
            }
            self.entries.deinit(self.allocator);

            var nit = self.negative.iterator();
            while (nit.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            self.negative.deinit(self.allocator);

            for (self.lru_order.items) |key| {
                self.allocator.free(key);
            }
            self.lru_order.deinit(self.allocator);

            var iit = self.in_flight.iterator();
            while (iit.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.decRef();
            }
            self.in_flight.deinit(self.allocator);
        }
    }

    fn cacheLookup(self: *Self, hostname: []const u8) ?CacheEntry {
        const now_ms = common.nowMillis();

        if (self.entries.getPtr(hostname)) |entry| {
            if (now_ms < entry.created_at_ms + entry.ttl_ms) {
                self.touchLRU(hostname);
                return entry.*;
            }
            self.removeEntry(hostname);
            return null;
        }

        if (self.negative.getPtr(hostname)) |neg| {
            if (now_ms < neg.created_at_ms + neg.ttl_ms) {
                self.stats.negative_hits += 1;
                return null;
            }
            self.removeNegative(hostname);
        }

        return null;
    }

    fn cacheStore(self: *Self, hostname: []const u8, addresses: []net.Address, ttl_ms: i64) void {
        self.lock.lock(common.threadIo()) catch {};
        defer self.lock.unlock(common.threadIo());

        self.evictIfNeeded();

        if (self.entries.fetchRemove(hostname)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value.addresses);
        }
        self.removeNegative(hostname);

        const key = self.allocator.dupe(u8, hostname) catch return;
        const addrs = self.allocator.dupe(net.Address, addresses) catch {
            self.allocator.free(key);
            return;
        };

        self.entries.put(self.allocator, key, .{
            .addresses = addrs,
            .created_at_ms = common.nowMillis(),
            .ttl_ms = ttl_ms,
        }) catch {
            self.allocator.free(key);
            self.allocator.free(addrs);
            return;
        };

        const lru_key = self.allocator.dupe(u8, hostname) catch return;
        self.lru_order.append(self.allocator, lru_key) catch {
            self.allocator.free(lru_key);
        };
    }

    fn cacheNegative(self: *Self, hostname: []const u8) void {
        self.lock.lock(common.threadIo()) catch {};
        defer self.lock.unlock(common.threadIo());

        self.evictIfNeeded();
        self.stats.failures += 1;

        if (self.entries.fetchRemove(hostname)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value.addresses);
        }

        const key = self.allocator.dupe(u8, hostname) catch return;
        self.negative.put(self.allocator, key, .{
            .created_at_ms = common.nowMillis(),
            .ttl_ms = self.config.negative_ttl_ms,
        }) catch {
            self.allocator.free(key);
        };
    }

    fn evictIfNeeded(self: *Self) void {
        if (self.config.max_cache_entries == 0) return;
        while (self.entries.count() >= self.config.max_cache_entries) {
            if (self.lru_order.items.len == 0) break;
            const oldest = self.lru_order.orderedRemove(0);
            if (self.entries.fetchRemove(oldest)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value.addresses);
            }
            self.allocator.free(oldest);
            self.stats.evictions += 1;
        }
    }

    fn touchLRU(self: *Self, hostname: []const u8) void {
        var i: usize = 0;
        while (i < self.lru_order.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.lru_order.items[i], hostname)) {
                const removed = self.lru_order.orderedRemove(i);
                self.allocator.free(removed);
                break;
            }
        }
        const lru_key = self.allocator.dupe(u8, hostname) catch return;
        self.lru_order.append(self.allocator, lru_key) catch {
            self.allocator.free(lru_key);
        };
    }

    fn removeEntry(self: *Self, hostname: []const u8) void {
        if (self.entries.fetchRemove(hostname)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value.addresses);
        }
        var i: usize = 0;
        while (i < self.lru_order.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.lru_order.items[i], hostname)) {
                const removed = self.lru_order.orderedRemove(i);
                self.allocator.free(removed);
                break;
            }
        }
    }

    fn removeNegative(self: *Self, hostname: []const u8) void {
        if (self.negative.fetchRemove(hostname)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    pub fn evictExpired(self: *Self) void {
        const now_ms = common.nowMillis();

        self.lock.lock(common.threadIo()) catch {};
        defer self.lock.unlock(common.threadIo());

        var expired = std.ArrayList([]const u8).empty;
        defer expired.deinit(self.allocator);

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (now_ms >= entry.value_ptr.created_at_ms + entry.value_ptr.ttl_ms) {
                expired.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (expired.items) |key| {
            self.removeEntry(key);
            self.stats.evictions += 1;
        }

        expired.clearRetainingCapacity();
        var nit = self.negative.iterator();
        while (nit.next()) |entry| {
            if (now_ms >= entry.value_ptr.created_at_ms + entry.value_ptr.ttl_ms) {
                expired.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (expired.items) |key| {
            self.removeNegative(key);
        }
    }

    pub fn count(self: *Self) u32 {
        self.lock.lock(common.threadIo()) catch {};
        defer self.lock.unlock(common.threadIo());
        const pos: u64 = self.entries.count();
        const neg: u64 = self.negative.count();
        return @intCast(@min(pos + neg, @as(u64, std.math.maxInt(u32))));
    }

    pub fn clear(self: *Self) void {
        self.lock.lock(common.threadIo()) catch {};
        defer self.lock.unlock(common.threadIo());

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*.addresses);
        }
        self.entries.clearRetainingCapacity();

        var nit = self.negative.iterator();
        while (nit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.negative.clearRetainingCapacity();

        for (self.lru_order.items) |key| {
            self.allocator.free(key);
        }
        self.lru_order.clearRetainingCapacity();
    }

    pub fn invalidate(self: *Self, hostname: []const u8) void {
        self.lock.lock(common.threadIo()) catch {};
        defer self.lock.unlock(common.threadIo());
        self.removeEntry(hostname);
        self.removeNegative(hostname);
    }

    pub fn getStats(self: *Self) DNSStats {
        self.lock.lock(common.threadIo()) catch {};
        defer self.lock.unlock(common.threadIo());
        return self.stats;
    }
};

pub const DNSResolver = struct {
    allocator: Allocator,
    cache: DNSCache,

    const Self = @This();

    pub fn init(allocator: Allocator, config: DNSConfig) Self {
        return .{
            .allocator = allocator,
            .cache = DNSCache.init(allocator, config),
        };
    }

    pub fn deinit(self: *Self) void {
        self.cache.deinit();
    }

    pub const ResolveOptions = struct {
        port: u16 = 0,
        address_family: ?AddressFamily = null,
        address_order: ?AddressOrder = null,
    };

    pub fn resolve(self: *Self, hostname: []const u8, options: ResolveOptions) !DNSResolution {
        const family = options.address_family orelse self.cache.config.address_family;
        const order = options.address_order orelse self.cache.config.address_order;

        if (address_mod.isIp4Address(hostname)) {
            self.cache.stats.literal_hits += 1;
            const parsed = try net.Address.parseIp(hostname, options.port);
            const addrs = try self.allocator.alloc(net.Address, 1);
            addrs[0] = parsed;
            return .{
                .hostname = hostname,
                .addresses = addrs,
                .allocator = self.allocator,
            };
        }
        if (address_mod.isIp6Address(hostname)) {
            self.cache.stats.literal_hits += 1;
            const parsed = try net.Address.parseIp(hostname, options.port);
            const addrs = try self.allocator.alloc(net.Address, 1);
            addrs[0] = parsed;
            return .{
                .hostname = hostname,
                .addresses = addrs,
                .allocator = self.allocator,
            };
        }

        if (self.cache.config.cache_enabled) {
            self.cache.lock.lock(common.threadIo()) catch {};
            const cached = self.cache.cacheLookup(hostname);
            self.cache.lock.unlock(common.threadIo());

            if (cached) |entry| {
                self.cache.stats.hits += 1;
                const filtered = self.filterAddresses(entry.addresses, family, order);
                const addrs = try self.allocator.dupe(net.Address, filtered);
                for (addrs) |*a| a.setPort(options.port);
                return .{
                    .hostname = hostname,
                    .addresses = addrs,
                    .allocator = self.allocator,
                };
            }
            self.cache.stats.misses += 1;
        }

        if (self.cache.config.dedup_enabled) {
            self.cache.lock.lock(common.threadIo()) catch {};
            if (self.cache.in_flight.getPtr(hostname)) |inf| {
                inf.*.incRef();
                self.cache.stats.dedup_hits += 1;
                self.cache.lock.unlock(common.threadIo());

                while (!inf.*.ready.load(.acquire)) {
                    std.Thread.yield() catch {};
                }
                const failed = inf.*.failed;
                const addrs = inf.*.addresses;
                inf.*.decRef();

                if (failed) {
                    return error.DNSLookupFailed;
                }

                const filtered = self.filterAddresses(addrs, family, order);
                const result_addrs = try self.allocator.dupe(net.Address, filtered);
                for (result_addrs) |*a| a.setPort(options.port);
                return .{
                    .hostname = hostname,
                    .addresses = result_addrs,
                    .allocator = self.allocator,
                };
            }

            const inf = try self.cache.allocator.create(InFlight);
            inf.* = .{ .allocator = self.cache.allocator };
            inf.incRef();
            inf.incRef();
            self.cache.in_flight.put(self.cache.allocator, try self.cache.allocator.dupe(u8, hostname), inf) catch {
                inf.decRef();
                self.cache.lock.unlock(common.threadIo());
                return error.OutOfMemory;
            };
            self.cache.lock.unlock(common.threadIo());

            const result = self.performResolution(hostname, family);

            self.cache.lock.lock(common.threadIo()) catch {};
            inf.ready.store(true, .release);
            switch (result) {
                .ok => |addrs| {
                    inf.addresses = addrs;
                    inf.failed = false;
                },
                .err => {
                    inf.failed = true;
                    self.cache.evictIfNeeded();
                    self.cache.stats.failures += 1;
                    if (self.cache.entries.fetchRemove(hostname)) |kv| {
                        self.cache.allocator.free(kv.key);
                        self.cache.allocator.free(kv.value.addresses);
                    }
                    const neg_key = self.cache.allocator.dupe(u8, hostname) catch return error.OutOfMemory;
                    self.cache.negative.put(self.cache.allocator, neg_key, .{
                        .created_at_ms = common.nowMillis(),
                        .ttl_ms = self.cache.config.negative_ttl_ms,
                    }) catch {
                        self.cache.allocator.free(neg_key);
                    };
                },
            }
            if (self.cache.in_flight.fetchRemove(hostname)) |kv| {
                self.cache.allocator.free(kv.key);
                kv.value.decRef();
            }
            self.cache.lock.unlock(common.threadIo());

            const inf_failed = inf.failed;
            const inf_addrs_len = inf.addresses.len;
            const inf_addrs: []net.Address = if (!inf_failed and inf_addrs_len > 0)
                try self.allocator.dupe(net.Address, inf.addresses)
            else
                &.{};
            inf.decRef();

            if (!inf_failed) {
                self.cache.cacheStore(hostname, inf_addrs, self.cache.config.positive_ttl_ms);
            }

            if (inf_failed) {
                self.allocator.free(inf_addrs);
                return error.DNSLookupFailed;
            }

            const filtered = self.filterAddresses(inf_addrs, family, order);
            const addrs = try self.allocator.dupe(net.Address, filtered);
            self.allocator.free(inf_addrs);
            for (addrs) |*a| a.setPort(options.port);
            return .{
                .hostname = hostname,
                .addresses = addrs,
                .allocator = self.allocator,
            };
        }

        const result = self.performResolution(hostname, family);

        switch (result) {
            .ok => |addrs| {
                if (self.cache.config.cache_enabled) {
                    self.cache.cacheStore(hostname, addrs, self.cache.config.positive_ttl_ms);
                }
                const filtered = self.filterAddresses(addrs, family, order);
                const out = try self.allocator.dupe(net.Address, filtered);
                for (out) |*a| a.setPort(options.port);
                return .{
                    .hostname = hostname,
                    .addresses = out,
                    .allocator = self.allocator,
                };
            },
            .err => {
                self.cache.cacheNegative(hostname);
                return error.DNSLookupFailed;
            },
        }
    }

    pub fn resolveAll(self: *Self, hostname: []const u8, options: ResolveOptions) !DNSResolution {
        const family = options.address_family orelse self.cache.config.address_family;
        const order = options.address_order orelse self.cache.config.address_order;

        if (address_mod.isIp4Address(hostname)) {
            self.cache.stats.literal_hits += 1;
            const parsed = try net.Address.parseIp(hostname, options.port);
            const addrs = try self.allocator.alloc(net.Address, 1);
            addrs[0] = parsed;
            return .{
                .hostname = hostname,
                .addresses = addrs,
                .allocator = self.allocator,
            };
        }
        if (address_mod.isIp6Address(hostname)) {
            self.cache.stats.literal_hits += 1;
            const parsed = try net.Address.parseIp(hostname, options.port);
            const addrs = try self.allocator.alloc(net.Address, 1);
            addrs[0] = parsed;
            return .{
                .hostname = hostname,
                .addresses = addrs,
                .allocator = self.allocator,
            };
        }

        if (self.cache.config.cache_enabled) {
            self.cache.lock.lock(common.threadIo()) catch {};
            const cached = self.cache.cacheLookup(hostname);
            self.cache.lock.unlock(common.threadIo());

            if (cached) |entry| {
                self.cache.stats.hits += 1;
                const filtered = self.filterAddresses(entry.addresses, family, order);
                const addrs = try self.allocator.dupe(net.Address, filtered);
                for (addrs) |*a| a.setPort(options.port);
                return .{
                    .hostname = hostname,
                    .addresses = addrs,
                    .allocator = self.allocator,
                };
            }
            self.cache.stats.misses += 1;
        }

        const result = self.performResolution(hostname, family);

        switch (result) {
            .ok => |addrs| {
                if (self.cache.config.cache_enabled) {
                    self.cache.cacheStore(hostname, addrs, self.cache.config.positive_ttl_ms);
                }
                const filtered = self.filterAddresses(addrs, family, order);
                const out = try self.allocator.dupe(net.Address, filtered);
                for (out) |*a| a.setPort(options.port);
                return .{
                    .hostname = hostname,
                    .addresses = out,
                    .allocator = self.allocator,
                };
            },
            .err => {
                self.cache.cacheNegative(hostname);
                return error.DNSLookupFailed;
            },
        }
    }

    pub fn invalidate(self: *Self, hostname: []const u8) void {
        self.cache.invalidate(hostname);
    }

    pub fn clear(self: *Self) void {
        self.cache.clear();
    }

    pub fn evictExpired(self: *Self) void {
        self.cache.evictExpired();
    }

    pub fn getStats(self: *Self) DNSStats {
        return self.cache.getStats();
    }

    const ResolveResult = union(enum) {
        ok: []net.Address,
        err: anyerror,
    };

    fn performResolution(self: *Self, hostname: []const u8, family: AddressFamily) ResolveResult {
        var all_addrs = std.ArrayList(net.Address).empty;
        defer all_addrs.deinit(self.allocator);

        const should_query_v4 = family == .any or family == .ipv4_only;
        const should_query_v6 = family == .any or family == .ipv6_only;

        if (should_query_v4) {
            if (queryDns(
                self.cache.config.dns_servers,
                hostname,
                .A,
                self.cache.config.udp_timeout_ms,
                self.cache.config.tcp_timeout_ms,
                self.allocator,
            )) |msg| {
                var m = msg;
                defer m.deinit();
                self.cache.stats.udp_queries += 1;
                if (extractIpv4Addresses(&m, hostname, self.allocator)) |v4_addrs| {
                    defer self.allocator.free(v4_addrs);
                    all_addrs.appendSlice(self.allocator, v4_addrs) catch {};
                } else |_| {}
            } else |_| {}
        }

        if (should_query_v6) {
            if (queryDns(
                self.cache.config.dns_servers,
                hostname,
                .AAAA,
                self.cache.config.udp_timeout_ms,
                self.cache.config.tcp_timeout_ms,
                self.allocator,
            )) |msg| {
                var m = msg;
                defer m.deinit();
                self.cache.stats.tcp_queries += 1;
                if (extractIpv6Addresses(&m, hostname, self.allocator)) |v6_addrs| {
                    defer self.allocator.free(v6_addrs);
                    all_addrs.appendSlice(self.allocator, v6_addrs) catch {};
                } else |_| {}
            } else |_| {}
        }

        if (all_addrs.items.len == 0) {
            return .{ .err = error.DNSResolutionFailed };
        }

        const addrs = self.allocator.dupe(net.Address, all_addrs.items) catch {
            return .{ .err = error.OutOfMemory };
        };
        return .{ .ok = addrs };
    }

    fn filterAddresses(self: *Self, addrs: []const net.Address, family: AddressFamily, order: AddressOrder) []const net.Address {
        _ = self;
        var ipv4 = std.ArrayList(net.Address).empty;
        var ipv6 = std.ArrayList(net.Address).empty;
        defer ipv4.deinit(std.heap.page_allocator);
        defer ipv6.deinit(std.heap.page_allocator);

        for (addrs) |addr| {
            if (addr.any.family == std.posix.AF.INET) {
                ipv4.append(std.heap.page_allocator, addr) catch continue;
            } else if (addr.any.family == std.posix.AF.INET6) {
                ipv6.append(std.heap.page_allocator, addr) catch continue;
            }
        }

        switch (family) {
            .any => {},
            .ipv4_only => {
                ipv6.clearRetainingCapacity();
            },
            .ipv6_only => {
                ipv4.clearRetainingCapacity();
            },
        }

        switch (order) {
            .system => {
                ipv4.appendSlice(std.heap.page_allocator, ipv6.items) catch {};
                return ipv4.items;
            },
            .ipv4_preferred => {
                ipv4.appendSlice(std.heap.page_allocator, ipv6.items) catch {};
                return ipv4.items;
            },
            .ipv6_preferred => {
                ipv6.appendSlice(std.heap.page_allocator, ipv4.items) catch {};
                return ipv6.items;
            },
        }
    }
};

fn dnsTestWorker(resolver: *DNSResolver, thread_id: u32) void {
    for (0..50) |i| {
        const name = std.fmt.allocPrint(
            std.heap.page_allocator,
            "thread{d}-host{d}.com",
            .{ thread_id, i },
        ) catch continue;
        defer std.heap.page_allocator.free(name);

        _ = resolver.resolve(name, .{}) catch {};
        resolver.invalidate(name);
    }
}

test "DNSConfig defaults" {
    const cfg = DNSConfig{};
    try std.testing.expectEqual(@as(i64, 60_000), cfg.positive_ttl_ms);
    try std.testing.expectEqual(@as(i64, 5_000), cfg.negative_ttl_ms);
    try std.testing.expectEqual(@as(u32, 1024), cfg.max_cache_entries);
    try std.testing.expectEqual(AddressFamily.any, cfg.address_family);
    try std.testing.expectEqual(AddressOrder.system, cfg.address_order);
    try std.testing.expect(cfg.cache_enabled);
    try std.testing.expect(cfg.dedup_enabled);
}

test "DNSResolution ok/failed" {
    const allocator = std.testing.allocator;
    const addrs = try allocator.alloc(net.Address, 1);
    addrs[0] = net.Address.initIp4(.{ 8, 8, 8, 8 }, 80);

    var res = DNSResolution{
        .hostname = "example.com",
        .addresses = addrs,
        .allocator = allocator,
    };
    try std.testing.expect(res.ok());
    res.deinit();

    var fail = DNSResolution{
        .hostname = "bad.host",
        .addresses = &.{},
        .failed = true,
        .allocator = allocator,
    };
    try std.testing.expect(!fail.ok());
}

test "DNSStats hitRate" {
    var stats = DNSStats{};
    try std.testing.expectEqual(@as(f64, 0.0), stats.hitRate());
    stats.hits = 7;
    stats.misses = 3;
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), stats.hitRate(), 0.001);
}

test "DNSCache init and deinit" {
    var cache = DNSCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    try std.testing.expectEqual(@as(u32, 0), cache.count());
}

test "DNSCache clear" {
    var cache = DNSCache.init(std.testing.allocator, .{});
    defer cache.deinit();

    const key1 = try std.testing.allocator.dupe(u8, "example1.com");
    const addrs1 = try std.testing.allocator.alloc(net.Address, 1);
    addrs1[0] = net.Address.initIp4(.{ 1, 2, 3, 4 }, 80);
    cache.entries.put(std.testing.allocator, key1, .{
        .addresses = addrs1,
        .created_at_ms = common.nowMillis(),
        .ttl_ms = 60_000,
    }) catch {
        std.testing.allocator.free(key1);
        std.testing.allocator.free(addrs1);
    };

    try std.testing.expectEqual(@as(u32, 1), cache.count());
    cache.clear();
    try std.testing.expectEqual(@as(u32, 0), cache.count());
}

test "DNSCache evictExpired" {
    var cache = DNSCache.init(std.testing.allocator, .{});
    defer cache.deinit();

    const key1 = try std.testing.allocator.dupe(u8, "expired.com");
    const addrs1 = try std.testing.allocator.alloc(net.Address, 1);
    addrs1[0] = net.Address.initIp4(.{ 1, 2, 3, 4 }, 80);
    cache.entries.put(std.testing.allocator, key1, .{
        .addresses = addrs1,
        .created_at_ms = 0,
        .ttl_ms = 1,
    }) catch {
        std.testing.allocator.free(key1);
        std.testing.allocator.free(addrs1);
    };

    const key2 = try std.testing.allocator.dupe(u8, "valid.com");
    const addrs2 = try std.testing.allocator.alloc(net.Address, 1);
    addrs2[0] = net.Address.initIp4(.{ 5, 6, 7, 8 }, 80);
    cache.entries.put(std.testing.allocator, key2, .{
        .addresses = addrs2,
        .created_at_ms = common.nowMillis(),
        .ttl_ms = 60_000,
    }) catch {
        std.testing.allocator.free(key2);
        std.testing.allocator.free(addrs2);
    };

    try std.testing.expectEqual(@as(u32, 2), cache.count());
    cache.evictExpired();
    try std.testing.expectEqual(@as(u32, 1), cache.count());
}

test "DNSCache max_entries LRU eviction" {
    var cache = DNSCache.init(std.testing.allocator, .{ .max_cache_entries = 2 });
    defer cache.deinit();

    for (0..2) |i| {
        const key = try std.fmt.allocPrint(std.testing.allocator, "host{d}.com", .{i});
        const addrs = try std.testing.allocator.alloc(net.Address, 1);
        addrs[0] = net.Address.initIp4(.{ 1, 0, 0, @intCast(i) }, 80);
        cache.entries.put(std.testing.allocator, key, .{
            .addresses = addrs,
            .created_at_ms = common.nowMillis(),
            .ttl_ms = 60_000,
        }) catch {
            std.testing.allocator.free(key);
            std.testing.allocator.free(addrs);
        };
        const lru_key = try std.testing.allocator.dupe(u8, key);
        cache.lru_order.append(std.testing.allocator, lru_key) catch {
            std.testing.allocator.free(lru_key);
        };
    }

    try std.testing.expectEqual(@as(u32, 2), cache.count());

    const key_new = try std.testing.allocator.dupe(u8, "newhost.com");
    const addrs_new = try std.testing.allocator.alloc(net.Address, 1);
    addrs_new[0] = net.Address.initIp4(.{ 9, 9, 9, 9 }, 80);
    cache.evictIfNeeded();
    cache.entries.put(std.testing.allocator, key_new, .{
        .addresses = addrs_new,
        .created_at_ms = common.nowMillis(),
        .ttl_ms = 60_000,
    }) catch {
        std.testing.allocator.free(key_new);
        std.testing.allocator.free(addrs_new);
    };

    try std.testing.expect(cache.count() <= 2);
}

test "DNSCache invalidate" {
    var cache = DNSCache.init(std.testing.allocator, .{});
    defer cache.deinit();

    const key = try std.testing.allocator.dupe(u8, "example.com");
    const addrs = try std.testing.allocator.alloc(net.Address, 1);
    addrs[0] = net.Address.initIp4(.{ 1, 2, 3, 4 }, 80);
    cache.entries.put(std.testing.allocator, key, .{
        .addresses = addrs,
        .created_at_ms = common.nowMillis(),
        .ttl_ms = 60_000,
    }) catch {
        std.testing.allocator.free(key);
        std.testing.allocator.free(addrs);
    };

    try std.testing.expectEqual(@as(u32, 1), cache.count());
    cache.invalidate("example.com");
    try std.testing.expectEqual(@as(u32, 0), cache.count());
}

test "DNSCache negative cache" {
    var cache = DNSCache.init(std.testing.allocator, .{ .negative_ttl_ms = 1000 });
    defer cache.deinit();

    cache.cacheNegative("nonexistent.host");
    try std.testing.expectEqual(@as(u32, 1), cache.count());
    try std.testing.expectEqual(@as(u64, 1), cache.stats.failures);
}

test "DNSResolver init and deinit" {
    var resolver = DNSResolver.init(std.testing.allocator, .{});
    defer resolver.deinit();
}

test "DNSResolver resolve IP literal" {
    var resolver = DNSResolver.init(std.testing.allocator, .{ .cache_enabled = false });
    defer resolver.deinit();

    var res = try resolver.resolve("127.0.0.1", .{ .port = 80 });
    defer res.deinit();
    try std.testing.expect(res.ok());
    try std.testing.expectEqual(@as(usize, 1), res.addresses.len);

    var res6 = try resolver.resolve("::1", .{ .port = 443 });
    defer res6.deinit();
    try std.testing.expect(res6.ok());
    try std.testing.expectEqual(@as(usize, 1), res6.addresses.len);
}

test "DNSResolver resolveAll IP literal" {
    var resolver = DNSResolver.init(std.testing.allocator, .{ .cache_enabled = false });
    defer resolver.deinit();

    var res = try resolver.resolveAll("10.0.0.1", .{ .port = 8080 });
    defer res.deinit();
    try std.testing.expect(res.ok());
    try std.testing.expectEqual(@as(usize, 1), res.addresses.len);
}

test "AddressFamily filtering" {
    var resolver = DNSResolver.init(std.testing.allocator, .{});
    defer resolver.deinit();

    var addrs = [_]net.Address{
        net.Address.initIp4(.{ 1, 2, 3, 4 }, 80),
        net.Address.initIp6(.{ 0x20, 0x01, 0xdb, 0x88, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0),
        net.Address.initIp4(.{ 5, 6, 7, 8 }, 80),
    };

    const any_filtered = resolver.filterAddresses(&addrs, .any, .system);
    try std.testing.expectEqual(@as(usize, 3), any_filtered.len);

    const v4_filtered = resolver.filterAddresses(&addrs, .ipv4_only, .system);
    try std.testing.expectEqual(@as(usize, 2), v4_filtered.len);

    const v6_filtered = resolver.filterAddresses(&addrs, .ipv6_only, .system);
    try std.testing.expectEqual(@as(usize, 1), v6_filtered.len);
}

test "AddressOrder" {
    var resolver = DNSResolver.init(std.testing.allocator, .{});
    defer resolver.deinit();

    var addrs = [_]net.Address{
        net.Address.initIp4(.{ 1, 2, 3, 4 }, 80),
        net.Address.initIp6(.{ 0x20, 0x01, 0xdb, 0x88, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 80, 0, 0),
    };

    const v4_pref = resolver.filterAddresses(&addrs, .any, .ipv4_preferred);
    try std.testing.expect(v4_pref.len >= 2);

    const v6_pref = resolver.filterAddresses(&addrs, .any, .ipv6_preferred);
    try std.testing.expect(v6_pref.len >= 2);
}

test "DNSCache thread safety" {
    var resolver = DNSResolver.init(std.testing.allocator, .{ .cache_enabled = true, .max_cache_entries = 100 });
    defer resolver.deinit();

    var threads: [4]std.Thread = undefined;
    for (0..4) |t| {
        threads[t] = std.Thread.spawn(.{}, dnsTestWorker, .{ &resolver, @as(u32, @intCast(t)) }) catch continue;
    }
    for (threads) |t| {
        t.join();
    }

    const count = resolver.cache.count();
    try std.testing.expect(count <= 100);
}

test "DNSResolver getStats" {
    var resolver = DNSResolver.init(std.testing.allocator, .{});
    defer resolver.deinit();

    var res = try resolver.resolve("127.0.0.1", .{});
    defer res.deinit();

    const stats = resolver.getStats();
    try std.testing.expect(stats.literal_hits > 0);
}

test "encodeDnsName basic" {
    var buf: [256]u8 = undefined;
    const result = try encodeDnsName("example.com", &buf);
    try std.testing.expectEqual(@as(usize, 13), result.len);
    try std.testing.expectEqual(@as(u8, 7), buf[0]);
    try std.testing.expectEqualStrings("example", buf[1..8]);
    try std.testing.expectEqual(@as(u8, 3), buf[8]);
    try std.testing.expectEqualStrings("com", buf[9..12]);
    try std.testing.expectEqual(@as(u8, 0), buf[12]);
}

test "decodeDnsName basic" {
    var buf: [256]u8 = undefined;
    const result = try encodeDnsName("example.com", &buf);

    var offset: usize = 0;
    var out: [256]u8 = undefined;
    const name_len = try decodeDnsName(buf[0..result.len], &offset, &out);
    try std.testing.expectEqualStrings("example.com", out[0..name_len]);
}

test "buildDnsQuery header" {
    var buf: [512]u8 = undefined;
    const len = try buildDnsQuery("example.com", .A, false, &buf);
    try std.testing.expect(len >= 12);

    const flags = getU16(buf[2..4]);
    try std.testing.expect((flags & (1 << 8)) != 0); // RD set

    const qdcount = getU16(buf[4..6]);
    try std.testing.expectEqual(@as(u16, 1), qdcount);

    const ancount = getU16(buf[6..8]);
    try std.testing.expectEqual(@as(u16, 0), ancount);
}

test "parseDnsMessage header" {
    var buf: [256]u8 = undefined;
    const len = try buildDnsQuery("test.com", .A, false, &buf);

    var msg = try parseDnsMessage(buf[0..len], std.testing.allocator);
    defer msg.deinit();

    try std.testing.expectEqual(@as(u16, 1), msg.header.qdcount);
    try std.testing.expectEqual(@as(u16, 0), msg.header.ancount);
    try std.testing.expectEqual(@as(usize, 1), msg.questions.len);
    try std.testing.expectEqualStrings("test.com", msg.questions[0].name);
    try std.testing.expectEqual(DnsRecordType.A, msg.questions[0].qtype);
}
