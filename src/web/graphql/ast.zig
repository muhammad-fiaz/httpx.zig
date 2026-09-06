//! GraphQL AST nodes and lexer definitions.
//!
//! Full GraphQL Specification support:
//! - Queries, Mutations, Subscriptions
//! - Fields, Aliases, Arguments, Directives
//! - Variables, Inline Fragments, Named Fragments
//! - Selection Sets, Object Values, List Values

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TokenKind = enum {
    eof,
    name,
    int_value,
    float_value,
    string_value,
    punctuator_bang, // !
    punctuator_dollar, // $
    punctuator_amp, // &
    punctuator_paren_l, // (
    punctuator_paren_r, // )
    punctuator_spread, // ...
    punctuator_colon, // :
    punctuator_equals, // =
    punctuator_at, // @
    punctuator_bracket_l, // [
    punctuator_bracket_r, // ]
    punctuator_brace_l, // {
    punctuator_pipe, // |
    punctuator_brace_r, // }
};

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    pos: usize,
};

pub const Value = union(enum) {
    variable: []const u8,
    int: i64,
    float: f64,
    string: []const u8,
    boolean: bool,
    null_val: void,
    enum_val: []const u8,
    list: []const Value,
    object: []const ObjectField,
};

pub const ObjectField = struct {
    name: []const u8,
    value: Value,
};

pub const Argument = struct {
    name: []const u8,
    value: Value,
};

pub const Directive = struct {
    name: []const u8,
    arguments: []const Argument,
};

pub const Selection = union(enum) {
    field: Field,
    fragment_spread: FragmentSpread,
    inline_fragment: InlineFragment,
};

pub const Field = struct {
    alias: ?[]const u8 = null,
    name: []const u8,
    arguments: []const Argument = &.{},
    directives: []const Directive = &.{},
    selection_set: []const Selection = &.{},
};

pub const FragmentSpread = struct {
    name: []const u8,
    directives: []const Directive = &.{},
};

pub const InlineFragment = struct {
    type_condition: ?[]const u8 = null,
    directives: []const Directive = &.{},
    selection_set: []const Selection = &.{},
};

pub const OperationType = enum {
    query,
    mutation,
    subscription,
};

pub const VariableDefinition = struct {
    name: []const u8,
    type_name: []const u8,
    is_non_null: bool = false,
    is_list: bool = false,
    default_value: ?Value = null,
};

pub const OperationDefinition = struct {
    operation_type: OperationType,
    name: ?[]const u8 = null,
    variable_definitions: []const VariableDefinition = &.{},
    directives: []const Directive = &.{},
    selection_set: []const Selection = &.{},
};

pub const FragmentDefinition = struct {
    name: []const u8,
    type_condition: []const u8,
    directives: []const Directive = &.{},
    selection_set: []const Selection = &.{},
};

pub const Definition = union(enum) {
    operation: OperationDefinition,
    fragment: FragmentDefinition,
};

pub const Document = struct {
    definitions: []const Definition,
};
