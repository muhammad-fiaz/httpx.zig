//! Template renderer.
//!
//! Evaluates compiled template ASTs against Context values, supporting:
//!   - Secure auto-escaping of HTML characters (&, <, >, ", ')
//!   - Raw trusted HTML bypass via RawHtml/Value.rawHtml
//!   - Dot-path variable lookups and basic conditional expressions
//!   - Template inheritance ({% extends %}, {% block %}) with block overrides
//!   - Reusable includes ({% include %}) with recursion and cycle detection
//!   - Loops ({% for %}) with loop metadata (index, first, last, length)
//!   - Direct streaming to any Zig writer

const std = @import("std");
const Allocator = std.mem.Allocator;
const context_mod = @import("context.zig");
const parser_mod = @import("parser.zig");
const err_mod = @import("error.zig");

pub const Value = context_mod.Value;
pub const Context = context_mod.Context;
pub const TemplateAst = parser_mod.TemplateAst;
pub const TemplateNode = parser_mod.TemplateNode;
pub const BlockInfo = parser_mod.BlockInfo;
pub const TemplateError = err_mod.TemplateError;

/// Minimal provider interface used by renderer to retrieve ASTs for includes and parent templates.
pub const TemplateProvider = struct {
    ptr: *const anyopaque,
    getAstFn: *const fn (ptr: *const anyopaque, name: []const u8) ?*const TemplateAst,

    pub fn getAst(self: TemplateProvider, name: []const u8) ?*const TemplateAst {
        return self.getAstFn(self.ptr, name);
    }
};

/// Writes string content escaping HTML special characters: &, <, >, ", '
pub fn writeEscaped(writer: anytype, text: []const u8) !void {
    var last: usize = 0;
    for (text, 0..) |c, i| {
        const replacement: ?[]const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => null,
        };
        if (replacement) |escaped| {
            if (i > last) {
                try writer.writeAll(text[last..i]);
            }
            try writer.writeAll(escaped);
            last = i + 1;
        }
    }
    if (last < text.len) {
        try writer.writeAll(text[last..]);
    }
}

pub const RenderOptions = struct {
    maxIncludeDepth: usize = 32,
    maxInheritanceDepth: usize = 16,
};

pub const ListWriter = struct {
    list: *std.ArrayList(u8),
    allocator: Allocator,

    pub fn writeAll(self: *ListWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }

    pub fn print(self: *ListWriter, comptime fmt: []const u8, args: anytype) !void {
        const formatted = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(formatted);
        try self.list.appendSlice(self.allocator, formatted);
    }
};

pub const Renderer = struct {
    options: RenderOptions = .{},

    /// Renders a template AST directly to any writer.
    pub fn render(
        self: Renderer,
        ast: *const TemplateAst,
        ctx: *const Context,
        provider: ?TemplateProvider,
        writer: anytype,
    ) !void {
        var stack_buf: [32][]const u8 = undefined;
        var depth: usize = 0;
        try self.renderInternal(ast, ctx, provider, writer, ast.blocks, stack_buf[0..0], &depth);
    }

    /// Renders a template AST to an allocated string.
    pub fn renderToString(
        self: Renderer,
        allocator: Allocator,
        ast: *const TemplateAst,
        ctx: *const Context,
        provider: ?TemplateProvider,
    ) ![]u8 {
        var list = std.ArrayList(u8).empty;
        errdefer list.deinit(allocator);
        var lw = ListWriter{ .list = &list, .allocator = allocator };
        try self.render(ast, ctx, provider, &lw);
        return try list.toOwnedSlice(allocator);
    }

    fn renderInternal(
        self: Renderer,
        ast: *const TemplateAst,
        ctx: *const Context,
        provider: ?TemplateProvider,
        writer: anytype,
        block_overrides: []const BlockInfo,
        include_stack: []const []const u8,
        inheritance_depth: *usize,
    ) anyerror!void {
        // Handle inheritance: if ast extends a parent, render parent with block overrides
        if (ast.extendsPath) |parentPath| {
            inheritance_depth.* += 1;
            if (inheritance_depth.* > self.options.maxInheritanceDepth) {
                return TemplateError.DepthLimitExceeded;
            }

            const p = provider orelse return TemplateError.TemplateNotFound;
            const parent_ast = p.getAst(parentPath) orelse return TemplateError.TemplateNotFound;

            // Merge block overrides: current ast's blocks take precedence over inherited blocks
            var combined_blocks = std.ArrayList(BlockInfo).empty;
            defer combined_blocks.deinit(ctx.arena.child_allocator);

            for (ast.blocks) |b| {
                try combined_blocks.append(ctx.arena.child_allocator, b);
            }
            for (block_overrides) |b| {
                var found = false;
                for (ast.blocks) |existing| {
                    if (std.mem.eql(u8, existing.name, b.name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try combined_blocks.append(ctx.arena.child_allocator, b);
                }
            }

            return self.renderInternal(
                parent_ast,
                ctx,
                provider,
                writer,
                combined_blocks.items,
                include_stack,
                inheritance_depth,
            );
        }

        // Render nodes of current AST
        try self.renderNodes(ast.nodes, ctx, provider, writer, block_overrides, include_stack, inheritance_depth);
    }

    fn renderNodes(
        self: Renderer,
        nodes: []const TemplateNode,
        ctx: *const Context,
        provider: ?TemplateProvider,
        writer: anytype,
        block_overrides: []const BlockInfo,
        include_stack: []const []const u8,
        inheritance_depth: *usize,
    ) anyerror!void {
        for (nodes) |node| {
            switch (node) {
                .text => |txt| {
                    try writer.writeAll(txt);
                },
                .expression => |expr_info| {
                    try self.renderExpression(expr_info.expr, ctx, writer);
                },
                .ifBlock => |if_info| {
                    const is_true = self.evalCondition(ctx, if_info.condition);
                    if (is_true) {
                        try self.renderNodes(if_info.thenNodes, ctx, provider, writer, block_overrides, include_stack, inheritance_depth);
                    } else if (if_info.elseNodes.len > 0) {
                        try self.renderNodes(if_info.elseNodes, ctx, provider, writer, block_overrides, include_stack, inheritance_depth);
                    }
                },
                .forLoop => |for_info| {
                    try self.renderForLoop(for_info, ctx, provider, writer, block_overrides, include_stack, inheritance_depth);
                },
                .block => |block_info| {
                    // Check if block is overridden by a child template
                    var block_to_render = block_info.bodyNodes;
                    for (block_overrides) |ov| {
                        if (std.mem.eql(u8, ov.name, block_info.name)) {
                            block_to_render = ov.nodes;
                            break;
                        }
                    }
                    try self.renderNodes(block_to_render, ctx, provider, writer, block_overrides, include_stack, inheritance_depth);
                },
                .extends => {
                    // Handled at template root level
                },
                .include => |inc_info| {
                    if (include_stack.len >= self.options.maxIncludeDepth) {
                        return TemplateError.DepthLimitExceeded;
                    }
                    for (include_stack) |item| {
                        if (std.mem.eql(u8, item, inc_info.templatePath)) {
                            return TemplateError.CircularInclude;
                        }
                    }

                    const p = provider orelse return TemplateError.TemplateNotFound;
                    const inc_ast = p.getAst(inc_info.templatePath) orelse return TemplateError.TemplateNotFound;

                    // Allocate next include stack
                    const new_stack = try ctx.arena.child_allocator.alloc([]const u8, include_stack.len + 1);
                    defer ctx.arena.child_allocator.free(new_stack);
                    @memcpy(new_stack[0..include_stack.len], include_stack);
                    new_stack[include_stack.len] = inc_info.templatePath;

                    try self.renderInternal(
                        inc_ast,
                        ctx,
                        provider,
                        writer,
                        &[_]BlockInfo{},
                        new_stack,
                        inheritance_depth,
                    );
                },
            }
        }
    }

    fn renderExpression(self: Renderer, expr: []const u8, ctx: *const Context, writer: anytype) !void {
        _ = self;
        const trimmed = std.mem.trim(u8, expr, " \t\r\n");
        if (trimmed.len == 0) return;

        // String literal?
        if (trimmed.len >= 2 and ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\''))) {
            try writeEscaped(writer, trimmed[1 .. trimmed.len - 1]);
            return;
        }

        const val = ctx.get(trimmed) orelse return;
        switch (val) {
            .nullVal => {},
            .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
            .integer => |i| try writer.print("{d}", .{i}),
            .float => |f| try writer.print("{d}", .{f}),
            .string => |s| try writeEscaped(writer, s),
            .rawHtml => |h| try writer.writeAll(h),
            .list => {},
            .map => {},
        }
    }

    fn evalCondition(self: Renderer, ctx: *const Context, cond_str: []const u8) bool {
        _ = self;
        const s = std.mem.trim(u8, cond_str, " \t\r\n");
        if (s.len == 0) return false;

        // Negation: !expr
        if (s[0] == '!') {
            const inner = std.mem.trim(u8, s[1..], " \t\r\n");
            return !evalSimpleValue(ctx, inner).isTruthy();
        }

        // Equality: a == b
        if (std.mem.indexOf(u8, s, "==")) |idx| {
            const left_s = std.mem.trim(u8, s[0..idx], " \t\r\n");
            const right_s = std.mem.trim(u8, s[idx + 2 ..], " \t\r\n");
            const left_val = evalSimpleValue(ctx, left_s);
            const right_val = evalSimpleValue(ctx, right_s);
            return left_val.equals(right_val);
        }

        // Inequality: a != b
        if (std.mem.indexOf(u8, s, "!=")) |idx| {
            const left_s = std.mem.trim(u8, s[0..idx], " \t\r\n");
            const right_s = std.mem.trim(u8, s[idx + 2 ..], " \t\r\n");
            const left_val = evalSimpleValue(ctx, left_s);
            const right_val = evalSimpleValue(ctx, right_s);
            return !left_val.equals(right_val);
        }

        return evalSimpleValue(ctx, s).isTruthy();
    }

    fn evalSimpleValue(ctx: *const Context, expr: []const u8) Value {
        const s = std.mem.trim(u8, expr, " \t\r\n");
        if (std.mem.eql(u8, s, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, s, "false")) return .{ .boolean = false };
        if (std.mem.eql(u8, s, "null")) return .nullVal;

        // Quoted string literal
        if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\''))) {
            return .{ .string = s[1 .. s.len - 1] };
        }

        // Number literal
        if (std.fmt.parseInt(i64, s, 10)) |num| {
            return .{ .integer = num };
        } else |_| {}

        // Look up variable in context
        return ctx.get(s) orelse .nullVal;
    }

    fn renderForLoop(
        self: Renderer,
        for_info: anytype,
        ctx: *const Context,
        provider: ?TemplateProvider,
        writer: anytype,
        block_overrides: []const BlockInfo,
        include_stack: []const []const u8,
        inheritance_depth: *usize,
    ) anyerror!void {
        const coll_val = ctx.get(for_info.collectionExpr) orelse return;
        const items = switch (coll_val) {
            .list => |l| l,
            else => return,
        };

        const original_root = ctx.root;

        for (items, 0..) |item, i| {
            // Build loop metadata: loop.index (1-based), loop.first, loop.last, loop.length
            const loop_meta_entries = try ctx.arena.child_allocator.alloc(context_mod.Entry, 5);
            defer ctx.arena.child_allocator.free(loop_meta_entries);
            loop_meta_entries[0] = .{ .key = "index", .value = .{ .integer = @intCast(i + 1) } };
            loop_meta_entries[1] = .{ .key = "index0", .value = .{ .integer = @intCast(i) } };
            loop_meta_entries[2] = .{ .key = "first", .value = .{ .boolean = (i == 0) } };
            loop_meta_entries[3] = .{ .key = "last", .value = .{ .boolean = (i + 1 == items.len) } };
            loop_meta_entries[4] = .{ .key = "length", .value = .{ .integer = @intCast(items.len) } };

            // Create temporary overlaid map containing itemVar and loop metadata
            var orig_entries: []const context_mod.Entry = &[_]context_mod.Entry{};
            if (original_root == .map) {
                orig_entries = original_root.map;
            }

            const scoped_entries = try ctx.arena.child_allocator.alloc(context_mod.Entry, orig_entries.len + 2);
            defer ctx.arena.child_allocator.free(scoped_entries);
            @memcpy(scoped_entries[0..orig_entries.len], orig_entries);
            scoped_entries[orig_entries.len] = .{ .key = for_info.itemVar, .value = item };
            scoped_entries[orig_entries.len + 1] = .{ .key = "loop", .value = .{ .map = loop_meta_entries } };

            const scoped_ctx: Context = .{
                .arena = undefined,
                .root = .{ .map = scoped_entries },
            };

            try self.renderNodes(for_info.bodyNodes, &scoped_ctx, provider, writer, block_overrides, include_stack, inheritance_depth);
        }
    }
};

test "Renderer escapes HTML and supports raw HTML" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const src = "<title>{{ title }}</title><body>{{ safe_body }}</body>";
    var parser = parser_mod.Parser.init(alloc, "test.html", src);
    var ast = try parser.parse();
    defer ast.deinit();

    var ctx = try Context.init(alloc, .{
        .title = "<script>alert('xss')</script> & \"more\"",
        .safe_body = context_mod.raw("<b>Trusted Content</b>"),
    });
    defer ctx.deinit();

    const renderer = Renderer{};
    const output = try renderer.renderToString(alloc, &ast, &ctx, null);
    defer alloc.free(output);

    const expected = "<title>&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt; &amp; &quot;more&quot;</title><body><b>Trusted Content</b></body>";
    try testing.expectEqualStrings(expected, output);
}

test "Renderer evaluates conditionals and loops" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const src =
        \\{% if user %}
        \\Hello {{ user.name }}!
        \\{% endif %}
        \\Items:
        \\{% for item in items %}
        \\{{ loop.index }}: {{ item }}
        \\{% endfor %}
    ;

    var parser = parser_mod.Parser.init(alloc, "test.html", src);
    var ast = try parser.parse();
    defer ast.deinit();

    var ctx = try Context.init(alloc, .{
        .user = .{ .name = "Muhammad" },
        .items = [_][]const u8{ "apple", "banana" },
    });
    defer ctx.deinit();

    const renderer = Renderer{};
    const output = try renderer.renderToString(alloc, &ast, &ctx, null);
    defer alloc.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "Hello Muhammad!") != null);
    try testing.expect(std.mem.indexOf(u8, output, "1: apple") != null);
    try testing.expect(std.mem.indexOf(u8, output, "2: banana") != null);
}
