const std = @import("std");
const builtin = @import("builtin");

fn linkPlatformLibs(compile: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    compile.root_module.link_libc = true;
    if (target.result.os.tag == .windows) {
        // Winsock symbols are provided by these system libraries on Windows.
        compile.root_module.linkSystemLibrary("ws2_32", .{});
        compile.root_module.linkSystemLibrary("mswsock", .{});
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

    const env_dep = b.dependency("env", .{
        .target = target,
        .optimize = optimize,
    });

    const loaders_dep = b.dependency("loaders", .{
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
    httpx_module.addImport("env", env_dep.module("env"));
    httpx_module.addImport("loaders", loaders_dep.module("loaders"));

    const examples = [_]struct { name: []const u8, path: []const u8, skip_run_all: bool = false }{
        .{ .name = "simple-get", .path = "examples/simple_get.zig" },
        .{ .name = "post-json", .path = "examples/post_json.zig" },
        .{ .name = "custom-headers", .path = "examples/custom_headers.zig" },
        .{ .name = "connection-pool", .path = "examples/connection_pool.zig" },
        .{ .name = "redirect", .path = "examples/redirect.zig" },
        .{ .name = "streaming", .path = "examples/streaming.zig" },
        .{ .name = "multipart", .path = "examples/multipart.zig" },
        .{ .name = "custom-responses", .path = "examples/custom_responses.zig" },
        .{ .name = "browser-demo-server", .path = "examples/browser_demo_server.zig", .skip_run_all = true },
        .{ .name = "simple-server", .path = "examples/simple_server.zig" },
        .{ .name = "static-files", .path = "examples/static_files.zig" },
        .{ .name = "health-check", .path = "examples/health_check.zig" },
        .{ .name = "tls-get", .path = "examples/tls_get.zig" },
        .{ .name = "resolve", .path = "examples/resolve.zig" },
        .{ .name = "openapi", .path = "examples/openapi.zig" },
        .{ .name = "http10-client", .path = "examples/http10_client.zig" },
        .{ .name = "http2-client", .path = "examples/http2_client.zig" },
        .{ .name = "http2-multiplex", .path = "examples/http2_multiplex.zig" },
        .{ .name = "http3-client", .path = "examples/http3_client.zig" },
        .{ .name = "http3-quic", .path = "examples/http3_quic.zig" },
        .{ .name = "ftp-client", .path = "examples/ftp_client.zig" },
        .{ .name = "live-static-watcher", .path = "examples/live_static_watcher.zig", .skip_run_all = true },
        .{ .name = "docs-server", .path = "examples/docs_server.zig", .skip_run_all = true },
        .{ .name = "graphql-server", .path = "examples/graphql_server.zig", .skip_run_all = true },
        .{ .name = "auth-and-errors", .path = "examples/auth_and_errors.zig" },
        .{ .name = "spa-fallback", .path = "examples/spa_fallback.zig", .skip_run_all = true },
        .{ .name = "websocket-server", .path = "examples/websocket_server.zig", .skip_run_all = true },
        .{ .name = "sse-server", .path = "examples/sse_server.zig", .skip_run_all = true },
        .{ .name = "session-server", .path = "examples/session_server.zig", .skip_run_all = true },
        .{ .name = "metrics-server", .path = "examples/metrics_server.zig", .skip_run_all = true },
        .{ .name = "interceptor-example", .path = "examples/interceptor_example.zig", .skip_run_all = true },
        .{ .name = "cookie-server", .path = "examples/cookie_server.zig", .skip_run_all = true },
        .{ .name = "concurrent-demo", .path = "examples/concurrent_demo.zig" },
        .{ .name = "proxy-demo", .path = "examples/proxy_demo.zig" },
        .{ .name = "dns-demo", .path = "examples/dns_demo.zig" },
        .{ .name = "compression-demo", .path = "examples/compression_demo.zig" },
        .{ .name = "retry-demo", .path = "examples/retry_demo.zig" },
        .{ .name = "custom-server", .path = "examples/custom_server.zig", .skip_run_all = true },
        .{ .name = "cors-server", .path = "examples/cors_server.zig", .skip_run_all = true },
        .{ .name = "rate-limit-server", .path = "examples/rate_limit_server.zig", .skip_run_all = true },
        .{ .name = "helmet-server", .path = "examples/helmet_server.zig", .skip_run_all = true },
        .{ .name = "body-parser-server", .path = "examples/body_parser_server.zig", .skip_run_all = true },
        .{ .name = "tls-server", .path = "examples/tls_server.zig", .skip_run_all = true },
        .{ .name = "https-client", .path = "examples/https_client.zig", .skip_run_all = true },
        .{ .name = "tls12-client", .path = "examples/tls12_client.zig", .skip_run_all = true },
        .{ .name = "tls13-client", .path = "examples/tls13_client.zig", .skip_run_all = true },
        .{ .name = "tls-mtls", .path = "examples/tls_mtls.zig", .skip_run_all = true },
        .{ .name = "dns-cache", .path = "examples/dns_cache.zig" },
        .{ .name = "ftp-server", .path = "examples/ftp_server.zig", .skip_run_all = true },
        .{ .name = "download", .path = "examples/download.zig", .skip_run_all = true },
        .{ .name = "download-info", .path = "examples/download_info.zig", .skip_run_all = true },
        .{ .name = "download-verify", .path = "examples/download_verify.zig", .skip_run_all = true },
        .{ .name = "download-resume", .path = "examples/download_resume.zig", .skip_run_all = true },
        .{ .name = "download-existing", .path = "examples/download_existing.zig", .skip_run_all = true },
        .{ .name = "download-custom-progress", .path = "examples/download_custom_progress.zig", .skip_run_all = true },
        .{ .name = "download-batch", .path = "examples/download_batch.zig", .skip_run_all = true },
        .{ .name = "download-update", .path = "examples/download_update.zig", .skip_run_all = true },
        .{ .name = "download-checksum-file", .path = "examples/download_checksum_file.zig", .skip_run_all = true },
        .{ .name = "ftp-download", .path = "examples/ftp_download.zig", .skip_run_all = true },
        .{ .name = "parse-html", .path = "examples/parse_html.zig" },
    };

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

    const build_all_examples = b.step("build-all-examples", "Build all example executables");
    inline for (examples) |_| {
        build_all_examples.dependOn(b.getInstallStep());
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
    tests.root_module.addImport("env", env_dep.module("env"));
    tests.root_module.addImport("loaders", loaders_dep.module("loaders"));
    linkPlatformLibs(tests, target);

    const run_tests = b.addRunArtifact(tests);
    run_tests.has_side_effects = true;
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

    const lib_root_module = b.createModule(.{
        .root_source_file = b.path("src/httpx.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_root_module.addImport("zstd", zstd_dep.module("zstd"));
    lib_root_module.addImport("brotli", brotli_dep.module("brotli"));
    lib_root_module.addImport("env", env_dep.module("env"));
    lib_root_module.addImport("loaders", loaders_dep.module("loaders"));

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
