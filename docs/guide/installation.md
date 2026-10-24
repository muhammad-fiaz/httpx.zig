# Installation

This guide covers all supported installation methods for `httpx.zig`.

## Requirements

- **Zig Version**: 0.17.0 or later
- **Operating System**: Windows, Linux, or macOS

> [!IMPORTANT]
> `httpx.zig` v0.2.3 requires Zig 0.17.0 or newer. Zig 0.16.0 is not supported by this release.

::: warning v0.2.3 release and Zig 0.16 deprecation
`v0.2.3` is the current release and targets Zig `0.17.0+`.
`v0.2.2` is the previous release.
Zig `0.16` support is legacy and remains available only through `0.2.1`.
New projects should use **Zig 0.17.0+** with **httpx.zig v0.2.3**.
:::

## Platform Support

httpx.zig supports Linux, Windows, and macOS across 32-bit and 64-bit builds:

### Operating Systems

| OS | Status | Notes |
|----|--------|-------|
| Linux | Full support | All major distributions. Unix domain sockets fully supported. |
| Windows | Full support | Windows 10/11, Server 2019+. Unix domain sockets require build 17061+ with Developer Mode. |
| macOS | Full support | macOS 11+ (Big Sur and later). Unix domain sockets fully supported. |

### Architectures

| Architecture | Linux | Windows | macOS |
|--------------|-------|---------|-------|
| x86_64 (64-bit) | Yes | Yes | Yes |
| aarch64 (ARM64) | Yes | Yes | Yes |
| x86 (32-bit) | Yes | Yes | No |

::: tip Cross-Compilation
Zig makes cross-compilation easy. You can build for any supported target from any host:
```bash
# Build for Linux ARM64 from Windows
zig build -Dtarget=aarch64-linux

# Build for Windows from Linux
zig build -Dtarget=x86_64-windows

# Build for macOS from Linux
zig build -Dtarget=aarch64-macos
```
:::

## Method 1: Zig Fetch (Recommended)

**Latest Release (v0.2.3)**

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.2.3.tar.gz
```

This installs the released package as a dependency in your project's `build.zig.zon`. Use this once the `0.2.3` tag is published.

**Previous Release (v0.2.2)**

```bash
zig fetch --save https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.2.2.tar.gz
```

> [!WARNING]
> Zig **0.17** is required by **v0.2.3**. Zig **0.16** is deprecated and supported only by **v0.2.1**, and Zig **0.15** is deprecated and supported only by **v0.0.7**. New projects should use **Zig 0.17.0+** with **httpx.zig v0.2.3**.

## Method 2: Zig Fetch (Latest Development Build)

Use this for the latest in-development version from the `main` branch. It may contain unreleased changes:

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/httpx.zig.git
```

## Method 3: Manual `build.zig.zon` Configuration

```zig
.{
    .name = "my-project",
    .version = "0.1.0",
    .dependencies = .{
        .httpx = .{
            .url = "https://github.com/muhammad-fiaz/httpx.zig/archive/refs/tags/0.2.3.tar.gz",
            // Replace with the real hash below. Never invent one:
            // run `zig fetch --save <url>` and copy the hash it prints.
            .hash = "<actual-hash-generated-by-zig-fetch>",
        },
    },
    .paths = .{
        "",
    },
}
```

## Method 4: Local Source Checkout

Clone and build directly (the installed compiler must be Zig 0.17.0 or newer):

```bash
git clone https://github.com/muhammad-fiaz/httpx.zig.git
cd httpx.zig
zig build
```

To use a local checkout from another project:

```zig
.dependencies = .{
    .httpx = .{
        .path = "../httpx.zig",
    },
},
```

## Configure `build.zig`

After adding the dependency, expose the module in your build script (Zig 0.17.0 build API):

```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const httpx_dep = b.dependency("httpx", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "my-app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("httpx", httpx_dep.module("httpx"));
    b.installArtifact(exe);
}
```

> [!NOTE]
> If the build fails with `file exists in modules 'X' and 'X0'`, a dependency on the client side is being resolved twice with different options — usually a transitive dependency the project also declares directly. Resolve shared dependencies with empty options (`.{}`) instead of re-passing `.target`/`.optimize`, so every importer shares one module instance. See https://codeberg.org/ziglang/zig/issues/36694.

## Import in your code

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var client = httpx.Client.init(allocator, io, .{});
    defer client.deinit();

    _ = try client.get("https://httpbun.com/get", .{});
}
```

## Validation and Target Matrix

Run these commands from the repository root to verify functionality:

```bash
# Host tests and runnable examples
zig build test
zig build run-all-examples  # Runs sequentially to prevent parallel compiler OOM / PC crashes

# Cross-target library compile validation
zig build build-all-examples -Dtarget=x86_64-linux-gnu
```

To validate Linux runtime behavior, run the cross-compiled artifacts on Linux/WSL (a foreign-target `zig build test` only compiles; it does not execute):

```bash
# Build Linux artifacts
zig build test -Dtarget=x86_64-linux-gnu
zig build run-simple-get -Dtarget=x86_64-linux-gnu

# Run on Linux/WSL
./zig-out/bin/test
./zig-out/bin/simple-get
```

To compile tests or examples for a specific target:

```bash
# Compile tests for 32-bit Windows
zig build test -Dtarget=x86-windows-gnu

# Compile an example for macOS ARM64
zig build run-simple-get -Dtarget=aarch64-macos
```

For client requests against external endpoints, prefer explicit timeout and error handling:

```zig
var res = client.get("https://example.com", .{ .timeoutMs = 10_000 }) catch |err| {
    std.debug.print("request failed: {s}\n", .{@errorName(err)});
    return;
};
defer res.deinit();
```

`httpx.zig` uses `build-all-examples` with an explicit `-Dtarget=` triple as the cross-target validation step.
