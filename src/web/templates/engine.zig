//! Template engine owner and orchestrator.
//!
//! Owns configuration, loader, cache, compiler, and renderer.
//! Reusable and concurrency-safe across multiple HTTP requests.

const std = @import("std");
const Allocator = std.mem.Allocator;
const loaderMod = @import("loader.zig");
const cacheMod = @import("cache.zig");
const parserMod = @import("parser.zig");
const rendererMod = @import("renderer.zig");
const contextMod = @import("context.zig");
const errMod = @import("error.zig");

const sync = @import("../../common/sync.zig");

pub const Config = struct {
    enabled: bool = true,
    directory: []const u8 = "templates",
    enableCache: bool = true,
    maxTemplates: usize = 1024,
    maxFileSize: usize = 10 * 1024 * 1024,
    maxIncludeDepth: usize = 32,
    maxInheritanceDepth: usize = 16,
    /// When true, rendering an undefined value fails instead of emitting empty.
    strictUndefined: bool = false,
    /// Default HTML autoescaping for `{{ }}` (per-region override via
    /// `{% autoescape %}`).
    autoescape: bool = true,
    /// Cap on rendered output bytes per render (DoS guard).
    maxOutputBytes: usize = 64 << 20,
    /// Cap on nested macro/call depth (recursion guard).
    maxMacroDepth: usize = 64,
    /// Cap on `range()` sequence length (memory guard).
    maxRangeItems: usize = 1 << 20,
};

pub const Engine = struct {
    allocator: Allocator,
    io: std.Io,
    config: Config,
    loader: loaderMod.Loader,
    cache: cacheMod.Cache,
    renderer: rendererMod.Renderer,
    filters: rendererMod.FilterRegistry,
    globals: rendererMod.GlobalMap,
    lock: sync.Spinlock = .{},
    lastError: ?errMod.SourceError = null,
    /// Location of the node being rendered when the latest render failed
    /// (mirrored from the renderer via the provider hook).
    lastRenderLoc: ?rendererMod.ErrLoc = null,
    /// Scratch AST stack for cache-disabled mode: every `getOrCompile`
    /// parses fresh and pushes a slot (nested includes push their own),
    /// and each top-level `render` pops the slots it added. Never shared
    /// across renders without the no-cache lock below.
    scratchStack: std.ArrayList(ScratchSlot) = .empty,
    /// Serializes cache-disabled renders: scratch slots are per-render
    /// state, so uncached renders must not interleave. Cached renders
    /// stay fully concurrent (the cache parks evictions instead).
    noCacheGate: sync.Semaphore = sync.Semaphore.init(1),

    pub const ScratchSlot = struct {
        ast: parserMod.TemplateAst,
        source: []u8,
    };

    pub fn init(allocator: Allocator, io: std.Io, config: Config) !Engine {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .loader = loaderMod.Loader.init(.{
                .directory = config.directory,
                .maxFileSize = config.maxFileSize,
            }),
            .cache = cacheMod.Cache.init(allocator, .{
                .enabled = config.enableCache,
                .maxTemplates = config.maxTemplates,
            }),
            .renderer = rendererMod.Renderer{
                .options = .{
                    .maxIncludeDepth = config.maxIncludeDepth,
                    .maxInheritanceDepth = config.maxInheritanceDepth,
                    .strictUndefined = config.strictUndefined,
                    .autoescapeDefault = config.autoescape,
                    .maxOutputBytes = config.maxOutputBytes,
                    .maxMacroDepth = config.maxMacroDepth,
                    .maxRangeItems = config.maxRangeItems,
                },
            },
            .filters = rendererMod.FilterRegistry.init(allocator),
            .globals = rendererMod.GlobalMap.init(allocator),
        };
    }

    pub fn deinit(self: *Engine) void {
        for (self.scratchStack.items) |*slot| {
            slot.ast.deinit();
            self.allocator.free(slot.source);
        }
        self.scratchStack.deinit(self.allocator);
        self.cache.deinit();
        self.filters.deinit();
        self.globals.deinit();
    }

    /// Registers a custom filter for `{{ value|name }}` pipelines.
    /// Register before rendering; builtins remain available as fallback.
    pub fn registerFilter(self: *Engine, name: []const u8, func: rendererMod.FilterFn) !void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.filters.register(name, func);
    }

    /// Registers a global callable for `{{ name(args) }}` expressions.
    /// `userData` is passed through on every call (e.g. a router pointer
    /// for `urlFor`); it must outlive the engine. Macros and the `range`
    /// builtin take precedence at call sites.
    pub fn addGlobal(self: *Engine, name: []const u8, func: rendererMod.GlobalFn, userData: ?*const anyopaque) !void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.globals.map.put(name, .{ .func = func, .userData = userData });
    }

    /// Provides AST lookup for includes and inheritance.
    /// Per-render state: where the renderer was when it failed, and the engine
    /// that owns the render.
    ///
    /// This used to be the Engine's own `lastRenderLoc`, which is wrong twice
    /// over. It is per-render state kept on shared storage, and cached renders
    /// are concurrent by design (see `render`), so two threads walking two
    /// templates overwrote each other's location: a failure could be reported
    /// at another template's line, or at line 1 because the other thread had
    /// just cleared it. The reset at the top of `render` and the read in
    /// `captureRenderError` were both unsynchronised against the one write
    /// that did take the lock, so this was a data race and not only a
    /// last-writer-wins bug.
    ///
    /// Locking the field cannot fix that. The location and the error have to
    /// move together to describe one render, and no lock binds them to the
    /// same thread across the whole walk.
    ///
    /// Held by value in the render's own frame: no synchronisation needed, and
    /// it cannot outlive the call that owns it.
    const RenderCtx = struct {
        engine: *Engine,
        loc: ?rendererMod.ErrLoc = null,

        fn provider(self: *RenderCtx) rendererMod.TemplateProvider {
            return .{
                .ptr = @ptrCast(self),
                .getAstFn = getAstCallback,
                .reportLocFn = reportLocCallback,
            };
        }
    };

    /// Provider for callers that drive the renderer themselves. Locations land
    /// on the Engine rather than on a per-render context, so they are only
    /// meaningful for one render at a time. `render` and `renderString` do not
    /// use this; they carry a `RenderCtx`.
    pub fn provider(self: *Engine) rendererMod.TemplateProvider {
        return .{
            .ptr = @ptrCast(self),
            .getAstFn = engineGetAst,
            .reportLocFn = engineReportLoc,
        };
    }

    fn getAstCallback(ptr: *const anyopaque, name: []const u8) ?*const parserMod.TemplateAst {
        const rc: *RenderCtx = @ptrCast(@alignCast(@constCast(ptr)));
        return rc.engine.getOrCompile(name) catch null;
    }

    /// No lock: `rc` is owned by the thread running this render and is not
    /// reachable from any other.
    fn reportLocCallback(ptr: *const anyopaque, line: usize, col: usize, startByte: usize) void {
        const rc: *RenderCtx = @ptrCast(@alignCast(@constCast(ptr)));
        rc.loc = .{ .line = line, .col = col, .startByte = startByte };
    }

    fn engineGetAst(ptr: *const anyopaque, name: []const u8) ?*const parserMod.TemplateAst {
        const self: *Engine = @ptrCast(@alignCast(@constCast(ptr)));
        return self.getOrCompile(name) catch null;
    }

    fn engineReportLoc(ptr: *const anyopaque, line: usize, col: usize, startByte: usize) void {
        const self: *Engine = @ptrCast(@alignCast(@constCast(ptr)));
        self.lock.lock();
        defer self.lock.unlock();
        self.lastRenderLoc = .{ .line = line, .col = col, .startByte = startByte };
    }

    /// Compiles a template or retrieves it from cache.
    /// With enableCache=false, parses fresh on every call and pushes the
    /// result on the scratch stack (owned until the enclosing top-level
    /// `render` pops it), so nested includes each get a valid AST.
    /// NOTE: in no-cache mode every slot stays alive until the enclosing
    /// render finishes; call `render` (which holds the no-cache lock and
    /// drains its slots) rather than retaining these pointers.
    pub fn getOrCompile(self: *Engine, name: []const u8) !*const parserMod.TemplateAst {
        if (!self.config.enableCache) {
            self.lock.lock();
            defer self.lock.unlock();
            const source = try self.loader.load(self.allocator, name);
            errdefer self.allocator.free(source);
            var parser = parserMod.Parser.init(self.allocator, name, source);
            const ast = parser.parse() catch |err| {
                if (parser.lastError) |diag| self.lastError = diag;
                self.allocator.free(source);
                return err;
            };
            try self.scratchStack.append(self.allocator, .{ .ast = ast, .source = source });
            return &self.scratchStack.items[self.scratchStack.items.len - 1].ast;
        }
        if (self.cache.get(name)) |cached| {
            return cached;
        }

        const source = try self.loader.load(self.allocator, name);
        // `source` is ours only until `put` takes it. A concurrent
        // invalidate can make the `get` at the end of this function
        // miss, and the resulting error must not free a buffer the
        // cache is still holding.
        var sourceOwnedByCache = false;
        errdefer if (!sourceOwnedByCache) self.allocator.free(source);

        var parser = parserMod.Parser.init(self.allocator, name, source);
        const ast = parser.parse() catch |err| {
            // Cached renders are concurrent, and this is shared state, so the
            // store is taken. Same lock as `captureRenderError`, which is the
            // other writer of this field.
            if (parser.lastError) |diag| {
                self.lock.lock();
                defer self.lock.unlock();
                self.lastError = diag;
            }
            return err;
        };

        try self.cache.put(name, source, ast);
        sourceOwnedByCache = true;

        // Preload any extends parent
        if (ast.extendsPath) |parent| {
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
        // No-cache renders are serialized (scratch slots are per-render
        // state); cached renders borrow cache ASTs under begin/endRender
        // so concurrent invalidation can never free under us.
        if (!self.config.enableCache) self.noCacheGate.wait();
        defer if (!self.config.enableCache) self.noCacheGate.post();
        const scratchBase = self.scratchStack.items.len;
        defer self.popScratchTo(scratchBase);
        self.cache.beginRender();
        defer self.cache.endRender();

        const ast = try self.getOrCompile(name);

        var ctx = try contextMod.Context.init(self.allocator, data);
        defer ctx.deinit();

        var renderer = self.renderer;
        renderer.filters = &self.filters;
        renderer.globals = &self.globals;
        var rc: RenderCtx = .{ .engine = self };
        renderer.render(ast, &ctx, rc.provider(), writer) catch |err| {
            self.captureRenderError(&rc, name, err);
            return err;
        };
    }

    /// Pops scratch slots back to `base`, freeing their ASTs/sources.
    fn popScratchTo(self: *Engine, base: usize) void {
        while (self.scratchStack.items.len > base) {
            const slot = self.scratchStack.pop() orelse break;
            var ast = slot.ast;
            ast.deinit();
            self.allocator.free(slot.source);
        }
    }

    /// Records a failed render as the Engine's `lastError`.
    ///
    /// The location comes from `rc`, the context of the render that actually
    /// failed, so message and position always describe the same template.
    ///
    /// `lastError` is a single slot on shared storage, so with concurrent
    /// renders the newest failure wins: it is a "most recent failure" summary
    /// rather than per-render state. The lock is what keeps a reader from
    /// seeing a half-written value.
    fn captureRenderError(self: *Engine, rc: *const RenderCtx, templateName: []const u8, err: anyerror) void {
        const loc = rc.loc;
        const info: errMod.SourceError = .{
            .kind = .renderError,
            .templateName = templateName,
            .line = if (loc) |l| l.line else 1,
            .column = if (loc) |l| l.col else 1,
            .byteOffset = if (loc) |l| l.startByte else 0,
            .message = @errorName(err),
        };
        self.lock.lock();
        defer self.lock.unlock();
        self.lastError = info;
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
        var lw = rendererMod.ListWriter{ .list = &list, .allocator = allocator };
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
        if (!self.config.enableCache) self.noCacheGate.wait();
        defer if (!self.config.enableCache) self.noCacheGate.post();
        const scratchBase = self.scratchStack.items.len;
        defer self.popScratchTo(scratchBase);
        self.cache.beginRender();
        defer self.cache.endRender();

        var parser = parserMod.Parser.init(self.allocator, "<inline>", source);
        var ast = try parser.parse();
        defer ast.deinit();

        var ctx = try contextMod.Context.init(self.allocator, data);
        defer ctx.deinit();

        var renderer = self.renderer;
        renderer.filters = &self.filters;
        renderer.globals = &self.globals;
        var rc: RenderCtx = .{ .engine = self };
        renderer.render(&ast, &ctx, rc.provider(), writer) catch |err| {
            self.captureRenderError(&rc, "<inline>", err);
            return err;
        };
    }

    /// Invalidate a template and all its dependents when a watched file changes.
    pub fn invalidate(self: *Engine, path: []const u8) void {
        // Strip template directory prefix if present
        var relName = path;
        if (std.mem.startsWith(u8, path, self.config.directory)) {
            relName = path[self.config.directory.len..];
            if (relName.len > 0 and (relName[0] == '/' or relName[0] == '\\')) {
                relName = relName[1..];
            }
        }

        // Normalize backslashes to forward slashes for cross-platform lookup
        var normBuf: [256]u8 = undefined;
        var normName = relName;
        if (relName.len <= normBuf.len) {
            @memcpy(normBuf[0..relName.len], relName);
            for (normBuf[0..relName.len]) |*b| {
                if (b.* == '\\') b.* = '/';
            }
            normName = normBuf[0..relName.len];
        }

        self.cache.invalidate(normName);
        if (!std.mem.eql(u8, normName, relName)) {
            self.cache.invalidate(relName);
        }
    }
};

test "Engine cache-disabled still renders" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const fsMod = @import("../../utils/fs.zig");

    // Filesystem-backed template (no global embedded registry, which is
    // process-lifetime and would leak under the test allocator).
    const dir = "test_nocache_templates.tmp";
    const tplPath = dir ++ "/hello.html";
    {
        var tmp: [512]u8 = undefined;
        @memcpy(tmp[0..dir.len], dir);
        tmp[dir.len] = 0;
        _ = std.c.mkdir(tmp[0..dir.len :0], 0o755);
    }
    defer {
        fsMod.deleteFile(tplPath) catch {};
        var tmp: [512]u8 = undefined;
        @memcpy(tmp[0..dir.len], dir);
        tmp[dir.len] = 0;
        _ = std.c.rmdir(tmp[0..dir.len :0]);
    }
    try fsMod.writeFile(tplPath, "<h1>{{ title }}</h1>");

    var engine = try Engine.init(alloc, undefined, .{ .directory = dir, .enableCache = false });
    defer engine.deinit();

    var list = std.ArrayList(u8).empty;
    defer list.deinit(alloc);
    var lw = rendererMod.ListWriter{ .list = &list, .allocator = alloc };
    try engine.render("hello.html", .{ .title = "Hi" }, &lw);
    try testing.expect(std.mem.indexOf(u8, list.items, "<h1>Hi</h1>") != null);

    // Second render must work too (scratch slot recycled, no TemplateNotFound).
    list.clearRetainingCapacity();
    try engine.render("hello.html", .{ .title = "Again" }, &lw);
    try testing.expect(std.mem.indexOf(u8, list.items, "<h1>Again</h1>") != null);
}

test "Engine renders safely under concurrent load" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var engine = try Engine.init(alloc, undefined, .{});
    defer engine.deinit();

    const src = "<h1>{{ title }}</h1>{% for item in items %}<span>{{ item }}</span>{% endfor %}";
    const Worker = struct {
        fn run(eng: *Engine, out: *?[]const u8) void {
            var list = std.ArrayList(u8).empty;
            defer list.deinit(std.testing.allocator);
            var lw = rendererMod.ListWriter{ .list = &list, .allocator = std.testing.allocator };
            eng.renderString(src, .{ .title = "T", .items = [_][]const u8{ "a", "b" } }, &lw) catch {
                out.* = null;
                return;
            };
            out.* = std.testing.allocator.dupe(u8, list.items) catch null;
        }
    };
    var outs: [8]?[]const u8 = .{null} ** 8;
    defer for (outs) |o| {
        if (o) |s| alloc.free(s);
    };
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &engine, &outs[i] });
    for (&threads) |*t| t.join();
    for (outs) |o| {
        try testing.expect(o != null);
        try testing.expect(std.mem.indexOf(u8, o.?, "<h1>T</h1>") != null);
        try testing.expect(std.mem.indexOf(u8, o.?, "<span>b</span>") != null);
    }
}

test "Engine custom globals resolve in expressions" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const double = struct {
        fn f(_: ?*const anyopaque, _: Allocator, args: []const contextMod.Value, kwargs: []const rendererMod.GlobalKwarg) anyerror!contextMod.Value {
            _ = kwargs;
            if (args.len != 1 or args[0] != .integer) return .nullVal;
            return .{ .integer = args[0].integer * 2 };
        }
    }.f;

    var engine = try Engine.init(alloc, undefined, .{});
    defer engine.deinit();
    try engine.addGlobal("double", double, null);

    var list = std.ArrayList(u8).empty;
    defer list.deinit(alloc);
    var lw = rendererMod.ListWriter{ .list = &list, .allocator = alloc };
    try engine.renderString("{{ double(21) }}", .{}, &lw);
    try testing.expectEqualStrings("42", list.items);
}

test "Engine strictUndefined config fails on missing output" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var engine = try Engine.init(alloc, undefined, .{ .strictUndefined = true });
    defer engine.deinit();
    var list = std.ArrayList(u8).empty;
    defer list.deinit(alloc);
    var lw = rendererMod.ListWriter{ .list = &list, .allocator = alloc };
    try testing.expectError(error.UnknownVariable, engine.renderString("{{ nope }}", .{}, &lw));
    list.clearRetainingCapacity();
    try engine.renderString("{{ nope|default(\"ok\") }}", .{}, &lw);
    try testing.expectEqualStrings("ok", list.items);
}

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

    var lw = rendererMod.ListWriter{ .list = &list, .allocator = alloc };
    try engine.renderString(src, .{
        .title = "Hello HTTPX",
        .items = [_][]const u8{ "A", "B" },
    }, &lw);

    const out = list.items;
    try testing.expect(std.mem.indexOf(u8, out, "<h1>Hello HTTPX</h1>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<span>A</span>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<span>B</span>") != null);
}

/// Creates a temp template directory populated with `files`, returning the
/// directory path (caller must delete files + dir; see existing test).
fn makeTempDir(dir: []const u8, files: []const struct { name: []const u8, src: []const u8 }) !void {
    const fsMod = @import("../../utils/fs.zig");
    {
        var tmp: [512]u8 = undefined;
        @memcpy(tmp[0..dir.len], dir);
        tmp[dir.len] = 0;
        _ = std.c.mkdir(tmp[0..dir.len :0], 0o755);
    }
    for (files) |f| {
        var pathBuf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&pathBuf, "{s}/{s}", .{ dir, f.name });
        try fsMod.writeFile(path, f.src);
    }
}

test "Engine no-cache nested includes render" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const fsMod = @import("../../utils/fs.zig");
    const dir = "test_nocache_nested.tmp";
    try makeTempDir(dir, &.{
        .{ .name = "main.html", .src = "A{% include \"mid.html\" %}Z" },
        .{ .name = "mid.html", .src = "M{% include \"leaf.html\" %}M" },
        .{ .name = "leaf.html", .src = "L" },
    });
    defer {
        fsMod.deleteFile(dir ++ "/main.html") catch {};
        fsMod.deleteFile(dir ++ "/mid.html") catch {};
        fsMod.deleteFile(dir ++ "/leaf.html") catch {};
        var tmp: [512]u8 = undefined;
        @memcpy(tmp[0..dir.len], dir);
        tmp[dir.len] = 0;
        _ = std.c.rmdir(tmp[0..dir.len :0]);
    }
    var engine = try Engine.init(alloc, undefined, .{ .directory = dir, .enableCache = false });
    defer engine.deinit();

    var list = std.ArrayList(u8).empty;
    defer list.deinit(alloc);
    var lw = rendererMod.ListWriter{ .list = &list, .allocator = alloc };
    // Nested includes in no-cache mode used to free the outer AST while
    // the outer render still borrowed it (scratch-slot clobbering).
    try engine.render("main.html", .{}, &lw);
    try testing.expectEqualStrings("AMLMZ", list.items);
    list.clearRetainingCapacity();
    try engine.render("main.html", .{}, &lw);
    try testing.expectEqualStrings("AMLMZ", list.items);
}

test "Engine invalidates dependents and reports render errors" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const fsMod = @import("../../utils/fs.zig");
    const dir = "test_invalidate.tmp";
    try makeTempDir(dir, &.{
        .{ .name = "base.html", .src = "B:{% block c %}base{% endblock %}" },
        .{ .name = "page.html", .src = "{% extends \"base.html\" %}{% block c %}page{% endblock %}" },
    });
    defer {
        fsMod.deleteFile(dir ++ "/base.html") catch {};
        fsMod.deleteFile(dir ++ "/page.html") catch {};
        var tmp: [512]u8 = undefined;
        @memcpy(tmp[0..dir.len], dir);
        tmp[dir.len] = 0;
        _ = std.c.rmdir(tmp[0..dir.len :0]);
    }
    var engine = try Engine.init(alloc, undefined, .{ .directory = dir });
    defer engine.deinit();

    var list = std.ArrayList(u8).empty;
    defer list.deinit(alloc);
    var lw = rendererMod.ListWriter{ .list = &list, .allocator = alloc };
    try engine.render("page.html", .{}, &lw);
    try testing.expectEqualStrings("B:page", list.items);

    // Rewriting the parent + invalidating recompiles dependents.
    try fsMod.writeFile(dir ++ "/base.html", "B2:{% block c %}base{% endblock %}");
    engine.invalidate("base.html");
    list.clearRetainingCapacity();
    try engine.render("page.html", .{}, &lw);
    try testing.expectEqualStrings("B2:page", list.items);

    // Runtime failures populate lastError with template + location.
    // (Covered precisely by the strict diagnostics test below.)
}

test "Engine render frees arena nodes pushed during rendering" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const fsMod = @import("../../utils/fs.zig");
    const dir = "test_arena_free.tmp";
    try makeTempDir(dir, &.{
        .{ .name = "page.html", .src = "{% set greeting = \"hi\" %}{{ greeting }}" },
    });
    defer {
        fsMod.deleteFile(dir ++ "/page.html") catch {};
        var tmp: [512]u8 = undefined;
        @memcpy(tmp[0..dir.len], dir);
        tmp[dir.len] = 0;
        _ = std.c.rmdir(tmp[0..dir.len :0]);
    }
    var engine = try Engine.init(alloc, undefined, .{ .directory = dir });
    defer engine.deinit();

    var list = std.ArrayList(u8).empty;
    defer list.deinit(alloc);
    var lw = rendererMod.ListWriter{ .list = &list, .allocator = alloc };

    // Empty data means Context.init allocates nothing, so
    // `ctx.arena.state.used_list` stays null until the render pushes a node.
    // `{% set %}` allocates from `state.alloc` (the Context arena), which is
    // exactly the mutation that `Renderer.render`'s `*const Context`
    // parameter declares away as LLVM `readonly`: a caller may then prove
    // the list is still null and fold `defer ctx.deinit()` into nothing,
    // leaking the node. The test runner reports that as a leaked test.
    try engine.render("page.html", .{}, &lw);
    try testing.expectEqualStrings("hi", list.items);
}

test "Engine strict renderString surfaces diagnostics" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var engine = try Engine.init(alloc, undefined, .{ .strictUndefined = true });
    defer engine.deinit();
    var list = std.ArrayList(u8).empty;
    defer list.deinit(alloc);
    var lw = rendererMod.ListWriter{ .list = &list, .allocator = alloc };
    try testing.expectError(error.UnknownVariable, engine.renderString("ok {{ nope }}!", .{}, &lw));
    try testing.expect(engine.lastError != null);
    try testing.expectEqualStrings("<inline>", engine.lastError.?.templateName);
    try testing.expectEqual(@as(usize, 1), engine.lastError.?.line);
}

test "Engine concurrent render with invalidation is safe" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const fsMod = @import("../../utils/fs.zig");
    const dir = "test_concurrent.tmp";
    try makeTempDir(dir, &.{
        .{ .name = "base.html", .src = "B:{% block c %}base{% endblock %}" },
        .{ .name = "page.html", .src = "{% extends \"base.html\" %}{% block c %}p{{ v }}{% endblock %}" },
    });
    defer {
        fsMod.deleteFile(dir ++ "/base.html") catch {};
        fsMod.deleteFile(dir ++ "/page.html") catch {};
        var tmp: [512]u8 = undefined;
        @memcpy(tmp[0..dir.len], dir);
        tmp[dir.len] = 0;
        _ = std.c.rmdir(tmp[0..dir.len :0]);
    }
    var engine = try Engine.init(alloc, undefined, .{ .directory = dir });
    defer engine.deinit();

    const Worker = struct {
        fn run(eng: *Engine, stop: *std.atomic.Value(bool)) void {
            var i: usize = 0;
            while (!stop.load(.acquire) and i < 200) : (i += 1) {
                var list = std.ArrayList(u8).empty;
                defer list.deinit(std.testing.allocator);
                var lw = rendererMod.ListWriter{ .list = &list, .allocator = std.testing.allocator };
                eng.render("page.html", .{ .v = @as(i32, 1) }, &lw) catch continue;
            }
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    var threads: [4]std.Thread = undefined;
    for (&threads) |*th| th.* = std.Thread.spawn(.{}, Worker.run, .{ &engine, &stop }) catch return;
    var k: usize = 0;
    while (k < 20) : (k += 1) {
        engine.invalidate("base.html");
        std.Thread.yield() catch {};
    }
    stop.store(true, .release);
    for (&threads) |*th| th.join();
    // Cache still coherent after the storm.
    var list = std.ArrayList(u8).empty;
    defer list.deinit(alloc);
    var lw = rendererMod.ListWriter{ .list = &list, .allocator = alloc };
    try engine.render("page.html", .{ .v = @as(i32, 2) }, &lw);
    try testing.expectEqualStrings("B:p2", list.items);
}

test "Engine concurrent failing renders do not mix their diagnostics" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const fsMod = @import("../../utils/fs.zig");
    const dir = "test_diag_race.tmp";
    // Two templates that fail on different lines, so a report that mixes one
    // template's name with the other's line is detectable rather than merely
    // wrong. `strictUndefined` turns the missing variable into the failure.
    try makeTempDir(dir, &.{
        .{ .name = "a.html", .src = "one\n{{ missing_a }}\n" },
        .{ .name = "b.html", .src = "one\ntwo\nthree\n{{ missing_b }}\n" },
    });
    defer {
        fsMod.deleteFile(dir ++ "/a.html") catch {};
        fsMod.deleteFile(dir ++ "/b.html") catch {};
        var tmp: [512]u8 = undefined;
        @memcpy(tmp[0..dir.len], dir);
        tmp[dir.len] = 0;
        _ = std.c.rmdir(tmp[0..dir.len :0]);
    }
    var engine = try Engine.init(alloc, undefined, .{ .directory = dir, .strictUndefined = true });
    defer engine.deinit();

    const Worker = struct {
        fn run(eng: *Engine, which: usize) void {
            const name = if (which % 2 == 0) "a.html" else "b.html";
            var i: usize = 0;
            while (i < 300) : (i += 1) {
                var list = std.ArrayList(u8).empty;
                defer list.deinit(std.testing.allocator);
                var lw = rendererMod.ListWriter{ .list = &list, .allocator = std.testing.allocator };
                eng.render(name, .{}, &lw) catch {};
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*th, n| th.* = try std.Thread.spawn(.{}, Worker.run, .{ &engine, n });
    for (&threads) |*th| th.join();

    // Threads are joined, so whatever is in `lastError` came from one finished
    // render. What is asserted is that the report is self-consistent: the line
    // belongs to the template named alongside it.
    //
    // Scope of this test, stated plainly: it does NOT catch the bug it was
    // written for. Verified by reintroducing the shared field and running this
    // at 4 threads x 2000 iterations over 8 cores -- it still passed, because
    // the window between the render failing and the location being read is a
    // few instructions and nothing in it is ever observed to go wrong on this
    // machine. ThreadSanitizer is not an option either: `-fsanitize-thread`
    // builds and links, but it fails to report a deliberately unsynchronised
    // counter written by two threads, so it cannot be trusted to report
    // anything here.
    //
    // So the fix rests on the ownership argument, not on this test: the
    // location now lives in a `RenderCtx` owned by the thread running that
    // render, so no interleaving can attribute another render's position to
    // this one. Keeping the test is still worth it as a smoke test that
    // concurrent failing renders leave the engine coherent, which is the
    // property that would break first if the ownership were lost again.
    const reported = engine.lastError orelse return error.TestExpectedErrorReported;
    const selfConsistent =
        (std.mem.eql(u8, reported.templateName, "a.html") and reported.line == 2) or
        (std.mem.eql(u8, reported.templateName, "b.html") and reported.line == 4);
    try testing.expect(selfConsistent);
}
