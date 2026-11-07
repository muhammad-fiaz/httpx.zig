//! httpx.graphql - GraphQL Server & GraphiQL Documentation Engine.
//!
//! Provides:
//! - AST definitions (ast.zig)
//! - Lexer & Parser (parser.zig)
//! - Schema, Type System, Resolvers, and Introspection (schema.zig)
//! - HTTP Endpoint & Handler (server.zig)
//! - GraphiQL 6.0.0 UI integration via `httpx.docs` or `httpx.graphql.mount`
//!
//! Types are spec-driven: list every field explicitly with a scalar kind
//! (`Scalar.id`, `Scalar.string`, …) or a declared object, enum, interface, or
//! union type, and bind typed resolvers. Object, enum, input object, interface,
//! and union types are all declared explicitly, and every one of them reaches
//! introspection so GraphiQL / ReDoc / Scalar render the complete schema.
//! `Object(...)` is the string-named counterpart of `Type(...)` for schemas
//! assembled from external type names.
//!
//! Client-side decoding is typed too: a string query goes out through
//! `Client.graphql`, and the response is read with
//! `res.json(httpx.graphql.Payload(T))`.

const std = @import("std");

pub const ast = @import("ast.zig");
pub const parser = @import("graphQlParser.zig");
pub const schema = @import("graphQlSchema.zig");
pub const server = @import("graphQlServer.zig");

pub const Schema = schema.Schema;
pub const SchemaConfig = schema.SchemaConfig;
/// Field execution context: `fn (*httpx.graphql.Context) !T`, the GraphQL
/// counterpart of `httpx.router.Context` for routes.
pub const Context = schema.Context;
/// Scalar kinds for field specs: `httpx.graphql.Scalar.string`,
/// `Scalar.int`, `Scalar.float`, `Scalar.boolean`, `Scalar.id`.
pub const Scalar = schema.Scalar;
/// `Type("User", .{ .id = Scalar.id, .name = Scalar.string })` — an object type
/// declared from an explicit field spec.
pub const Type = schema.Type;
/// Root `Query` object from a resolver spec.
pub const Query = schema.Query;
/// Root `Mutation` object from a resolver spec.
pub const Mutation = schema.Mutation;
/// String-named object type for schemas assembled from raw type names:
/// `Object("User", &.{ .{ .name = "id", .typeName = "ID" } })`. The non-typed
/// counterpart of `Type(...)`.
pub const Object = schema.Object;
/// Enum type: `Enum("Role", &.{ "ADMIN", "USER" })`.
pub const Enum = schema.Enum;
/// Input object type for field arguments: `Input("Filter", .{ .role = Role })`.
pub const Input = schema.Input;
/// Interface type: `Interface("Node", .{ .id = Scalar.id })`.
pub const Interface = schema.Interface;
/// Union of object types: `Union("Search", &.{UserType, ItemType})`.
pub const Union = schema.Union;
/// Marks an object type as implementing interfaces:
/// `implements(Type("User", .{...}), &.{NodeInterface})`.
pub const implements = schema.implements;
pub const ArgDef = schema.ArgDef;
pub const FieldDef = schema.FieldDef;
pub const InputFieldDef = schema.InputFieldDef;
pub const ObjectTypeDef = schema.ObjectTypeDef;
pub const EnumTypeDef = schema.EnumTypeDef;
pub const InputTypeDef = schema.InputTypeDef;
pub const InterfaceTypeDef = schema.InterfaceTypeDef;
pub const UnionTypeDef = schema.UnionTypeDef;

/// Typed GraphQL response envelope for client-side decoding:
///
/// ```zig
/// const Me = struct { me: struct { id: []const u8, name: []const u8 } };
/// var res = try client.graphql(url, "{ me { id name } }", null, .{});
/// defer res.deinit();
/// const payload = try res.json(httpx.graphql.Payload(Me));
/// if (payload.data) |data| std.debug.print("{s}\n", .{data.me.name});
/// ```
///
/// `T` declares only the fields it selected; unknown response keys are
/// ignored, and the values live in the response arena until `deinit`.
pub fn Payload(comptime T: type) type {
    return struct {
        data: ?T = null,
        errors: ?[]const GraphQLError = null,

        pub const GraphQLError = struct {
            message: []const u8,
            path: ?[]const std.json.Value = null,
            extensions: ?std.json.Value = null,
        };
    };
}
pub const HandlerConfig = server.HandlerConfig;
pub const mount = server.mount;
pub const unmount = server.unmount;
// NOTE: client GraphQL requests live on Client.graphql
// (client.graphql(url, query, variables, .{})); they are not
// re-exported here to keep server/client namespaces distinct.

test {
    _ = ast;
    _ = parser;
    _ = schema;
    _ = server;
}
