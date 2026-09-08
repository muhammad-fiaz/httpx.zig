//! Template engine owner and orchestrator.
//!
//! Owns configuration, loader, cache, compiler, and renderer.
//! Reusable and concurrency-safe across multiple HTTP requests.

const std = @import("std");
const Allocator = std.mem.Allocator;
const loader_mod = @import("loader.zig");
const cache_mod = @import("cache.zig");
const parser_mod = @import("parser.zig");
const renderer_mod = @import("renderer.zig");
const context_mod = @import("context.zig");
const err_mod = @import("error.zig");

const sync = @import("../../common/sync.zig");

pub const Config = struct {
    enabled: bool = true,
    directory: []const u8 = "templates",
    enableCache: bool = true,
    max_templates: usize = 1024,
    max_file_size: usize = 10 * 1024 * 1024,
    max_include_depth: usize = 32,
    max_inheritance_depth: usize = 16,
};

pub const Engine = struct {
    allocator: Allocator,
    io: std.Io,
    config: Config,
    loader: loader_mod.Loader,
    cache: cache_mod.Cache,
    renderer: renderer_mod.Renderer,
    lock: sync.Spinlock = .{},
    last_error: ?err_mod.SourceError = null,

    pub fn init(allocator: Allocator, io: std.Io, config: Config) !Engine {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .loader = loader_mod.Loader.init(.{
                .directory = config.directory,
                .max_file_size = config.max_file_size,
            }),
            .cache = cache_mod.Cache.init(allocator, .{
                .enabled = config.enableCache,
                .max_templates = config.max_templates,
            }),
            .renderer = renderer_mod.Renderer{
                .options = .{
                    .max_include_depth = config.max_include_depth,
                    .max_inheritance_depth = config.max_inheritance_depth,
                },
            },
        };
    }

    pub fn deinit(self: *Engine) void {
        self.cache.deinit();
    }

    /// Provides AST lookup for includes and inheritance.
    pub fn provider(self: *Engine) renderer_mod.TemplateProvider {
        return .{
            .ptr = @ptrCast(self),
            .getAstFn = getAstCallback,
        };
    }

    fn getAstCallback(ptr: *const anyopaque, name: []const u8) ?*const parser_mod.TemplateAst {
        const self: *Engine = @ptrCast(@alignCast(@constCast(ptr)));
        return self.getOrCompile(name) catch null;
    }

    /// Compiles a template or retrieves it from cache.
    pub fn getOrCompile(self: *Engine, name: []const u8) !*const parser_mod.TemplateAst {
        if (self.cache.get(name)) |cached| {
            return cached;
        }

        const source = try self.loader.load(self.allocator, name);
        errdefer self.allocator.free(source);

        var parser = parser_mod.Parser.init(self.allocator, name, source);
        const ast = parser.parse() catch |err| {
            if (parser.last_error) |diag| {
                self.last_error = diag;
            }
            return err;
        };

        try self.cache.put(name, source, ast);

        // Preload any extends parent
        if (ast.extends_path) |parent| {
            _ = self.getOrCompile(parent) catch {};
        }

        // Preload any includes
        for (ast.includes) |inc| {
            _ = self.getOrCompile(inc) catch {};
        }

        return self.cache.get(name) orelse error.TemplateNotFound;
    }

    /// Renders a template directly into a writer using arbitrary Zig data.
    pub fn render(
        self: *Engine,
        name: []const u8,
        data: anytype,
        writer: anytype,
    ) !void {
        const ast = try self.getOrCompile(name);

        var ctx = try context_mod.Context.init(self.allocator, data);
        defer ctx.deinit();

        try self.renderer.render(ast, &ctx, self.provider(), writer);
    }

    /// Renders a template to an allocated string.
    pub fn renderToString(
        self: *Engine,
        allocator: Allocator,
        name: []const u8,
        data: anytype,
    ) ![]u8 {
        var list = std.ArrayList(u8).empty;
        errdefer list.deinit(allocator);
        var lw = renderer_mod.ListWriter{ .list = &list, .allocator = allocator };
        try self.render(name, data, &lw);
        return try list.toOwnedSlice(allocator);
    }

    /// Compiles template directly from in-memory string (useful for testing or inline templates).
    pub fn renderString(
        self: *Engine,
        source: []const u8,
        data: anytype,
        writer: anytype,
    ) !void {
        var parser = parser_mod.Parser.init(self.allocator, "<inline>", source);
        var ast = try parser.parse();
        defer ast.deinit();

        var ctx = try context_mod.Context.init(self.allocator, data);
        defer ctx.deinit();

        try self.renderer.render(&ast, &ctx, self.provider(), writer);
    }

    /// Invalidate a template and all its dependents when a watched file changes.
    pub fn invalidate(self: *Engine, path: []const u8) void {
        // Strip template directory prefix if present
        var rel_name = path;
        if (std.mem.startsWith(u8, path, self.config.directory)) {
            rel_name = path[self.config.directory.len..];
            if (rel_name.len > 0 and (rel_name[0] == '/' or rel_name[0] == '\\')) {
                rel_name = rel_name[1..];
            }
        }

        // Normalize backslashes to forward slashes for cross-platform lookup
        var norm_buf: [256]u8 = undefined;
        var norm_name = rel_name;
        if (rel_name.len <= norm_buf.len) {
            @memcpy(norm_buf[0..rel_name.len], rel_name);
            for (norm_buf[0..rel_name.len]) |*b| {
                if (b.* == '\\') b.* = '/';
            }
            norm_name = norm_buf[0..rel_name.len];
        }

        self.cache.invalidate(norm_name);
        if (!std.mem.eql(u8, norm_name, rel_name)) {
            self.cache.invalidate(rel_name);
        }
    }
};

test "Engine in-memory rendering and context evaluation" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var engine = try Engine.init(alloc, undefined, .{});
    defer engine.deinit();

    var list = std.ArrayList(u8).empty;
    defer list.deinit(alloc);

    const src =
        \\<h1>{{ title }}</h1>
        \\{% for item in items %}
        \\<span>{{ item }}</span>
        \\{% endfor %}
    ;

    var lw = renderer_mod.ListWriter{ .list = &list, .allocator = alloc };
    try engine.renderString(src, .{
        .title = "Hello HTTPX",
        .items = [_][]const u8{ "A", "B" },
    }, &lw);

    const out = list.items;
    try testing.expect(std.mem.indexOf(u8, out, "<h1>Hello HTTPX</h1>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<span>A</span>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<span>B</span>") != null);
}
