//! httpx.graphql - GraphQL Server & GraphiQL Documentation Engine.
//!
//! Provides:
//! - AST definitions (ast.zig)
//! - Lexer & Parser (parser.zig)
//! - Schema, Type System, Resolvers, and Introspection (schema.zig)
//! - HTTP Endpoint & Handler (server.zig)
//! - GraphiQL 5.3.0 UI integration via `httpx.docs` or `httpx.graphql.mount`

pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");
pub const schema = @import("schema.zig");
pub const server = @import("server.zig");

pub const Schema = schema.Schema;
pub const SchemaConfig = schema.SchemaConfig;
pub const ObjectTypeDef = schema.ObjectTypeDef;
pub const FieldDef = schema.FieldDef;
pub const ResolverContext = schema.ResolverContext;
pub const FieldResolver = schema.FieldResolver;
pub const Parser = parser.Parser;
pub const ParseLimits = parser.ParseLimits;
pub const HandlerConfig = server.HandlerConfig;
pub const mount = server.mount;
pub const query = @import("../../client/client.zig").globalGraphql;
pub const execute = @import("../../client/client.zig").globalGraphql;

test {
    _ = ast;
    _ = parser;
    _ = schema;
    _ = server;
}
