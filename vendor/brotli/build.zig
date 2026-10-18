const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const brotli_mod = b.addModule("brotli", .{
        .root_source_file = b.path("src/brotli.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });

    const lib = b.addLibrary(.{
        .name = "brotli",
        .root_module = brotli_mod,
    });
    b.installArtifact(lib);

    // `zig build test` runs library unit, integration, and interoperability tests.
    const test_step = b.step("test", "Run all tests");
    const tests = b.addTest(.{ .root_module = brotli_mod });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz/decode_fuzzer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "brotli", .module = brotli_mod },
        },
    });
    const fuzz_tests = b.addTest(.{ .root_module = fuzz_mod });
    const run_fuzz = b.addRunArtifact(fuzz_tests);
    const fuzz_step = b.step("fuzz", "Run the decoder robustness fuzzer");
    fuzz_step.dependOn(&run_fuzz.step);

    const docs_step = b.step("docs", "Generate documentation");
    const docs = b.addTest(.{ .root_module = brotli_mod });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&install_docs.step);

    const examples = [_]struct { name: []const u8, file: []const u8 }{
        .{ .name = "decompress_file", .file = "examples/decompress_file.zig" },
        .{ .name = "streaming_decompression", .file = "examples/streaming_decompression.zig" },
        .{ .name = "compress_file", .file = "examples/compress_file.zig" },
        .{ .name = "streaming_compression", .file = "examples/streaming_compression.zig" },
        .{ .name = "dictionary_compression", .file = "examples/dictionary_compression.zig" },
        .{ .name = "error_handling", .file = "examples/error_handling.zig" },
        .{ .name = "reusable_context", .file = "examples/reusable_context.zig" },
        .{ .name = "format_introspection", .file = "examples/format_introspection.zig" },
        .{ .name = "bit_level", .file = "examples/bit_level.zig" },
        .{ .name = "io_pipeline", .file = "examples/io_pipeline.zig" },
    };

    const run_all = b.step("run-all-examples", "Run all examples");

    inline for (examples) |example| {
        const run_step = b.step(
            "run-" ++ example.name,
            "Run " ++ example.name ++ " example",
        );

        const exe = b.addExecutable(.{
            .name = "example-" ++ example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.file),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "brotli", .module = brotli_mod },
                },
            }),
        });

        const run_exe = b.addRunArtifact(exe);
        run_step.dependOn(&run_exe.step);
        run_all.dependOn(&run_exe.step);
        run_exe.step.dependOn(&lib.step);
    }
}
