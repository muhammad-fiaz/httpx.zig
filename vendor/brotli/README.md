<div align="center">

# brotli.zig

<a href="https://muhammad-fiaz.github.io/brotli.zig/"><img src="https://img.shields.io/badge/docs-muhammad--fiaz.github.io-blue" alt="Documentation"></a>
<a href="https://ziglang.org/"><img src="https://img.shields.io/badge/Zig-0.17.0-orange.svg?logo=zig" alt="Zig Version"></a>
<a href="https://github.com/muhammad-fiaz/brotli.zig"><img src="https://img.shields.io/github/stars/muhammad-fiaz/brotli.zig" alt="GitHub stars"></a>
<a href="https://github.com/muhammad-fiaz/brotli.zig/issues"><img src="https://img.shields.io/github/issues/muhammad-fiaz/brotli.zig" alt="GitHub issues"></a>
<a href="https://github.com/muhammad-fiaz/brotli.zig/pulls"><img src="https://img.shields.io/github/issues-pr/muhammad-fiaz/brotli.zig" alt="GitHub pull requests"></a>
<a href="https://github.com/muhammad-fiaz/brotli.zig"><img src="https://img.shields.io/github/last-commit/muhammad-fiaz/brotli.zig" alt="GitHub last commit"></a>
<a href="https://github.com/muhammad-fiaz/brotli.zig/blob/main/LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License"></a>
<img src="https://img.shields.io/badge/platforms-linux%20%7C%20windows%20%7C%20macos-blue" alt="Supported Platforms">
<a href="https://github.com/muhammad-fiaz/brotli.zig/releases/latest"><img src="https://img.shields.io/github/v/release/muhammad-fiaz/brotli.zig?label=Latest%20Release&style=flat-square" alt="Latest Release"></a>
<a href="https://pay.muhammadfiaz.com"><img src="https://img.shields.io/badge/Sponsor-pay.muhammadfiaz.com-ff69b4?style=flat&logo=heart" alt="Sponsor"></a>
<a href="https://github.com/sponsors/muhammad-fiaz"><img src="https://img.shields.io/badge/Sponsor-GitHub-pink?style=social&logo=github" alt="GitHub Sponsors"></a>
<a href="https://hits.sh/muhammad-fiaz/brotli.zig/"><img src="https://hits.sh/muhammad-fiaz/brotli.zig.svg?label=Visitors&extraCount=0&color=green" alt="Repo Visitors"></a>

<p><em>Fast, native Brotli compression for Zig.</em></p>

<b><a href="https://muhammad-fiaz.github.io/brotli.zig/">Documentation</a> |
<a href="https://muhammad-fiaz.github.io/brotli.zig/api/">API Reference</a> |
<a href="https://muhammad-fiaz.github.io/brotli.zig/guide/getting-started">Quick Start</a> |
<a href="CONTRIBUTING.md">Contributing</a></b>

</div>

`brotli.zig` is a complete, native Zig implementation of the [Brotli](https://www.brotli.org/) compressed-data format (RFC 7932, including Large Window Brotli) targeting **Zig 0.17.0**, built entirely from scratch in pure Zig. No C bindings, no libc, and no external dependencies.

> [!TIP]
> If you build with brotli.zig, make sure to give it a star!

> [!NOTE]
> `brotli.zig` implements the RFC 7932 format specification and Large Window extension. The upstream [Brotli project](https://github.com/google/brotli) is used as a reference for format behavior, compatibility requirements, and interoperability testing.
>
> - **Streaming decoder state machine** - window bits (incl. large window up to 30), metablock headers, metadata blocks, uncompressed metablocks, partial input/output resumption across arbitrary byte splits.
> - **Huffman decoding & encoding** - canonical codes, code-length tables, two-level explicit tables, simple/complex tree construction.
> - **Context modeling** - 2nd-order literal context models, context maps with inverse move-to-front and RLE decoding.
> - **LZ77 back-references** with ring-buffer history and distance caches.
> - **Static dictionary** - complete 122,784-byte RFC 7932 static dictionary with 121 transforms.
> - **Custom dictionaries** - attach shared raw dictionaries to encoder and decoder.
> - **Native encoder** - hash-chain match finder, Huffman coding, block splitting, quality levels 0-11, literal block switching, NPOSTFIX/NDIRECT distance coding, metadata metablocks.
> - **Progress callbacks** - monitor streaming compression progress for large inputs.
> - **Reusable contexts** - initialize once, compress/decompress multiple streams via `reset()`, eliminating allocation churn.

---

<details>
<summary><strong>Features</strong> (click to expand)</summary>

| Feature | Description |
|---|---|
| **One-shot Compression** | `brotli.compress(allocator, data)` for single-call compression |
| **One-shot Decompression** | `brotli.decompress(allocator, data)` for single-call decompression |
| **Compression Levels** | Quality 0-11 via `brotli.compressWithOptions(allocator, data, .{ .quality = ... })` |
| **Reusable Compressor** | `brotli.Compressor` (`init`, `compress`, `reset`, `deinit`) |
| **Reusable Decompressor** | `brotli.Decompressor` (`init`, `decompress`, `decompressInto`, `reset`, `deinit`) |
| **I/O Streaming** | `compressStream` and `decompressStream` with Zig 0.17 `std.Io.Reader` & `std.Io.Writer` |
| **Streaming Compressor** | `StreamingCompressor` with `write(chunk, writer)` and `finish(writer)` |
| **Streaming Decompressor** | `StreamingDecompressor` with `read(reader, writer)` and `feed(chunk)` / `take(out)` |
| **Dictionary Compression** | `attachDictionary()` on both compressor and decompressor |
| **Shared / Compound Dictionaries** | `brotli.SharedDictionary` supporting up to 15 compound chunks |
| **UTF-8 Heuristic Modeling** | Automatic UTF-8 detection and context modeling optimization |
| **Built-in Static Dictionary** | Complete RFC 7932 word list + 121 transforms |
| **Window Sizes** | LGWIN 10-24 standard; large-window up to 30 |
| **Modes** | Generic (`.generic`), text (`.text`), and font (`.font`) |
| **Resource Limits** | `maxOutputSize` and `ringBufferSizeLimit` on `DecompressionOptions` |
| **Canonical Error Set** | Coherent `brotli.Error` error set mapped from internal codes |
| **Zero Dependencies** | Pure Zig implementation targeting Zig 0.17.0 |

</details>

---

<details>
<summary><strong>Prerequisites and Supported Platforms</strong> (click to expand)</summary>

<br>

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| **Zig** | **0.17.0** (required) | Download from [ziglang.org](https://ziglang.org/download/) |
| **Operating System** | Windows 10+, Linux, macOS | Cross-platform support |

---

## Supported Platforms

`brotli.zig` targets these architectures:

| Platform | x86_64 (64-bit) | aarch64 (ARM64) | x86 (32-bit) |
|---|---|---|---|
| **Linux** | Yes | Yes | Yes |
| **Windows** | Yes | Yes | Yes |
| **macOS** | Yes | Yes (Apple Silicon) | Yes |

### Cross-Compilation

Zig makes cross-compilation easy:

```bash
# Build for Linux ARM64
zig build -Dtarget=aarch64-linux

# Build for Windows x86_64
zig build -Dtarget=x86_64-windows

# Build for macOS Apple Silicon
zig build -Dtarget=aarch64-macos

# Build for 32-bit Windows
zig build -Dtarget=x86-windows
```

</details>

---

## Installation

### Method 1: Zig Fetch (Recommended) - Latest Release

```bash
zig fetch --save https://github.com/muhammad-fiaz/brotli.zig/archive/refs/tags/0.0.5.tar.gz
```

For projects using **Zig 0.16.0**, install the `v0.0.3` release:

```bash
zig fetch --save https://github.com/muhammad-fiaz/brotli.zig/archive/refs/tags/0.0.3.tar.gz
```

### Method 2: Zig Fetch (Main Branch)

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/brotli.zig.git
```

### Wire into `build.zig`

```zig
const target = b.standardTargetOptions(.{});
const optimize = b.standardOptimizeOption(.{});

const brotli_dep = b.dependency("brotli", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("brotli", brotli_dep.module("brotli"));
```

---

## Quick Start

### One-Shot Compression & Decompression

```zig
const brotli = @import("brotli");

// Compress
const compressed = try brotli.compress(allocator, data);
defer allocator.free(compressed);

// Decompress
const decompressed = try brotli.decompress(allocator, compressed);
defer allocator.free(decompressed);
```

### Advanced Options (camelCase)

```zig
const compressed = try brotli.compressWithOptions(allocator, data, .{
    .quality = 9,          // 0..11
    .lgWin = 22,           // 10..24 window bits
    .mode = .text,         // .generic | .text | .font
    .sizeHint = data.len,  // size hint for block allocation
});
defer allocator.free(compressed);

const decompressed = try brotli.decompressWithOptions(allocator, compressed, .{
    .maxOutputSize = 10 * 1024 * 1024, // protect against decompression bombs
    .ringBufferSizeLimit = 4 * 1024 * 1024,
});
defer allocator.free(decompressed);
```

### Reusable Contexts (Zero Allocation Churn)

Initialize the context once with your allocator, reuse across multiple streams via `reset()`, and deinitialize when done:

```zig
var compressor = brotli.Compressor.init(allocator, .{ .quality = 6 });
defer compressor.deinit();

var decompressor = brotli.Decompressor.init(allocator, .{});
defer decompressor.deinit();

// First stream
const comp1 = try compressor.compress(input1);
defer allocator.free(comp1);
const out1 = try decompressor.decompress(comp1);
defer allocator.free(out1);

// Reset state without reallocating buffers
compressor.reset(.{ .quality = 9 });
decompressor.reset(.{});

// Second stream
const comp2 = try compressor.compress(input2);
defer allocator.free(comp2);
const out2 = try decompressor.decompress(comp2);
defer allocator.free(out2);
```

### Streaming I/O with `std.Io`

Stream directly between `std.Io.Reader` and `std.Io.Writer`:

```zig
// Stream compression
var reader = std.Io.Reader.fixed(input_bytes);
var writer = std.Io.Writer.fixed(&out_buffer);

try brotli.compressStream(allocator, &reader, &writer, .{ .quality = 5 });

// Stream decompression
var comp_reader = std.Io.Reader.fixed(writer.buffered());
var decomp_writer = std.Io.Writer.fixed(&decomp_buffer);

try brotli.decompressStream(allocator, &comp_reader, &decomp_writer, .{});
```

### Chunked Streaming Compressor & Decompressor

```zig
// Incremental compression
var sc = brotli.StreamingCompressor.init(allocator, .{ .quality = 9 });
defer sc.deinit();

try sc.write(chunk1, &writer);
try sc.write(chunk2, &writer);
try sc.finish(&writer);

// Incremental decompression
var sd = brotli.StreamingDecompressor.init(allocator, .{});
defer sd.deinit();

try sd.feed(chunk);
var out_buf: [4096]u8 = undefined;
while (!sd.isFinished()) {
    const n = try sd.take(&out_buf);
    if (n == 0) break;
    // process out_buf[0..n]
}
```

### Custom Dictionary Compression

```zig
const dict = "shared vocabulary and schema definitions for compact communication";

// Attach dictionary on both sides
var compressor = brotli.Compressor.init(allocator, .{ .quality = 11 });
defer compressor.deinit();
_ = compressor.attachDictionary(dict);

var decompressor = brotli.Decompressor.init(allocator, .{});
defer decompressor.deinit();
_ = decompressor.attachDictionary(dict);

const compressed = try compressor.compress("compact communication with shared vocabulary");
defer allocator.free(compressed);

const original = try decompressor.decompress(compressed);
defer allocator.free(original);
```

### Shared & Compound Dictionaries

```zig
var shared_dict = brotli.SharedDictionary.init(allocator);
defer shared_dict.deinit();

_ = shared_dict.attach(.raw, prefix_chunk_1);
_ = shared_dict.attach(.raw, prefix_chunk_2);

// Single-call helper with compound dictionary
const comp = try brotli.compressWithSharedDictionary(allocator, payload, &shared_dict, .{ .quality = 9 });
defer allocator.free(comp);

const decomp = try brotli.decompressWithSharedDictionary(allocator, comp, &shared_dict, .{});
defer allocator.free(decomp);
```

---

## API Reference

### Top-Level Functions

| Function | Description |
|---|---|
| `brotli.compress(alloc, src)` | One-shot compression (default quality 11) |
| `brotli.decompress(alloc, src)` | One-shot decompression |
| `brotli.compressWithOptions(alloc, src, opts)` | Compression with `CompressionOptions` |
| `brotli.decompressWithOptions(alloc, src, opts)` | Decompression with `DecompressionOptions` |
| `brotli.decompressInto(alloc, src, dst)` | Decompress into preallocated buffer |
| `brotli.compressStream(alloc, reader, writer, opts)` | Stream compression via `std.Io` |
| `brotli.decompressStream(alloc, reader, writer, opts)` | Stream decompression via `std.Io` |
| `brotli.maxCompressedSize(src_size)` | Calculate upper bound on compressed size |
| `brotli.versionString()` / `versionNumber()` | Library version (`0.0.5` / `5`) |

### Types

| Type | Description |
|---|---|
| `brotli.Compressor` | Reusable compressor: `init`, `compress`, `reset`, `attachDictionary`, `deinit` |
| `brotli.Decompressor` | Reusable decompressor: `init`, `decompress`, `decompressInto`, `reset`, `attachDictionary`, `deinit` |
| `brotli.StreamingCompressor` | Streaming compressor: `write(chunk, writer)`, `finish(writer)`, `process(chunk)`, `flushAlloc()`, `finishAlloc()` |
| `brotli.StreamingDecompressor` | Streaming decompressor: `read(reader, writer)`, `feed(chunk)`, `take(out)`, `reset()` |
| `brotli.CompressionOptions` | `quality`, `lgWin`, `mode`, `lgBlock`, `sizeHint`, `largeWindow`, `nPostfix`, `nDirect`, `customDictionary` |
| `brotli.DecompressionOptions` | `largeWindow`, `customDictionary`, `maxOutputSize`, `ringBufferSizeLimit`, `metadataCallbacks` |
| `brotli.CompressionMode` | `.generic`, `.text`, `.font` |
| `brotli.Error` | Canonical public error set: `CorruptStream`, `TruncatedInput`, `ResourceLimitExceeded`, etc. |
| `brotli.ErrorCode` | Detailed Brotli codec error enumeration mirroring upstream specifications |

### Parameter Identifiers

- `brotli.paramMode`
- `brotli.paramQuality`
- `brotli.paramLgWin`
- `brotli.paramLgBlock`
- `brotli.paramDisableLiteralContextModeling`
- `brotli.paramSizeHint`
- `brotli.paramLargeWindow`
- `brotli.paramNPostfix`
- `brotli.paramNDirect`

---

## Examples

The `examples/` directory contains complete, runnable examples:

| Example | File | Description |
|---|---|---|
| `compress_file` | `examples/compress_file.zig` | One-shot compression across quality levels with round-trip verification |
| `streaming_compression` | `examples/streaming_compression.zig` | Chunked streaming compression with progress callback |
| `decompress_file` | `examples/decompress_file.zig` | File decompression using `std.Io` |
| `streaming_decompression` | `examples/streaming_decompression.zig` | Chunked streaming decompression |
| `dictionary_compression` | `examples/dictionary_compression.zig` | Custom shared-dictionary compression |
| `reusable_context` | `examples/reusable_context.zig` | Context reuse via `reset()` without reallocating buffers |
| `error_handling` | `examples/error_handling.zig` | Corrupted bitstream detection and diagnostics |
| `format_introspection` | `examples/format_introspection.zig` | Library version, codec constants, and format limits |
| `bit_level` | `examples/bit_level.zig` | Low-level bit reader and writer primitives |
| `io_pipeline` | `examples/io_pipeline.zig` | In-memory, caller-buffer, reader/writer, and chunked I/O shapes |

Run any example:

```bash
zig build run-compress_file
zig build run-streaming_compression
zig build run-reusable_context
zig build run-all-examples   # Run all 10 examples
```

---

## Building & Testing

```bash
zig build                    # Build native Brotli library
zig build test               # Run all unit and interoperability tests
zig build test --summary all # Detailed test execution summary
zig build run-all-examples   # Run all 10 example executables
zig build fuzz               # Run decoder fuzzer
zig build docs               # Generate documentation in zig-out/docs/
```

---

## Contributing

Contributions are welcome! Please ensure all tests pass:

```bash
zig fmt .
zig build test --summary all
zig build run-all-examples
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines.

## Security

For vulnerability reporting and security guarantees, please see [SECURITY.md](SECURITY.md).

## Acknowledgements

`brotli.zig` is a native Zig implementation of the Brotli format and codec, built entirely from scratch in Zig.

The [Brotli project](https://github.com/google/brotli) is used as a reference for the Brotli format, codec behavior, compatibility, and interoperability verification.

This project does not depend on the upstream implementation.

## License

MIT License - see [LICENSE](LICENSE) for details.

