//! Server-side multipart form handling and safe file persistence.
//!
//! The transport currently buffers request bodies, so this helper parses the
//! complete `ctx.body` while enforcing parser limits. Files are saved under a
//! generated name; the client-supplied filename is only used as a suffix.

const std = @import("std");
const Allocator = std.mem.Allocator;
const parser = @import("multipartParser.zig");
const common = @import("multipartCommon.zig");

pub const Options = struct {
    limits: parser.Limits = .{},
    max_fields: usize = 1024,
    max_files: usize = 64,
};

pub const Error = parser.ParseError || error{
    MissingContentType,
    TooManyFields,
    TooManyFiles,
    MissingFilename,
    FileTooLarge,
    PathTooLong,
};

pub const Form = struct {
    allocator: Allocator,
    fields: []parser.Field,

    pub fn deinit(self: *Form) void {
        parser.freeFieldsAlloc(self.allocator, self.fields);
        self.fields = &.{};
    }

    pub fn value(self: *const Form, name: []const u8) ?[]const u8 {
        for (self.fields) |*part| {
            if (part.filename == null and part.filenameStar == null and
                std.mem.eql(u8, part.name, name))
                return part.data;
        }
        return null;
    }

    pub fn values(self: *const Form, name: []const u8) ValueIterator {
        return .{ .fields = self.fields, .name = name };
    }

    pub fn field(self: *const Form, name: []const u8) ?*const parser.Field {
        for (self.fields) |*part| {
            if (std.mem.eql(u8, part.name, name)) return part;
        }
        return null;
    }

    pub fn file(self: *const Form, name: []const u8) ?*const parser.Field {
        for (self.fields) |*part| {
            if (part.name.len == name.len and std.mem.eql(u8, part.name, name) and
                (part.filename != null or part.filenameStar != null))
                return part;
        }
        return null;
    }

    pub fn fileCount(self: *const Form) usize {
        var count: usize = 0;
        for (self.fields) |part| {
            if (part.filename != null or part.filenameStar != null) count += 1;
        }
        return count;
    }

    pub const ValueIterator = struct {
        fields: []const parser.Field,
        name: []const u8,
        index: usize = 0,

        pub fn next(self: *ValueIterator) ?[]const u8 {
            while (self.index < self.fields.len) {
                const part = &self.fields[self.index];
                self.index += 1;
                if (part.filename == null and part.filenameStar == null and
                    std.mem.eql(u8, part.name, self.name))
                    return part.data;
            }
            return null;
        }
    };
};

/// Parses a form-data body. The subtype is detected from `contentType`;
/// `multipart/form-data` requires Content-Disposition names.
pub fn parse(allocator: Allocator, body: []const u8, contentType: []const u8, options: Options) Error!Form {
    const fields = try parser.parseBody(allocator, body, contentType, options.limits);
    errdefer parser.freeFieldsAlloc(allocator, fields);

    var field_count: usize = 0;
    var file_count: usize = 0;
    for (fields) |field| {
        if (field.filename != null or field.filenameStar != null) {
            file_count += 1;
        } else {
            field_count += 1;
        }
    }
    if (options.max_fields > 0 and field_count > options.max_fields) return Error.TooManyFields;
    if (options.max_files > 0 and file_count > options.max_files) return Error.TooManyFiles;

    return .{ .allocator = allocator, .fields = fields };
}

pub const SaveOptions = struct {
    /// Destination directory. Created when `create_dir` is true.
    directory: []const u8 = "uploads",
    /// Prefix for the generated on-disk filename.
    prefix: []const u8 = "upload-",
    /// Refuse files larger than this (0 = parser limit only).
    max_size: usize = 0,
    create_dir: bool = true,
};

pub const SavedFile = struct {
    /// Absolute or directory-relative path of the saved file.
    path: []u8,
    /// Generated basename.
    filename: []u8,
    size: usize,

    pub fn deinit(self: *SavedFile, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.free(self.filename);
        self.* = undefined;
    }
};

var save_counter = std.atomic.Value(usize).init(0);

/// Saves a file part using a generated basename. The caller keeps ownership of
/// `field`; `SavedFile.deinit` releases the result.
pub fn saveFile(
    allocator: Allocator,
    io: std.Io,
    field: *const parser.Field,
    options: SaveOptions,
) !SavedFile {
    const suggested = parser.effectiveFilename(field) orelse return Error.MissingFilename;
    if (options.max_size > 0 and field.data.len > options.max_size) return Error.FileTooLarge;

    const safe = try common.safeFilename(allocator, suggested);
    defer allocator.free(safe);

    const count = save_counter.fetchAdd(1, .monotonic);
    const base = try std.fmt.allocPrint(allocator, "{s}{d}-{s}", .{ options.prefix, count, safe });
    defer allocator.free(base);

    if (options.create_dir and !std.fs.path.isAbsolute(options.directory)) {
        std.Io.Dir.cwd().createDirPath(io, options.directory) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    var dir = if (std.fs.path.isAbsolute(options.directory))
        try std.Io.Dir.openDirAbsolute(io, options.directory, .{})
    else
        try std.Io.Dir.cwd().openDir(io, options.directory, .{});
    defer dir.close(io);

    const file = try dir.createFile(io, base, .{ .exclusive = true, .truncate = false });
    file.writeStreamingAll(io, field.data) catch |err| {
        file.close(io);
        dir.deleteFile(io, base) catch {};
        return err;
    };
    file.sync(io) catch |err| {
        file.close(io);
        dir.deleteFile(io, base) catch {};
        return err;
    };
    file.close(io);

    const path = try std.fs.path.join(allocator, &.{ options.directory, base });
    errdefer allocator.free(path);
    const filename = try allocator.dupe(u8, base);
    return .{ .path = path, .filename = filename, .size = field.data.len };
}

/// Streams an incoming multipart body directly to disk sinks using StreamParser,
/// writing chunk by chunk without loading the complete upload into memory.
pub fn streamSaveFiles(
    allocator: Allocator,
    io: std.Io,
    contentType: []const u8,
    reader: anytype,
    options: SaveOptions,
) ![]SavedFile {
    const boundary = parser.extractBoundary(contentType) orelse return Error.MissingContentType;
    var sp = try parser.StreamParser.init(allocator, boundary, .{});
    defer sp.deinit();

    if (options.create_dir and !std.fs.path.isAbsolute(options.directory)) {
        std.Io.Dir.cwd().createDirPath(io, options.directory) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    var dir = if (std.fs.path.isAbsolute(options.directory))
        try std.Io.Dir.openDirAbsolute(io, options.directory, .{})
    else
        try std.Io.Dir.cwd().openDir(io, options.directory, .{});
    defer dir.close(io);

    var saved = std.ArrayList(SavedFile).empty;
    errdefer {
        for (saved.items) |*f| f.deinit(allocator);
        saved.deinit(allocator);
    }

    var currentFile: ?std.Io.File = null;
    var currentBase: ?[]u8 = null;
    var currentSize: usize = 0;

    defer {
        if (currentFile) |cf| {
            cf.close(io);
            if (currentBase) |b| dir.deleteFile(io, b) catch {};
        }
        if (currentBase) |b| allocator.free(b);
    }

    var buf: [4096]u8 = undefined;
    var eof = false;

    while (true) {
        if (!eof) {
            const n = try reader.read(&buf);
            if (n == 0) {
                eof = true;
                try sp.finish();
            } else {
                try sp.feed(buf[0..n]);
            }
        }

        while (try sp.next()) |ev| {
            switch (ev) {
                .partBegin => |pb| {
                    const suggested: ?[]const u8 = if (pb.filename) |f|
                        f
                    else if (pb.filenameStar) |fs|
                        fs.value
                    else
                        null;
                    if (suggested) |origName| {
                        const safe = try common.safeFilename(allocator, origName);
                        defer allocator.free(safe);

                        const count = save_counter.fetchAdd(1, .monotonic);
                        const base = try std.fmt.allocPrint(allocator, "{s}{d}-{s}", .{ options.prefix, count, safe });

                        const f = try dir.createFile(io, base, .{ .exclusive = true, .truncate = false });
                        currentFile = f;
                        currentBase = base;
                        currentSize = 0;
                    }
                },
                .partData => |chunk| {
                    defer allocator.free(chunk);
                    if (currentFile) |cf| {
                        currentSize += chunk.len;
                        if (options.max_size > 0 and currentSize > options.max_size) {
                            return Error.FileTooLarge;
                        }
                        try cf.writeStreamingAll(io, chunk);
                    }
                },
                .partEnd => {
                    if (currentFile) |cf| {
                        cf.sync(io) catch {};
                        cf.close(io);
                        currentFile = null;

                        const base = currentBase.?;
                        const fullPath = try std.fs.path.join(allocator, &.{ options.directory, base });
                        try saved.append(allocator, .{
                            .path = fullPath,
                            .filename = base,
                            .size = currentSize,
                        });
                        currentBase = null;
                        currentSize = 0;
                    }
                },
                .done => break,
            }
        }

        if (eof and sp.state == .closed) break;
    }

    return saved.toOwnedSlice(allocator);
}

test "server form exposes fields and files" {
    const body =
        "--server-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"title\"\r\n\r\n" ++
        "hello\r\n" ++
        "--server-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"upload\"; filename=\"a.txt\"\r\n" ++
        "Content-Type: text/plain\r\n\r\n" ++
        "file-data\r\n" ++
        "--server-boundary--\r\n";
    const ct = "multipart/form-data; boundary=\"server-boundary\"";

    var form = try parse(std.testing.allocator, body, ct, .{});
    defer form.deinit();

    try std.testing.expectEqualStrings("hello", form.value("title").?);
    try std.testing.expect(form.file("upload") != null);
    try std.testing.expectEqual(@as(usize, 1), form.fileCount());
}

test "server form enforces field limits" {
    const body =
        "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n" ++
        "--B\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\n2\r\n" ++
        "--B--\r\n";
    try std.testing.expectError(Error.TooManyFields, parse(
        std.testing.allocator,
        body,
        "multipart/form-data; boundary=B",
        .{ .max_fields = 1 },
    ));
}

test "server form enforces file limits" {
    const body =
        "--B\r\nContent-Disposition: form-data; name=\"f1\"; filename=\"a.txt\"\r\n\r\na\r\n" ++
        "--B\r\nContent-Disposition: form-data; name=\"f2\"; filename=\"b.txt\"\r\n\r\nb\r\n" ++
        "--B--\r\n";
    try std.testing.expectError(Error.TooManyFiles, parse(
        std.testing.allocator,
        body,
        "multipart/form-data; boundary=B",
        .{ .max_files = 1 },
    ));
}

test "saveFile uses a generated safe basename" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir_path);

    const fields = try parser.parseMultipart(
        a,
        "--B\r\nContent-Disposition: form-data; name=\"f\"; filename=\"../../secret.txt\"\r\n\r\npayload\r\n--B--\r\n",
        "B",
        .{},
    );
    defer parser.freeFieldsAlloc(a, fields);

    var saved = try saveFile(a, io, &fields[0], .{
        .directory = dir_path,
        .create_dir = false,
        .prefix = "test-",
    });
    defer saved.deinit(a);

    try std.testing.expect(std.mem.indexOf(u8, saved.filename, "secret.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved.filename, "..") == null);
    try std.testing.expect(std.mem.startsWith(u8, saved.path, dir_path));

    const content = try tmp.dir.readFileAlloc(io, saved.filename, a, .unlimited);
    defer a.free(content);
    try std.testing.expectEqualStrings("payload", content);
}

test "streamSaveFiles streams directly to disk sink without buffering complete body" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir_path);

    const body =
        "--stream-b\r\n" ++
        "Content-Disposition: form-data; name=\"file1\"; filename=\"streamed.bin\"\r\n" ++
        "Content-Type: application/octet-stream\r\n\r\n" ++
        "chunk1chunk2chunk3\r\n" ++
        "--stream-b--\r\n";
    const ct = "multipart/form-data; boundary=stream-b";

    const TestReader = struct {
        data: []const u8,
        pos: usize = 0,
        pub fn read(self: *@This(), out: []u8) !usize {
            if (self.pos >= self.data.len) return 0;
            const n = @min(out.len, self.data.len - self.pos);
            @memcpy(out[0..n], self.data[self.pos .. self.pos + n]);
            self.pos += n;
            return n;
        }
    };

    var r = TestReader{ .data = body };
    const savedList = try streamSaveFiles(a, io, ct, &r, .{
        .directory = dir_path,
        .create_dir = false,
        .prefix = "stream-",
    });
    defer {
        for (savedList) |*f| f.deinit(a);
        a.free(savedList);
    }

    try std.testing.expectEqual(@as(usize, 1), savedList.len);
    try std.testing.expectEqual(@as(usize, 18), savedList[0].size);

    const diskContent = try tmp.dir.readFileAlloc(io, savedList[0].filename, a, .unlimited);
    defer a.free(diskContent);
    try std.testing.expectEqualStrings("chunk1chunk2chunk3", diskContent);
}
