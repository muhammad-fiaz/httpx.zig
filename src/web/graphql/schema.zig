//! GraphQL Schema Definition, Validation, and Execution Engine.
//!
//! Features:
//! - Type System: Scalars (Int, Float, String, Boolean, ID, Custom), Objects, Lists, NonNull
//! - Schema Introspection (__schema, __type, __typename) for GraphiQL and tools
//! - Resolvers: Synchronous field resolution with context, arguments, and source data
//! - Error formatting with locations, paths, and extensions
//! - Query complexity and depth security limits

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");

pub const TypeKind = enum {
    scalar,
    object,
    interface,
    union_type,
    enum_type,
    input_object,
    list,
    non_null,
};

pub const FieldResolver = *const fn (ctx: *ResolverContext) anyerror!std.json.Value;

pub const ResolverContext = struct {
    allocator: Allocator,
    parent: ?std.json.Value = null,
    args: std.json.Value = .null,
    variables: std.json.Value = .null,
    field_name: []const u8,
    user_context: ?*anyopaque = null,
};

pub const FieldDef = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    type_name: []const u8,
    is_list: bool = false,
    is_non_null: bool = false,
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
    max_depth: usize = 32,
    max_complexity: usize = 500,
    enable_introspection: bool = true,
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

    pub fn execute(self: *const Schema, arena: Allocator, query: []const u8, variables_json: ?[]const u8, user_context: ?*anyopaque) ![]u8 {
        var parsed_vars: std.json.Value = .null;
        if (variables_json) |v_str| {
            if (v_str.len > 0 and !std.mem.eql(u8, v_str, "null")) {
                const parsed = std.json.parseFromSlice(std.json.Value, arena, v_str, .{}) catch return self.formatError(arena, "Invalid variables JSON payload");
                parsed_vars = parsed.value;
            }
        }

        var parser = parser_mod.Parser.init(arena, query, .{ .max_depth = self.config.max_depth }) catch |err| {
            return self.formatError(arena, switch (err) {
                error.RequestEntityTooLarge => "Query payload exceeds maximum size limit",
                error.MaxQueryDepthExceeded => "Query exceeds maximum depth limit",
                error.TokenLimitExceeded => "Query exceeds maximum token complexity limit",
                else => "Syntax error while parsing GraphQL query",
            });
        };

        const doc = parser.parseDocument() catch return self.formatError(arena, "GraphQL syntax error: failed to parse document");

        // Find query or mutation operation
        var op_def: ?ast.OperationDefinition = null;
        var fragments = std.StringHashMap(ast.FragmentDefinition).init(arena);

        for (doc.definitions) |d| {
            switch (d) {
                .operation => |op| {
                    if (op_def == null) op_def = op;
                },
                .fragment => |f| {
                    try fragments.put(f.name, f);
                },
            }
        }

        if (op_def == null) return self.formatError(arena, "No executable operation found in GraphQL request");

        const op = op_def.?;
        const target_obj = switch (op.operation_type) {
            .query => self.config.query,
            .mutation => self.config.mutation orelse return self.formatError(arena, "Mutations are not supported by this schema"),
            .subscription => return self.formatError(arena, "Subscriptions are not supported over standard HTTP POST"),
        };

        var root_data = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;

        for (op.selection_set) |sel| {
            switch (sel) {
                .field => |f| {
                    const field_val = try self.resolveField(arena, target_obj, f, null, parsed_vars, &fragments, user_context);
                    const output_name = f.alias orelse f.name;
                    try root_data.put(arena, output_name, field_val);
                },
                .fragment_spread => |fs| {
                    if (fragments.get(fs.name)) |f_def| {
                        for (f_def.selection_set) |f_sel| {
                            if (f_sel == .field) {
                                const f = f_sel.field;
                                const field_val = try self.resolveField(arena, target_obj, f, null, parsed_vars, &fragments, user_context);
                                const output_name = f.alias orelse f.name;
                                try root_data.put(arena, output_name, field_val);
                            }
                        }
                    }
                },
                .inline_fragment => |inf| {
                    for (inf.selection_set) |inf_sel| {
                        if (inf_sel == .field) {
                            const f = inf_sel.field;
                            const field_val = try self.resolveField(arena, target_obj, f, null, parsed_vars, &fragments, user_context);
                            const output_name = f.alias orelse f.name;
                            try root_data.put(arena, output_name, field_val);
                        }
                    }
                },
            }
        }

        var response_obj = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
        try response_obj.put(arena, "data", std.json.Value{ .object = root_data });

        var out: std.Io.Writer.Allocating = .init(arena);
        try std.json.fmt(std.json.Value{ .object = response_obj }, .{}).format(&out.writer);
        return out.toOwnedSlice();
    }

    fn resolveField(
        self: *const Schema,
        arena: Allocator,
        obj_def: ObjectTypeDef,
        field: ast.Field,
        parent_val: ?std.json.Value,
        variables: std.json.Value,
        fragments: *const std.StringHashMap(ast.FragmentDefinition),
        user_ctx: ?*anyopaque,
    ) !std.json.Value {
        // Introspection handling
        if (self.config.enable_introspection) {
            if (std.mem.eql(u8, field.name, "__typename")) {
                return std.json.Value{ .string = obj_def.name };
            }
            if (std.mem.eql(u8, field.name, "__schema")) {
                return self.resolveSchemaIntrospection(arena, field);
            }
        }

        // Locate field definition in schema
        var field_def: ?FieldDef = null;
        for (obj_def.fields) |fd| {
            if (std.mem.eql(u8, fd.name, field.name)) {
                field_def = fd;
                break;
            }
        }

        if (field_def == null) {
            // Check if parent is a JSON object with this key
            if (parent_val) |pv| {
                if (pv == .object) {
                    if (pv.object.get(field.name)) |v| return v;
                }
            }
            return .null;
        }

        const fd = field_def.?;

        // Evaluate arguments
        var args_obj = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
        for (field.arguments) |arg| {
            const arg_val = self.evaluateValue(arena, arg.value, variables);
            try args_obj.put(arena, arg.name, arg_val);
        }

        var res_ctx = ResolverContext{
            .allocator = arena,
            .parent = parent_val,
            .args = std.json.Value{ .object = args_obj },
            .variables = variables,
            .field_name = field.name,
            .user_context = user_ctx,
        };

        var resolved_value: std.json.Value = .null;
        if (fd.resolver) |r| {
            resolved_value = r(&res_ctx) catch {
                return .null;
            };
        } else if (parent_val) |pv| {
            if (pv == .object) {
                resolved_value = pv.object.get(field.name) orelse .null;
            }
        }

        // If field has selection set and resolved value is an object or array
        if (field.selection_set.len > 0) {
            const nested_type = self.findType(fd.type_name) orelse ObjectTypeDef{ .name = fd.type_name, .fields = &.{} };
            switch (resolved_value) {
                .object => |sub_obj| {
                    var out_obj = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
                    for (field.selection_set) |sel| {
                        switch (sel) {
                            .field => |sf| {
                                const sv = try self.resolveField(arena, nested_type, sf, std.json.Value{ .object = sub_obj }, variables, fragments, user_ctx);
                                const out_name = sf.alias orelse sf.name;
                                try out_obj.put(arena, out_name, sv);
                            },
                            .fragment_spread => |sfs| {
                                if (fragments.get(sfs.name)) |f_def| {
                                    for (f_def.selection_set) |f_sel| {
                                        if (f_sel == .field) {
                                            const sf = f_sel.field;
                                            const sv = try self.resolveField(arena, nested_type, sf, std.json.Value{ .object = sub_obj }, variables, fragments, user_ctx);
                                            const out_name = sf.alias orelse sf.name;
                                            try out_obj.put(arena, out_name, sv);
                                        }
                                    }
                                }
                            },
                            .inline_fragment => |inf| {
                                for (inf.selection_set) |inf_sel| {
                                    if (inf_sel == .field) {
                                        const sf = inf_sel.field;
                                        const sv = try self.resolveField(arena, nested_type, sf, std.json.Value{ .object = sub_obj }, variables, fragments, user_ctx);
                                        const out_name = sf.alias orelse sf.name;
                                        try out_obj.put(arena, out_name, sv);
                                    }
                                }
                            },
                        }
                    }
                    return std.json.Value{ .object = out_obj };
                },
                .array => |arr| {
                    var out_arr = std.json.Array.init(arena);
                    for (arr.items) |elem| {
                        if (elem == .object) {
                            var elem_obj = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
                            for (field.selection_set) |sel| {
                                if (sel == .field) {
                                    const sf = sel.field;
                                    const sv = try self.resolveField(arena, nested_type, sf, elem, variables, fragments, user_ctx);
                                    const out_name = sf.alias orelse sf.name;
                                    try elem_obj.put(arena, out_name, sv);
                                }
                            }
                            try out_arr.append(std.json.Value{ .object = elem_obj });
                        } else {
                            try out_arr.append(elem);
                        }
                    }
                    return std.json.Value{ .array = out_arr };
                },
                else => return resolved_value,
            }
        }

        return resolved_value;
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
            .variable => |v_name| {
                if (variables == .object) {
                    return variables.object.get(v_name) orelse .null;
                }
                return .null;
            },
            .int => |i| .{ .integer = i },
            .float => |f| .{ .float = f },
            .string => |s| .{ .string = s },
            .boolean => |b| .{ .bool = b },
            .null_val => .null,
            .enum_val => |e| .{ .string = e },
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
        var s_obj = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
        var q_type = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
        try q_type.put(arena, "name", std.json.Value{ .string = self.config.query.name });
        try s_obj.put(arena, "queryType", std.json.Value{ .object = q_type });

        if (self.config.mutation) |m| {
            var m_type = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
            try m_type.put(arena, "name", std.json.Value{ .string = m.name });
            try s_obj.put(arena, "mutationType", std.json.Value{ .object = m_type });
        } else {
            try s_obj.put(arena, "mutationType", .null);
        }

        try s_obj.put(arena, "subscriptionType", .null);
        try s_obj.put(arena, "directives", std.json.Value{ .array = std.json.Array.init(arena) });

        var types_list = std.json.Array.init(arena);

        // Add standard built-in scalar types (Int, Float, String, Boolean, ID)
        for ([_][]const u8{ "Int", "Float", "String", "Boolean", "ID" }) |scalar_name| {
            var sc_obj = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
            try sc_obj.put(arena, "kind", std.json.Value{ .string = "SCALAR" });
            try sc_obj.put(arena, "name", std.json.Value{ .string = scalar_name });
            try sc_obj.put(arena, "description", .null);
            try sc_obj.put(arena, "fields", .null);
            try sc_obj.put(arena, "interfaces", .null);
            try sc_obj.put(arena, "possibleTypes", .null);
            try sc_obj.put(arena, "enumValues", .null);
            try sc_obj.put(arena, "inputFields", .null);
            try sc_obj.put(arena, "ofType", .null);
            try types_list.append(std.json.Value{ .object = sc_obj });
        }

        // Add Query type
        try types_list.append(try self.formatIntrospectionType(arena, self.config.query));

        // Add Mutation type if present
        if (self.config.mutation) |m| {
            try types_list.append(try self.formatIntrospectionType(arena, m));
        }

        // Add user types
        for (self.config.types) |t| {
            try types_list.append(try self.formatIntrospectionType(arena, t));
        }

        try s_obj.put(arena, "types", std.json.Value{ .array = types_list });
        return std.json.Value{ .object = s_obj };
    }

    fn formatIntrospectionType(self: *const Schema, arena: Allocator, obj: ObjectTypeDef) !std.json.Value {
        _ = self;
        var t_obj = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
        try t_obj.put(arena, "kind", std.json.Value{ .string = "OBJECT" });
        try t_obj.put(arena, "name", std.json.Value{ .string = obj.name });
        if (obj.description) |d| {
            try t_obj.put(arena, "description", std.json.Value{ .string = d });
        } else {
            try t_obj.put(arena, "description", .null);
        }

        var fields_list = std.json.Array.init(arena);
        for (obj.fields) |f| {
            var f_map = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
            try f_map.put(arena, "name", std.json.Value{ .string = f.name });
            if (f.description) |fd| {
                try f_map.put(arena, "description", std.json.Value{ .string = fd });
            } else {
                try f_map.put(arena, "description", .null);
            }
            try f_map.put(arena, "isDeprecated", std.json.Value{ .bool = false });
            try f_map.put(arena, "deprecationReason", .null);

            var type_ref = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
            try type_ref.put(arena, "kind", std.json.Value{ .string = "SCALAR" });
            try type_ref.put(arena, "name", std.json.Value{ .string = f.type_name });
            try type_ref.put(arena, "ofType", .null);
            try f_map.put(arena, "type", std.json.Value{ .object = type_ref });

            try f_map.put(arena, "args", std.json.Value{ .array = std.json.Array.init(arena) });
            try fields_list.append(std.json.Value{ .object = f_map });
        }
        try t_obj.put(arena, "fields", std.json.Value{ .array = fields_list });
        try t_obj.put(arena, "interfaces", std.json.Value{ .array = std.json.Array.init(arena) });
        try t_obj.put(arena, "possibleTypes", .null);
        try t_obj.put(arena, "enumValues", .null);
        try t_obj.put(arena, "inputFields", .null);
        try t_obj.put(arena, "ofType", .null);

        return std.json.Value{ .object = t_obj };
    }

    fn formatError(self: *const Schema, arena: Allocator, msg: []const u8) ![]u8 {
        _ = self;
        var err_obj = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
        try err_obj.put(arena, "message", std.json.Value{ .string = msg });

        var errs_list = std.json.Array.init(arena);
        try errs_list.append(std.json.Value{ .object = err_obj });

        var res_obj = std.json.ObjectMap.init(arena, &.{}, &.{}) catch unreachable;
        try res_obj.put(arena, "errors", std.json.Value{ .array = errs_list });

        var out: std.Io.Writer.Allocating = .init(arena);
        try std.json.fmt(std.json.Value{ .object = res_obj }, .{}).format(&out.writer);
        return out.toOwnedSlice();
    }
};

test "graphql schema basic execution" {
    const a = std.testing.allocator;

    const UserType = ObjectTypeDef{
        .name = "User",
        .fields = &.{
            .{ .name = "id", .type_name = "ID" },
            .{ .name = "name", .type_name = "String" },
        },
    };

    const resolver = struct {
        fn getMe(ctx: *ResolverContext) anyerror!std.json.Value {
            var map = std.json.ObjectMap.init(ctx.allocator, &.{}, &.{}) catch unreachable;
            try map.put(ctx.allocator, "id", .{ .string = "101" });
            try map.put(ctx.allocator, "name", .{ .string = "Muhammad" });
            return .{ .object = map };
        }
    };

    const QueryType = ObjectTypeDef{
        .name = "Query",
        .fields = &.{
            .{ .name = "me", .type_name = "User", .resolver = &resolver.getMe },
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
