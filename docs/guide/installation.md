# Installation

To use `httpx.zig` in your project, you need to add it as a dependency in your `build.zig.zon` file.

## Requirements

- **Zig Version**: 0.15.0 or later (tested on 0.15.2)
- **Operating System**: Windows, Linux, macOS, or FreeBSD

## Platform Support

httpx.zig supports all major platforms and architectures:

### Operating Systems

| OS | Status | Notes |
|----|--------|-------|
| Linux | ✅ Full | All major distributions |
| Windows | ✅ Full | Windows 10/11, Server 2019+ |
| macOS | ✅ Full | macOS 11+ (Big Sur and later) |
| FreeBSD | ✅ Full | FreeBSD 13+ |

### Architectures

| Architecture | Linux | Windows | macOS |
|--------------|-------|---------|-------|
| x86_64 (64-bit) | ✅ | ✅ | ✅ |
| aarch64 (ARM64) | ✅ | ✅ | ✅ |
| i386 (32-bit) | ✅ | ✅ | ✅ |
| arm (32-bit) | ✅ | ✅ | ✅ |

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

## 1. Add Dependency

### Automatic installation (recommended)

Run the following command in your terminal:

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/httpx.zig
```

### Alternative: fetch from tarball

Run the following command in your terminal to fetch the library:

```bash
zig fetch --save "https://github.com/muhammad-fiaz/httpx.zig/archive/refs/heads/main.tar.gz"
```

Or manually add it to your `build.zig.zon`:

```zig
.{
    .name = "my-project",
    .version = "0.0.1",
    .dependencies = .{
        .httpx = .{
            .url = "https://github.com/muhammad-fiaz/httpx.zig/archive/refs/heads/main.tar.gz",
            // .hash = "...", // Zig will suggest the hash
        },
    },
    .paths = .{
        "",
    },
}
```

## 2. Configure `build.zig`

Add the module to your `build.zig` file to expose it to your executable or library:

```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Get the dependency
    const httpx_dep = b.dependency("httpx", .{
        .target = target,
        .optimize = optimize,
    });

    // 2. Get the module
    const httpx_mod = httpx_dep.module("httpx");

    // 3. Add to your executable
    const exe = b.addExecutable(.{
        .name = "my-app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("httpx", httpx_mod);

    b.installArtifact(exe);
}
```

## 3. Import in your code

You can now import the library in your Zig code:

```zig
const std = @import("std");
const httpx = @import("httpx");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Use the client
    var client = httpx.Client.init(allocator, io);
    defer client.deinit();
    
    // ...
}
```
