//! Hot-reload orchestration: classify → analyze → invalidate → notify.
//!
//! Filesystem events arrive from backend.zig. This module decides the
//! reload level per file kind, runs Tree-sitter incremental analysis for
//! structured sources (templates, HTML, JSON), updates the dependency
//! graph, invalidates exactly the affected cache entries, and emits an
//! internal reload event for live-reload fan-out. It never watches files
//! itself and never renders templates: compilation stays in
//! `web/templates/cache.zig`, rendering in `web/templates/renderer.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ts = @import("treesitter");
const events = @import("events.zig");
const dependency = @import("dependency.zig");
const template_parser = @import("../templates/parser.zig");
const html_mod = @import("../../parsing/html.zig");
const logging = @import("../../common/logging.zig");
const metrics_mod = @import("../metrics/registry.zig");

/// Counters reusing HTTPX's metrics primitives (no new metrics system).
pub const WatcherMetrics = struct {
    events: metrics_mod.Counter = .{},
    reloads: metrics_mod.Counter = .{},
    templateReloads: metrics_mod.Counter = .{},
    invalidations: metrics_mod.Counter = .{},
    incrementalParses: metrics_mod.Counter = .{},
    fullParses: metrics_mod.Counter = .{},
    errors: metrics_mod.Counter = .{},
};

/// Internal reload bus event (see also `onReload` below).
pub const ReloadKind = enum {
    templateChanged,
    assetChanged,
    configChanged,
    sourceChanged,
    serverRestartRequired,
};

pub const ReloadEvent = struct {
    kind: ReloadKind,
    path: []const u8,
    /// Affected resources including the changed file itself (owned).
    affected: []const []const u8 = &.{},
    changed_ranges: usize = 0,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ReloadEvent) void {
        self.arena.deinit();
    }
};

pub const ReloadHandler = *const fn (event: *const ReloadEvent, user_data: ?*anyopaque) void;

fn editPoint(source: []const u8, offset: usize) ts.Point {
    const clamped = @min(offset, source.len);
    var row: u32 = 0;
    var col: u32 = 0;
    for (source[0..clamped]) |b| {
        if (b == '\n') {
            row += 1;
            col = 0;
        } else {
            col += 1;
        }
    }
    return .{ .row = row, .column = col };
}

/// Tree-sitter incremental reparse for a whole-buffer replacement under
/// the given language. Returns structurally changed range count.
pub fn incrementalChangedRanges(allocator: Allocator, language: ts.Language, old_src: []const u8, new_src: []const u8) !usize {
    var parser = ts.Parser.init(allocator);
    defer parser.deinit();
    try parser.setLanguage(language);
    var old_tree = try parser.parseString(old_src);
    defer old_tree.deinit();
    const edit = ts.InputEdit{
        .start_byte = 0,
        .old_end_byte = @intCast(old_src.len),
        .new_end_byte = @intCast(new_src.len),
        .start_point = .{ .row = 0, .column = 0 },
        .old_end_point = editPoint(old_src, old_src.len),
        .new_end_point = editPoint(new_src, new_src.len),
    };
    var new_tree = try parser.parse(&old_tree, edit, new_src);
    defer new_tree.deinit();
    const ranges = try ts.getChangedRanges(allocator, &old_tree, &new_tree);
    defer ts.freeChangedRanges(allocator, ranges);
    return ranges.len;
}

pub const TemplateChange = struct {
    changed_ranges: usize,
    has_error: bool,
    extends_path: ?[]const u8 = null,
    includes: []const []const u8 = &.{},
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *TemplateChange) void {
        self.arena.deinit();
    }
};

/// Template change analysis: incremental syntax reparse for changed ranges
/// plus dependency extraction (extends/include) for targeted invalidation.
pub fn analyzeTemplateChange(allocator: Allocator, old_src: []const u8, new_src: []const u8) !TemplateChange {
    const changed = try incrementalChangedRanges(allocator, template_parser.templateLanguage, old_src, new_src);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var parser = template_parser.Parser.init(a, "<watch>", new_src);
    var ast = parser.parse() catch {
        return .{ .changed_ranges = changed, .has_error = true, .arena = arena };
    };
    defer ast.deinit();
    var change = TemplateChange{ .changed_ranges = changed, .has_error = false, .arena = arena };
    if (ast.extendsPath) |ext| change.extends_path = try a.dupe(u8, ext);
    if (ast.includes.len > 0) {
        const incs = try a.alloc([]const u8, ast.includes.len);
        for (ast.includes, 0..) |inc, i| incs[i] = try a.dupe(u8, inc);
        change.includes = incs;
    }
    return change;
}

/// HTML change analysis through the Tree-sitter HTML grammar.
pub fn analyzeHtmlChange(allocator: Allocator, old_src: []const u8, new_src: []const u8) !usize {
    return incrementalChangedRanges(allocator, html_mod.htmlLanguage, old_src, new_src);
}

pub const Reloader = struct {
    allocator: Allocator,
    logger: ?*const logging.Logger = null,
    metrics: *WatcherMetrics,
    onReload: ?ReloadHandler = null,
    onReloadData: ?*anyopaque = null,

    pub fn init(allocator: Allocator, metrics: *WatcherMetrics) Reloader {
        return .{ .allocator = allocator, .metrics = metrics };
    }

    fn log(self: *const Reloader, comptime fmt: []const u8, args: anytype) void {
        if (self.logger) |l| l.log(.info, "watcher", fmt, args);
    }

    /// Full hot-reload pipeline for a template file change. Analyzes the
    /// new source, refreshes graph edges, invalidates exactly the affected
    /// cache entries, and emits a reload event. Returns the event (owned).
    pub fn handleTemplateChange(
        self: *Reloader,
        engine: anytype,
        graph: *dependency.DependencyGraph,
        path: []const u8,
        old_src: []const u8,
        new_src: []const u8,
    ) !ReloadEvent {
        self.metrics.events.inc();
        var change = analyzeTemplateChange(self.allocator, old_src, new_src) catch |err| {
            self.metrics.errors.inc();
            return err;
        };
        defer change.deinit();
        self.metrics.incrementalParses.inc();

        if (change.has_error) {
            self.log("template {s} has syntax errors; invalidating without dependency update", .{path});
        } else {
            var deps = std.ArrayList([]const u8).empty;
            defer deps.deinit(self.allocator);
            if (change.extends_path) |ext| deps.append(self.allocator, ext) catch {};
            for (change.includes) |inc| deps.append(self.allocator, inc) catch {};
            graph.setDependencies(path, deps.items) catch {};
        }

        const affected = try graph.affectedSet(self.allocator, path);
        errdefer {
            for (affected) |s| self.allocator.free(s);
            self.allocator.free(affected);
        }
        for (affected) |victim| engine.invalidate(victim);
        self.metrics.invalidations.inc();
        self.metrics.templateReloads.inc();
        self.metrics.reloads.inc();
        self.log("reparsed {s} ({d} changed ranges); invalidated {d} template(s)", .{ path, change.changed_ranges, affected.len });

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const owned_affected = try arena.allocator().alloc([]const u8, affected.len);
        for (affected, 0..) |s, i| owned_affected[i] = try arena.allocator().dupe(u8, s);
        for (affected) |s| self.allocator.free(s);
        self.allocator.free(affected);
        var event = ReloadEvent{
            .kind = .templateChanged,
            .path = path,
            .affected = owned_affected,
            .changed_ranges = change.changed_ranges,
            .arena = arena,
        };
        if (self.onReload) |cb| cb(&event, self.onReloadData);
        return event;
    }

    /// Handles template deletion: drops graph edges and cache entries so no
    /// stale content keeps serving; the next render fails loudly.
    pub fn handleDelete(
        self: *Reloader,
        engine: anytype,
        graph: *dependency.DependencyGraph,
        path: []const u8,
    ) !ReloadEvent {
        self.metrics.events.inc();
        graph.removeNode(path);
        engine.invalidate(path);
        self.metrics.invalidations.inc();
        self.metrics.reloads.inc();
        self.log("removed deleted template {s}", .{path});
        const affected = try graph.affectedSet(self.allocator, path);
        errdefer {
            for (affected) |s| self.allocator.free(s);
            self.allocator.free(affected);
        }
        for (affected) |victim| {
            if (!std.mem.eql(u8, victim, path)) engine.invalidate(victim);
        }
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const owned_affected = try arena.allocator().alloc([]const u8, affected.len);
        for (affected, 0..) |s, i| owned_affected[i] = try arena.allocator().dupe(u8, s);
        for (affected) |s| self.allocator.free(s);
        self.allocator.free(affected);
        var event = ReloadEvent{
            .kind = .templateChanged,
            .path = path,
            .affected = owned_affected,
            .changed_ranges = 0,
            .arena = arena,
        };
        if (self.onReload) |cb| cb(&event, self.onReloadData);
        return event;
    }

    /// Routes a renamed template through delete+create semantics.
    pub fn handleRename(
        self: *Reloader,
        engine: anytype,
        graph: *dependency.DependencyGraph,
        old_path: []const u8,
        new_path: []const u8,
        new_src: []const u8,
    ) !ReloadEvent {
        var del = try self.handleDelete(engine, graph, old_path);
        defer del.deinit();
        return self.handleTemplateChange(engine, graph, new_path, "", new_src);
    }

    /// Static assets reload directly with no syntax analysis.
    pub fn handleAsset(self: *Reloader, path: []const u8) !ReloadEvent {
        self.metrics.events.inc();
        self.metrics.reloads.inc();
        self.log("reloaded asset {s}", .{path});
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const owned = try arena.allocator().alloc([]const u8, 1);
        owned[0] = try arena.allocator().dupe(u8, path);
        var event = ReloadEvent{ .kind = .assetChanged, .path = path, .affected = owned, .arena = arena };
        if (self.onReload) |cb| cb(&event, self.onReloadData);
        return event;
    }

    /// Zig sources can never hot-swap: report a controlled restart need.
    pub fn handleSource(self: *Reloader, path: []const u8) !ReloadEvent {
        self.metrics.events.inc();
        self.log("source {s} changed; restart required", .{path});
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const owned = try arena.allocator().alloc([]const u8, 1);
        owned[0] = try arena.allocator().dupe(u8, path);
        var event = ReloadEvent{ .kind = .serverRestartRequired, .path = path, .affected = owned, .arena = arena };
        if (self.onReload) |cb| cb(&event, self.onReloadData);
        return event;
    }
};

test "incremental template analysis detects changes and dependencies" {
    const a = std.testing.allocator;
    const old = "{% extends \"base.html\" %}<h1>{{ title }}</h1>";
    const new = "{% extends \"base.html\" %}<h1>{{ title }}</h1>{% include \"foot.html\" %}";
    var change = try analyzeTemplateChange(a, old, new);
    defer change.deinit();
    try std.testing.expect(!change.has_error);
    try std.testing.expect(change.changed_ranges > 0);
    try std.testing.expectEqualStrings("base.html", change.extends_path.?);
    try std.testing.expectEqual(@as(usize, 1), change.includes.len);
    try std.testing.expectEqualStrings("foot.html", change.includes[0]);

    var same = try analyzeTemplateChange(a, old, old);
    defer same.deinit();
    try std.testing.expect(!same.has_error);
    try std.testing.expectEqual(@as(usize, 0), same.changed_ranges);

    var broken = try analyzeTemplateChange(a, old, "{% if unclosed %}");
    defer broken.deinit();
    try std.testing.expect(broken.has_error);
}

test "incremental html analysis detects structural changes" {
    const a = std.testing.allocator;
    const changed = try analyzeHtmlChange(a, "<p>one</p>", "<p>one</p><p>two</p>");
    try std.testing.expect(changed > 0);
    const same = try analyzeHtmlChange(a, "<p>one</p>", "<p>one</p>");
    try std.testing.expectEqual(@as(usize, 0), same);
}

test "reloader invalidates exactly the affected templates" {
    const a = std.testing.allocator;
    const FakeEngine = struct {
        allocator: Allocator,
        invalidated: std.ArrayList([]const u8) = .empty,
        fn invalidate(self: *@This(), path: []const u8) void {
            self.invalidated.append(self.allocator, path) catch {};
        }
    };
    var engine = FakeEngine{ .allocator = a };
    defer engine.invalidated.deinit(a);
    var metrics = WatcherMetrics{};
    var reloader = Reloader.init(a, &metrics);
    var graph = dependency.DependencyGraph.init(a);
    defer graph.deinit();
    try graph.addEdge("index.html", "base.html");

    var ev = try reloader.handleTemplateChange(&engine, &graph, "base.html", "<h1>A</h1>", "<h1>A</h1><p>New</p>");
    defer ev.deinit();
    try std.testing.expect(ev.changed_ranges > 0);
    try std.testing.expectEqual(@as(usize, 2), ev.affected.len);
    try std.testing.expectEqual(@as(usize, 2), engine.invalidated.items.len);
    try std.testing.expectEqual(@as(u64, 1), metrics.templateReloads.get());

    var del = try reloader.handleDelete(&engine, &graph, "base.html");
    defer del.deinit();
    try std.testing.expectEqual(@as(usize, 3), engine.invalidated.items.len);
}
