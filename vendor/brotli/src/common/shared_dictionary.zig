//! Shared and compound dictionary support.
//!
//! Provides container structures for raw and compound dictionaries that can
//! be attached to the encoder and decoder to establish shared match contexts.

const std = @import("std");

/// Practical maximum number of prefix dictionary chunks.
pub const MAX_COMPOUND_DICTS: usize = 15;

/// Type tag for dictionary data attached to a shared dictionary instance.
pub const SharedDictionaryType = enum(u8) {
    raw = 0,
    serialized = 1,
};

/// A shared dictionary holding reference data across streams.
pub const SharedDictionary = struct {
    allocator: std.mem.Allocator,
    prefixes: [MAX_COMPOUND_DICTS][]const u8 = undefined,
    prefix_count: usize = 0,
    total_size: usize = 0,

    /// Initializes a new, empty shared dictionary instance.
    pub fn init(allocator: std.mem.Allocator) SharedDictionary {
        return .{
            .allocator = allocator,
            .prefix_count = 0,
            .total_size = 0,
        };
    }

    /// Releases any held resources (raw data is referenced, not owned).
    pub fn deinit(self: *SharedDictionary) void {
        self.clear();
    }

    /// Clears all attached dictionary chunks.
    pub fn clear(self: *SharedDictionary) void {
        self.prefix_count = 0;
        self.total_size = 0;
    }

    /// Attaches a dictionary chunk to the shared dictionary.
    /// Data is referenced (not copied) and must outlive the dictionary and any codec operations.
    pub fn attach(self: *SharedDictionary, dict_type: SharedDictionaryType, data: []const u8) bool {
        if (dict_type != .raw) return false;
        if (data.len == 0) return true; // soft no-op
        if (self.prefix_count >= MAX_COMPOUND_DICTS) return false;
        if (data.len > (1 << 24)) return false;
        if (self.total_size + data.len > (1 << 24)) return false;

        self.prefixes[self.prefix_count] = data;
        self.prefix_count += 1;
        self.total_size += data.len;
        return true;
    }

    /// Returns the number of chunks attached.
    pub fn numChunks(self: *const SharedDictionary) usize {
        return self.prefix_count;
    }

    /// Returns the chunk at `index`, or null if out of range.
    pub fn chunk(self: *const SharedDictionary, index: usize) ?[]const u8 {
        if (index >= self.prefix_count) return null;
        return self.prefixes[index];
    }

    /// Returns the combined size of all attached chunks in bytes.
    pub fn totalSize(self: *const SharedDictionary) usize {
        return self.total_size;
    }
};

test "shared dictionary attach and query" {
    var dict = SharedDictionary.init(std.testing.allocator);
    defer dict.deinit();

    try std.testing.expectEqual(@as(usize, 0), dict.numChunks());
    try std.testing.expectEqual(@as(usize, 0), dict.totalSize());

    const c1 = "sample prefix dictionary data";
    const c2 = "second prefix chunk";

    try std.testing.expect(dict.attach(.raw, c1));
    try std.testing.expect(dict.attach(.raw, c2));
    try std.testing.expectEqual(@as(usize, 2), dict.numChunks());
    try std.testing.expectEqual(c1.len + c2.len, dict.totalSize());
    try std.testing.expectEqualStrings(c1, dict.chunk(0).?);
    try std.testing.expectEqualStrings(c2, dict.chunk(1).?);
    try std.testing.expect(dict.chunk(2) == null);

    // Reject non-raw types
    try std.testing.expect(!dict.attach(.serialized, "invalid"));

    dict.clear();
    try std.testing.expectEqual(@as(usize, 0), dict.numChunks());
}
