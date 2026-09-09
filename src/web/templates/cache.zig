//! Thread-safe compiled template cache with dependency graph tracking.

const std = @import("std");
const Allocator = std.mem.Allocator;
const parser_mod = @import("parser.zig");
pub const TemplateAst = parser_mod.TemplateAst;

pub const CachedTemplate = struct {
    name: []const u8,
    ast: TemplateAst,
    source: []const u8,
};

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
    entries: std.StringHashMap(CachedTemplate),
    // map dependency_name -> list of dependents
    // e.g. "base.html" -> ["index.html", "about.html"]
    dependents: std.StringHashMap(std.ArrayList([]const u8)),

    pub fn init(allocator: Allocator, config: CacheConfig) Cache {
        return .{
            .allocator = allocator,
            .config = config,
            .entries = std.StringHashMap(CachedTemplate).init(allocator),
            .dependents = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
        };
    }

    pub fn deinit(self: *Cache) void {
        self.lock.lock();
        defer self.lock.unlock();

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.source);
            entry.value_ptr.ast.deinit();
        }
        self.entries.deinit();

        var dep_it = self.dependents.iterator();
        while (dep_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |dep| {
                self.allocator.free(dep);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.dependents.deinit();
    }

    /// Looks up a compiled template AST by name. Caller must not retain pointer beyond cache lifetime.
    pub fn get(self: *Cache, name: []const u8) ?*const TemplateAst {
        if (!self.config.enabled) return null;

        self.lock.lock();
        defer self.lock.unlock();

        if (self.entries.getPtr(name)) |entry| {
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
            var mut_ast = ast;
            mut_ast.deinit();
            self.allocator.free(source);
            return;
        }

        self.lock.lock();
        defer self.lock.unlock();

        // If existing entry, free it first
        if (self.entries.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value.source);
            var old_ast = kv.value.ast;
            old_ast.deinit();
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        try self.entries.put(owned_name, .{
            .name = owned_name,
            .ast = ast,
            .source = source,
        });

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

        const owned_dep = try self.allocator.dupe(u8, dependent);
        try gop.value_ptr.append(self.allocator, owned_dep);
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
            self.allocator.free(kv.key);
            self.allocator.free(kv.value.source);
            var old_ast = kv.value.ast;
            old_ast.deinit();
        }

        // Invalidate dependents
        if (self.dependents.get(name)) |dep_list| {
            for (dep_list.items) |dep| {
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
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.source);
            entry.value_ptr.ast.deinit();
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
    const base_src = try alloc.dupe(u8, "<html>{% block body %}{% endblock %}</html>");
    var base_parser = parser_mod.Parser.init(alloc, "base.html", base_src);
    const base_ast = try base_parser.parse();
    try cache.put("base.html", base_src, base_ast);

    // Create a child template AST that extends base.html
    const child_src = try alloc.dupe(u8, "{% extends \"base.html\" %}{% block body %}Hello{% endblock %}");
    var child_parser = parser_mod.Parser.init(alloc, "index.html", child_src);
    const child_ast = try child_parser.parse();
    try cache.put("index.html", child_src, child_ast);

    try testing.expect(cache.get("base.html") != null);
    try testing.expect(cache.get("index.html") != null);

    // Invalidating base.html should also invalidate index.html!
    cache.invalidate("base.html");
    try testing.expect(cache.get("base.html") == null);
    try testing.expect(cache.get("index.html") == null);
}
