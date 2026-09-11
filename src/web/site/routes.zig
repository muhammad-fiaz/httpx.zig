//! File-based route discovery: asset tree paths -> router patterns.
//!
//! Pure functions over logical file paths (no IO). The same builder feeds
//! filesystem walks and build-generated embedded manifests, so both modes
//! produce identical route structures.
//!
//! Rules (deterministic, documented):
//!   * Only `.html`/`.htm` files (ASCII case-insensitive) become pages;
//!     every other extension is skipped (assets belong to static serving).
//!   * `index` (configurable base name) files become their directory route:
//!     `dist/index.html` -> `/`, `dist/about/index.html` -> `/about`.
//!   * `[name]` segments become router `{name}` params, `[...name]` becomes
//!     a trailing `*name` wildcard (must be the final segment).
//!   * Every other segment is used byte-verbatim (case, `-`, `_`, dots and
//!     Unicode preserved); only the page extension is stripped. Filenames
//!     containing `{`, `}` or `*` outside dynamic syntax are rejected.
//!   * Clean URLs drop the extension (`/about/team`); extension URLs keep
//!     the on-disk form (`/about/team.html`). `UrlStyle` selects which are
//!     registered. Static segments needing percent-encoding additionally
//!     register an encoded alias route for the same file.
//!   * Route names default to the dotted clean path (`blog.hello-world`,
//!     root is `home`); explicit `CustomRoute.name` overrides.
//!   * Collisions (same final route from several files, including identical
//!     dynamic shapes) resolve by rank: custom > index.html > index.htm >
//!     stem.html > stem.htm, ties broken by smaller file path. A losing
//!     file loses all of its routes; every conflict is reported in
//!     `BuildResult.collisions`, never silently picked.

const std = @import("std");
const Allocator = std.mem.Allocator;
const uri = @import("../../common/uri.zig");

pub const UrlStyle = enum { clean, extension, both };

pub const FileRoute = struct {
    /// Logical file path, e.g. `blog/hello-world.html` (owned).
    file: []const u8,
    /// Router pattern and canonical clean route, e.g. `/blog/hello-world`
    /// (owned, root is `/`). Dynamic files carry router syntax here
    /// (`/users/{id}`, `/blog/*path`).
    route: []const u8,
    /// Deterministic name (`blog.hello-world`, root is `home`).
    name: []const u8,
    /// Extension URL (`/blog/hello-world.html`); null unless style has it.
    /// Only static pages have one; dynamic files serve clean routes only.
    extRoute: ?[]const u8,
    /// Encoded-alias routes for segments needing escaping (owned).
    aliases: [][]u8,
    /// True when the file is a directory index page.
    isIndex: bool,
    /// Collision precedence rank (lower wins); see module docs.
    rank: u8,
};

pub const Collision = struct {
    route: []const u8,
    winner: []const u8,
    loser: []const u8,
};

pub const CustomRoute = struct {
    file: []const u8,
    route: []const u8,
    name: ?[]const u8 = null,
};

pub const Options = struct {
    base: []const u8 = "/",
    urls: UrlStyle = .both,
    indexBase: []const u8 = "index",
    custom: []const CustomRoute = &.{},
};

const ShapeEntry = struct { shape: []u8, idx: usize };
const ShapeList = std.ArrayList(ShapeEntry);

pub const BuildResult = struct {
    routes: []FileRoute,
    collisions: []Collision,

    pub fn deinit(self: *BuildResult, allocator: Allocator) void {
        for (self.routes) |r| freeRoute(allocator, r);
        allocator.free(self.routes);
        for (self.collisions) |c| {
            allocator.free(c.route);
            allocator.free(c.winner);
            allocator.free(c.loser);
        }
        allocator.free(self.collisions);
    }
};

fn freeRoute(allocator: Allocator, r: FileRoute) void {
    allocator.free(r.file);
    allocator.free(r.route);
    allocator.free(r.name);
    if (r.extRoute) |e| allocator.free(e);
    for (r.aliases) |a| allocator.free(a);
    allocator.free(r.aliases);
}

fn isHtmlExt(ext: []const u8) bool {
    if (ext.len == 0 or ext[0] != '.') return false;
    if (ext.len == 4) return std.ascii.eqlIgnoreCase(ext[1..], "htm");
    if (ext.len == 5) return std.ascii.eqlIgnoreCase(ext[1..], "html");
    return false;
}

/// True when the file path ends in a page extension (pre-filter helper).
fn looksHtml(file: []const u8) bool {
    const base = if (std.mem.lastIndexOfScalar(u8, file, '/')) |s| file[s + 1 ..] else file;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return false;
    return isHtmlExt(base[dot..]);
}

fn validSegment(seg: []const u8) bool {
    if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
    if (std.mem.indexOfScalar(u8, seg, 0) != null) return false;
    if (std.mem.indexOfScalar(u8, seg, '\\') != null) return false;
    if (std.mem.indexOfScalar(u8, seg, '{') != null) return false;
    if (std.mem.indexOfScalar(u8, seg, '}') != null) return false;
    if (std.mem.indexOfScalar(u8, seg, '*') != null) return false;
    if (seg.len >= 2 and seg[1] == ':') return false;
    return true;
}

fn trimBase(base: []const u8) []const u8 {
    const b = if (base.len == 0) @as([]const u8, "/") else base;
    const trimmed = std.mem.trimEnd(u8, b, "/");
    return if (trimmed.len == 0) b[0..1] else trimmed;
}

fn joinBase(allocator: Allocator, base: []const u8, route: []const u8) ![]u8 {
    const bt = trimBase(base);
    var r = route;
    while (r.len > 1 and r[0] == '/') r = r[1..];
    if (std.mem.eql(u8, r, "/") or r.len == 0) return allocator.dupe(u8, bt);
    if (std.mem.eql(u8, bt, "/")) return std.fmt.allocPrint(allocator, "/{s}", .{r});
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ bt, r });
}

fn dottedName(allocator: Allocator, route: []const u8) ![]u8 {
    if (std.mem.eql(u8, route, "/")) return allocator.dupe(u8, "home");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, route, '/');
    var first = true;
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (!first) try out.append(allocator, '.');
        first = false;
        try out.appendSlice(allocator, seg);
    }
    return out.toOwnedSlice(allocator);
}

/// Pattern shape key for dynamic-conflict detection (`{x}` -> `{}`).
/// Builder-generated patterns are always brace-balanced by construction.
fn shapeKey(allocator: Allocator, pattern: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < pattern.len) {
        if (pattern[i] == '{') {
            if (std.mem.indexOfScalarPos(u8, pattern, i, '}')) |end| {
                try out.appendSlice(allocator, "{}");
                i = end + 1;
            } else {
                try out.appendSlice(allocator, pattern[i..]);
                break;
            }
        } else {
            try out.append(allocator, pattern[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn encodeSegment(allocator: Allocator, seg: []const u8) ![]u8 {
    var buf: [1024]u8 = undefined;
    if (seg.len * 3 <= buf.len) {
        return allocator.dupe(u8, try uri.percentEncode(&buf, seg));
    }
    const big = try allocator.alloc(u8, seg.len * 3);
    defer allocator.free(big);
    return allocator.dupe(u8, try uri.percentEncode(big, seg));
}

const ParsedFile = struct {
    /// Clean segments (borrowed slices into `file`).
    segments: std.ArrayList([]const u8),
    /// Router pattern segments (all owned).
    patterns: std.ArrayList([]const u8),
    isIndex: bool,
    rank: u8,
};

fn parseFile(
    allocator: Allocator,
    file: []const u8,
    indexBase: []const u8,
) error{ InvalidFilePath, OutOfMemory }!ParsedFile {
    var segments: std.ArrayList([]const u8) = .empty;
    errdefer segments.deinit(allocator);
    var patterns: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (patterns.items) |p| allocator.free(p);
        patterns.deinit(allocator);
    }

    var count: usize = 0;
    var it = std.mem.splitScalar(u8, file, '/');
    while (it.next()) |seg| {
        if (!validSegment(seg)) return error.InvalidFilePath;
        count += 1;
    }
    if (count == 0) return error.InvalidFilePath;

    it = std.mem.splitScalar(u8, file, '/');
    var idx: usize = 0;
    var is_index = false;
    var rank: u8 = 3;
    while (it.next()) |seg| {
        idx += 1;
        const last = idx == count;
        if (!last) {
            if (seg.len >= 2 and seg[0] == '[' and seg[seg.len - 1] == ']') {
                const inner = seg[1 .. seg.len - 1];
                if (inner.len == 0 or std.mem.startsWith(u8, inner, "...")) return error.InvalidFilePath;
                try segments.append(allocator, seg);
                try patterns.append(allocator, try std.fmt.allocPrint(allocator, "{{{s}}}", .{inner}));
            } else {
                try segments.append(allocator, seg);
                try patterns.append(allocator, try allocator.dupe(u8, seg));
            }
            continue;
        }
        const dot = std.mem.lastIndexOfScalar(u8, seg, '.') orelse return error.InvalidFilePath;
        const stem = seg[0..dot];
        const file_ext = seg[dot..];
        if (!isHtmlExt(file_ext)) return error.InvalidFilePath;
        const lower_htm = file_ext.len == 4;
        if (stem.len >= 2 and stem[0] == '[' and stem[stem.len - 1] == ']') {
            const inner = stem[1 .. stem.len - 1];
            if (std.mem.startsWith(u8, inner, "...")) {
                const pname = inner[3..];
                if (pname.len == 0) return error.InvalidFilePath;
                try segments.append(allocator, seg);
                try patterns.append(allocator, try std.fmt.allocPrint(allocator, "*{s}", .{pname}));
            } else {
                if (inner.len == 0) return error.InvalidFilePath;
                try segments.append(allocator, seg);
                try patterns.append(allocator, try std.fmt.allocPrint(allocator, "{{{s}}}", .{inner}));
            }
            rank = 5;
        } else {
            if (stem.len == 0) return error.InvalidFilePath;
            if (std.mem.eql(u8, stem, indexBase)) {
                is_index = true;
                rank = if (lower_htm) 2 else 1;
            } else {
                try segments.append(allocator, stem);
                try patterns.append(allocator, try allocator.dupe(u8, stem));
                rank = if (lower_htm) 4 else 3;
            }
        }
    }
    return .{ .segments = segments, .patterns = patterns, .isIndex = is_index, .rank = rank };
}

fn joinSlashed(allocator: Allocator, base: []const u8, segments: []const []const u8) ![]u8 {
    const bt = trimBase(base);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (!std.mem.eql(u8, bt, "/")) try out.appendSlice(allocator, bt);
    for (segments) |seg| {
        try out.append(allocator, '/');
        try out.appendSlice(allocator, seg);
    }
    if (out.items.len == 0) try out.append(allocator, '/');
    return out.toOwnedSlice(allocator);
}

const Pending = struct {
    file: []u8,
    clean: []u8,
    name: []u8,
    ext: ?[]u8,
    aliases: [][]u8,
    isIndex: bool,
    rank: u8,
    dynamic: bool,
};

fn freePending(allocator: Allocator, p: Pending) void {
    allocator.free(p.file);
    allocator.free(p.clean);
    allocator.free(p.name);
    if (p.ext) |e| allocator.free(e);
    for (p.aliases) |a| allocator.free(a);
    allocator.free(p.aliases);
}

/// Builds one owned candidate from a logical file path.
/// Returns null for skipped non-page files; errors loudly otherwise.
fn buildOne(allocator: Allocator, file: []const u8, options: Options, customs: *std.StringHashMap(CustomRoute)) !?Pending {
    if (!looksHtml(file)) return null;
    var parsed = parseFile(allocator, file, options.indexBase) catch |err| switch (err) {
        error.InvalidFilePath => return error.InvalidFilePath,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer {
        for (parsed.patterns.items) |p| allocator.free(p);
        parsed.patterns.deinit(allocator);
        parsed.segments.deinit(allocator);
    }

    const custom = customs.get(file);
    const rank: u8 = if (custom != null) 0 else parsed.rank;

    var dynamic = false;
    for (parsed.patterns.items) |seg| {
        const s0 = seg[0];
        if (s0 == '{' or s0 == '*') {
            dynamic = true;
            break;
        }
    }

    // Relative (base-independent) forms drive names; registered forms
    // carry the base prefix. Dynamic files register router syntax
    // (`{param}`/`*rest`) as their clean route.
    const rel_clean: []u8 = if (custom) |c| blk: {
        if (c.route.len == 0 or c.route[0] != '/') return error.InvalidFilePath;
        break :blk try allocator.dupe(u8, c.route);
    } else try joinSlashed(allocator, "/", parsed.segments.items);
    defer allocator.free(rel_clean);
    const rel_route: []u8 = if (custom != null) try allocator.dupe(u8, rel_clean) else try joinSlashed(allocator, "/", parsed.patterns.items);
    defer allocator.free(rel_route);
    const clean: []u8 = try joinBase(allocator, options.base, rel_route);
    errdefer allocator.free(clean);

    // Extension URLs keep the on-disk form and only exist for static
    // pages; dynamic files serve clean routes only.
    var ext_route: ?[]u8 = null;
    errdefer if (ext_route) |e| allocator.free(e);
    if (options.urls != .clean and !dynamic) {
        const full = try std.fmt.allocPrint(allocator, "/{s}", .{file});
        defer allocator.free(full);
        ext_route = try joinBase(allocator, options.base, full);
    }

    // Encoded aliases for static segments needing percent-encoding.
    var aliases: std.ArrayList([]u8) = .empty;
    errdefer {
        for (aliases.items) |a| allocator.free(a);
        aliases.deinit(allocator);
    }
    if (options.urls != .extension and !dynamic and custom == null) {
        var enc: std.ArrayList([]const u8) = .empty;
        defer {
            for (enc.items) |s| allocator.free(s);
            enc.deinit(allocator);
        }
        var differs = false;
        for (parsed.segments.items) |seg| {
            const e = try encodeSegment(allocator, seg);
            errdefer allocator.free(e);
            if (!std.mem.eql(u8, e, seg)) differs = true;
            try enc.append(allocator, e);
        }
        if (differs) {
            const alias = try joinSlashed(allocator, options.base, enc.items);
            errdefer allocator.free(alias);
            if (!std.mem.eql(u8, alias, clean)) try aliases.append(allocator, alias);
        }
    }

    const route_name: []u8 = if (custom) |c| (if (c.name) |n| try allocator.dupe(u8, n) else try dottedName(allocator, rel_clean)) else try dottedName(allocator, rel_route);
    errdefer allocator.free(route_name);
    const file_owned = try allocator.dupe(u8, file);
    errdefer allocator.free(file_owned);

    return .{
        .file = file_owned,
        .clean = clean,
        .name = route_name,
        .ext = ext_route,
        .aliases = try aliases.toOwnedSlice(allocator),
        .isIndex = parsed.isIndex,
        .rank = rank,
        .dynamic = dynamic,
    };
}

fn beats(rank_a: u8, file_a: []const u8, rank_b: u8, file_b: []const u8) bool {
    if (rank_a != rank_b) return rank_a < rank_b;
    return std.mem.order(u8, file_a, file_b) == .lt;
}

/// Builds a deterministic route table from logical file paths.
/// `files` may be in any order; output is sorted by route.
pub fn buildRoutes(allocator: Allocator, files: []const []const u8, options: Options) !BuildResult {
    const sorted = try allocator.dupe([]const u8, files);
    defer allocator.free(sorted);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    var customs = std.StringHashMap(CustomRoute).init(allocator);
    defer customs.deinit();
    for (options.custom) |c| try customs.put(c.file, c);

    var routes: std.ArrayList(FileRoute) = .empty;
    errdefer {
        for (routes.items) |r| freeRoute(allocator, r);
        routes.deinit(allocator);
    }
    var collisions: std.ArrayList(Collision) = .empty;
    errdefer {
        for (collisions.items) |c| {
            allocator.free(c.route);
            allocator.free(c.winner);
            allocator.free(c.loser);
        }
        collisions.deinit(allocator);
    }
    // Claimed final route strings -> entry index (borrowed slices).
    var byKey = std.StringHashMap(usize).init(allocator);
    defer byKey.deinit();
    // Dynamic shape keys -> entry index (owned shape strings).
    var shapes: ShapeList = .empty;
    defer {
        for (shapes.items) |s| allocator.free(s.shape);
        shapes.deinit(allocator);
    }

    for (sorted) |file| {
        const maybe = try buildOne(allocator, file, options, &customs);
        const pend = maybe orelse continue;
        try placeCandidate(allocator, &routes, &collisions, &byKey, &shapes, pend);
    }

    std.mem.sort(FileRoute, routes.items, {}, struct {
        fn less(_: void, a: FileRoute, b: FileRoute) bool {
            return std.mem.order(u8, a.route, b.route) == .lt;
        }
    }.less);

    return .{
        .routes = try routes.toOwnedSlice(allocator),
        .collisions = try collisions.toOwnedSlice(allocator),
    };
}

fn collectFoe(byKey: *std.StringHashMap(usize), key: []const u8, foes: *[9]usize, count: *usize) void {
    if (byKey.get(key)) |idx| {
        for (foes[0..count.*]) |e| if (e == idx) return;
        if (count.* < foes.len) {
            foes[count.*] = idx;
            count.* += 1;
        }
    }
}

fn shapeIndexOf(shapes: *ShapeList, shape: []const u8) ?usize {
    for (shapes.items) |s| {
        if (std.mem.eql(u8, s.shape, shape)) return s.idx;
    }
    return null;
}

/// Inserts one candidate, resolving every key it claims (clean, extension,
/// encoded aliases, dynamic shape). A losing file loses all of its routes;
/// every conflict is recorded. Ownership transfers on success.
fn placeCandidate(
    allocator: Allocator,
    routes: *std.ArrayList(FileRoute),
    collisions: *std.ArrayList(Collision),
    byKey: *std.StringHashMap(usize),
    shapes: *ShapeList,
    pend: Pending,
) !void {
    var foes: [9]usize = undefined;
    var foeCount: usize = 0;
    collectFoe(byKey, pend.clean, &foes, &foeCount);
    if (pend.ext) |e| collectFoe(byKey, e, &foes, &foeCount);
    for (pend.aliases) |a| collectFoe(byKey, a, &foes, &foeCount);

    const shape = try shapeKey(allocator, pend.clean);
    defer allocator.free(shape);
    var shape_hit: ?usize = null;
    if (shapeIndexOf(shapes, shape)) |idx| {
        if (!std.mem.eql(u8, routes.items[idx].route, pend.clean)) shape_hit = idx;
    }
    if (shape_hit) |idx| {
        var dup = false;
        for (foes[0..foeCount]) |f| if (f == idx) {
            dup = true;
            break;
        };
        if (!dup and foeCount < foes.len) {
            foes[foeCount] = idx;
            foeCount += 1;
        }
    }

    if (foeCount == 0) {
        const idx = routes.items.len;
        errdefer {
            // Roll back a half-registered entry on OOM.
            _ = byKey.remove(pend.clean);
            if (pend.ext) |e| _ = byKey.remove(e);
            for (pend.aliases) |a| _ = byKey.remove(a);
            freePending(allocator, pend);
            _ = routes.pop();
        }
        try routes.append(allocator, .{
            .file = pend.file,
            .route = pend.clean,
            .name = pend.name,
            .extRoute = pend.ext,
            .aliases = pend.aliases,
            .isIndex = pend.isIndex,
            .rank = pend.rank,
        });
        try byKey.put(pend.clean, idx);
        if (pend.ext) |e| try byKey.put(e, idx);
        for (pend.aliases) |a| try byKey.put(a, idx);
        try shapes.append(allocator, .{ .shape = try shapeKey(allocator, pend.clean), .idx = idx });
        return;
    }

    var best_file: []const u8 = pend.file;
    var cand_wins = true;
    for (foes[0..foeCount]) |idx| {
        const o = &routes.items[idx];
        if (!beats(pend.rank, pend.file, o.rank, o.file)) {
            cand_wins = false;
            best_file = o.file;
            break;
        }
    }
    if (!cand_wins) {
        try collisions.append(allocator, .{
            .route = try allocator.dupe(u8, pend.clean),
            .winner = try allocator.dupe(u8, best_file),
            .loser = try allocator.dupe(u8, pend.file),
        });
        freePending(allocator, pend);
        return;
    }

    // Candidate beats every foe: evict losers (descending), record each.
    std.mem.sort(usize, foes[0..foeCount], {}, struct {
        fn less(_: void, a: usize, b: usize) bool {
            return a > b;
        }
    }.less);
    for (foes[0..foeCount]) |idx| {
        const o = routes.items[idx];
        try collisions.append(allocator, .{
            .route = try allocator.dupe(u8, pend.clean),
            .winner = try allocator.dupe(u8, pend.file),
            .loser = try allocator.dupe(u8, o.file),
        });
        evictAt(allocator, routes, byKey, shapes, idx);
    }
    const idx = routes.items.len;
    errdefer {
        _ = byKey.remove(pend.clean);
        if (pend.ext) |e| _ = byKey.remove(e);
        for (pend.aliases) |a| _ = byKey.remove(a);
        freePending(allocator, pend);
        _ = routes.pop();
    }
    try routes.append(allocator, .{
        .file = pend.file,
        .route = pend.clean,
        .name = pend.name,
        .extRoute = pend.ext,
        .aliases = pend.aliases,
        .isIndex = pend.isIndex,
        .rank = pend.rank,
    });
    try byKey.put(pend.clean, idx);
    if (pend.ext) |e| try byKey.put(e, idx);
    for (pend.aliases) |a| try byKey.put(a, idx);
    try shapes.append(allocator, .{ .shape = try shapeKey(allocator, pend.clean), .idx = idx });
}

test "routes: index, nested, htm, slugs, base" {
    const files = [_][]const u8{
        "index.html",
        "about/index.html",
        "about/team.html",
        "about/company.htm",
        "blog/index.html",
        "blog/hello-world.html",
        "contact.html",
        "assets/app.css",
    };
    var res = try buildRoutes(std.testing.allocator, &files, .{});
    defer res.deinit(std.testing.allocator);
    // 7 pages (css skipped), sorted by route.
    try std.testing.expectEqual(@as(usize, 7), res.routes.len);
    try std.testing.expectEqual(@as(usize, 0), res.collisions.len);
    try std.testing.expectEqualStrings("/", res.routes[0].route);
    try std.testing.expectEqualStrings("home", res.routes[0].name);
    try std.testing.expect(res.routes[0].isIndex);
    try std.testing.expectEqualStrings("/about", res.routes[1].route);
    try std.testing.expectEqualStrings("/about/company", res.routes[2].route);
    try std.testing.expectEqualStrings("/about/team", res.routes[3].route);
    try std.testing.expectEqualStrings("/blog", res.routes[4].route);
    try std.testing.expectEqualStrings("/blog/hello-world", res.routes[5].route);
    try std.testing.expectEqualStrings("blog.hello-world", res.routes[5].name);
    try std.testing.expectEqualStrings("/contact", res.routes[6].route);
    // Extension forms registered under .both.
    try std.testing.expectEqualStrings("/about/team.html", res.routes[3].extRoute.?);
    try std.testing.expectEqualStrings("/about/company.htm", res.routes[2].extRoute.?);

    var based = try buildRoutes(std.testing.allocator, &files, .{ .base = "/app" });
    defer based.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/app", based.routes[0].route);
    try std.testing.expectEqualStrings("/app/blog/hello-world", based.routes[5].route);
    // Names are base-independent.
    try std.testing.expectEqualStrings("home", based.routes[0].name);
}

test "routes: url styles and custom overrides" {
    const files = [_][]const u8{ "index.html", "about.html" };
    var clean_only = try buildRoutes(std.testing.allocator, &files, .{ .urls = .clean });
    defer clean_only.deinit(std.testing.allocator);
    try std.testing.expect(clean_only.routes[1].extRoute == null);

    var ext_only = try buildRoutes(std.testing.allocator, &files, .{ .urls = .extension });
    defer ext_only.deinit(std.testing.allocator);
    try std.testing.expect(ext_only.routes[1].extRoute != null);

    const custom = [_]CustomRoute{.{ .file = "about.html", .route = "/account", .name = "account" }};
    var over = try buildRoutes(std.testing.allocator, &files, .{ .custom = &custom });
    defer over.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/account", over.routes[1].route);
    try std.testing.expectEqualStrings("account", over.routes[1].name);
    // Custom file still serves its extension form.
    try std.testing.expectEqualStrings("/about.html", over.routes[1].extRoute.?);
}

test "routes: collisions resolve deterministically with diagnostics" {
    const files = [_][]const u8{ "about.html", "about.htm", "about/index.html", "about/index.htm" };
    var res = try buildRoutes(std.testing.allocator, &files, .{ .urls = .clean });
    defer res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), res.routes.len);
    try std.testing.expectEqualStrings("about/index.html", res.routes[0].file);
    try std.testing.expectEqual(@as(usize, 3), res.collisions.len);
    // Input order must not matter.
    const shuffled = [_][]const u8{ "about/index.htm", "about.html", "about/index.html", "about.htm" };
    var res2 = try buildRoutes(std.testing.allocator, &shuffled, .{ .urls = .clean });
    defer res2.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("about/index.html", res2.routes[0].file);
}

test "routes: dynamic segments and shape conflicts" {
    const files = [_][]const u8{ "users/new.html", "users/[id].html", "blog/[...path].html" };
    var res = try buildRoutes(std.testing.allocator, &files, .{ .urls = .clean });
    defer res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), res.routes.len);
    try std.testing.expectEqualStrings("/users/{id}", res.routes[2].route);
    try std.testing.expectEqualStrings("users.{id}", res.routes[2].name);
    try std.testing.expectEqualStrings("/blog/*path", res.routes[0].route);

    const dup = [_][]const u8{ "users/[id].html", "users/[slug].html" };
    var res2 = try buildRoutes(std.testing.allocator, &dup, .{ .urls = .clean });
    defer res2.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), res2.routes.len);
    try std.testing.expectEqual(@as(usize, 1), res2.collisions.len);
    try std.testing.expectEqualStrings("users/[id].html", res2.routes[0].file);
}

test "routes: rejects structural hazards loudly" {
    const bad = [_][]const u8{"../secret.html"};
    try std.testing.expectError(error.InvalidFilePath, buildRoutes(std.testing.allocator, &bad, .{}));
    const wild = [_][]const u8{"docs/[...path]/more.html"};
    try std.testing.expectError(error.InvalidFilePath, buildRoutes(std.testing.allocator, &wild, .{}));
    const brace = [_][]const u8{"a{b}.html"};
    try std.testing.expectError(error.InvalidFilePath, buildRoutes(std.testing.allocator, &brace, .{}));
}

fn evictAt(
    allocator: Allocator,
    routes: *std.ArrayList(FileRoute),
    byKey: *std.StringHashMap(usize),
    shapes: *ShapeList,
    idx: usize,
) void {
    const victim = routes.items[idx];
    const last = routes.items.len - 1;
    // Collect victim keys first (never mutate a map while iterating it),
    // then fix swapped-slot references in a second pass.
    var drop: [10][]const u8 = undefined;
    var dropCount: usize = 0;
    var it = byKey.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* == idx and dropCount < drop.len) {
            drop[dropCount] = kv.key_ptr.*;
            dropCount += 1;
        }
    }
    var it2 = byKey.iterator();
    while (it2.next()) |kv| {
        if (kv.value_ptr.* == last) kv.value_ptr.* = idx;
    }
    for (drop[0..dropCount]) |k| _ = byKey.remove(k);
    // Drop victim shape entries.
    var si: usize = 0;
    while (si < shapes.items.len) {
        if (shapes.items[si].idx == idx) {
            allocator.free(shapes.items[si].shape);
            _ = shapes.swapRemove(si);
        } else {
            if (shapes.items[si].idx == last) shapes.items[si].idx = idx;
            si += 1;
        }
    }
    freeRoute(allocator, victim);
    _ = routes.swapRemove(idx);
}
