const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const boundary = "----httpxBoundary7MA4YWxkTrZu0gW";
    var builder = httpx.MultipartBuilder.init(allocator, boundary);
    defer builder.deinit();

    try builder.addField("username", "alice");
    try builder.addField("email", "alice@example.com");
    try builder.addField("message", "Hello from httpx.zig!");
    try builder.addFile(
        "avatar",
        "avatar.png",
        "image/png",
        &.{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A },
    );

    const body = try builder.build();
    defer allocator.free(body);

    const ct = try builder.contentType();
    defer allocator.free(ct);

    std.debug.print("Content-Type: {s}\n", .{ct});
    std.debug.print("Body size:    {d} bytes\n\n", .{body.len});

    const test_ct = "multipart/form-data; boundary=----httpxBoundary7MA4YWxkTrZu0gW";
    const extracted = httpx.extractMultipartBoundary(test_ct);
    std.debug.print("From: \"{s}\"\n", .{test_ct});
    std.debug.print("Got:  \"{s}\"\n", .{extracted orelse "(none)"});
    std.debug.print("Match: {}\n\n", .{std.mem.eql(u8, extracted orelse "", boundary)});

    var parsed = try httpx.parseMultipart(allocator, body, boundary);
    defer parsed.deinit();

    std.debug.print("Parts found: {d}\n\n", .{parsed.parts.len});
    for (parsed.parts, 0..) |part, i| {
        std.debug.print("  Part {d}:\n", .{i + 1});
        std.debug.print("    name:         \"{s}\"\n", .{part.name});
        if (part.filename) |f| std.debug.print("    filename:     \"{s}\"\n", .{f});
        std.debug.print("    content-type: {s}\n", .{part.content_type});
        const is_text = std.mem.startsWith(u8, part.content_type, "text/");
        if (is_text) {
            std.debug.print("    data:         \"{s}\"\n", .{part.data});
        } else {
            std.debug.print("    data:         <{d} bytes binary>\n", .{part.data.len});
        }
        std.debug.print("    headers:      {d}\n", .{part.headers.len});
    }

    var request = try httpx.Request.init(allocator, .POST, "http://httpbun.com/upload");
    defer request.deinit();

    var req_builder = httpx.MultipartBuilder.init(allocator, "reqBoundary123");
    defer req_builder.deinit();
    try req_builder.addField("title", "My Upload");
    try req_builder.addFile("file", "report.txt", "text/plain", "Report contents here");
    const req_body = try req_builder.build();
    defer allocator.free(req_body);
    const req_ct = try req_builder.contentType();
    defer allocator.free(req_ct);

    try request.headers.set("Content-Type", req_ct);
    request.body = req_body;

    std.debug.print("Request method:       {s}\n", .{request.method.toString()});
    std.debug.print("Request Content-Type: {s}\n", .{request.headers.get("Content-Type").?});
    std.debug.print("Request body size:    {d} bytes\n", .{request.body.?.len});

    const quoted_ct = "multipart/form-data; boundary=\"my boundary with spaces\"";
    const quoted_b = httpx.extractMultipartBoundary(quoted_ct);
    std.debug.print("Input:    \"{s}\"\n", .{quoted_ct});
    std.debug.print("Boundary: \"{s}\"\n", .{quoted_b orelse "(none)"});

    var client = httpx.Client.init(allocator);
    defer client.deinit();

    const fields = [_]httpx.MultipartField{
        .{ .name = "user", .value = "bob" },
    };
    const files = [_]httpx.MultipartFile{
        .{ .name = "attachment", .filename = "resume.html", .data = "resumedata" },
    };

    const reqOpts = httpx.RequestOptions.defaults()
        .withMultipartFields(&fields)
        .withMultipartFiles(&files)
        .withMultipartBoundary("clientBoundary999");

    var req = try httpx.Request.init(allocator, .POST, "http://localhost/upload");
    defer req.deinit();

    const boundary_opts = reqOpts.multipart_boundary orelse "----httpxBoundary1234567890";
    var cli_builder = httpx.MultipartBuilder.init(allocator, boundary_opts);
    defer cli_builder.deinit();

    if (reqOpts.multipart_fields) |flds| {
        for (flds) |field| {
            try cli_builder.addField(field.name, field.value);
        }
    }
    if (reqOpts.multipart_files) |fls| {
        for (fls) |file| {
            const resolved_mime = file.content_type orelse httpx.mimeTypeFromPathOr(file.filename, "application/octet-stream");
            try cli_builder.addFile(file.name, file.filename, resolved_mime, file.data);
        }
    }
    const cli_body = try cli_builder.build();
    defer allocator.free(cli_body);
    try req.setBody(cli_body);

    const cli_ct = try cli_builder.contentType();
    defer allocator.free(cli_ct);
    try req.headers.set("Content-Type", cli_ct);

    std.debug.print("Formatted Content-Type: {s}\n", .{req.headers.get("Content-Type").?});
    std.debug.print("Formatted Body contents:\n{s}", .{req.body.?});

    const large_data = try allocator.alloc(u8, 200 * 1024);
    defer allocator.free(large_data);
    @memset(large_data, 0xAB);

    var chunk_builder = httpx.MultipartBuilder.init(allocator, "chunkBound42");
    defer chunk_builder.deinit();

    try chunk_builder.addField("part_index", "1");

    try chunk_builder.addFileChunked(
        "payload",
        "large_file.bin",
        "application/octet-stream",
        large_data,
    );

    const chunk_body = try chunk_builder.build();
    defer allocator.free(chunk_body);

    std.debug.print("\nBuilt chunked multipart body: {d} bytes\n", .{chunk_body.len});
    std.debug.print("Max recommended chunk size:   {d} bytes ({d} KB)\n", .{
        httpx.MultipartMaxChunk,
        httpx.MultipartMaxChunk / 1024,
    });

    var file_offset: usize = 0;
    var chunk_idx: usize = 1;
    while (file_offset < large_data.len) {
        const end = @min(file_offset + httpx.MultipartMaxChunk, large_data.len);
        const slice = large_data[file_offset..end];

        var per_chunk_builder = httpx.MultipartBuilder.init(allocator, "perChunk");
        defer per_chunk_builder.deinit();

        const idx_str = try std.fmt.allocPrint(allocator, "{d}", .{chunk_idx});
        defer allocator.free(idx_str);
        try per_chunk_builder.addField("chunk_index", idx_str);
        try per_chunk_builder.addFile("data", "chunk.bin", "application/octet-stream", slice);

        const per_body = try per_chunk_builder.build();
        defer allocator.free(per_body);

        std.debug.print("  chunk {d}: offset={d} size={d}\n", .{ chunk_idx, file_offset, per_body.len });

        file_offset = end;
        chunk_idx += 1;
    }
}
