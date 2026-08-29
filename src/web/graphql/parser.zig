//! GraphQL Lexer and Recursive Descent Parser.
//!
//! Follows GraphQL specification (October 2021):
//! - Ignored tokens: whitespace, commas, comments (#)
//! - Operation parsing (query, mutation, subscription, shorthand)
//! - Arguments, directives, variable definitions, fragments
//! - Full value tree (scalars, enums, objects, lists)
//! - Depth and complexity limits protection
//!
//! References:
//!   - GraphQL Specification Section 2 — Language

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");

pub const ParseLimits = struct {
    max_depth: usize = 64,
    max_tokens: usize = 10000,
    max_length: usize = 1024 * 1024,
};

pub const ParseError = error{
    OutOfMemory,
    RequestEntityTooLarge,
    TokenLimitExceeded,
    UnterminatedString,
    UnexpectedCharacter,
    EmptyDocument,
    ExpectedDefinition,
    ExpectedFragmentName,
    ExpectedOnKeyword,
    ExpectedTypeCondition,
    ExpectedDollar,
    ExpectedVariableName,
    ExpectedColon,
    ExpectedTypeName,
    ExpectedClosingBracket,
    ExpectedClosingParen,
    ExpectedDirectiveName,
    ExpectedArgumentName,
    ExpectedBraceOpen,
    ExpectedBraceClose,
    ExpectedFieldName,
    MaxQueryDepthExceeded,
    InvalidInt,
    InvalidFloat,
    ExpectedBracketClose,
    UnexpectedValueToken,
};

pub const Parser = struct {
    allocator: Allocator,
    source: []const u8,
    pos: usize = 0,
    current_token: ast.Token = .{ .kind = .eof, .text = "", .pos = 0 },
    tokens_read: usize = 0,
    current_depth: usize = 0,
    limits: ParseLimits,

    pub fn init(allocator: Allocator, source: []const u8, limits: ParseLimits) ParseError!Parser {
        if (source.len > limits.max_length) return error.RequestEntityTooLarge;
        var p = Parser{
            .allocator = allocator,
            .source = source,
            .limits = limits,
        };
        try p.advance();
        return p;
    }

    fn skipWhitespaceAndComments(self: *Parser) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == ',') {
                self.pos += 1;
            } else if (c == '#') {
                while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                    self.pos += 1;
                }
            } else {
                break;
            }
        }
    }

    fn isNameStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }

    fn isNameContinue(c: u8) bool {
        return isNameStart(c) or (c >= '0' and c <= '9');
    }

    pub fn advance(self: *Parser) !void {
        self.skipWhitespaceAndComments();
        if (self.pos >= self.source.len) {
            self.current_token = .{ .kind = .eof, .text = "", .pos = self.pos };
            return;
        }

        self.tokens_read += 1;
        if (self.tokens_read > self.limits.max_tokens) {
            return error.TokenLimitExceeded;
        }

        const start = self.pos;
        const c = self.source[self.pos];

        if (c == '!') {
            self.pos += 1;
            self.current_token = .{ .kind = .punctuator_bang, .text = self.source[start..self.pos], .pos = start };
        } else if (c == '$') {
            self.pos += 1;
            self.current_token = .{ .kind = .punctuator_dollar, .text = self.source[start..self.pos], .pos = start };
        } else if (c == '&') {
            self.pos += 1;
            self.current_token = .{ .kind = .punctuator_amp, .text = self.source[start..self.pos], .pos = start };
        } else if (c == '(') {
            self.pos += 1;
            self.current_token = .{ .kind = .punctuator_paren_l, .text = self.source[start..self.pos], .pos = start };
        } else if (c == ')') {
            self.pos += 1;
            self.current_token = .{ .kind = .punctuator_paren_r, .text = self.source[start..self.pos], .pos = start };
        } else if (c == ':') {
            self.pos += 1;
            self.current_token = .{ .kind = .punctuator_colon, .text = self.source[start..self.pos], .pos = start };
        } else if (c == '=') {
            self.pos += 1;
            self.current_token = .{ .kind = .punctuator_equals, .text = self.source[start..self.pos], .pos = start };
        } else if (c == '@') {
            self.pos += 1;
            self.current_token = .{ .kind = .punctuator_at, .text = self.source[start..self.pos], .pos = start };
        } else if (c == '[') {
            self.pos += 1;
            self.current_token = .{ .kind = .punctuator_bracket_l, .text = self.source[start..self.pos], .pos = start };
        } else if (c == ']') {
            self.pos += 1;
            self.current_token = .{ .kind = .punctuator_bracket_r, .text = self.source[start..self.pos], .pos = start };
        } else if (c == '{') {
            self.pos += 1;
            self.current_token = .{ .kind = .punctuator_brace_l, .text = self.source[start..self.pos], .pos = start };
        } else if (c == '|') {
            self.pos += 1;
            self.current_token = .{ .kind = .punctuator_pipe, .text = self.source[start..self.pos], .pos = start };
        } else if (c == '}') {
            self.pos += 1;
            self.current_token = .{ .kind = .punctuator_brace_r, .text = self.source[start..self.pos], .pos = start };
        } else if (c == '.' and self.pos + 2 < self.source.len and self.source[self.pos + 1] == '.' and self.source[self.pos + 2] == '.') {
            self.pos += 3;
            self.current_token = .{ .kind = .punctuator_spread, .text = self.source[start..self.pos], .pos = start };
        } else if (isNameStart(c)) {
            while (self.pos < self.source.len and isNameContinue(self.source[self.pos])) {
                self.pos += 1;
            }
            self.current_token = .{ .kind = .name, .text = self.source[start..self.pos], .pos = start };
        } else if (c == '-' or (c >= '0' and c <= '9')) {
            var is_float = false;
            if (c == '-') self.pos += 1;
            while (self.pos < self.source.len and (self.source[self.pos] >= '0' and self.source[self.pos] <= '9')) {
                self.pos += 1;
            }
            if (self.pos < self.source.len and self.source[self.pos] == '.') {
                is_float = true;
                self.pos += 1;
                while (self.pos < self.source.len and (self.source[self.pos] >= '0' and self.source[self.pos] <= '9')) {
                    self.pos += 1;
                }
            }
            if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
                is_float = true;
                self.pos += 1;
                if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
                    self.pos += 1;
                }
                while (self.pos < self.source.len and (self.source[self.pos] >= '0' and self.source[self.pos] <= '9')) {
                    self.pos += 1;
                }
            }
            self.current_token = .{
                .kind = if (is_float) .float_value else .int_value,
                .text = self.source[start..self.pos],
                .pos = start,
            };
        } else if (c == '"') {
            self.pos += 1;
            var escaped = false;
            const str_start = self.pos;
            while (self.pos < self.source.len) {
                const sc = self.source[self.pos];
                if (escaped) {
                    escaped = false;
                    self.pos += 1;
                } else if (sc == '\\') {
                    escaped = true;
                    self.pos += 1;
                } else if (sc == '"') {
                    break;
                } else {
                    self.pos += 1;
                }
            }
            if (self.pos >= self.source.len or self.source[self.pos] != '"') {
                return error.UnterminatedString;
            }
            const content = self.source[str_start..self.pos];
            self.pos += 1; // skip closing quote
            self.current_token = .{ .kind = .string_value, .text = content, .pos = start };
        } else {
            return error.UnexpectedCharacter;
        }
    }

    pub fn parseDocument(self: *Parser) ParseError!ast.Document {
        var defs = std.ArrayList(ast.Definition).empty;
        while (self.current_token.kind != .eof) {
            const def = try self.parseDefinition();
            try defs.append(self.allocator, def);
        }
        if (defs.items.len == 0) return error.EmptyDocument;
        return ast.Document{ .definitions = try defs.toOwnedSlice(self.allocator) };
    }

    fn parseDefinition(self: *Parser) ParseError!ast.Definition {
        if (self.current_token.kind == .punctuator_brace_l) {
            // Shorthand query
            const sel_set = try self.parseSelectionSet();
            return ast.Definition{
                .operation = .{
                    .operation_type = .query,
                    .selection_set = sel_set,
                },
            };
        }

        if (self.current_token.kind == .name) {
            if (std.mem.eql(u8, self.current_token.text, "query")) {
                return ast.Definition{ .operation = try self.parseOperation(.query) };
            } else if (std.mem.eql(u8, self.current_token.text, "mutation")) {
                return ast.Definition{ .operation = try self.parseOperation(.mutation) };
            } else if (std.mem.eql(u8, self.current_token.text, "subscription")) {
                return ast.Definition{ .operation = try self.parseOperation(.subscription) };
            } else if (std.mem.eql(u8, self.current_token.text, "fragment")) {
                return ast.Definition{ .fragment = try self.parseFragment() };
            }
        }

        return error.ExpectedDefinition;
    }

    fn parseOperation(self: *Parser, op_type: ast.OperationType) ParseError!ast.OperationDefinition {
        try self.advance(); // consume query/mutation/subscription
        var name: ?[]const u8 = null;
        if (self.current_token.kind == .name) {
            name = self.current_token.text;
            try self.advance();
        }

        var var_defs: []const ast.VariableDefinition = &.{};
        if (self.current_token.kind == .punctuator_paren_l) {
            var_defs = try self.parseVariableDefinitions();
        }

        var directives: []const ast.Directive = &.{};
        if (self.current_token.kind == .punctuator_at) {
            directives = try self.parseDirectives();
        }

        const sel_set = try self.parseSelectionSet();
        return ast.OperationDefinition{
            .operation_type = op_type,
            .name = name,
            .variable_definitions = var_defs,
            .directives = directives,
            .selection_set = sel_set,
        };
    }

    fn parseFragment(self: *Parser) ParseError!ast.FragmentDefinition {
        try self.advance(); // consume 'fragment'
        if (self.current_token.kind != .name or std.mem.eql(u8, self.current_token.text, "on")) {
            return error.ExpectedFragmentName;
        }
        const name = self.current_token.text;
        try self.advance();

        if (self.current_token.kind != .name or !std.mem.eql(u8, self.current_token.text, "on")) {
            return error.ExpectedOnKeyword;
        }
        try self.advance();

        if (self.current_token.kind != .name) {
            return error.ExpectedTypeCondition;
        }
        const type_condition = self.current_token.text;
        try self.advance();

        var directives: []const ast.Directive = &.{};
        if (self.current_token.kind == .punctuator_at) {
            directives = try self.parseDirectives();
        }

        const sel_set = try self.parseSelectionSet();
        return ast.FragmentDefinition{
            .name = name,
            .type_condition = type_condition,
            .directives = directives,
            .selection_set = sel_set,
        };
    }

    fn parseVariableDefinitions(self: *Parser) ParseError![]const ast.VariableDefinition {
        try self.advance(); // consume '('
        var list = std.ArrayList(ast.VariableDefinition).empty;
        while (self.current_token.kind != .punctuator_paren_r and self.current_token.kind != .eof) {
            if (self.current_token.kind != .punctuator_dollar) return error.ExpectedDollar;
            try self.advance();
            if (self.current_token.kind != .name) return error.ExpectedVariableName;
            const var_name = self.current_token.text;
            try self.advance();

            if (self.current_token.kind != .punctuator_colon) return error.ExpectedColon;
            try self.advance();

            var is_list = false;
            var type_name: []const u8 = "";
            if (self.current_token.kind == .punctuator_bracket_l) {
                is_list = true;
                try self.advance();
                if (self.current_token.kind != .name) return error.ExpectedTypeName;
                type_name = self.current_token.text;
                try self.advance();
                if (self.current_token.kind != .punctuator_bracket_r) return error.ExpectedClosingBracket;
                try self.advance();
            } else if (self.current_token.kind == .name) {
                type_name = self.current_token.text;
                try self.advance();
            } else {
                return error.ExpectedTypeName;
            }

            var is_non_null = false;
            if (self.current_token.kind == .punctuator_bang) {
                is_non_null = true;
                try self.advance();
            }

            var default_val: ?ast.Value = null;
            if (self.current_token.kind == .punctuator_equals) {
                try self.advance();
                default_val = try self.parseValue();
            }

            try list.append(self.allocator, .{
                .name = var_name,
                .type_name = type_name,
                .is_non_null = is_non_null,
                .is_list = is_list,
                .default_value = default_val,
            });
        }
        if (self.current_token.kind != .punctuator_paren_r) return error.ExpectedClosingParen;
        try self.advance();
        return try list.toOwnedSlice(self.allocator);
    }

    fn parseDirectives(self: *Parser) ParseError![]const ast.Directive {
        var list = std.ArrayList(ast.Directive).empty;
        while (self.current_token.kind == .punctuator_at) {
            try self.advance();
            if (self.current_token.kind != .name) return error.ExpectedDirectiveName;
            const name = self.current_token.text;
            try self.advance();
            var args: []const ast.Argument = &.{};
            if (self.current_token.kind == .punctuator_paren_l) {
                args = try self.parseArguments();
            }
            try list.append(self.allocator, .{ .name = name, .arguments = args });
        }
        return try list.toOwnedSlice(self.allocator);
    }

    fn parseArguments(self: *Parser) ParseError![]const ast.Argument {
        try self.advance(); // consume '('
        var list = std.ArrayList(ast.Argument).empty;
        while (self.current_token.kind != .punctuator_paren_r and self.current_token.kind != .eof) {
            if (self.current_token.kind != .name) return error.ExpectedArgumentName;
            const name = self.current_token.text;
            try self.advance();
            if (self.current_token.kind != .punctuator_colon) return error.ExpectedColon;
            try self.advance();
            const val = try self.parseValue();
            try list.append(self.allocator, .{ .name = name, .value = val });
        }
        if (self.current_token.kind != .punctuator_paren_r) return error.ExpectedClosingParen;
        try self.advance();
        return try list.toOwnedSlice(self.allocator);
    }

    fn parseSelectionSet(self: *Parser) ParseError![]const ast.Selection {
        if (self.current_token.kind != .punctuator_brace_l) return error.ExpectedBraceOpen;
        self.current_depth += 1;
        if (self.current_depth > self.limits.max_depth) return error.MaxQueryDepthExceeded;
        defer self.current_depth -= 1;

        try self.advance(); // consume '{'
        var list = std.ArrayList(ast.Selection).empty;
        while (self.current_token.kind != .punctuator_brace_r and self.current_token.kind != .eof) {
            const sel = try self.parseSelection();
            try list.append(self.allocator, sel);
        }
        if (self.current_token.kind != .punctuator_brace_r) return error.ExpectedBraceClose;
        try self.advance();
        return try list.toOwnedSlice(self.allocator);
    }

    fn parseSelection(self: *Parser) ParseError!ast.Selection {
        if (self.current_token.kind == .punctuator_spread) {
            try self.advance(); // consume '...'
            if (self.current_token.kind == .name and !std.mem.eql(u8, self.current_token.text, "on")) {
                const frag_name = self.current_token.text;
                try self.advance();
                var dirs: []const ast.Directive = &.{};
                if (self.current_token.kind == .punctuator_at) dirs = try self.parseDirectives();
                return ast.Selection{ .fragment_spread = .{ .name = frag_name, .directives = dirs } };
            } else {
                var type_cond: ?[]const u8 = null;
                if (self.current_token.kind == .name and std.mem.eql(u8, self.current_token.text, "on")) {
                    try self.advance();
                    if (self.current_token.kind != .name) return error.ExpectedTypeCondition;
                    type_cond = self.current_token.text;
                    try self.advance();
                }
                var dirs: []const ast.Directive = &.{};
                if (self.current_token.kind == .punctuator_at) dirs = try self.parseDirectives();
                const sel_set = try self.parseSelectionSet();
                return ast.Selection{
                    .inline_fragment = .{
                        .type_condition = type_cond,
                        .directives = dirs,
                        .selection_set = sel_set,
                    },
                };
            }
        }

        if (self.current_token.kind != .name) return error.ExpectedFieldName;
        const name1 = self.current_token.text;
        try self.advance();

        var alias: ?[]const u8 = null;
        var name: []const u8 = name1;

        if (self.current_token.kind == .punctuator_colon) {
            alias = name1;
            try self.advance();
            if (self.current_token.kind != .name) return error.ExpectedFieldName;
            name = self.current_token.text;
            try self.advance();
        }

        var args: []const ast.Argument = &.{};
        if (self.current_token.kind == .punctuator_paren_l) {
            args = try self.parseArguments();
        }

        var dirs: []const ast.Directive = &.{};
        if (self.current_token.kind == .punctuator_at) {
            dirs = try self.parseDirectives();
        }

        var sub_sel: []const ast.Selection = &.{};
        if (self.current_token.kind == .punctuator_brace_l) {
            sub_sel = try self.parseSelectionSet();
        }

        return ast.Selection{
            .field = .{
                .alias = alias,
                .name = name,
                .arguments = args,
                .directives = dirs,
                .selection_set = sub_sel,
            },
        };
    }

    pub fn parseValue(self: *Parser) !ast.Value {
        switch (self.current_token.kind) {
            .punctuator_dollar => {
                try self.advance();
                if (self.current_token.kind != .name) return error.ExpectedVariableName;
                const v = self.current_token.text;
                try self.advance();
                return ast.Value{ .variable = v };
            },
            .int_value => {
                const val = std.fmt.parseInt(i64, self.current_token.text, 10) catch return error.InvalidInt;
                try self.advance();
                return ast.Value{ .int = val };
            },
            .float_value => {
                const val = std.fmt.parseFloat(f64, self.current_token.text) catch return error.InvalidFloat;
                try self.advance();
                return ast.Value{ .float = val };
            },
            .string_value => {
                const val = self.current_token.text;
                try self.advance();
                return ast.Value{ .string = val };
            },
            .name => {
                const txt = self.current_token.text;
                try self.advance();
                if (std.mem.eql(u8, txt, "true")) {
                    return ast.Value{ .boolean = true };
                } else if (std.mem.eql(u8, txt, "false")) {
                    return ast.Value{ .boolean = false };
                } else if (std.mem.eql(u8, txt, "null")) {
                    return ast.Value{ .null_val = {} };
                } else {
                    return ast.Value{ .enum_val = txt };
                }
            },
            .punctuator_bracket_l => {
                try self.advance();
                var items = std.ArrayList(ast.Value).empty;
                while (self.current_token.kind != .punctuator_bracket_r and self.current_token.kind != .eof) {
                    const item = try self.parseValue();
                    try items.append(self.allocator, item);
                }
                if (self.current_token.kind != .punctuator_bracket_r) return error.ExpectedBracketClose;
                try self.advance();
                return ast.Value{ .list = try items.toOwnedSlice(self.allocator) };
            },
            .punctuator_brace_l => {
                try self.advance();
                var fields = std.ArrayList(ast.ObjectField).empty;
                while (self.current_token.kind != .punctuator_brace_r and self.current_token.kind != .eof) {
                    if (self.current_token.kind != .name) return error.ExpectedFieldName;
                    const fn_name = self.current_token.text;
                    try self.advance();
                    if (self.current_token.kind != .punctuator_colon) return error.ExpectedColon;
                    try self.advance();
                    const val = try self.parseValue();
                    try fields.append(self.allocator, .{ .name = fn_name, .value = val });
                }
                if (self.current_token.kind != .punctuator_brace_r) return error.ExpectedBraceClose;
                try self.advance();
                return ast.Value{ .object = try fields.toOwnedSlice(self.allocator) };
            },
            else => return error.UnexpectedValueToken,
        }
    }
};

test "parse basic query" {
    const a = std.testing.allocator;
    const q =
        \\query MyQuery($limit: Int = 10) {
        \\  users(limit: $limit) {
        \\    id
        \\    name
        \\    ... UserFields
        \\  }
        \\}
        \\fragment UserFields on User {
        \\  email
        \\}
    ;
    var p = try Parser.init(a, q, .{});
    const doc = try p.parseDocument();
    defer {
        for (doc.definitions) |d| {
            switch (d) {
                .operation => |op| {
                    a.free(op.variable_definitions);
                    a.free(op.selection_set[0].field.arguments);
                    a.free(op.selection_set[0].field.selection_set);
                    a.free(op.selection_set);
                },
                .fragment => |f| {
                    a.free(f.selection_set);
                },
            }
        }
        a.free(doc.definitions);
    }
    try std.testing.expectEqual(@as(usize, 2), doc.definitions.len);
    try std.testing.expectEqualStrings("MyQuery", doc.definitions[0].operation.name.?);
}
