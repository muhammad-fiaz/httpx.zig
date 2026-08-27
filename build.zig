const std = @import("std");
const builtin = @import("builtin");

fn linkPlatformLibs(compile: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag == .windows) {
        // Winsock symbols are provided by these system libraries on Windows.
        compile.root_module.linkSystemLibrary("ws2_32", .{});
        compile.root_module.linkSystemLibrary("mswsock", .{});
        compile.root_module.linkSystemLibrary("c", .{});
    }
}

/// Build configuration for httpx.zig - Production-ready HTTP library for Zig
/// Supports HTTP/1.1, HTTP/2, HTTP/3 with TLS, connection pooling, and more.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const zstd_dep = b.dependency("zstd", .{
        .target = target,
        .optimize = optimize,
    });

    const brotli_dep = b.dependency("brotli", .{
        .target = target,
        .optimize = optimize,
    });

    const tint_dep = b.dependency("tint", .{
        .target = target,
        .optimize = optimize,
    });

    // Create the public module that will be exported as "httpx" to consumers.
    // Dependencies must be added here so they propagate to downstream packages.
    const httpx_module = b.addModule("httpx", .{
        .root_source_file = b.path("src/httpx.zig"),
    });

    httpx_module.addImport("zstd", zstd_dep.module("zstd"));
    httpx_module.addImport("brotli", brotli_dep.module("brotli"));
    httpx_module.addImport("tint", tint_dep.module("tint"));

    const examples = [_]struct { name: []const u8, path: []const u8, skip_run_all: bool = false }{};

    inline for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.path),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("httpx", httpx_module);
        linkPlatformLibs(exe, target);

        const install_exe = b.addInstallArtifact(exe, .{});
        const example_step = b.step("example-" ++ example.name, "Build " ++ example.name ++ " example");
        example_step.dependOn(&install_exe.step);

        const run_exe = b.addRunArtifact(exe);
        run_exe.step.dependOn(&install_exe.step);
        const run_step = b.step("run-" ++ example.name, "Run " ++ example.name ++ " example");
        run_step.dependOn(&run_exe.step);
    }

    const run_all_examples = b.step("run-all-examples", "Run all examples sequentially");
    var previous_run_step: ?*std.Build.Step = null;

    inline for (examples) |example| {
        if (example.skip_run_all) continue;
        const exe = b.addExecutable(.{
            .name = "run-all-" ++ example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.path),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("httpx", httpx_module);
        linkPlatformLibs(exe, target);

        const install_exe = b.addInstallArtifact(exe, .{});
        if (previous_run_step) |prev| {
            exe.step.dependOn(prev);
            install_exe.step.dependOn(prev);
        }
        const run_exe = b.addRunArtifact(exe);
        run_exe.step.dependOn(&install_exe.step);

        previous_run_step = &run_exe.step;
    }

    if (previous_run_step) |last| {
        run_all_examples.dependOn(last);
    }

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/httpx.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("zstd", zstd_dep.module("zstd"));
    tests.root_module.addImport("brotli", brotli_dep.module("brotli"));
    tests.root_module.addImport("tint", tint_dep.module("tint"));
    linkPlatformLibs(tests, target);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");

    // Only run tests when target matches host; otherwise build test artifact only.
    if (target.result.os.tag == builtin.os.tag and target.result.cpu.arch == builtin.cpu.arch) {
        test_step.dependOn(&run_tests.step);
    } else {
        const install_tests = b.addInstallArtifact(tests, .{});
        test_step.dependOn(&install_tests.step);
    }

    const bench_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    bench_exe.root_module.addImport("httpx", httpx_module);
    linkPlatformLibs(bench_exe, target);

    const install_bench = b.addInstallArtifact(bench_exe, .{});
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.step.dependOn(&install_bench.step);

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // Cross-compilation targets to verify support
    const cross_targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .linux },
        .{ .cpu_arch = .aarch64, .os_tag = .linux },
        .{ .cpu_arch = .x86, .os_tag = .linux },
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .cpu_arch = .aarch64, .os_tag = .windows },
        .{ .cpu_arch = .x86, .os_tag = .windows },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
    };

    const build_all_step = b.step("build-all-targets", "Build library for all supported targets");

    for (cross_targets) |t| {
        const target_cross = b.resolveTargetQuery(t);
        const root_module_cross = b.createModule(.{
            .root_source_file = b.path("src/httpx.zig"),
            .target = target_cross,
            .optimize = optimize,
        });
        root_module_cross.addImport("zstd", zstd_dep.module("zstd"));
        root_module_cross.addImport("brotli", brotli_dep.module("brotli"));
        root_module_cross.addImport("tint", tint_dep.module("tint"));
        const lib_cross = b.addLibrary(.{
            .name = "httpx",
            .linkage = .static,
            .root_module = root_module_cross,
        });
        linkPlatformLibs(lib_cross, target_cross);

        // Just build the artifact to verify it compiles
        build_all_step.dependOn(&lib_cross.step);
    }

    const lib_root_module = b.createModule(.{
        .root_source_file = b.path("src/httpx.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_root_module.addImport("zstd", zstd_dep.module("zstd"));
    lib_root_module.addImport("brotli", brotli_dep.module("brotli"));
    lib_root_module.addImport("tint", tint_dep.module("tint"));

    const lib = b.addLibrary(.{
        .name = "httpx",
        .linkage = .static,
        .root_module = lib_root_module,
    });
    linkPlatformLibs(lib, target);

    b.installArtifact(lib);

    const docs_step = b.step("docs", "Generate library documentation");
    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&install_docs.step);

    const test_all_step = b.step("test-all", "Run tests, benchmarks, and all runnable examples");
    test_all_step.dependOn(test_step);
    test_all_step.dependOn(bench_step);
    test_all_step.dependOn(run_all_examples);
}
