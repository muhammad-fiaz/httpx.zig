//! Compatibility facade for the shared MIME registry.

pub const registry = @import("../common/mime.zig");
pub const octetStream = registry.octetStream;
pub const fromPath = registry.fromPath;
pub const fromExtension = registry.fromExtension;
pub const lookupExtension = registry.lookupExtension;
pub const extensionFor = registry.extensionFor;
pub const json = registry.json;
pub const applicationJson = registry.applicationJson;
pub const applicationJsonUtf8 = registry.applicationJsonUtf8;
pub const isJson = registry.isJson;
pub const isJsonPath = registry.isJsonPath;
