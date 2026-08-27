//! Typed route metadata — the single source of truth for OpenAPI.
//!
//! Handlers are registered ONCE with optional Metadata; documentation is
//! derived from it. All strings are borrowed (typically comptime literals),
//! so metadata carries no allocation or ownership burden.
//!
//! Thread-safety: immutable after registration; safe to read concurrently.

const std = @import("std");

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
    /// ISO-ish string date; still a string schema with format hint.
    string_fmt: []const u8,
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

pub const Param = struct {
    name: []const u8,
    in: Location,
    required: bool = false,
    description: []const u8 = "",
    schema: *const Schema = &default_schema,

    pub const default_schema: Schema = .string;
};

pub const ContentType = enum {
    json,
    form,
    multipart,
    text_plain,
    html,
    octet_stream,

    pub fn mime(self: ContentType) []const u8 {
        return switch (self) {
            .json => "application/json",
            .form => "application/x-www-form-urlencoded",
            .multipart => "multipart/form-data",
            .text_plain => "text/plain",
            .html => "text/html",
            .octet_stream => "application/octet-stream",
        };
    }
};

pub const RequestBody = struct {
    content: ContentType,
    schema: ?*const Schema = null,
    required: bool = true,
    description: []const u8 = "",
};

pub const ResponseDesc = struct {
    status: u16,
    description: []const u8,
    schema: ?*const Schema = null,
};

/// A named reference to an auth scheme registered on the application
/// (e.g. "bearerAuth"). Schemes themselves live in the docs/security layer.
pub const SecurityReq = struct {
    scheme: []const u8,
    scopes: []const []const u8 = &.{},
};

/// Ready-to-reference comptime schema instances (`&schemas.integer`).
pub const schemas = struct {
    pub const string: Schema = .string;
    pub const integer: Schema = .integer;
    pub const number: Schema = .number;
    pub const boolean: Schema = .boolean;
};

pub const Metadata = struct {
    operation_id: ?[]const u8 = null,
    summary: []const u8 = "",
    description: []const u8 = "",
    tags: []const []const u8 = &.{},
    deprecated: bool = false,
    params: []const Param = &.{},
    request: ?RequestBody = null,
    /// Defaults to a single `200 OK` when empty and not deprecated.
    responses: []const ResponseDesc = &.{},
    security: []const SecurityReq = &.{},
};
