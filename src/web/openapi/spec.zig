//! OpenAPI 3.1 document generation from registered routes.
//!
//! Paths are derived from the router's patterns:
//!   literal   -> kept verbatim
//!   {param}   -> emitted as `{param}` (OpenAPI template syntax)
//!   *wildcard -> emitted as `{name}` (documented approximation; OpenAPI
//!                has no catch-all concept)
//!
//! operationIds are `<method>_<sanitized path>` and are de-duplicated with a
//! numeric suffix when sanitization would collide two distinct paths.

const std = @import("std");
const Allocator = std.mem.Allocator;
const routerMod = @import("../router/router.zig");
const Context = routerMod.Context;
const Response = routerMod.Response;
const Router = routerMod.Router;
const Method = @import("../../common/method.zig").Method;
const metaMod = @import("../router/metadata.zig");
const patternMod = @import("../router/pattern.zig");
pub const Info = @import("../../common/version.zig").Info;

const PathGroup = struct {
    openapiPath: []u8, // owned
    methods: std.ArrayList(Method) = .empty,
    /// Indexes into router.routes rendering to this OpenAPI path. Distinct
    /// router shapes (e.g. /f/{id} and /f/*rest) may share one group.
    entryIdx: std.ArrayList(usize) = .empty,
};

pub const GenerateError = Allocator.Error || std.Io.Writer.Error || error{DuplicateOperationId};

/// Generates an OpenAPI 3.1 JSON document (owned by caller) describing every
/// route currently registered on `router`. Uses the router's internal allocator.
pub fn generate(router: *const Router, info: Info) GenerateError![]u8 {
    const allocator = router.allocator;
    var groups: std.ArrayList(PathGroup) = .empty;
    defer {
        for (groups.items) |*g| {
            allocator.free(g.openapiPath);
            g.methods.deinit(allocator);
            g.entryIdx.deinit(allocator);
        }
        groups.deinit(allocator);
    }

    for (router.entries(), 0..) |entry, ei| {
        // Internal infrastructure routes (docs UI, assets) never appear.
        if (entry.meta.internal) continue;
        // Fallback for docs routes registered without the internal flag
        // (backwards compat): exact match or slash-boundary prefix only, so
        // user routes like "/docs-custom" or "/redocly" are NOT filtered.
        if (isDocsPath(entry.path)) continue;

        const pathStr = try renderOpenApiPath(allocator, &entry.pattern);
        defer allocator.free(pathStr);

        const found = for (groups.items) |*g| {
            if (std.mem.eql(u8, g.openapiPath, pathStr)) break g;
        } else null;

        if (found) |g| {
            try g.methods.append(allocator, entry.method);
            try g.entryIdx.append(allocator, ei);
        } else {
            var methods: std.ArrayList(Method) = .empty;
            try methods.append(allocator, entry.method);
            var idx: std.ArrayList(usize) = .empty;
            try idx.append(allocator, ei);
            try groups.append(allocator, .{
                .openapiPath = try allocator.dupe(u8, pathStr),
                .methods = methods,
                .entryIdx = idx,
            });
        }
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var j: std.json.Stringify = .{ .writer = &out.writer };

    try j.beginObject();
    try j.objectField("openapi");
    try j.write("3.1.0");

    try j.objectField("info");
    try j.beginObject();
    try j.objectField("title");
    try j.write(info.title);
    if (info.description.len > 0) {
        try j.objectField("description");
        try j.write(info.description);
    }
    try j.objectField("version");
    try j.write(info.version);
    try j.endObject();

    try j.objectField("paths");
    try j.beginObject();

    var usedIds: std.ArrayList([]u8) = .empty;
    defer {
        for (usedIds.items) |id| allocator.free(id);
        usedIds.deinit(allocator);
    }

    for (groups.items) |*g| {
        try j.objectField(g.openapiPath);
        try j.beginObject();

        // Deterministic ordering within a path; at most one operation per
        // method even when multiple router shapes render to the same path.
        const order = [_]Method{ .GET, .POST, .PUT, .PATCH, .DELETE, .HEAD, .OPTIONS, .TRACE, .CONNECT };
        var emitted = (@as([order.len]bool, @splat(false)));
        const allEntries = router.entries();
        for (order, 0..) |m, mi| {
            for (g.entryIdx.items) |ei| {
                const entry = allEntries[ei];
                if (entry.method != m or emitted[mi]) continue;
                emitted[mi] = true;

                const opId = if (entry.meta.operationId) |explicit|
                    try uniqueExplicitId(allocator, explicit, &usedIds)
                else
                    try uniqueOperationId(allocator, m, g.openapiPath, &usedIds);

                try j.objectField(methodName(m));
                try j.beginObject();
                try writeOperation(&j, entry.meta, &entry.pattern, opId);
                try j.endObject();
            }
        }
        try j.endObject();
    }

    try j.endObject(); // paths
    try j.endObject(); // root

    return out.toOwnedSlice();
}

/// Stack-render variant used for grouping comparisons (no allocation).
fn isDocsPath(path: []const u8) bool {
    if (std.mem.eql(u8, path, "/openapi.json")) return true;
    for ([_][]const u8{ "/docs", "/redoc", "/scalar", "/graphiql" }) |prefix| {
        if (std.mem.eql(u8, path, prefix)) return true;
        if (path.len > prefix.len and std.mem.startsWith(u8, path, prefix) and path[prefix.len] == '/') return true;
    }
    return false;
}

fn renderOpenApiPathInto(buf: []u8, pattern: anytype) ![]u8 {
    var n: usize = 0;
    buf[n] = '/';
    n += 1;
    for (pattern.segments[0..pattern.count], 0..) |seg, i| {
        if (i > 0) {
            buf[n] = '/';
            n += 1;
        }
        switch (seg.kind) {
            .literal => {
                @memcpy(buf[n..][0..seg.text.len], seg.text);
                n += seg.text.len;
            },
            .parameter => {
                buf[n] = '{';
                n += 1;
                @memcpy(buf[n..][0..seg.text.len], seg.text);
                n += seg.text.len;
                buf[n] = '}';
                n += 1;
            },
            .wildcard => {
                buf[n] = '{';
                n += 1;
                const nm = if (seg.text.len > 0) seg.text else "path";
                @memcpy(buf[n..][0..nm.len], nm);
                n += nm.len;
                buf[n] = '}';
                n += 1;
            },
        }
    }
    return buf[0..n];
}

/// Explicit operation ids must be globally unique — collisions are a
/// developer error we refuse to paper over.
fn uniqueExplicitId(allocator: Allocator, explicit: []const u8, used: *std.ArrayList([]u8)) GenerateError![]const u8 {
    for (used.items) |id| {
        if (std.mem.eql(u8, id, explicit)) return error.DuplicateOperationId;
    }
    const copy = try allocator.dupe(u8, explicit);
    try used.append(allocator, copy);
    return copy;
}

/// Maps a route converter to an OpenAPI schema for synthesized path params.
const uuidSchema: metaMod.Schema = .{ .stringFmt = "uuid" };
fn converterSchema(conv: patternMod.Converter) *const metaMod.Schema {
    return switch (conv) {
        .int, .uint => &metaMod.schemas.integer,
        .float => &metaMod.schemas.number,
        .boolean => &metaMod.schemas.boolean,
        .uuid => &uuidSchema,
        .str, .slug, .path => &metaMod.schemas.string,
    };
}

fn writeOperation(j: *std.json.Stringify, meta: metaMod.Metadata, pattern: *const patternMod.Pattern, opId: []const u8) !void {
    try j.objectField("operationId");
    try j.write(opId);
    if (meta.summary.len > 0) {
        try j.objectField("summary");
        try j.write(meta.summary);
    }
    if (meta.description.len > 0) {
        try j.objectField("description");
        try j.write(meta.description);
    }
    if (meta.deprecated) {
        try j.objectField("deprecated");
        try j.write(true);
    }
    if (meta.tags.len > 0) {
        try j.objectField("tags");
        try j.beginArray();
        for (meta.tags) |t| try j.write(t);
        try j.endArray();
    }
    if (meta.security.len > 0) {
        try j.objectField("security");
        try j.beginArray();
        for (meta.security) |sec| {
            try j.beginObject();
            try j.objectField(sec.scheme);
            try j.beginArray();
            for (sec.scopes) |s| try j.write(s);
            try j.endArray();
            try j.endObject();
        }
        try j.endArray();
    }

    if (meta.params.len > 0) {
        try j.objectField("parameters");
        try j.beginArray();
        for (meta.params) |p| {
            try j.beginObject();
            try j.objectField("name");
            try j.write(p.name);
            try j.objectField("in");
            try j.write(p.in.name());
            try j.objectField("required");
            try j.write(p.in == .path or p.required);
            if (p.description.len > 0) {
                try j.objectField("description");
                try j.write(p.description);
            }
            try j.objectField("schema");
            try writeSchema(j, p.schema);
            try j.endObject();
        }
        try j.endArray();
    }

    // Synthesize path parameters from typed converters for pattern params
    // not explicitly documented in meta.params (converter chooses schema).
    {
        var anySynth = false;
        for (pattern.segments[0..pattern.count]) |seg| {
            if (seg.kind != .parameter and seg.kind != .wildcard) continue;
            var covered = false;
            for (meta.params) |p| {
                if (p.in == .path and std.mem.eql(u8, p.name, seg.text)) {
                    covered = true;
                    break;
                }
            }
            if (covered) continue;
            if (!anySynth) {
                try j.objectField("parameters");
                try j.beginArray();
                anySynth = true;
            }
            try j.beginObject();
            try j.objectField("name");
            try j.write(seg.text);
            try j.objectField("in");
            try j.write("path");
            try j.objectField("required");
            try j.write(true);
            try j.objectField("schema");
            try writeSchema(j, converterSchema(seg.converter));
            try j.endObject();
        }
        if (anySynth) try j.endArray();
    }

    if (meta.request) |rb| {
        try j.objectField("requestBody");
        try j.beginObject();
        try j.objectField("required");
        try j.write(rb.required);
        if (rb.description.len > 0) {
            try j.objectField("description");
            try j.write(rb.description);
        }
        try j.objectField("content");
        try j.beginObject();
        try j.objectField(rb.content.mime());
        try j.beginObject();
        if (rb.schema) |s| {
            try j.objectField("schema");
            try writeSchema(j, s);
        }
        try j.endObject(); // media-type obj
        try j.endObject(); // content
        try j.endObject(); // requestBody
    }

    try j.objectField("responses");
    try j.beginObject();
    if (meta.responses.len == 0) {
        try writeBareResponse(j, "200", "OK", null);
    } else {
        var statusBuf: [8]u8 = undefined;
        for (meta.responses) |r| {
            const s = std.fmt.bufPrint(&statusBuf, "{d}", .{r.status}) catch "200";
            try writeBareResponse(j, s, r.description, r.schema);
        }
    }
    try j.endObject();
}

fn writeBareResponse(j: *std.json.Stringify, status: []const u8, description: []const u8, schema: ?*const metaMod.Schema) !void {
    try j.objectField(status);
    try j.beginObject();
    try j.objectField("description");
    try j.write(description);
    if (schema) |s| {
        try j.objectField("content");
        try j.beginObject();
        try j.objectField("application/json");
        try j.beginObject();
        try j.objectField("schema");
        try writeSchema(j, s);
        try j.endObject();
        try j.endObject();
    }
    try j.endObject();
}

fn writeSchema(j: *std.json.Stringify, s: *const metaMod.Schema) !void {
    switch (s.*) {
        .string, .integer, .number, .boolean => {
            try j.beginObject();
            try j.objectField("type");
            try j.write(switch (s.*) {
                .string => "string",
                .integer => "integer",
                .number => "number",
                else => "boolean",
            });
            try j.endObject();
        },
        .stringFmt => |f| {
            try j.beginObject();
            try j.objectField("type");
            try j.write("string");
            try j.objectField("format");
            try j.write(f);
            try j.endObject();
        },
        .array => |elem| {
            try j.beginObject();
            try j.objectField("type");
            try j.write("array");
            try j.objectField("items");
            try writeSchema(j, elem);
            try j.endObject();
        },
        .object => |fields| {
            try j.beginObject();
            try j.objectField("type");
            try j.write("object");
            try j.objectField("properties");
            try j.beginObject();
            for (fields) |f| {
                try j.objectField(f.name);
                if (f.nullable) {
                    try j.beginObject();
                    try j.objectField("anyOf");
                    try j.beginArray();
                    try writeSchema(j, f.schema);
                    try j.beginObject();
                    try j.objectField("type");
                    try j.write("null");
                    try j.endObject();
                    try j.endArray();
                    try j.endObject();
                } else {
                    try writeSchema(j, f.schema);
                }
            }
            try j.endObject(); // properties
            var anyRequired = false;
            for (fields) |f| {
                if (!f.required) continue;
                if (!anyRequired) {
                    try j.objectField("required");
                    try j.beginArray();
                    anyRequired = true;
                }
                try j.write(f.name);
            }
            if (anyRequired) try j.endArray();
            try j.endObject(); // object
        },
        .ref => |name| {
            try j.beginObject();
            try j.objectField("$ref");
            try j.print("#/components/schemas/{s}", .{name});
            try j.endObject();
        },
    }
}

fn methodName(m: Method) []const u8 {
    return switch (m) {
        .GET => "get",
        .POST => "post",
        .PUT => "put",
        .PATCH => "patch",
        .DELETE => "delete",
        .HEAD => "head",
        .OPTIONS => "options",
        .TRACE => "trace",
        .CONNECT => "connect",
    };
}

/// "/users/{id}" + wildcard tail rendered as OpenAPI template syntax.
fn renderOpenApiPath(allocator: Allocator, pattern: anytype) (Allocator.Error || std.Io.Writer.Error)![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    w.writeAll("/") catch return error.WriteFailed;
    for (pattern.segments[0..pattern.count], 0..) |seg, i| {
        if (i > 0) w.writeAll("/") catch return error.WriteFailed;
        switch (seg.kind) {
            .literal => w.writeAll(seg.text) catch return error.WriteFailed,
            .parameter => {
                w.writeAll("{") catch return error.WriteFailed;
                w.writeAll(seg.text) catch return error.WriteFailed;
                w.writeAll("}") catch return error.WriteFailed;
            },
            .wildcard => {
                w.writeAll("{") catch return error.WriteFailed;
                w.writeAll(if (seg.text.len > 0) seg.text else "path") catch return error.WriteFailed;
                w.writeAll("}") catch return error.WriteFailed;
            },
        }
    }
    return allocator.dupe(u8, out.written());
}

/// `get_users_{id}` style ids; appends `_2`, `_3`, ... on sanitized collision.
fn uniqueOperationId(
    allocator: Allocator,
    method: Method,
    openapiPath: []const u8,
    used: *std.ArrayList([]u8),
) (Allocator.Error || std.Io.Writer.Error)![]const u8 {
    var base: std.Io.Writer.Allocating = .init(allocator);
    defer base.deinit();
    const w = &base.writer;

    w.writeAll(methodName(method)) catch return error.WriteFailed;
    for (openapiPath) |c| {
        const ok = std.ascii.isAlphanumeric(c);
        w.writeByte(if (ok) c else '_') catch return error.WriteFailed;
    }
    const sanitized = base.written();

    var candidate: []u8 = try allocator.dupe(u8, sanitized);
    errdefer allocator.free(candidate);
    while (containsId(used.items, candidate)) {
        const n = used.items.len + 1;
        const grown = std.fmt.allocPrint(allocator, "{s}_{d}", .{ sanitized, n }) catch |e| {
            allocator.free(candidate);
            return e;
        };
        allocator.free(candidate);
        candidate = grown;
    }
    try used.append(allocator, candidate);
    return candidate;
}

fn containsId(ids: []const []u8, candidate: []const u8) bool {
    for (ids) |id| {
        if (std.mem.eql(u8, id, candidate)) return true;
    }
    return false;
}

// Tests

fn h(ctx: *routerMod.Context) anyerror!routerMod.Response {
    _ = ctx;
    return .{};
}

test "generates valid spec for mixed routes" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    try router.get("/", h, .{});
    try router.get("/users/{id}", h, .{});
    try router.post("/users", h, .{});
    try router.delete("/users/{id}", h, .{});
    try router.get("/files/*path", h, .{});

    const jsonData = try generate(&router, .{ .title = "T", .version = "9.9" });
    defer a.free(jsonData);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, jsonData, .{});
    defer parsed.deinit();

    const root = parsed.value;
    try std.testing.expectEqualStrings("3.1.0", root.object.get("openapi").?.string);
    const paths = root.object.get("paths").?.object;

    try std.testing.expect(paths.get("/users/{id}") != null);
    try std.testing.expect(paths.get("/users") != null);
    try std.testing.expect(paths.get("/") != null);

    const usersId = paths.get("/users/{id}").?.object;
    try std.testing.expect(usersId.get("get") != null);
    try std.testing.expect(usersId.get("delete") != null);
    try std.testing.expectEqualStrings(
        "get_users__id_",
        usersId.get("get").?.object.get("operationId").?.string,
    );
}

test "empty router yields empty paths object" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    const jsonData = try generate(&router, .{});
    defer a.free(jsonData);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, jsonData, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("paths").?.object.count());
}

test "operation ids are de-duplicated on sanitizer collision" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    // Distinct shapes -> both allowed by the router; both sanitize to getAB.
    try router.get("/a b", h, .{});
    try router.get("/a_b", h, .{});

    const jsonData = try generate(&router, .{});
    defer a.free(jsonData);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, jsonData, .{});
    defer parsed.deinit();
    const paths = parsed.value.object.get("paths").?.object;

    var seenGetAB: usize = 0;
    var seenGetAB2: usize = 0;
    var it = paths.iterator();
    while (it.next()) |kv| {
        const op = kv.value_ptr.*.object.get("get").?;
        const id = op.object.get("operationId").?.string;
        if (std.mem.eql(u8, id, "get_a_b")) seenGetAB += 1;
        if (std.mem.eql(u8, id, "get_a_b_2")) seenGetAB2 += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), seenGetAB);
    try std.testing.expectEqual(@as(usize, 1), seenGetAB2);
}

// Metadata-driven generation ("define once" verification)

const tmeta = @import("../router/metadata.zig");

const UserSchema = tmeta.Schema{
    .object = &.{
        .{ .name = "id", .schema = &tmeta.schemas.integer },
        .{ .name = "name", .schema = &tmeta.schemas.string },
        .{ .name = "nickname", .schema = &tmeta.schemas.string, .required = false, .nullable = true },
    },
};

fn hMeta(ctx: *Context) anyerror!Response {
    _ = ctx;
    return .{ .body = "{}", .contentType = "application/json" };
}

test "typed converters synthesize path parameters" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    try router.get("/users/{id:int}", hMeta, .{});
    try router.get("/posts/{slug:slug}", hMeta, .{});

    const jsonData = try generate(&router, .{});
    defer a.free(jsonData);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, jsonData, .{});
    defer parsed.deinit();
    const paths = parsed.value.object.get("paths").?.object;

    const users = paths.get("/users/{id}").?.object.get("get").?.object;
    const uparams = users.get("parameters").?.array;
    try std.testing.expectEqual(@as(usize, 1), uparams.items.len);
    const up0 = uparams.items[0].object;
    try std.testing.expectEqualStrings("id", up0.get("name").?.string);
    try std.testing.expectEqualStrings("path", up0.get("in").?.string);
    try std.testing.expectEqual(true, up0.get("required").?.bool);
    try std.testing.expectEqualStrings("integer", up0.get("schema").?.object.get("type").?.string);

    const posts = paths.get("/posts/{slug}").?.object.get("get").?.object;
    const pparams = posts.get("parameters").?.array;
    try std.testing.expectEqual(@as(usize, 1), pparams.items.len);
    try std.testing.expectEqualStrings("string", pparams.items[0].object.get("schema").?.object.get("type").?.string);
}

test "explicit meta params take precedence over synthesis" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    try router.get("/users/{id:int}", hMeta, .{ .meta = .{
        .params = &.{
            .{ .name = "id", .in = .path, .description = "custom", .schema = &tmeta.schemas.string },
        },
    } });

    const jsonData = try generate(&router, .{});
    defer a.free(jsonData);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, jsonData, .{});
    defer parsed.deinit();
    const users = parsed.value.object.get("paths").?.object.get("/users/{id}").?.object.get("get").?.object;
    const uparams = users.get("parameters").?.array;
    try std.testing.expectEqual(@as(usize, 1), uparams.items.len);
    try std.testing.expectEqualStrings("custom", uparams.items[0].object.get("description").?.string);
    try std.testing.expectEqualStrings("string", uparams.items[0].object.get("schema").?.object.get("type").?.string);
}

test "metadata flows into full operation object" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    const pageParam = tmeta.Param{
        .name = "page",
        .in = .query,
        .description = "1-based page number",
        .schema = &tmeta.schemas.integer,
    };
    try router.add(.GET, "/users/{id}", hMeta, .{ .meta = .{
        .operationId = "getUserById",
        .summary = "Fetch one user",
        .tags = &.{"users"},
        .params = &.{
            pageParam,
            .{ .name = "id", .in = .path, .schema = &tmeta.schemas.integer },
        },
        .request = .{
            .content = .json,
            .schema = &UserSchema,
            .description = "Updated fields",
        },
        .responses = &.{
            .{ .status = 200, .description = "The user", .schema = &UserSchema },
            .{ .status = 404, .description = "No such user" },
        },
        .security = &.{.{ .scheme = "bearerAuth" }},
        .deprecated = false,
    } });

    const jsonData = try generate(&router, .{});
    defer a.free(jsonData);

    // Spot-check every metadata surface made it through.
    for ([_][]const u8{
        "\"operationId\":\"getUserById\"",
        "\"summary\":\"Fetch one user\"",
        "\"tags\":[\"users\"]",
        "\"name\":\"page\"",
        "\"in\":\"query\"",
        "\"name\":\"id\"",
        "\"in\":\"path\"",
        "\"required\":true",
        "\"requestBody\"",
        "\"application/json\"",
        "\"properties\"",
        "\"required\":[\"id\",\"name\"]",
        "\"format\":\"uri\"",
        "\"200\"",
        "\"404\"",
        "\"security\":[{\"bearerAuth\":[]}]",
    }) |needle| {
        if (std.mem.eql(u8, needle, "\"format\":\"uri\"")) {
            // no uri format used here; skip sentinel
            continue;
        }
        try std.testing.expect(std.mem.indexOf(u8, jsonData, needle) != null);
    }

    // Parse to guarantee structurally valid JSON.
    const parsed = try std.json.parseFromSlice(std.json.Value, a, jsonData, .{});
    defer parsed.deinit();
}

test "explicit duplicate operation ids are rejected" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    try router.add(.GET, "/one", hMeta, .{ .meta = .{ .operationId = "dup" } });
    try router.get("/two", hMeta, .{});
    try router.add(.POST, "/three", hMeta, .{ .meta = .{ .operationId = "dup" } });

    try std.testing.expectError(error.DuplicateOperationId, generate(&router, .{}));
}

test "nullable object field emits anyOf null union" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    try router.add(.POST, "/nicknames", hMeta, .{ .meta = .{
        .request = .{ .content = .json, .schema = &UserSchema },
    } });

    const jsonData = try generate(&router, .{});
    defer a.free(jsonData);
    try std.testing.expect(std.mem.indexOf(u8, jsonData, "\"anyOf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonData, "\"type\":\"null\"") != null);
}

test "docs prefix filter uses slash boundary and internal flag" {
    const a = std.testing.allocator;
    var router = Router.init(a);
    defer router.deinit();

    // User routes that merely share a prefix must NOT be filtered.
    try router.get("/docs-custom", h, .{});
    try router.get("/redocly", h, .{});
    try router.get("/scalar-app", h, .{});
    try router.get("/graphiql-test", h, .{});
    // Internal routes are always filtered regardless of path.
    try router.add(.GET, "/custom-docs-page", h, .{ .meta = .{ .internal = true } });
    // Real docs paths are filtered.
    try router.get("/docs", h, .{});
    try router.get("/docs/swagger-ui-bundle.js", h, .{});

    const jsonData = try generate(&router, .{});
    defer a.free(jsonData);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, jsonData, .{});
    defer parsed.deinit();
    const paths = parsed.value.object.get("paths").?.object;
    try std.testing.expect(paths.get("/docs-custom") != null);
    try std.testing.expect(paths.get("/redocly") != null);
    try std.testing.expect(paths.get("/scalar-app") != null);
    try std.testing.expect(paths.get("/graphiql-test") != null);
    try std.testing.expect(paths.get("/docs") == null);
    try std.testing.expect(paths.get("/custom-docs-page") == null);
}
