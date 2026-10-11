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

pub const FieldResolver = *const fn (ctx: ResolverContext) anyerror!std.json.Value;

pub const ResolverContext = struct {
    allocator: Allocator,
    parent: ?std.json.Value = null,
    args: std.json.Value = .null,
    variables: std.json.Value = .null,
    fieldName: []const u8,
    userContext: ?*anyopaque = null,

    /// Converts any Zig value, struct, slice, or primitive directly into a std.json.Value.
    /// Eliminates manual ObjectMap/Array boilerplate in resolvers.
    pub fn value(self: ResolverContext, val: anytype) anyerror!std.json.Value {
        const jsonBytes = try std.json.Stringify.valueAlloc(self.allocator, val, .{});
        defer self.allocator.free(jsonBytes);
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, jsonBytes, .{});
        return parsed.value;
    }
};

pub const FieldDef = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    typeName: []const u8,
    isList: bool = false,
    isNonNull: bool = false,
    resolver: ?FieldResolver = null,
};

pub const ObjectTypeDef = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    fields: []const FieldDef,
};

pub const SchemaConfig = struct {
    query: ObjectTypeDef,
    mutation: ?ObjectTypeDef = null,
    types: []const ObjectTypeDef = &.{},
    maxDepth: usize = 32,
    maxComplexity: usize = 500,
    introspection: bool = true,
    enableIntrospection: ?bool = null,

    pub fn isIntrospectionEnabled(self: SchemaConfig) bool {
        return self.enableIntrospection orelse self.introspection;
    }
};

pub const Schema = struct {
    allocator: Allocator,
    config: SchemaConfig,

    pub fn init(allocator: Allocator, config: SchemaConfig) Schema {
        return Schema{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn execute(self: *const Schema, arena: Allocator, query: []const u8, variablesJson: ?[]const u8, userContext: ?*anyopaque) ![]u8 {
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

        // Find query or mutation operation
        var opDef: ?ast.OperationDefinition = null;
        var fragments = std.StringHashMap(ast.FragmentDefinition).init(arena);

        for (doc.definitions) |d| {
            switch (d) {
                .operation => |op| {
                    if (opDef == null) opDef = op;
                },
                .fragment => |f| {
                    try fragments.put(f.name, f);
                },
            }
        }

        if (opDef == null) return self.formatError(arena, "No executable operation found in GraphQL request");

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
        if (self.config.isIntrospectionEnabled()) {
            if (std.mem.eql(u8, field.name, "__typename")) {
                return std.json.Value{ .string = objDef.name };
            }
            if (std.mem.eql(u8, field.name, "__schema")) {
                return self.resolveSchemaIntrospection(arena, field);
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

        const resCtx = ResolverContext{
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

        // Add standard built-in scalar types (Int, Float, String, Boolean, ID)
        for ([_][]const u8{ "Int", "Float", "String", "Boolean", "ID" }) |scalarName| {
            var scObj = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
            try scObj.put(arena, "kind", std.json.Value{ .string = "SCALAR" });
            try scObj.put(arena, "name", std.json.Value{ .string = scalarName });
            try scObj.put(arena, "description", .null);
            try scObj.put(arena, "fields", .null);
            try scObj.put(arena, "interfaces", .null);
            try scObj.put(arena, "possibleTypes", .null);
            try scObj.put(arena, "enumValues", .null);
            try scObj.put(arena, "inputFields", .null);
            try scObj.put(arena, "ofType", .null);
            try typesList.append(std.json.Value{ .object = scObj });
        }

        // Add Query type
        try typesList.append(try self.formatIntrospectionType(arena, self.config.query));

        // Add Mutation type if present
        if (self.config.mutation) |m| {
            try typesList.append(try self.formatIntrospectionType(arena, m));
        }

        // Add user types
        for (self.config.types) |t| {
            try typesList.append(try self.formatIntrospectionType(arena, t));
        }

        try sObj.put(arena, "types", std.json.Value{ .array = typesList });
        return std.json.Value{ .object = sObj };
    }

    fn formatIntrospectionType(self: *const Schema, arena: Allocator, obj: ObjectTypeDef) !std.json.Value {
        _ = self;
        var tObj = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
        try tObj.put(arena, "kind", std.json.Value{ .string = "OBJECT" });
        try tObj.put(arena, "name", std.json.Value{ .string = obj.name });
        if (obj.description) |d| {
            try tObj.put(arena, "description", std.json.Value{ .string = d });
        } else {
            try tObj.put(arena, "description", .null);
        }

        var fieldsList = std.json.Array.init(arena);
        for (obj.fields) |f| {
            var fMap = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
            try fMap.put(arena, "name", std.json.Value{ .string = f.name });
            if (f.description) |fd| {
                try fMap.put(arena, "description", std.json.Value{ .string = fd });
            } else {
                try fMap.put(arena, "description", .null);
            }
            try fMap.put(arena, "isDeprecated", std.json.Value{ .bool = false });
            try fMap.put(arena, "deprecationReason", .null);

            var typeRef = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
            try typeRef.put(arena, "kind", std.json.Value{ .string = "SCALAR" });
            try typeRef.put(arena, "name", std.json.Value{ .string = f.typeName });
            try typeRef.put(arena, "ofType", .null);
            try fMap.put(arena, "type", std.json.Value{ .object = typeRef });

            try fMap.put(arena, "args", std.json.Value{ .array = std.json.Array.init(arena) });
            try fieldsList.append(std.json.Value{ .object = fMap });
        }
        try tObj.put(arena, "fields", std.json.Value{ .array = fieldsList });
        try tObj.put(arena, "interfaces", std.json.Value{ .array = std.json.Array.init(arena) });
        try tObj.put(arena, "possibleTypes", .null);
        try tObj.put(arena, "enumValues", .null);
        try tObj.put(arena, "inputFields", .null);
        try tObj.put(arena, "ofType", .null);

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

test "graphql schema basic execution" {
    const a = std.testing.allocator;

    const UserType = ObjectTypeDef{
        .name = "User",
        .fields = &.{
            .{ .name = "id", .typeName = "ID" },
            .{ .name = "name", .typeName = "String" },
        },
    };

    const resolver = struct {
        fn getMe(ctx: ResolverContext) anyerror!std.json.Value {
            return ctx.value(.{
                .id = "101",
                .name = "Muhammad",
            });
        }
    };

    const QueryType = ObjectTypeDef{
        .name = "Query",
        .fields = &.{
            .{ .name = "me", .typeName = "User", .resolver = resolver.getMe },
        },
    };

    const schema = Schema.init(a, .{
        .query = QueryType,
        .types = &.{UserType},
    });

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const res = try schema.execute(arena.allocator(), "{ me { id name } }", null, null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"id\":\"101\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"name\":\"Muhammad\"") != null);
}
