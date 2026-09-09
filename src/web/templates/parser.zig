//! Template syntax tokenizer and AST parser.
//!
//! Parses template source containing:
//!   - Expressions: {{ value }}, {{ user.name }}
//!   - Conditionals: {% if cond %}, {% else %}, {% endif %}
//!   - Loops: {% for item in items %}, {% endfor %}
//!   - Inheritance: {% extends "base.html" %}, {% block name %}, {% endblock %}
//!   - Partials: {% include "file.html" %}
//!   - Comments: {# comment #}

const std = @import("std");
const Allocator = std.mem.Allocator;
const err_mod = @import("error.zig");
pub const TemplateError = err_mod.TemplateError;
pub const SourceError = err_mod.SourceError;
pub const lineColFromOffset = err_mod.lineColFromOffset;

pub const TemplateNode = union(enum) {
    text: []const u8,
    expression: struct {
        expr: []const u8,
        startByte: usize,
        line: usize,
        col: usize,
    },
    ifBlock: struct {
        condition: []const u8,
        thenNodes: []const TemplateNode,
        elseNodes: []const TemplateNode,
        startByte: usize,
        line: usize,
        col: usize,
    },
    forLoop: struct {
        itemVar: []const u8,
        collectionExpr: []const u8,
        bodyNodes: []const TemplateNode,
        startByte: usize,
        line: usize,
        col: usize,
    },
    block: struct {
        name: []const u8,
        bodyNodes: []const TemplateNode,
        startByte: usize,
        line: usize,
        col: usize,
    },
    extends: struct {
        parentPath: []const u8,
        startByte: usize,
        line: usize,
        col: usize,
    },
    include: struct {
        templatePath: []const u8,
        startByte: usize,
        line: usize,
        col: usize,
    },
};

pub const BlockInfo = struct {
    name: []const u8,
    nodes: []const TemplateNode,
};

pub const TemplateAst = struct {
    nodes: []const TemplateNode,
    extendsPath: ?[]const u8 = null,
    blocks: []const BlockInfo,
    includes: [][]const u8,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *TemplateAst) void {
        self.arena.deinit();
    }
};

pub const Parser = struct {
    allocator: Allocator,
    templateName: []const u8,
    source: []const u8,
    pos: usize = 0,
    lastError: ?SourceError = null,

    pub fn init(allocator: Allocator, templateName: []const u8, source: []const u8) Parser {
        return .{
            .allocator = allocator,
            .templateName = templateName,
            .source = source,
            .pos = 0,
        };
    }

    pub fn parse(self: *Parser) !TemplateAst {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var nodes_list = std.ArrayList(TemplateNode).empty;
        var blocks_list = std.ArrayList(BlockInfo).empty;
        var includes_list = std.ArrayList([]const u8).empty;
        var extendsPath: ?[]const u8 = null;

        try self.parseNodes(a, &nodes_list, &blocks_list, &includes_list, &extendsPath, null);

        return .{
            .nodes = try nodes_list.toOwnedSlice(a),
            .extendsPath = extendsPath,
            .blocks = try blocks_list.toOwnedSlice(a),
            .includes = try includes_list.toOwnedSlice(a),
            .arena = arena,
        };
    }

    fn fail(self: *Parser, kind: err_mod.TemplateErrorKind, offset: usize, message: []const u8) TemplateError {
        const loc = lineColFromOffset(self.source, offset);
        self.lastError = .{
            .kind = kind,
            .templateName = self.templateName,
            .line = loc.line,
            .column = loc.col,
            .byteOffset = offset,
            .message = message,
        };
        return switch (kind) {
            .syntax_error => TemplateError.SyntaxError,
            .unexpected_token => TemplateError.UnexpectedToken,
            .unclosed_block => TemplateError.UnclosedBlock,
            .unclosed_expression => TemplateError.UnclosedExpression,
            else => TemplateError.SyntaxError,
        };
    }

    fn parseNodes(
        self: *Parser,
        a: Allocator,
        out_nodes: *std.ArrayList(TemplateNode),
        blocks_list: *std.ArrayList(BlockInfo),
        includes_list: *std.ArrayList([]const u8),
        extendsPath: *?[]const u8,
        stop_tag: ?[]const u8,
    ) TemplateError!void {
        while (self.pos < self.source.len) {
            const next_open = std.mem.indexOfPos(u8, self.source, self.pos, "{");
            if (next_open == null) {
                // Remainder is plain text
                const text = self.source[self.pos..];
                if (text.len > 0) {
                    try out_nodes.append(a, .{ .text = text });
                }
                self.pos = self.source.len;
                break;
            }

            const open_idx = next_open.?;
            if (open_idx > self.pos) {
                try out_nodes.append(a, .{ .text = self.source[self.pos..open_idx] });
                self.pos = open_idx;
            }

            if (open_idx + 1 >= self.source.len) {
                try out_nodes.append(a, .{ .text = self.source[open_idx..] });
                self.pos = self.source.len;
                break;
            }

            const second = self.source[open_idx + 1];
            if (second == '{') {
                // Expression: {{ ... }}
                const expr_start = self.pos;
                const close_idx = std.mem.indexOfPos(u8, self.source, open_idx + 2, "}}") orelse {
                    return self.fail(.unclosed_expression, expr_start, "unclosed expression, expected '}}'");
                };
                const raw_expr = std.mem.trim(u8, self.source[open_idx + 2 .. close_idx], " \t\r\n");
                const loc = lineColFromOffset(self.source, expr_start);
                try out_nodes.append(a, .{
                    .expression = .{
                        .expr = raw_expr,
                        .startByte = expr_start,
                        .line = loc.line,
                        .col = loc.col,
                    },
                });
                self.pos = close_idx + 2;
            } else if (second == '#') {
                // Comment: {# ... #}
                const close_idx = std.mem.indexOfPos(u8, self.source, open_idx + 2, "#}") orelse {
                    return self.fail(.syntax_error, open_idx, "unclosed comment, expected '#}'");
                };
                self.pos = close_idx + 2;
            } else if (second == '%') {
                // Directive: {% ... %}
                const tag_start = self.pos;
                const close_idx = std.mem.indexOfPos(u8, self.source, open_idx + 2, "%}") orelse {
                    return self.fail(.syntax_error, tag_start, "unclosed directive, expected '%}'");
                };

                const tag_content = std.mem.trim(u8, self.source[open_idx + 2 .. close_idx], " \t\r\n");
                var tag_it = std.mem.tokenizeAny(u8, tag_content, " \t\r\n");
                const tag_cmd = tag_it.next() orelse "";

                // Check if this matches stop_tag
                if (stop_tag) |target| {
                    if (std.mem.eql(u8, tag_cmd, target) or
                        (std.mem.eql(u8, target, "endif_or_else") and (std.mem.eql(u8, tag_cmd, "else") or std.mem.eql(u8, tag_cmd, "endif"))))
                    {
                        // Stop before consuming this tag; parent will consume
                        return;
                    }
                }

                self.pos = close_idx + 2;
                const loc = lineColFromOffset(self.source, tag_start);

                if (std.mem.eql(u8, tag_cmd, "if")) {
                    const condition = std.mem.trim(u8, tag_content[2..], " \t\r\n");
                    var thenNodes = std.ArrayList(TemplateNode).empty;
                    var elseNodes = std.ArrayList(TemplateNode).empty;

                    try self.parseNodes(a, &thenNodes, blocks_list, includes_list, extendsPath, "endif_or_else");

                    if (self.pos < self.source.len) {
                        const next_dir_close = std.mem.indexOfPos(u8, self.source, self.pos, "%}") orelse {
                            return self.fail(.unclosed_block, tag_start, "expected {% else %} or {% endif %}");
                        };
                        const next_dir = std.mem.trim(u8, self.source[self.pos + 2 .. next_dir_close], " \t\r\n");
                        if (std.mem.startsWith(u8, next_dir, "else")) {
                            self.pos = next_dir_close + 2;
                            try self.parseNodes(a, &elseNodes, blocks_list, includes_list, extendsPath, "endif");
                            if (self.pos < self.source.len) {
                                const end_close = std.mem.indexOfPos(u8, self.source, self.pos, "%}") orelse {
                                    return self.fail(.unclosed_block, tag_start, "expected {% endif %}");
                                };
                                self.pos = end_close + 2;
                            }
                        } else if (std.mem.startsWith(u8, next_dir, "endif")) {
                            self.pos = next_dir_close + 2;
                        }
                    } else {
                        return self.fail(.unclosed_block, tag_start, "unclosed {% if %}, expected {% endif %}");
                    }

                    try out_nodes.append(a, .{
                        .ifBlock = .{
                            .condition = condition,
                            .thenNodes = try thenNodes.toOwnedSlice(a),
                            .elseNodes = try elseNodes.toOwnedSlice(a),
                            .startByte = tag_start,
                            .line = loc.line,
                            .col = loc.col,
                        },
                    });
                } else if (std.mem.eql(u8, tag_cmd, "for")) {
                    // Syntax: {% for item in collection %}
                    const remainder = std.mem.trim(u8, tag_content[3..], " \t\r\n");
                    const in_pos = std.mem.indexOf(u8, remainder, " in ") orelse {
                        return self.fail(.syntax_error, tag_start, "invalid for loop syntax, expected '{% for item in items %}'");
                    };
                    const itemVar = std.mem.trim(u8, remainder[0..in_pos], " \t\r\n");
                    const coll_expr = std.mem.trim(u8, remainder[in_pos + 4 ..], " \t\r\n");

                    var bodyNodes = std.ArrayList(TemplateNode).empty;
                    try self.parseNodes(a, &bodyNodes, blocks_list, includes_list, extendsPath, "endfor");

                    if (self.pos < self.source.len) {
                        const end_close = std.mem.indexOfPos(u8, self.source, self.pos, "%}") orelse {
                            return self.fail(.unclosed_block, tag_start, "expected {% endfor %}");
                        };
                        self.pos = end_close + 2;
                    } else {
                        return self.fail(.unclosed_block, tag_start, "unclosed {% for %}, expected {% endfor %}");
                    }

                    try out_nodes.append(a, .{
                        .forLoop = .{
                            .itemVar = itemVar,
                            .collectionExpr = coll_expr,
                            .bodyNodes = try bodyNodes.toOwnedSlice(a),
                            .startByte = tag_start,
                            .line = loc.line,
                            .col = loc.col,
                        },
                    });
                } else if (std.mem.eql(u8, tag_cmd, "block")) {
                    const block_name = std.mem.trim(u8, tag_content[5..], " \t\r\n");
                    if (block_name.len == 0) {
                        return self.fail(.syntax_error, tag_start, "expected block name in '{% block name %}'");
                    }

                    var bodyNodes = std.ArrayList(TemplateNode).empty;
                    try self.parseNodes(a, &bodyNodes, blocks_list, includes_list, extendsPath, "endblock");

                    if (self.pos < self.source.len) {
                        const end_close = std.mem.indexOfPos(u8, self.source, self.pos, "%}") orelse {
                            return self.fail(.unclosed_block, tag_start, "expected {% endblock %}");
                        };
                        self.pos = end_close + 2;
                    } else {
                        return self.fail(.unclosed_block, tag_start, "unclosed {% block %}, expected {% endblock %}");
                    }

                    const owned_body = try bodyNodes.toOwnedSlice(a);
                    try blocks_list.append(a, .{
                        .name = block_name,
                        .nodes = owned_body,
                    });

                    try out_nodes.append(a, .{
                        .block = .{
                            .name = block_name,
                            .bodyNodes = owned_body,
                            .startByte = tag_start,
                            .line = loc.line,
                            .col = loc.col,
                        },
                    });
                } else if (std.mem.eql(u8, tag_cmd, "extends")) {
                    const raw_path = std.mem.trim(u8, tag_content[7..], " \t\r\n");
                    const path = parseQuotedString(raw_path) orelse {
                        return self.fail(.syntax_error, tag_start, "invalid path in '{% extends \"...\" %}'");
                    };
                    extendsPath.* = path;
                    try out_nodes.append(a, .{
                        .extends = .{
                            .parentPath = path,
                            .startByte = tag_start,
                            .line = loc.line,
                            .col = loc.col,
                        },
                    });
                } else if (std.mem.eql(u8, tag_cmd, "include")) {
                    const raw_path = std.mem.trim(u8, tag_content[7..], " \t\r\n");
                    const path = parseQuotedString(raw_path) orelse {
                        return self.fail(.syntax_error, tag_start, "invalid path in '{% include \"...\" %}'");
                    };
                    try includes_list.append(a, path);
                    try out_nodes.append(a, .{
                        .include = .{
                            .templatePath = path,
                            .startByte = tag_start,
                            .line = loc.line,
                            .col = loc.col,
                        },
                    });
                } else {
                    return self.fail(.unexpected_token, tag_start, "unknown template directive");
                }
            } else {
                // Just a solitary '{'
                try out_nodes.append(a, .{ .text = self.source[open_idx .. open_idx + 1] });
                self.pos = open_idx + 1;
            }
        }
    }
};

fn parseQuotedString(s: []const u8) ?[]const u8 {
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\''))) {
        return s[1 .. s.len - 1];
    }
    return null;
}

test "Parser parses expressions, conditionals, and loops" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const src =
        \\<h1>{{ title }}</h1>
        \\{% if user %}
        \\  <p>Hello {{ user.name }}</p>
        \\{% else %}
        \\  <p>Guest</p>
        \\{% endif %}
        \\<ul>
        \\{% for item in items %}
        \\  <li>{{ item }}</li>
        \\{% endfor %}
        \\</ul>
    ;

    var parser = Parser.init(alloc, "test.html", src);
    var ast = try parser.parse();
    defer ast.deinit();

    try testing.expect(ast.nodes.len > 0);
    try testing.expect(ast.extendsPath == null);
}

test "Parser parses blocks, extends, and includes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const src =
        \\{% extends "base.html" %}
        \\{% block content %}
        \\  {% include "partials/header.html" %}
        \\  <p>Body</p>
        \\{% endblock %}
    ;

    var parser = Parser.init(alloc, "child.html", src);
    var ast = try parser.parse();
    defer ast.deinit();

    try testing.expectEqualStrings("base.html", ast.extendsPath.?);
    try testing.expectEqual(@as(usize, 1), ast.blocks.len);
    try testing.expectEqualStrings("content", ast.blocks[0].name);
    try testing.expectEqual(@as(usize, 1), ast.includes.len);
    try testing.expectEqualStrings("partials/header.html", ast.includes[0]);
}

test "Parser reports syntax errors with line/column" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const src = "line 1\n{% if unclosed %}\nhello";
    var parser = Parser.init(alloc, "bad.html", src);
    const res = parser.parse();
    try testing.expectError(TemplateError.UnclosedBlock, res);
    try testing.expect(parser.lastError != null);
    try testing.expectEqual(@as(usize, 2), parser.lastError.?.line);
}
