//! Typed route metadata — the single source of truth for OpenAPI.
//!
//! Handlers are registered ONCE with optional Metadata; documentation is
//! derived from it. All strings are borrowed (typically comptime literals),
//! so metadata carries no allocation or ownership burden.
//!
//! Thread-safety: immutable after registration; safe to read concurrently.

const std = @import("std");
const mimeMod = @import("../../common/mime.zig");
const mediaTypeMod = @import("../../common/mediaType.zig");
const z = @import("zigantic");

/// Schema for a value zigantic cannot inspect structurally (function
/// pointers, opaque pointers, fixed byte arrays). Type-checked only.
fn typedSchema(comptime T: type) type {
    return z.custom(T, .{ .check = struct {
        fn accept(_: T) bool {
            return true;
        }
    }.accept });
}

/// Parameter location.
pub const Location = enum {
    path,
    query,
    header,
    cookie,

    pub fn name(self: Location) []const u8 {
        return switch (self) {
            .path => "path",
            .query => "query",
            .header => "header",
            .cookie => "cookie",
        };
    }
};

/// Minimal OpenAPI schema model (borrowed tree).
pub const Schema = union(enum) {
    string,
    integer,
    number,
    boolean,
    /// Free-form JSON: any object, array, scalar, or null. Serialized as the
    /// empty schema `{}`, which accepts every JSON value.
    any,
    /// ISO-ish string date; still a string schema with format hint.
    stringFmt: []const u8,
    array: *const Schema,
    object: []const ObjectField,
    /// Reference into components/schemas.
    ref: []const u8,

    pub const ObjectField = struct {
        name: []const u8,
        schema: *const Schema,
        required: bool = true,
        nullable: bool = false,
    };
};

pub const ParamSchema = z.objectOf(.{
    .name = z.string(.{ .min = 1 }),
    .in = z.enumType(Location, .{}),
    .required = z.withDefault(z.boolean(.{}), false),
    .description = z.withDefault(z.string(.{}), ""),
    .schema = z.withDefault(typedSchema(*const Schema), &defaultSchema),
}, .{});
pub const Param = ParamSchema.Value;

pub const defaultSchema: Schema = .string;

pub const ContentType = enum {
    json,
    form,
    multipart,
    textPlain,
    html,
    octetStream,

    pub fn mime(self: ContentType) []const u8 {
        return switch (self) {
            .json => mediaTypeMod.applicationJson,
            .form => mediaTypeMod.formUrlEncoded,
            .multipart => mediaTypeMod.multipartFormData,
            .textPlain => mediaTypeMod.textPlain,
            .html => mediaTypeMod.textHtml,
            .octetStream => mimeMod.octetStream,
        };
    }
};

pub const RequestBodySchema = z.objectOf(.{
    .content = z.enumType(ContentType, .{}),
    .schema = z.optional(typedSchema(*const Schema)),
    .required = z.withDefault(z.boolean(.{}), true),
    .description = z.withDefault(z.string(.{}), ""),
}, .{});
pub const RequestBody = RequestBodySchema.Value;

pub const ResponseDescSchema = z.objectOf(.{
    .status = z.integer(u16, .{}),
    .description = z.string(.{}),
    .schema = z.optional(typedSchema(*const Schema)),
}, .{});
pub const ResponseDesc = ResponseDescSchema.Value;

/// A named reference to an auth scheme registered on the application
/// (e.g. "bearerAuth"). Schemes themselves live in the docs/security layer.
pub const SecurityReqSchema = z.objectOf(.{
    .scheme = z.string(.{ .min = 1 }),
    .scopes = z.withDefault(z.array(z.string(.{ .min = 1 }), .{}), &.{}),
}, .{});
pub const SecurityReq = SecurityReqSchema.Value;

/// Ready-to-reference comptime schema instances (`&schemas.integer`).
pub const schemas = struct {
    pub const string: Schema = .string;
    pub const integer: Schema = .integer;
    pub const number: Schema = .number;
    pub const boolean: Schema = .boolean;
};

pub const MetadataSchema = z.objectOf(.{
    .operationId = z.optional(z.string(.{ .min = 1 })),
    .summary = z.withDefault(z.string(.{}), ""),
    .description = z.withDefault(z.string(.{}), ""),
    .tags = z.withDefault(z.array(z.string(.{ .min = 1 }), .{}), &.{}),
    .deprecated = z.withDefault(z.boolean(.{}), false),
    .params = z.withDefault(z.array(ParamSchema, .{}), &.{}),
    .request = z.optional(RequestBodySchema),
    .responses = z.withDefault(z.array(ResponseDescSchema, .{}), &.{}),
    .security = z.withDefault(z.array(SecurityReqSchema, .{}), &.{}),
    .internal = z.withDefault(z.boolean(.{}), false),
}, .{});
pub const Metadata = MetadataSchema.Value;
