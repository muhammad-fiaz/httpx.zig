//! Small allocation-free matcher for HTTP Accept media ranges.

const std = @import("std");

/// Reports whether an Accept field permits `mediaType`.
///
/// The most specific matching range wins; therefore an explicit `q=0` for a
/// media type overrides a broader wildcard. Malformed ranges and invalid q
/// values do not permit a representation.
pub fn accepts(accept: []const u8, mediaType: []const u8) bool {
    const candidate = splitMediaType(mediaType) orelse return false;
    var best_specificity: u2 = 0;
    var best_quality: i32 = -1;
    var found = false;

    var ranges = std.mem.splitScalar(u8, accept, ',');
    while (ranges.next()) |raw_range| {
        const range = std.mem.trim(u8, raw_range, " \t\r\n");
        var parameters = std.mem.splitScalar(u8, range, ';');
        const raw_type = std.mem.trim(u8, parameters.next() orelse continue, " \t\r\n");
        const parsed = splitMediaType(raw_type) orelse continue;
        const specificity = matchSpecificity(parsed, candidate) orelse continue;

        var quality: u16 = 1000;
        var valid_quality = true;
        while (parameters.next()) |parameter| {
            const pair = std.mem.trim(u8, parameter, " \t\r\n");
            const equals = std.mem.indexOfScalar(u8, pair, '=') orelse {
                if (std.ascii.eqlIgnoreCase(pair, "q")) valid_quality = false;
                continue;
            };
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, pair[0..equals], " \t"), "q")) continue;
            const value = std.mem.trim(u8, pair[equals + 1 ..], " \t");
            quality = parseQuality(value) orelse {
                valid_quality = false;
                break;
            };
            break;
        }
        if (!valid_quality) quality = 0;
        if (!found or specificity > best_specificity or (specificity == best_specificity and @as(i32, quality) > best_quality)) {
            found = true;
            best_specificity = specificity;
            best_quality = quality;
        }
    }
    return found and best_quality > 0;
}

fn parseQuality(value: []const u8) ?u16 {
    if (value.len == 0) return null;
    if (value[0] == '1') {
        if (value.len == 1) return 1000;
        if (value[1] != '.' or value.len > 5) return null;
        for (value[2..]) |digit| if (digit != '0') return null;
        return 1000;
    }
    if (value[0] != '0') return null;
    if (value.len == 1) return 0;
    if (value[1] != '.' or value.len > 5) return null;
    var quality: u16 = 0;
    var place: u16 = 100;
    for (value[2..]) |digit| {
        if (!std.ascii.isDigit(digit)) return null;
        quality += @as(u16, digit - '0') * place;
        place /= 10;
    }
    return quality;
}

const MediaType = struct { major: []const u8, minor: []const u8 };

fn splitMediaType(value: []const u8) ?MediaType {
    const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const trimmed = std.mem.trim(u8, value[0..end], " \t\r\n");
    const slash = std.mem.indexOfScalar(u8, trimmed, '/') orelse return null;
    if (slash == 0 or slash + 1 >= trimmed.len or std.mem.indexOfScalar(u8, trimmed[slash + 1 ..], '/') != null) return null;
    const major = trimmed[0..slash];
    const minor = trimmed[slash + 1 ..];
    if (!validToken(major) and !std.mem.eql(u8, major, "*")) return null;
    if (!validToken(minor) and !std.mem.eql(u8, minor, "*")) return null;
    if (std.mem.eql(u8, major, "*") and !std.mem.eql(u8, minor, "*")) return null;
    return .{ .major = major, .minor = minor };
}

fn validToken(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        if (std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) == null) return false;
    }
    return true;
}

fn matchSpecificity(range: MediaType, candidate: MediaType) ?u2 {
    const major_wild = std.mem.eql(u8, range.major, "*");
    const minor_wild = std.mem.eql(u8, range.minor, "*");
    if (!major_wild and !std.ascii.eqlIgnoreCase(range.major, candidate.major)) return null;
    if (!minor_wild and !std.ascii.eqlIgnoreCase(range.minor, candidate.minor)) return null;
    if (major_wild) return 0;
    if (minor_wild) return 1;
    return 2;
}

test "Accept matching handles case, wildcards, quality, and specificity" {
    const testing = std.testing;
    try testing.expect(accepts("text/html", "TEXT/HTML; charset=utf-8"));
    try testing.expect(accepts("text/*", "text/html"));
    try testing.expect(accepts("*/*", "application/json"));
    try testing.expect(!accepts("application/json;q=0", "application/json"));
    try testing.expect(!accepts("text/html;q=0, */*;q=1", "text/html"));
    try testing.expect(accepts("text/html;q=0, */*;q=1", "application/json"));
    try testing.expect(!accepts("text/html;q=1.1", "text/html"));
    try testing.expect(!accepts("text/html;q=1e-1", "text/html"));
    try testing.expect(!accepts("text/html;q=0.0001", "text/html"));
    try testing.expect(!accepts("not a media type", "text/html"));
}
