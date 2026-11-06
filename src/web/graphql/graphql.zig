//! httpx.graphql - GraphQL Server & GraphiQL Documentation Engine.
//!
//! Provides:
//! - AST definitions (ast.zig)
//! - Lexer & Parser (parser.zig)
//! - Schema, Type System, Resolvers, and Introspection (schema.zig)
//! - HTTP Endpoint & Handler (server.zig)
//! - GraphiQL 6.0.0 UI integration via `httpx.docs` or `httpx.graphql.mount`
//!
//! Types are schema-based and struct-driven, like `httpx.json.Schema` and
//! `httpx.Schema(T)`: name a Zig struct, list fields with scalar kinds
//! (`.id`, `.name = .string`), and bind typed resolvers. No raw GraphQL
//! type-name strings or internal definition structs appear in user code.

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
/// `Type(User, .{ .id = .id, .name = .string })` — an object type from a
/// named Zig struct.
pub const Type = schema.Type;
/// Root `Query` object from a resolver spec.
pub const Query = schema.Query;
/// Root `Mutation` object from a resolver spec.
pub const Mutation = schema.Mutation;
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
