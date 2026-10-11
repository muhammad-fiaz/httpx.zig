//! Resource dependency graph for targeted invalidation.
//!
//! Tracks edges like `profile.html -> base.html` (dependent -> dependency)
//! discovered from Tree-sitter structural analysis (template extends and
//! includes). Given a changed file, computes the full affected set:
//! the file itself plus every transitive dependent. This graph is the
//! watcher's filesystem-level index and is intentionally separate from
//! the template compilation cache (`web/templates/cache.zig`), which owns
//! compiled ASTs: the graph answers "what is affected", the cache answers
//! "what is stored".

const std = @import("std");
const Allocator = std.mem.Allocator;
const sync = @import("../../common/sync.zig");

pub const DependencyGraph = struct {
    allocator: Allocator,
    /// dependency -> set of dependents, e.g. "base.html" -> {"index.html"}.
    dependents: std.StringHashMap(std.StringHashMap(void)),
    mu: sync.Spinlock = .{},

    pub fn init(allocator: Allocator) DependencyGraph {
        return .{
            .allocator = allocator,
            .dependents = std.StringHashMap(std.StringHashMap(void)).init(allocator),
        };
    }

    pub fn deinit(self: *DependencyGraph) void {
        var it = self.dependents.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var inner = entry.value_ptr.*;
            var jt = inner.iterator();
            while (jt.next()) |j| self.allocator.free(j.key_ptr.*);
            inner.deinit();
        }
        self.dependents.deinit();
    }

    /// Records that `dependent` depends on `dependency`.
    pub fn addEdge(self: *DependencyGraph, dependent: []const u8, dependency: []const u8) !void {
        self.mu.lock();
        defer self.mu.unlock();
        const gop = try self.dependents.getOrPut(dependency);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, dependency);
            gop.value_ptr.* = std.StringHashMap(void).init(self.allocator);
        }
        errdefer {
            if (!gop.found_existing) {
                self.allocator.free(gop.key_ptr.*);
                gop.value_ptr.deinit();
                _ = self.dependents.remove(dependency);
            }
        }
        if (gop.value_ptr.contains(dependent)) return;
        const owned = try self.allocator.dupe(u8, dependent);
        errdefer self.allocator.free(owned);
        try gop.value_ptr.put(owned, {});
    }

    /// Replaces the outgoing edges of `path` (its own dependencies) with a
    /// fresh set, keeping edges where others depend on it. Used when a
    /// file's content changes: dependents stay valid while dependencies
    /// get re-extracted from the new source.
    pub fn setDependencies(self: *DependencyGraph, path: []const u8, deps: []const []const u8) !void {
        self.mu.lock();
        defer self.mu.unlock();
        var it = self.dependents.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.fetchRemove(path)) |kv| {
                self.allocator.free(kv.key);
            }
        }
        for (deps) |dep| {
            const gop = try self.dependents.getOrPut(dep);
            if (!gop.found_existing) {
                gop.key_ptr.* = try self.allocator.dupe(u8, dep);
                gop.value_ptr.* = std.StringHashMap(void).init(self.allocator);
            }
            errdefer {
                if (!gop.found_existing) {
                    self.allocator.free(gop.key_ptr.*);
                    gop.value_ptr.deinit();
                    _ = self.dependents.remove(dep);
                }
            }
            if (gop.value_ptr.contains(path)) continue;
            const owned = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(owned);
            try gop.value_ptr.put(owned, {});
        }
    }

    /// Removes every edge touching `path` (deleted/renamed files).
    pub fn removeNode(self: *DependencyGraph, path: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.dependents.fetchRemove(path)) |kv| {
            self.allocator.free(kv.key);
            var inner = kv.value;
            var it = inner.iterator();
            while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
            inner.deinit();
        }
        var it = self.dependents.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.fetchRemove(path)) |kv| {
                self.allocator.free(kv.key);
            }
        }
    }

    /// Computes the affected set for a changed file: itself plus all
    /// transitive dependents. Caller owns the returned slice.
    pub fn affectedSet(self: *DependencyGraph, allocator: Allocator, path: []const u8) ![][]const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();
        var queue = std.ArrayList([]const u8).empty;
        defer queue.deinit(allocator);
        var out = std.ArrayList([]const u8).empty;
        errdefer {
            for (out.items) |s| allocator.free(s);
            out.deinit(allocator);
        }
        try queue.append(allocator, path);
        while (queue.items.len > 0) {
            const cur = queue.pop().?;
            if (seen.contains(cur)) continue;
            try seen.put(cur, {});
            try out.append(allocator, try allocator.dupe(u8, cur));
            if (self.dependents.get(cur)) |deps| {
                var it = deps.iterator();
                while (it.next()) |entry| {
                    if (!seen.contains(entry.key_ptr.*)) {
                        try queue.append(allocator, entry.key_ptr.*);
                    }
                }
            }
        }
        return out.toOwnedSlice(allocator);
    }
};

test "dependency graph tracks transitive dependents" {
    const a = std.testing.allocator;
    var g = DependencyGraph.init(a);
    defer g.deinit();
    try g.addEdge("layout.html", "base.html");
    try g.addEdge("profile.html", "layout.html");
    try g.addEdge("index.html", "base.html");
    try g.addEdge("other.html", "unrelated.html");

    const affected = try g.affectedSet(a, "base.html");
    defer {
        for (affected) |s| a.free(s);
        a.free(affected);
    }
    try std.testing.expectEqual(@as(usize, 4), affected.len);

    g.removeNode("layout.html");
    const affected2 = try g.affectedSet(a, "base.html");
    defer {
        for (affected2) |s| a.free(s);
        a.free(affected2);
    }
    try std.testing.expectEqual(@as(usize, 2), affected2.len);
}
