//! GraphQL Schema Definition, Validation, and Execution Engine.
//!
//! Features:
//! - Type System: Scalars (Int, Float, String, Boolean, ID, Custom), Objects, Lists, NonNull
//! - Schema Introspection (__schema, __type, __typename) for GraphiQL and tools
//! - Resolvers: Synchronous field resolution with context, arguments, and source data
//! - Error formatting with locations, paths, and extensions
//! - Query complexity and depth security limits
//!
//! References:
//!   - GraphQL Specification Section 3 — Type System
//!   - GraphQL Specification Section 6 — Execution
//!   - GraphQL Specification Section 5 — Introspection

const std = @import("std");
const Allocator = std.mem.Allocator;
const configCoerce = @import("../../common/configCoerce.zig");
const ast = @import("ast.zig");
const parserMod = @import("graphQlParser.zig");

pub const TypeKind = enum {
    scalar,
    object,
    interface,
    unionType,
    enumType,
    inputObject,
    list,
    nonNull,
};

pub const FieldResolver = *const fn (ctx: Context) anyerror!std.json.Value;

/// Per-field execution context handed to every resolver. One type for all
/// resolvers — the same role `httpx.router.Context` plays for routes and
/// `httpx.Context` for REST handlers.
pub const Context = struct {
    allocator: Allocator,
    parent: ?std.json.Value = null,
    args: std.json.Value = .null,
    variables: std.json.Value = .null,
    fieldName: []const u8,
    userContext: ?*anyopaque = null,

    /// Converts any Zig value, struct, slice, or primitive directly into a std.json.Value.
    /// Eliminates manual ObjectMap/Array boilerplate in resolvers.
    pub fn value(self: Context, val: anytype) anyerror!std.json.Value {
        const jsonBytes = try std.json.Stringify.valueAlloc(self.allocator, val, .{});
        defer self.allocator.free(jsonBytes);
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, jsonBytes, .{});
        return parsed.value;
    }
};

/// One declared field argument. Arguments are part of the type system, not an
/// afterthought: introspection reports them so every UI can show the argument
/// list and its input types.
pub const ArgDef = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    typeName: []const u8,
    isList: bool = false,
    isNonNull: bool = false,
    /// GraphQL literal, e.g. `"10"` or `"ADMIN"`; null means no default.
    defaultValue: ?[]const u8 = null,
};

/// Field of an input object type (no resolver: inputs only carry values).
pub const InputFieldDef = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    typeName: []const u8,
    isList: bool = false,
    isNonNull: bool = false,
    defaultValue: ?[]const u8 = null,
};

pub const FieldDef = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    typeName: []const u8,
    isList: bool = false,
    isNonNull: bool = false,
    resolver: ?FieldResolver = null,
    args: []const ArgDef = &.{},
};

pub const ObjectTypeDef = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    fields: []const FieldDef,
    /// Interface names this object implements, used by introspection.
    interfaces: []const []const u8 = &.{},
};

pub const EnumTypeDef = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    values: []const []const u8,
};

pub const InputTypeDef = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    fields: []const InputFieldDef,
};

pub const InterfaceTypeDef = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    fields: []const FieldDef,
};

pub const UnionTypeDef = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    members: []const []const u8,
};

/// The built-in GraphQL scalars, reported by introspection as `SCALAR`.
const builtinScalars = [_][]const u8{ "Int", "Float", "String", "Boolean", "ID" };

// Typed public API: types come from Zig structs, every field is explicit, and
// no raw GraphQL type-name strings ever appear in user code.
//
// ```zig
// const User = struct { id: u64, name: []const u8 };
// const UserType = httpx.graphql.Type("User", .{
//     .id = Scalar.id,
//     .name = Scalar.string,
// });
//
// fn getMe(ctx: *httpx.graphql.Context) !User {
//     _ = ctx;
//     return .{ .id = 1, .name = "alice" };
// }
//
// const QueryRoot = httpx.graphql.Query(.{
//     .me = .{ .type = UserType, .resolve = getMe },
// });
// const schema = httpx.graphql.Schema.init(allocator, io, .{
//     .query = QueryRoot,
//     .types = &.{UserType},
// });
// ```

/// GraphQL scalar kinds. An entry in a spec uses an explicit enum value,
/// exactly like this: `.id = Scalar.id`, `.name = Scalar.string`,
/// `.age = Scalar.int`.
pub const Scalar = enum {
    string,
    int,
    float,
    boolean,
    id,

    pub fn name(self: Scalar) []const u8 {
        return switch (self) {
            .string => "String",
            .int => "Int",
            .float => "Float",
            .boolean => "Boolean",
            .id => "ID",
        };
    }
};

fn checkQlName(comptime name: []const u8, comptime what: []const u8) []const u8 {
    if (name.len == 0) @compileError(what ++ " must not be empty");
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') {
        @compileError(what ++ " name `" ++ name ++ "` must start with a letter or `_`");
    }
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') {
            @compileError(what ++ " name `" ++ name ++ "` must use only letters, digits, and `_`");
        }
    }
    return name;
}

/// The raw GraphQL type name for a `.type` value in a spec: a scalar kind or
/// an object type built with `Type(...)`.
fn nameOf(comptime t: anytype) []const u8 {
    const T = @TypeOf(t);
    if (T == Scalar) return t.name();
    if (T == ObjectTypeDef) return t.name;
    if (T == EnumTypeDef) return t.name;
    if (T == InterfaceTypeDef) return t.name;
    if (T == UnionTypeDef) return t.name;
    if (T == InputTypeDef) return t.name;
    @compileError("GraphQL `.type` expects a scalar kind (.string/.id/...), a `Type(...)` object, an `Enum(...)`, an `Interface(...)`, a `Union(...)`, or an `Input(...)` in an argument");
}

fn fnChild(comptime F: type) type {
    if (@typeInfo(F) == .pointer) return @typeInfo(F).pointer.child;
    return F;
}

/// Builds a `std.json.Value` from a typed resolver payload. One generator for
/// structs, slices, optionals, enums, and scalars — same shapes the engine
/// consumes downstream — without a string round-trip.
fn toJsonValue(allocator: Allocator, val: anytype) anyerror!std.json.Value {
    const T = @TypeOf(val);
    const info = @typeInfo(T);
    return switch (info) {
        .int => std.json.Value{ .integer = @intCast(val) },
        .float => std.json.Value{ .float = @floatCast(val) },
        .bool => std.json.Value{ .bool = val },
        .null => .null,
        .void => .null,
        // GraphQL enums are wire strings (their tag name), never ordinals.
        .@"enum" => std.json.Value{ .string = @tagName(val) },
        .optional => if (val) |v| toJsonValue(allocator, v) else std.json.Value.null,
        .pointer => if (info.pointer.size == .slice) blk: {
            if (info.pointer.child == u8) {
                const copy = try allocator.dupe(u8, val);
                return std.json.Value{ .string = copy };
            }
            var arr = std.json.Array.init(allocator);
            for (val) |elem| {
                try arr.append(try toJsonValue(allocator, elem));
            }
            break :blk std.json.Value{ .array = arr };
        } else toJsonValue(allocator, val.*),
        .array => blk: {
            var arr = std.json.Array.init(allocator);
            for (val) |elem| {
                try arr.append(try toJsonValue(allocator, elem));
            }
            break :blk std.json.Value{ .array = arr };
        },
        .@"struct" => blk: {
            if (@TypeOf(val) == std.json.Value) break :blk val;
            var obj = std.json.ObjectMap.init(allocator, &.{}, &.{}) catch return error.OutOfMemory;
            inline for (info.@"struct".field_names) |fname| {
                try obj.put(allocator, fname, try toJsonValue(allocator, @field(val, fname)));
            }
            break :blk std.json.Value{ .object = obj };
        },
        else => (try std.json.parseFromSlice(std.json.Value, allocator, try std.json.Stringify.valueAlloc(allocator, val, .{}), .{})).value,
    };
}

/// Wraps a user resolver in the engine's `FieldResolver` shape. The resolver
/// signature is one of:
///
///   `fn (*Context) !T`
///   `fn (*Context, Args) !T`  — Args is a struct decoded from the field args
///
/// Adding the typed `Args` is the GraphQL equivalent of REST handlers'
/// second (body) parameter. The payload `T` becomes a JSON value through
/// `toJsonValue`; returning `std.json.Value` directly also works.
fn makeResolverFn(comptime resolver: anytype) FieldResolver {
    const Fn = fnChild(@TypeOf(resolver));
    const fnInfo = @typeInfo(Fn).@"fn";
    const ret = fnInfo.return_type orelse
        @compileError("GraphQL resolver must return an error union, e.g. `!User`");
    if (@typeInfo(ret) != .error_union) {
        @compileError("GraphQL resolver must return an error union, e.g. `!User` (got `" ++ @typeName(ret) ++ "`)");
    }
    if (fnInfo.param_types.len != 1 and fnInfo.param_types.len != 2) {
        @compileError("GraphQL resolver takes `(*Context)` or `(*Context, Args)`");
    }
    const W = struct {
        fn trampoline(ctx: Context) anyerror!std.json.Value {
            var current = ctx;
            const result = if (comptime fnInfo.param_types.len == 1)
                if (comptime fnInfo.param_types[0].? == *Context)
                    try resolver(&current)
                else
                    try resolver(current)
            else blk: {
                const Args = fnInfo.param_types[1].?;
                // No free here: the execution allocator is an arena that owns
                // these buffers for the whole request by design.
                const src = std.json.Stringify.valueAlloc(current.allocator, current.args, .{}) catch return .null;
                const parsed = std.json.parseFromSlice(Args, current.allocator, src, .{}) catch return .null;
                break :blk try resolver(&current, parsed.value);
            };
            return if (comptime @TypeOf(result) == std.json.Value) result else toJsonValue(current.allocator, result);
        }
    };
    return &W.trampoline;
}

fn toFieldDef(comptime fname: []const u8, comptime entry: anytype) FieldDef {
    const Entry = @TypeOf(entry);
    if (@typeInfo(Entry) == .@"enum") {
        // Scalar shorthand: dispatched by tag, so no type-equality needed.
        if (Entry != Scalar) {
            @compileError("GraphQL field `." ++ fname ++ "` must use an `httpx.graphql.Scalar` kind (.string/.id/...)");
        }
        return .{ .name = fname, .typeName = entry.name() };
    }
    if (Entry == ObjectTypeDef or Entry == EnumTypeDef or Entry == InterfaceTypeDef or Entry == UnionTypeDef) {
        // A type definition used directly as the field type: `.role = RoleEnum`.
        return .{ .name = fname, .typeName = entry.name };
    }
    if (@typeInfo(Entry) != .@"struct") {
        @compileError("GraphQL field `." ++ fname ++ "` must be a scalar kind (.string/.id/...), a type definition, or a field spec literal");
    }

    const resolved: ?FieldResolver = if (@hasField(Entry, "resolve")) makeResolverFn(@field(entry, "resolve")) else null;
    if (!@hasField(Entry, "type")) {
        @compileError("GraphQL field `." ++ fname ++ "` needs `.type` (a scalar kind, `Type(...)`, `Enum(...)`, `Interface(...)`, or `Union(...)`)");
    }

    const args = comptime if (@hasField(Entry, "args")) buildArgsSuffix(@field(entry, "args"), 0) else [0]ArgDef{};

    return .{
        .name = fname,
        .description = if (@hasField(Entry, "description")) entry.description else null,
        .typeName = nameOf(@field(entry, "type")),
        .isList = if (@hasField(Entry, "list")) entry.list else false,
        .isNonNull = if (@hasField(Entry, "nonNull")) entry.nonNull else false,
        .resolver = resolved,
        .args = &args,
    };
}

fn toArgDef(comptime aname: []const u8, comptime entry: anytype) ArgDef {
    const E = @TypeOf(entry);
    if (@typeInfo(E) == .@"enum") {
        if (E != Scalar) {
            @compileError("GraphQL argument `." ++ aname ++ "` must use an `httpx.graphql.Scalar` kind or a `.type` spec");
        }
        return .{ .name = aname, .typeName = entry.name() };
    }
    if (E == InputTypeDef or E == EnumTypeDef) {
        return .{ .name = aname, .typeName = entry.name };
    }
    if (@typeInfo(E) != .@"struct" or !@hasField(E, "type")) {
        @compileError("GraphQL argument `." ++ aname ++ "` must be a scalar kind, an `Input(...)`/`Enum(...)` type, or a spec with `.type`");
    }
    return .{
        .name = aname,
        .description = if (@hasField(E, "description")) entry.description else null,
        .typeName = nameOf(@field(entry, "type")),
        .isList = if (@hasField(E, "list")) entry.list else false,
        .isNonNull = if (@hasField(E, "nonNull")) entry.nonNull else false,
        .defaultValue = if (@hasField(E, "default")) entry.default else null,
    };
}

fn buildArgsSuffix(comptime spec: anytype, comptime i: usize) [@typeInfo(@TypeOf(spec)).@"struct".field_names.len - i]ArgDef {
    const names = @typeInfo(@TypeOf(spec)).@"struct".field_names;
    if (i >= names.len) return .{};
    return .{toArgDef(names[i], @field(spec, names[i]))} ++ buildArgsSuffix(spec, i + 1);
}

fn toInputFieldDef(comptime fname: []const u8, comptime entry: anytype) InputFieldDef {
    const E = @TypeOf(entry);
    if (@typeInfo(E) == .@"enum") {
        if (E != Scalar) {
            @compileError("GraphQL input field `." ++ fname ++ "` must use an `httpx.graphql.Scalar` kind or a `.type` spec");
        }
        return .{ .name = fname, .typeName = entry.name() };
    }
    if (E == InputTypeDef or E == EnumTypeDef) {
        return .{ .name = fname, .typeName = entry.name };
    }
    if (@typeInfo(E) != .@"struct" or !@hasField(E, "type")) {
        @compileError("GraphQL input field `." ++ fname ++ "` must be a scalar kind, an `Input(...)`/`Enum(...)` type, or a spec with `.type`");
    }
    return .{
        .name = fname,
        .description = if (@hasField(E, "description")) entry.description else null,
        .typeName = nameOf(@field(entry, "type")),
        .isList = if (@hasField(E, "list")) entry.list else false,
        .isNonNull = if (@hasField(E, "nonNull")) entry.nonNull else false,
        .defaultValue = if (@hasField(E, "default")) entry.default else null,
    };
}

fn buildInputFieldsSuffix(comptime spec: anytype, comptime i: usize) [@typeInfo(@TypeOf(spec)).@"struct".field_names.len - i]InputFieldDef {
    const names = @typeInfo(@TypeOf(spec)).@"struct".field_names;
    if (i >= names.len) return .{};
    return .{toInputFieldDef(names[i], @field(spec, names[i]))} ++ buildInputFieldsSuffix(spec, i + 1);
}

// Builds a fields array as a pure comptime value (recursive suffix concat).
// No mutation or buffer, so the result is comptime-known even when this
// definition is nested inside another spec as a field's `.type`.
fn buildFieldsSuffix(comptime spec: anytype, comptime i: usize) [@typeInfo(@TypeOf(spec)).@"struct".field_names.len - i]FieldDef {
    const names = @typeInfo(@TypeOf(spec)).@"struct".field_names;
    if (i >= names.len) return .{};
    const fname = names[i];
    return .{toFieldDef(fname, @field(spec, fname))} ++ buildFieldsSuffix(spec, i + 1);
}

fn rootType(comptime typeName: []const u8, comptime spec: anytype) ObjectTypeDef {
    const fields = buildFieldsSuffix(spec, 0);
    return .{ .name = typeName, .fields = &fields };
}

/// Defines an object type from an explicit per-field spec. Every field is
/// listed with its type; scalars are the enum values themselves, fully
/// explicit: `Scalar.id`, `Scalar.string`, `Scalar.int`, `Scalar.float`,
/// `Scalar.boolean`.
///
/// ```zig
/// const UserType = httpx.graphql.Type("User", .{
///     .id = Scalar.id,
///     .name = Scalar.string,
/// });
/// ```
///
/// Build definitions at namespace scope (file top-level or a namespace
/// struct): a definition created inside a function body loses its static
/// storage in Zig's comptime model and its fields misbehave at runtime.
pub fn Type(comptime typeName: []const u8, comptime spec: anytype) ObjectTypeDef {
    return rootType(checkQlName(typeName, "GraphQL type"), spec);
}

/// Defines the root `Query` object from a field spec with resolvers. Field
/// `.type` values reference object types built with `Type(...)`; declare
/// those at namespace scope (see [`Type`]).
pub fn Query(comptime spec: anytype) ObjectTypeDef {
    return rootType("Query", spec);
}

/// Defines the root `Mutation` object from a field spec with resolvers. Same
/// declaration rules as [`Query`].
pub fn Mutation(comptime spec: anytype) ObjectTypeDef {
    return rootType("Mutation", spec);
}

/// String-named object type for schemas assembled from external data: every
/// field is an explicit [`FieldDef`] whose `typeName` is a plain GraphQL type
/// name. Typed schemas use [`Type`]; this is the non-typed counterpart.
pub fn Object(comptime typeName: []const u8, comptime fields: []const FieldDef) ObjectTypeDef {
    return .{ .name = checkQlName(typeName, "GraphQL type"), .fields = fields };
}

/// Declares an enum type. Fields reference it exactly like a scalar:
/// `.type = RoleEnum`; resolvers return a Zig enum and the engine emits its
/// tag name on the wire.
pub fn Enum(comptime typeName: []const u8, comptime values: []const []const u8) EnumTypeDef {
    comptime {
        _ = checkQlName(typeName, "GraphQL enum");
        for (values) |value| _ = checkQlName(value, "GraphQL enum value");
    }
    return .{ .name = typeName, .values = values };
}

/// Declares an input object type for field arguments (`ArgDef.typeName`).
pub fn Input(comptime typeName: []const u8, comptime spec: anytype) InputTypeDef {
    const fields = buildInputFieldsSuffix(spec, 0);
    return .{ .name = checkQlName(typeName, "GraphQL input"), .fields = &fields };
}

/// Declares an interface. Objects opt in with [`implements`].
pub fn Interface(comptime typeName: []const u8, comptime spec: anytype) InterfaceTypeDef {
    const fields = buildFieldsSuffix(spec, 0);
    return .{ .name = checkQlName(typeName, "GraphQL interface"), .fields = &fields };
}

/// Comptime name list for union members. A `const` result keeps static
/// storage, so a global type definition may point at it.
fn objectNames(comptime defs: []const ObjectTypeDef) [defs.len][]const u8 {
    var out: [defs.len][]const u8 = undefined;
    for (defs, 0..) |def, i| out[i] = def.name;
    return out;
}

fn interfaceNames(comptime ifaces: []const InterfaceTypeDef) [ifaces.len][]const u8 {
    var out: [ifaces.len][]const u8 = undefined;
    for (ifaces, 0..) |iface, i| out[i] = iface.name;
    return out;
}

/// Declares a union of object types.
pub fn Union(comptime typeName: []const u8, comptime members: []const ObjectTypeDef) UnionTypeDef {
    const names = objectNames(members);
    return .{ .name = checkQlName(typeName, "GraphQL union"), .members = &names };
}

/// Marks an object type as implementing interfaces:
/// `const UserType = implements(Type("User", .{ ... }), &.{NodeInterface});`
pub fn implements(comptime def: ObjectTypeDef, comptime ifaces: []const InterfaceTypeDef) ObjectTypeDef {
    const names = interfaceNames(ifaces);
    var out = def;
    out.interfaces = &names;
    return out;
}

pub const SchemaConfig = struct {
    query: ObjectTypeDef,
    mutation: ?ObjectTypeDef = null,
    /// Object types (including types that implement interfaces).
    types: []const ObjectTypeDef = &.{},
    enums: []const EnumTypeDef = &.{},
    inputs: []const InputTypeDef = &.{},
    interfaces: []const InterfaceTypeDef = &.{},
    unions: []const UnionTypeDef = &.{},
    maxDepth: usize = 32,
    maxComplexity: usize = 500,
    introspection: bool = true,
};

pub const Schema = struct {
    allocator: Allocator,
    io: std.Io,
    config: SchemaConfig,

    /// Creates a schema from an explicit allocator, shared I/O, and a partial
    /// or full config literal. Omitted fields keep their declared defaults.
    pub fn init(allocator: Allocator, io: std.Io, config_in: anytype) Schema {
        const config = configCoerce.to(SchemaConfig, config_in);
        return Schema{
            .allocator = allocator,
            .io = io,
            .config = config,
        };
    }

    /// Executes `query` and returns a JSON response document. When the document
    /// holds several operations, the first one is used; prefer
    /// [`executeRequest`] so the client can choose with `operationName`.
    pub fn execute(self: *const Schema, arena: Allocator, query: []const u8, variablesJson: ?[]const u8, userContext: ?*anyopaque) ![]u8 {
        return self.executeRequest(arena, query, variablesJson, null, userContext);
    }

    /// Executes `query`, selecting the operation named `operationName`.
    ///
    /// JSON keys come from the document and from resolver output unchanged, so
    /// keys such as `user-name`, `@context` or `Content-Type` are preserved
    /// exactly as written — GraphQL names are only constrained on the query
    /// side, never on the JSON payload side.
    pub fn executeRequest(
        self: *const Schema,
        arena: Allocator,
        query: []const u8,
        variablesJson: ?[]const u8,
        operationName: ?[]const u8,
        userContext: ?*anyopaque,
    ) ![]u8 {
        var parsedVars: std.json.Value = .null;
        if (variablesJson) |vStr| {
            if (vStr.len > 0 and !std.mem.eql(u8, vStr, "null")) {
                const parsed = std.json.parseFromSlice(std.json.Value, arena, vStr, .{}) catch return self.formatError(arena, "Invalid variables JSON payload");
                parsedVars = parsed.value;
            }
        }

        var parser = parserMod.Parser.init(arena, query, .{ .maxDepth = self.config.maxDepth }) catch |err| {
            return self.formatError(arena, switch (err) {
                error.RequestEntityTooLarge => "Query payload exceeds maximum size limit",
                error.MaxQueryDepthExceeded => "Query exceeds maximum depth limit",
                error.TokenLimitExceeded => "Query exceeds maximum token complexity limit",
                else => "Syntax error while parsing GraphQL query",
            });
        };

        const doc = parser.parseDocument() catch return self.formatError(arena, "GraphQL syntax error: failed to parse document");

        // Fragments are collected first: an operation may reference one that is
        // defined later in the document.
        var fragments = std.StringHashMap(ast.FragmentDefinition).init(arena);
        var operationCount: usize = 0;
        var namedOp: ?ast.OperationDefinition = null;
        var firstOp: ?ast.OperationDefinition = null;

        for (doc.definitions) |d| {
            switch (d) {
                .operation => |op| {
                    operationCount += 1;
                    if (firstOp == null) firstOp = op;
                    if (operationName) |wanted| {
                        if (op.name) |name| {
                            if (std.mem.eql(u8, name, wanted)) namedOp = op;
                        }
                    }
                },
                .fragment => |f| {
                    try fragments.put(f.name, f);
                },
            }
        }

        const opDef: ?ast.OperationDefinition = if (operationName != null) namedOp else firstOp;

        if (opDef == null) {
            if (operationName) |wanted| {
                return self.formatError(arena, try std.fmt.allocPrint(arena, "Unknown operationName: {s}", .{wanted}));
            }
            return self.formatError(arena, "No executable operation found in GraphQL request");
        }
        if (operationName == null and operationCount > 1) {
            return self.formatError(arena, "operationName is required when a document contains multiple operations");
        }

        const op = opDef.?;
        const targetObj = switch (op.operationType) {
            .query => self.config.query,
            .mutation => self.config.mutation orelse return self.formatError(arena, "Mutations are not supported by this schema"),
            .subscription => return self.formatError(arena, "Subscriptions are not supported over standard HTTP POST"),
        };

        var rootData = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;

        for (op.selectionSet) |sel| {
            switch (sel) {
                .field => |f| {
                    const fieldVal = try self.resolveField(arena, targetObj, f, null, parsedVars, &fragments, userContext);
                    const outputName = f.alias orelse f.name;
                    try rootData.put(arena, outputName, fieldVal);
                },
                .fragmentSpread => |fs| {
                    if (fragments.get(fs.name)) |fDef| {
                        for (fDef.selectionSet) |fSel| {
                            if (fSel == .field) {
                                const f = fSel.field;
                                const fieldVal = try self.resolveField(arena, targetObj, f, null, parsedVars, &fragments, userContext);
                                const outputName = f.alias orelse f.name;
                                try rootData.put(arena, outputName, fieldVal);
                            }
                        }
                    }
                },
                .inlineFragment => |inf| {
                    for (inf.selectionSet) |infSel| {
                        if (infSel == .field) {
                            const f = infSel.field;
                            const fieldVal = try self.resolveField(arena, targetObj, f, null, parsedVars, &fragments, userContext);
                            const outputName = f.alias orelse f.name;
                            try rootData.put(arena, outputName, fieldVal);
                        }
                    }
                },
            }
        }

        var responseObj = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
        try responseObj.put(arena, "data", std.json.Value{ .object = rootData });

        var out: std.Io.Writer.Allocating = .init(arena);
        try std.json.fmt(std.json.Value{ .object = responseObj }, .{}).format(&out.writer);
        return out.toOwnedSlice();
    }

    fn resolveField(
        self: *const Schema,
        arena: Allocator,
        objDef: ObjectTypeDef,
        field: ast.Field,
        parentVal: ?std.json.Value,
        variables: std.json.Value,
        fragments: *const std.StringHashMap(ast.FragmentDefinition),
        userCtx: ?*anyopaque,
    ) !std.json.Value {
        // Introspection handling
        if (self.config.introspection) {
            if (std.mem.eql(u8, field.name, "__typename")) {
                return std.json.Value{ .string = objDef.name };
            }
            if (std.mem.eql(u8, field.name, "__schema")) {
                return self.resolveSchemaIntrospection(arena, field);
            }
            if (std.mem.eql(u8, field.name, "__type")) {
                for (field.arguments) |arg| {
                    if (!std.mem.eql(u8, arg.name, "name")) continue;
                    const wanted = self.evaluateValue(arena, arg.value, variables);
                    if (wanted == .string) return self.formatIntrospectionType(arena, wanted.string);
                }
                return .null;
            }
        }

        // Locate field definition in schema
        var fieldDef: ?FieldDef = null;
        for (objDef.fields) |fd| {
            if (std.mem.eql(u8, fd.name, field.name)) {
                fieldDef = fd;
                break;
            }
        }

        if (fieldDef == null) {
            // Check if parent is a JSON object with this key
            if (parentVal) |pv| {
                if (pv == .object) {
                    if (pv.object.get(field.name)) |v| return v;
                }
            }
            return .null;
        }

        const fd = fieldDef.?;

        // Evaluate arguments
        var argsObj = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
        for (field.arguments) |arg| {
            const argVal = self.evaluateValue(arena, arg.value, variables);
            try argsObj.put(arena, arg.name, argVal);
        }

        const resCtx = Context{
            .allocator = arena,
            .parent = parentVal,
            .args = std.json.Value{ .object = argsObj },
            .variables = variables,
            .fieldName = field.name,
            .userContext = userCtx,
        };

        var resolvedValue: std.json.Value = .null;
        if (fd.resolver) |r| {
            resolvedValue = r(resCtx) catch {
                return .null;
            };
        } else if (parentVal) |pv| {
            if (pv == .object) {
                resolvedValue = pv.object.get(field.name) orelse .null;
            }
        }

        // If field has selection set and resolved value is an object or array
        if (field.selectionSet.len > 0) {
            const nestedType = self.findType(fd.typeName) orelse ObjectTypeDef{ .name = fd.typeName, .fields = &.{} };
            switch (resolvedValue) {
                .object => |subObj| {
                    var outObj = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
                    for (field.selectionSet) |sel| {
                        switch (sel) {
                            .field => |sf| {
                                const sv = try self.resolveField(arena, nestedType, sf, std.json.Value{ .object = subObj }, variables, fragments, userCtx);
                                const outName = sf.alias orelse sf.name;
                                try outObj.put(arena, outName, sv);
                            },
                            .fragmentSpread => |sfs| {
                                if (fragments.get(sfs.name)) |fDef| {
                                    for (fDef.selectionSet) |fSel| {
                                        if (fSel == .field) {
                                            const sf = fSel.field;
                                            const sv = try self.resolveField(arena, nestedType, sf, std.json.Value{ .object = subObj }, variables, fragments, userCtx);
                                            const outName = sf.alias orelse sf.name;
                                            try outObj.put(arena, outName, sv);
                                        }
                                    }
                                }
                            },
                            .inlineFragment => |inf| {
                                for (inf.selectionSet) |infSel| {
                                    if (infSel == .field) {
                                        const sf = infSel.field;
                                        const sv = try self.resolveField(arena, nestedType, sf, std.json.Value{ .object = subObj }, variables, fragments, userCtx);
                                        const outName = sf.alias orelse sf.name;
                                        try outObj.put(arena, outName, sv);
                                    }
                                }
                            },
                        }
                    }
                    return std.json.Value{ .object = outObj };
                },
                .array => |arr| {
                    var outArr = std.json.Array.init(arena);
                    for (arr.items) |elem| {
                        if (elem == .object) {
                            var elemObj = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
                            for (field.selectionSet) |sel| {
                                if (sel == .field) {
                                    const sf = sel.field;
                                    const sv = try self.resolveField(arena, nestedType, sf, elem, variables, fragments, userCtx);
                                    const outName = sf.alias orelse sf.name;
                                    try elemObj.put(arena, outName, sv);
                                }
                            }
                            try outArr.append(std.json.Value{ .object = elemObj });
                        } else {
                            try outArr.append(elem);
                        }
                    }
                    return std.json.Value{ .array = outArr };
                },
                else => return resolvedValue,
            }
        }

        return resolvedValue;
    }

    fn findType(self: *const Schema, name: []const u8) ?ObjectTypeDef {
        if (std.mem.eql(u8, self.config.query.name, name)) return self.config.query;
        if (self.config.mutation) |m| {
            if (std.mem.eql(u8, m.name, name)) return m;
        }
        for (self.config.types) |t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        // Interface-backed fields execute against the interface's own fields.
        for (self.config.interfaces) |iface| {
            if (std.mem.eql(u8, iface.name, name)) {
                return .{ .name = iface.name, .description = iface.description, .fields = iface.fields };
            }
        }
        return null;
    }

    fn findInterface(self: *const Schema, name: []const u8) ?InterfaceTypeDef {
        for (self.config.interfaces) |iface| {
            if (std.mem.eql(u8, iface.name, name)) return iface;
        }
        return null;
    }

    fn findEnum(self: *const Schema, name: []const u8) ?EnumTypeDef {
        for (self.config.enums) |enumDef| {
            if (std.mem.eql(u8, enumDef.name, name)) return enumDef;
        }
        return null;
    }

    fn findInput(self: *const Schema, name: []const u8) ?InputTypeDef {
        for (self.config.inputs) |inputDef| {
            if (std.mem.eql(u8, inputDef.name, name)) return inputDef;
        }
        return null;
    }

    fn findUnion(self: *const Schema, name: []const u8) ?UnionTypeDef {
        for (self.config.unions) |unionDef| {
            if (std.mem.eql(u8, unionDef.name, name)) return unionDef;
        }
        return null;
    }

    fn evaluateValue(self: *const Schema, arena: Allocator, val: ast.Value, variables: std.json.Value) std.json.Value {
        return switch (val) {
            .variable => |vName| {
                if (variables == .object) {
                    return variables.object.get(vName) orelse .null;
                }
                return .null;
            },
            .int => |i| .{ .integer = i },
            .float => |f| .{ .float = f },
            .string => |s| .{ .string = s },
            .boolean => |b| .{ .bool = b },
            .nullVal => .null,
            .enumVal => |e| .{ .string = e },
            .list => |l| {
                var arr = std.json.Array.init(arena);
                for (l) |item| {
                    arr.append(self.evaluateValue(arena, item, variables)) catch {};
                }
                return .{ .array = arr };
            },
            .object => |o| {
                var map = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
                for (o) |field| {
                    map.put(arena, field.name, self.evaluateValue(arena, field.value, variables)) catch {};
                }
                return .{ .object = map };
            },
        };
    }

    fn resolveSchemaIntrospection(self: *const Schema, arena: Allocator, field: ast.Field) !std.json.Value {
        _ = field;
        var sObj = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
        var qType = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
        try qType.put(arena, "name", std.json.Value{ .string = self.config.query.name });
        try sObj.put(arena, "queryType", std.json.Value{ .object = qType });

        if (self.config.mutation) |m| {
            var mType = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
            try mType.put(arena, "name", std.json.Value{ .string = m.name });
            try sObj.put(arena, "mutationType", std.json.Value{ .object = mType });
        } else {
            try sObj.put(arena, "mutationType", .null);
        }

        try sObj.put(arena, "subscriptionType", .null);
        try sObj.put(arena, "directives", std.json.Value{ .array = std.json.Array.init(arena) });

        var typesList = std.json.Array.init(arena);
        for (builtinScalars) |scalarName| {
            try typesList.append(try self.formatIntrospectionType(arena, scalarName));
        }
        try typesList.append(try self.formatIntrospectionType(arena, self.config.query.name));
        if (self.config.mutation) |m| {
            try typesList.append(try self.formatIntrospectionType(arena, m.name));
        }
        for (self.config.types) |t| {
            try typesList.append(try self.formatIntrospectionType(arena, t.name));
        }
        for (self.config.enums) |e| {
            try typesList.append(try self.formatIntrospectionType(arena, e.name));
        }
        for (self.config.inputs) |i| {
            try typesList.append(try self.formatIntrospectionType(arena, i.name));
        }
        for (self.config.interfaces) |i| {
            try typesList.append(try self.formatIntrospectionType(arena, i.name));
        }
        for (self.config.unions) |u| {
            try typesList.append(try self.formatIntrospectionType(arena, u.name));
        }

        try sObj.put(arena, "types", std.json.Value{ .array = typesList });
        return std.json.Value{ .object = sObj };
    }

    fn isBuiltinScalar(typeName: []const u8) bool {
        for (builtinScalars) |scalarName| {
            if (std.mem.eql(u8, scalarName, typeName)) return true;
        }
        return false;
    }

    /// Introspection kind for any declared name. Unknown names are reported as
    /// custom scalars, which is what GraphQL clients expect for `scalar Name`.
    fn kindOf(self: *const Schema, typeName: []const u8) []const u8 {
        if (isBuiltinScalar(typeName)) return "SCALAR";
        if (std.mem.eql(u8, self.config.query.name, typeName)) return "OBJECT";
        if (self.config.mutation) |m| {
            if (std.mem.eql(u8, m.name, typeName)) return "OBJECT";
        }
        for (self.config.types) |t| {
            if (std.mem.eql(u8, t.name, typeName)) return "OBJECT";
        }
        for (self.config.interfaces) |i| {
            if (std.mem.eql(u8, i.name, typeName)) return "INTERFACE";
        }
        for (self.config.enums) |e| {
            if (std.mem.eql(u8, e.name, typeName)) return "ENUM";
        }
        for (self.config.inputs) |i| {
            if (std.mem.eql(u8, i.name, typeName)) return "INPUT_OBJECT";
        }
        for (self.config.unions) |u| {
            if (std.mem.eql(u8, u.name, typeName)) return "UNION";
        }
        return "SCALAR";
    }

    fn descriptionOf(self: *const Schema, typeName: []const u8) ?[]const u8 {
        if (self.findType(typeName)) |t| return t.description;
        if (self.findEnum(typeName)) |e| return e.description;
        if (self.findInput(typeName)) |i| return i.description;
        if (self.findUnion(typeName)) |u| return u.description;
        return null;
    }

    /// Bare named-type reference: `kind` reflects the real declared kind, so
    /// GraphiQL / Scalar / ReDoc render links to the correct type.
    fn introspectNamedType(self: *const Schema, arena: Allocator, typeName: []const u8) !std.json.Value {
        var ref = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
        try ref.put(arena, "kind", std.json.Value{ .string = self.kindOf(typeName) });
        try ref.put(arena, "name", std.json.Value{ .string = typeName });
        try ref.put(arena, "ofType", .null);
        return std.json.Value{ .object = ref };
    }

    /// Full type reference with `LIST` / `NON_NULL` wrappers nested in the
    /// order GraphQL defines them: `[T!]!` becomes NON_NULL(LIST(NON_NULL(T))).
    fn introspectTypeRef(self: *const Schema, arena: Allocator, typeName: []const u8, isList: bool, isNonNull: bool) !std.json.Value {
        var ref = try self.introspectNamedType(arena, typeName);
        if (isList) {
            var listObj = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
            try listObj.put(arena, "kind", std.json.Value{ .string = "LIST" });
            try listObj.put(arena, "name", .null);
            try listObj.put(arena, "ofType", ref);
            ref = std.json.Value{ .object = listObj };
        }
        if (isNonNull) {
            var nnObj = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
            try nnObj.put(arena, "kind", std.json.Value{ .string = "NON_NULL" });
            try nnObj.put(arena, "name", .null);
            try nnObj.put(arena, "ofType", ref);
            ref = std.json.Value{ .object = nnObj };
        }
        return ref;
    }

    fn formatFieldList(self: *const Schema, arena: Allocator, fields: []const FieldDef) !std.json.Value {
        var fieldsList = std.json.Array.init(arena);
        for (fields) |f| {
            var fMap = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
            try fMap.put(arena, "name", std.json.Value{ .string = f.name });
            const description: std.json.Value = if (f.description) |d| .{ .string = d } else .null;
            try fMap.put(arena, "description", description);
            try fMap.put(arena, "isDeprecated", std.json.Value{ .bool = false });
            try fMap.put(arena, "deprecationReason", .null);
            try fMap.put(arena, "type", try self.introspectTypeRef(arena, f.typeName, f.isList, f.isNonNull));

            var argsList = std.json.Array.init(arena);
            for (f.args) |a| {
                var aMap = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
                try aMap.put(arena, "name", std.json.Value{ .string = a.name });
                const argDescription: std.json.Value = if (a.description) |d| .{ .string = d } else .null;
                try aMap.put(arena, "description", argDescription);
                try aMap.put(arena, "type", try self.introspectTypeRef(arena, a.typeName, a.isList, a.isNonNull));
                const defaultValue: std.json.Value = if (a.defaultValue) |d| .{ .string = d } else .null;
                try aMap.put(arena, "defaultValue", defaultValue);
                try argsList.append(std.json.Value{ .object = aMap });
            }
            try fMap.put(arena, "args", std.json.Value{ .array = argsList });
            try fieldsList.append(std.json.Value{ .object = fMap });
        }
        return std.json.Value{ .array = fieldsList };
    }

    fn formatInputFieldList(self: *const Schema, arena: Allocator, fields: []const InputFieldDef) !std.json.Value {
        var list = std.json.Array.init(arena);
        for (fields) |f| {
            var fMap = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
            try fMap.put(arena, "name", std.json.Value{ .string = f.name });
            const description: std.json.Value = if (f.description) |d| .{ .string = d } else .null;
            try fMap.put(arena, "description", description);
            try fMap.put(arena, "type", try self.introspectTypeRef(arena, f.typeName, f.isList, f.isNonNull));
            const defaultValue: std.json.Value = if (f.defaultValue) |d| .{ .string = d } else .null;
            try fMap.put(arena, "defaultValue", defaultValue);
            try list.append(std.json.Value{ .object = fMap });
        }
        return std.json.Value{ .array = list };
    }

    fn formatEnumValues(self: *const Schema, arena: Allocator, values: []const []const u8) !std.json.Value {
        _ = self;
        var list = std.json.Array.init(arena);
        for (values) |value| {
            var vMap = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
            try vMap.put(arena, "name", std.json.Value{ .string = value });
            try vMap.put(arena, "description", .null);
            try vMap.put(arena, "isDeprecated", std.json.Value{ .bool = false });
            try vMap.put(arena, "deprecationReason", .null);
            try list.append(std.json.Value{ .object = vMap });
        }
        return std.json.Value{ .array = list };
    }

    fn formatNamedRefs(self: *const Schema, arena: Allocator, names: []const []const u8) !std.json.Value {
        var list = std.json.Array.init(arena);
        for (names) |name| try list.append(try self.introspectNamedType(arena, name));
        return std.json.Value{ .array = list };
    }

    fn formatImplementors(self: *const Schema, arena: Allocator, interfaceName: []const u8) !std.json.Value {
        var list = std.json.Array.init(arena);
        for (self.config.types) |t| {
            for (t.interfaces) |ifaceName| {
                if (std.mem.eql(u8, ifaceName, interfaceName)) {
                    try list.append(try self.introspectNamedType(arena, t.name));
                    break;
                }
            }
        }
        return std.json.Value{ .array = list };
    }

    /// Full introspection object for one named type.
    fn formatIntrospectionType(self: *const Schema, arena: Allocator, typeName: []const u8) !std.json.Value {
        const kind = self.kindOf(typeName);

        var tObj = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
        try tObj.put(arena, "kind", std.json.Value{ .string = kind });
        try tObj.put(arena, "name", std.json.Value{ .string = typeName });
        const description: std.json.Value = if (self.descriptionOf(typeName)) |d| .{ .string = d } else .null;
        try tObj.put(arena, "description", description);
        try tObj.put(arena, "ofType", .null);
        try tObj.put(arena, "fields", .null);
        try tObj.put(arena, "interfaces", .null);
        try tObj.put(arena, "possibleTypes", .null);
        try tObj.put(arena, "enumValues", .null);
        try tObj.put(arena, "inputFields", .null);

        if (std.mem.eql(u8, kind, "OBJECT")) {
            const obj = self.findType(typeName) orelse return std.json.Value{ .object = tObj };
            try tObj.put(arena, "fields", try self.formatFieldList(arena, obj.fields));
            try tObj.put(arena, "interfaces", try self.formatNamedRefs(arena, obj.interfaces));
        } else if (std.mem.eql(u8, kind, "INTERFACE")) {
            const iface = self.findInterface(typeName) orelse return std.json.Value{ .object = tObj };
            try tObj.put(arena, "fields", try self.formatFieldList(arena, iface.fields));
            try tObj.put(arena, "interfaces", std.json.Value{ .array = std.json.Array.init(arena) });
            try tObj.put(arena, "possibleTypes", try self.formatImplementors(arena, typeName));
        } else if (std.mem.eql(u8, kind, "ENUM")) {
            const enumDef = self.findEnum(typeName) orelse return std.json.Value{ .object = tObj };
            try tObj.put(arena, "enumValues", try self.formatEnumValues(arena, enumDef.values));
        } else if (std.mem.eql(u8, kind, "INPUT_OBJECT")) {
            const inputDef = self.findInput(typeName) orelse return std.json.Value{ .object = tObj };
            try tObj.put(arena, "inputFields", try self.formatInputFieldList(arena, inputDef.fields));
        } else if (std.mem.eql(u8, kind, "UNION")) {
            const unionDef = self.findUnion(typeName) orelse return std.json.Value{ .object = tObj };
            try tObj.put(arena, "possibleTypes", try self.formatNamedRefs(arena, unionDef.members));
        }

        return std.json.Value{ .object = tObj };
    }

    fn formatError(self: *const Schema, arena: Allocator, msg: []const u8) ![]u8 {
        _ = self;
        var errObj = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
        try errObj.put(arena, "message", std.json.Value{ .string = msg });

        var errsList = std.json.Array.init(arena);
        try errsList.append(std.json.Value{ .object = errObj });

        var resObj = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
        try resObj.put(arena, "errors", std.json.Value{ .array = errsList });

        var out: std.Io.Writer.Allocating = .init(arena);
        try std.json.fmt(std.json.Value{ .object = resObj }, .{}).format(&out.writer);
        return out.toOwnedSlice();
    }
};

// Test fixtures live at namespace scope: type and resolver declarations
// built inside a function body lose their static storage, so every schema
// under test is assembled from namespace-level declarations.
const Fixtures = struct {
    const User = struct { id: u64, name: []const u8 };
    const UserType = Type("User", .{ .id = Scalar.id, .name = Scalar.string });

    pub fn getMe(ctx: *Context) !User {
        _ = ctx;
        return .{ .id = 101, .name = "Muhammad" };
    }

    const Item = struct { id: u64, label: []const u8 };
    const ItemType = Type("Item", .{ .id = Scalar.id, .label = Scalar.string });
    const ItemArgs = struct { prefix: []const u8 };

    pub fn getItems(ctx: *Context, args: ItemArgs) ![]const Item {
        return &.{
            .{ .id = 1, .label = try std.fmt.allocPrint(ctx.allocator, "{s}-1", .{args.prefix}) },
            .{ .id = 2, .label = try std.fmt.allocPrint(ctx.allocator, "{s}-2", .{args.prefix}) },
        };
    }

    // Roots are namespace-level declarations too: a definition built inside
    // a function body loses its static storage in Zig's comptime model, so
    // `Query(...)` must not be called inline inside a runtime expression.
    const UserQuery = Query(.{
        .serverName = .{
            .type = Scalar.string,
            .resolve = getServerName,
        },
        .me = .{
            .type = UserType,
            .resolve = getMe,
        },
    });

    const ItemQuery = Query(.{
        .items = .{
            .type = ItemType,
            .list = true,
            .resolve = getItems,
        },
    });

    pub fn getServerName(ctx: Context) !std.json.Value {
        return ctx.value("unix-socket");
    }
};

test "graphql schema basic execution" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const schema = Schema.init(a, io, .{
        .query = Fixtures.UserQuery,
        .types = &.{Fixtures.UserType},
    });

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const res = try schema.execute(arena.allocator(), "{ serverName me { id name } }", null, null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"serverName\":\"unix-socket\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"id\":101") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"name\":\"Muhammad\"") != null);
}

test "graphql typed resolver args and list fields" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const schema = Schema.init(a, io, .{
        .query = Fixtures.ItemQuery,
        .types = &.{Fixtures.ItemType},
    });

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const res = try schema.execute(arena.allocator(), "{ items(prefix: \"item\") { id label } }", null, null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"label\":\"item-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"label\":\"item-2\"") != null);
}

// Full type-system fixtures: enum, input object, interface, union, args.
const AdvancedFixtures = struct {
    const Role = enum { ADMIN, USER };
    const RoleEnum = Enum("Role", &.{ "ADMIN", "USER" });

    const UserFilter = Input("UserFilter", .{
        .role = RoleEnum,
        .limit = .{ .type = Scalar.int, .nonNull = true },
    });

    const NodeInterface = Interface("Node", .{ .id = Scalar.id });

    const User = struct { id: u64, name: []const u8, role: Role };
    const UserType = implements(Type("User", .{
        .id = Scalar.id,
        .name = Scalar.string,
        .role = RoleEnum,
    }), &.{NodeInterface});

    const SearchResult = Union("SearchResult", &.{UserType});

    const Filter = struct { role: Role, limit: u16 };
    const Args = struct { filter: Filter, limit: u16 = 10 };

    pub fn getUsers(ctx: *Context, args: Args) ![]const User {
        _ = ctx;
        _ = args;
        return &.{.{ .id = 1, .name = "Alice", .role = .ADMIN }};
    }

    const UserQuery = Query(.{
        .users = .{
            .type = UserType,
            .list = true,
            .nonNull = true,
            .args = .{
                .filter = .{ .type = UserFilter, .nonNull = true },
                .limit = .{ .type = Scalar.int, .default = "10" },
            },
            .resolve = getUsers,
        },
    });
};

test "graphql enums, inputs, interfaces, unions, and typed introspection" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const schema = Schema.init(a, io, .{
        .query = AdvancedFixtures.UserQuery,
        .types = &.{AdvancedFixtures.UserType},
        .enums = &.{AdvancedFixtures.RoleEnum},
        .inputs = &.{AdvancedFixtures.UserFilter},
        .interfaces = &.{AdvancedFixtures.NodeInterface},
        .unions = &.{AdvancedFixtures.SearchResult},
    });

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Enum output, input-object arguments, and argument defaults.
    const res = try schema.execute(alloc, "{ users(filter: { role: ADMIN, limit: 1 }) { id name role } }", null, null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"role\":\"ADMIN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"name\":\"Alice\"") != null);

    // `__type` reports the object, its enum field, and its interface.
    const userType = try schema.execute(alloc, "{ __type(name: \"User\") { kind name } }", null, null);
    try std.testing.expect(std.mem.indexOf(u8, userType, "\"kind\":\"OBJECT\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, userType, "\"kind\":\"ENUM\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, userType, "\"name\":\"Role\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, userType, "\"kind\":\"INTERFACE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, userType, "\"name\":\"Node\"") != null);

    // The `users` field carries `[User!]!` plus its input-object argument and
    // the declared default, all with the correct nested wrappers.
    const queryType = try schema.execute(alloc, "{ __type(name: \"Query\") { kind name } }", null, null);
    try std.testing.expect(std.mem.indexOf(u8, queryType, "\"kind\":\"NON_NULL\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, queryType, "\"kind\":\"LIST\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, queryType, "\"name\":\"filter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, queryType, "\"kind\":\"INPUT_OBJECT\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, queryType, "\"defaultValue\":\"10\"") != null);

    const inputType = try schema.execute(alloc, "{ __type(name: \"UserFilter\") { kind name } }", null, null);
    try std.testing.expect(std.mem.indexOf(u8, inputType, "\"kind\":\"INPUT_OBJECT\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, inputType, "\"name\":\"limit\"") != null);

    const unionType = try schema.execute(alloc, "{ __type(name: \"SearchResult\") { kind name } }", null, null);
    try std.testing.expect(std.mem.indexOf(u8, unionType, "\"kind\":\"UNION\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, unionType, "\"possibleTypes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, unionType, "\"name\":\"User\"") != null);

    // `__schema` lists every declared kind so the UIs can show them all.
    const intro = try schema.execute(alloc, "{ __schema { types { name kind } } }", null, null);
    try std.testing.expect(std.mem.indexOf(u8, intro, "\"ENUM\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, intro, "\"INPUT_OBJECT\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, intro, "\"INTERFACE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, intro, "\"UNION\"") != null);
}
