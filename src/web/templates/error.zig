//! Template subsystem error definitions and source diagnostics.

const std = @import("std");

pub const TemplateErrorKind = enum {
    syntax_error,
    unexpected_token,
    unclosed_block,
    unclosed_expression,
    unknown_variable,
    type_mismatch,
    template_not_found,
    path_traversal,
    circular_inheritance,
    circular_include,
    depth_limit_exceeded,
    size_limit_exceeded,
    io_error,
    render_error,
};

pub const TemplateError = error{
    SyntaxError,
    UnexpectedToken,
    UnclosedBlock,
    UnclosedExpression,
    UnknownVariable,
    TypeMismatch,
    TemplateNotFound,
    PathTraversal,
    CircularInheritance,
    CircularInclude,
    DepthLimitExceeded,
    SizeLimitExceeded,
    IoError,
    RenderError,
    OutOfMemory,
};

/// Developer-friendly source diagnostic capturing precise location of template errors.
pub const SourceError = struct {
    kind: TemplateErrorKind,
    templateName: []const u8 = "",
    line: usize = 1,
    column: usize = 1,
    byteOffset: usize = 0,
    message: []const u8 = "",

    pub fn formatToString(self: SourceError, buf: []u8) ![]const u8 {
        if (self.templateName.len > 0) {
            return try std.fmt.bufPrint(buf, "{s}:{d}:{d}: {s}: {s}", .{
                self.templateName,
                self.line,
                self.column,
                @tagName(self.kind),
                self.message,
            });
        } else {
            return try std.fmt.bufPrint(buf, "{d}:{d}: {s}: {s}", .{
                self.line,
                self.column,
                @tagName(self.kind),
                self.message,
            });
        }
    }
};

/// Computes 1-based (line, column) for a given byte offset in template source.
pub fn lineColFromOffset(source: []const u8, offset: usize) struct { line: usize, col: usize } {
    var line: usize = 1;
    var col: usize = 1;
    const limit = @min(offset, source.len);
    for (source[0..limit]) |b| {
        if (b == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}

test "SourceError format and lineColFromOffset" {
    const src = "line 1\nline 2\nline 3";
    const loc = lineColFromOffset(src, 9); // 'i' in "line 2"
    try std.testing.expectEqual(@as(usize, 2), loc.line);
    try std.testing.expectEqual(@as(usize, 3), loc.col);

    const err = SourceError{
        .kind = .syntax_error,
        .templateName = "index.html",
        .line = loc.line,
        .column = loc.col,
        .byteOffset = 9,
        .message = "expected {% endif %}",
    };
    var buf: [128]u8 = undefined;
    const msg = try err.formatToString(&buf);
    try std.testing.expectEqualStrings("index.html:2:3: syntax_error: expected {% endif %}", msg);
}
