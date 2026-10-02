//! Thread-safe compiled template cache with dependency graph tracking.

const std = @import("std");
const Allocator = std.mem.Allocator;
const parserMod = @import("parser.zig");
pub const TemplateAst = parserMod.TemplateAst;

pub const CachedTemplate = struct {
    name: []const u8,
    ast: TemplateAst,
    source: []const u8,
};

/// An evicted entry awaiting safe release once no render references it.
/// An evicted entry awaiting safe release once no render references it.
/// Holds the same heap allocation the map owned, so a parked borrow
/// keeps pointing at live memory.
pub const GarbageEntry = *CachedTemplate;

pub const CacheConfig = struct {
    enabled: bool = true,
    maxTemplates: usize = 1024,
};

const sync = @import("../../common/sync.zig");

pub const Cache = struct {
    allocator: Allocator,
    config: CacheConfig,
    lock: sync.Spinlock = .{},
    // map templateName -> CachedTemplate
    // templateName -> heap CachedTemplate. The value must not live inline,
    // or a borrow can outlive the map slot it points into.
    entries: std.StringHashMap(*CachedTemplate),
    // map dependencyName -> list of dependents
    // e.g. "base.html" -> ["index.html", "about.html"]
    dependents: std.StringHashMap(std.ArrayList([]const u8)),
    /// Renders currently borrowing AST pointers. Evicted entries are
    /// parked in `garbage` (not freed) while this is nonzero, so a
    /// concurrent `invalidate`/`put` can never free an AST under an
    /// in-flight render. Drained when the last render ends.
    activeRenders: usize = 0,
    garbage: std.ArrayList(*CachedTemplate) = .empty,

    pub fn init(allocator: Allocator, config: CacheConfig) Cache {
        return .{
            .allocator = allocator,
            .config = config,
            .entries = std.StringHashMap(*CachedTemplate).init(allocator),
            .dependents = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
        };
    }

    /// Marks a render as borrowing ASTs; pair with `endRender`.
    pub fn beginRender(self: *Cache) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.activeRenders += 1;
    }

    /// Ends a render borrow, freeing parked entries when idle.
    pub fn endRender(self: *Cache) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.activeRenders -= 1;
        if (self.activeRenders == 0) self.drainGarbageLocked();
    }

    /// Releases an entry's payload. The name is NOT freed here: a
    /// StringHashMap stores its key slice without copying, so
    /// `entry.name` and the map key are the same allocation and the
    /// caller that removed the entry owns freeing it.
    fn freeEntry(self: *Cache, entry: *CachedTemplate) void {
        self.allocator.free(entry.source);
        entry.ast.deinit();
        self.allocator.destroy(entry);
    }

    fn retireLocked(self: *Cache, entry: *CachedTemplate) void {
        if (self.activeRenders > 0) {
            self.garbage.append(self.allocator, entry) catch {
                // OOM while parking: leak rather than use-after-free.
                return;
            };
            return;
        }
        self.freeEntry(entry);
    }

    fn drainGarbageLocked(self: *Cache) void {
        for (self.garbage.items) |g| self.freeEntry(g);
        self.garbage.clearRetainingCapacity();
    }

    pub fn deinit(self: *Cache) void {
        self.lock.lock();
        defer self.lock.unlock();

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.freeEntry(entry.value_ptr.*);
        }
        self.entries.deinit();

        var depIt = self.dependents.iterator();
        while (depIt.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |dep| {
                self.allocator.free(dep);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.dependents.deinit();

        for (self.garbage.items) |g| self.freeEntry(g);
        self.garbage.deinit(self.allocator);
    }

    /// Looks up a compiled template AST by name. Caller must not retain pointer beyond cache lifetime.
    pub fn get(self: *Cache, name: []const u8) ?*const TemplateAst {
        if (!self.config.enabled) return null;

        self.lock.lock();
        defer self.lock.unlock();

        if (self.entries.get(name)) |entry| {
            return &entry.ast;
        }
        return null;
    }

    /// Stores a compiled template AST and records its dependency relationships.
    pub fn put(
        self: *Cache,
        name: []const u8,
        source: []const u8,
        ast: TemplateAst,
    ) !void {
        if (!self.config.enabled) {
            var mutAst = ast;
            mutAst.deinit();
            self.allocator.free(source);
            return;
        }

        self.lock.lock();
        defer self.lock.unlock();

        // If existing entry, retire it first (parked while renders borrow it)
        if (self.entries.fetchRemove(name)) |kv| {
            // The map key and entry.name alias, so the key is freed here
            // and retireLocked handles only the payload.
            self.allocator.free(kv.key);
            self.retireLocked(kv.value);
        }

        const ownedName = self.allocator.dupe(u8, name) catch |err| return err;
        const entry = self.allocator.create(CachedTemplate) catch |err| {
            self.allocator.free(ownedName);
            return err;
        };
        entry.* = .{ .name = ownedName, .ast = ast, .source = source };

        // Ownership of `entry` — and of its `name`, `ast` and `source` —
        // transfers to the map here. No errdefer may stay armed past this
        // point: addDependencyInternal below can fail, and freeing the
        // name on that path would leave the map holding freed memory,
        // which freeEntry would then free a second time.
        self.entries.put(ownedName, entry) catch |err| {
            self.allocator.destroy(entry);
            self.allocator.free(ownedName);
            return err;
        };

        // Track dependencies: if this template extends a parent or includes partials,
        // register this template as a dependent of those parent/partial templates.
        if (ast.extendsPath) |parent| {
            try self.addDependencyInternal(parent, name);
        }
        for (ast.includes) |inc| {
            try self.addDependencyInternal(inc, name);
        }
    }

    fn addDependencyInternal(self: *Cache, target: []const u8, dependent: []const u8) !void {
        const gop = try self.dependents.getOrPut(target);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, target);
            gop.value_ptr.* = std.ArrayList([]const u8).empty;
        }

        // Avoid duplicates
        for (gop.value_ptr.items) |existing| {
            if (std.mem.eql(u8, existing, dependent)) return;
        }

        const ownedDep = try self.allocator.dupe(u8, dependent);
        try gop.value_ptr.append(self.allocator, ownedDep);
    }

    /// Invalidates a template and recursively invalidates all templates that depend on it.
    pub fn invalidate(self: *Cache, name: []const u8) void {
        self.lock.lock();
        defer self.lock.unlock();

        self.invalidateRecursive(name);
    }

    fn invalidateRecursive(self: *Cache, name: []const u8) void {
        // Invalidate target
        if (self.entries.fetchRemove(name)) |kv| {
            // The map key and entry.name alias, so the key is freed here
            // and retireLocked handles only the payload.
            self.allocator.free(kv.key);
            self.retireLocked(kv.value);
        }

        // Invalidate dependents
        if (self.dependents.get(name)) |depList| {
            for (depList.items) |dep| {
                self.invalidateRecursive(dep);
            }
        }
    }

    /// Invalidates all cached templates.
    pub fn invalidateAll(self: *Cache) void {
        self.lock.lock();
        defer self.lock.unlock();

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.retireLocked(entry.key_ptr.*, entry.value_ptr.ast, entry.value_ptr.source);
        }
        self.entries.clearRetainingCapacity();
    }
};

test "Cache stores and invalidates with dependency tracking" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cache = Cache.init(alloc, .{});
    defer cache.deinit();

    // Create a base template AST
    const baseSrc = try alloc.dupe(u8, "<html>{% block body %}{% endblock %}</html>");
    var baseParser = parserMod.Parser.init(alloc, "base.html", baseSrc);
    const baseAst = try baseParser.parse();
    try cache.put("base.html", baseSrc, baseAst);

    // Create a child template AST that extends base.html
    const childSrc = try alloc.dupe(u8, "{% extends \"base.html\" %}{% block body %}Hello{% endblock %}");
    var childParser = parserMod.Parser.init(alloc, "index.html", childSrc);
    const childAst = try childParser.parse();
    try cache.put("index.html", childSrc, childAst);

    try testing.expect(cache.get("base.html") != null);
    try testing.expect(cache.get("index.html") != null);

    // Invalidating base.html should also invalidate index.html!
    cache.invalidate("base.html");
    try testing.expect(cache.get("base.html") == null);
    try testing.expect(cache.get("index.html") == null);
}
