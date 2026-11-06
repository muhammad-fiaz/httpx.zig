//! Partial-to-full config coercion.
//!
//! Every configurable type in httpx has a full struct with declared defaults.
//! Callers routinely pass a partial anonymous struct literal instead
//! (`.{ .port = 0 }`). `to` completes that literal into the exact config type:
//!
//! * fields the caller states are copied (recursively, so nested `.{}` configs
//!   work too),
//! * fields the caller omits are filled from the type's declared defaults,
//! * a required field (no default) that the caller omits is a compile error,
//! * an unknown field is a compile error, so typos never pass silently,
//! * optional targets accept `null`, a payload literal, or an optional value.
//!
//! ```zig
//! const cfg = configCoerce.to(httpx.Server.Config, .{ .port = 0 });
//! ```
//!
//! `init`/`mount` entry points use this so a partial literal is always expanded
//! to the full config before any field is read.

const std = @import("std");

/// Recursively converts `value` into `T`, filling omitted fields with the
/// defaults declared by `T`.
pub fn to(comptime T: type, value: anytype) T {
    const V = @TypeOf(value);
    if (V == T) return value;

    if (@typeInfo(T) == .optional) {
        const Child = @typeInfo(T).optional.child;
        if (@typeInfo(V) == .null) return null;
        if (@typeInfo(V) == .optional) {
            const inner = value orelse return null;
            return to(Child, inner);
        }
        return to(Child, value);
    }

    if (@typeInfo(T) == .@"struct" and @typeInfo(V) == .@"struct") {
        const dst = @typeInfo(T).@"struct";
        const src = @typeInfo(V).@"struct";
        if (src.is_tuple and src.field_names.len != 0) {
            @compileError("config value must be a named-field struct literal");
        }
        // Unknown fields are rejected before building the result.
        inline for (src.field_names) |fname| {
            if (comptime !@hasField(T, fname)) {
                @compileError("unknown config option `." ++ fname ++ "` for " ++ @typeName(T));
            }
        }
        var out: T = undefined;
        inline for (dst.field_names, dst.field_attrs) |fname, attr| {
            if (@hasField(V, fname)) {
                @field(out, fname) = to(@FieldType(T, fname), @field(value, fname));
            } else {
                if (comptime attr.default_value_ptr == null) {
                    @compileError("missing required config field `." ++ fname ++ "` for " ++ @typeName(T));
                }
                @field(out, fname) = defaultValue(T, fname);
            }
        }
        return out;
    }

    return @as(T, value);
}

/// Reads the declared default for one field of `T`.
fn defaultValue(comptime T: type, comptime fname: []const u8) @FieldType(T, fname) {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_attrs) |name, attr| {
        if (comptime std.mem.eql(u8, name, fname)) {
            if (attr.default_value_ptr) |ptr| {
                const Field = @FieldType(T, fname);
                return @as(*const Field, @ptrCast(@alignCast(ptr))).*;
            }
        }
    }
    @compileError("missing required config field `." ++ fname ++ "` for " ++ @typeName(T));
}
