# Changelog

All notable changes to `httpx.zig` are documented here. Versioning follows
`build.zig.zon` (`.version`) and `src/common/version.zig`.

## v0.2.2 — Zig 0.17.0 migration release

> [!IMPORTANT]
> `httpx.zig` v0.2.2 requires Zig 0.17.0 or newer. Zig 0.16.0 is not
> supported by this release. There are no compatibility wrappers for older
> toolchains.

The v0.2.2 tag has not been published yet; install the development build
with `zig fetch --save git+https://github.com/muhammad-fiaz/httpx.zig.git`
until the `0.2.2` release archive is available.

### Minimum toolchain

- Minimum Zig version raised from `0.16.0` to `0.17.0`
  (`build.zig.zon`, CI workflows, README, docs, issue templates).

### Breaking language changes (Zig 0.17.0)

- **Array repeat operator `**` removed.** Every `[_]T{v} ** N` site now uses
  `@splat`, e.g. `[_]u8{0} ** 16` became `(@as([16]u8, @splat(0)))` and
  `.{0} ** 8` became `@splat(0)`. Multi-element patterns (string repeats,
  `"a" ++ "b" ** 70`) were rewritten as explicit `comptime` constructions.
  The template engine's own `**` power operator (`{{ 2**3 }}`) is
  unaffected — it is template-language syntax, not Zig.
- **`@typeInfo` struct-of-arrays.** `.@"struct".fields` replaced by
  `field_names` / `field_types` / `field_attrs` (client option coercion,
  router `bindParams`/`url`, site params, template context, request
  helpers); `.@"enum".fields` replaced by `field_names` / `field_values`
  (method, HTTP version, compression encodings); `pointer.is_const`
  replaced by `pointer.attrs.@"const"`.
- **`std.Io` operation model.** `VTable.netRead`/`netWrite` no longer exist;
  socket I/O now goes through `io.operate(.{ .net_read = ... })` /
  `io.operate(.{ .net_write = ... })`, with `NetRead` returning a
  `ReadResult` (`data_len`) instead of a bare byte count.

### Breaking standard-library changes

- `std.ascii.indexOfIgnoreCase` renamed to `std.ascii.findIgnoreCase`.
- `std.StaticBitSet(N).initEmpty()` replaced by the `.empty` value.
- `std.crypto X25519.KeyPair.generateDeterministic` no longer returns an
  error union — `try` was dropped at all call sites.
- `zstd.decompressBound` now takes `(allocator, data)`.
- `b.addExecutable` / docs now use the Zig 0.17.0 build API
  (`.root_module = b.createModule(...)`); the old `.root_source_file`
  form was removed from all examples.

### Dependency integration

- `tint` (`tint.zig` 0.0.2) is now a **direct, independent dependency**:
  declared in `build.zig.zon`, wired into the `httpx` module plus the
  test and library roots in `build.zig`, and imported as
  `@import("tint")` in `src/common/logging.zig` and
  `src/client/download.zig` instead of indirectly via `loaders`.
- The new namespaced tint API is used throughout:
  `tint.color.ansi4.<name>.fg()` sequences and `tint.ansi.reset.all`;
  `Level.colorCode()` now returns `tint.ansi.Sequence` (use `.slice()`
  at the write site). Progress-bar style fields use camelCase
  (`leftBracket`/`rightBracket`) and `color: ?tint.ansi.Sequence`.
- **Diamond-dependency rule:** `loaders.zig` also depends on `tint.zig`, so
  `tint` is resolved with the same empty options loaders uses
  (`loadersDep.builder.dependency("tint", .{})`) — one shared module
  instance. Passing different options (e.g. re-passing
  `.target`/`.optimize`) creates a second instance and fails with
  `file exists in modules 'tint' and 'tint0'`. See the note in
  `README.md` and `docs/guide/installation.md`.
- Reused installed packages unchanged: `zstd` 0.0.4, `brotli` 0.0.4,
  `env` 0.0.3, `loaders` 0.0.7, `treesitter` 0.0.2.

### Public API corrections (camelCase)

- Docs snippets corrected to camelCase throughout (`urlBuf`, `taskId`,
  `acceptEncoding`, `serverPort`, …) to match the real example sources.
- `tint` is re-exported as `httpx.tint` from the direct dependency.

### Bug fixes

- Fixed latent `.comptimeFloat` tag typo in `headersFromStruct`
  (now `.comptime_float`).
- Fixed `router.url` second and third field loops still referencing the
  removed `fields` variable.
- brotli bound test and multipart boundary test rewritten without `**`.
- `zig fmt` canonicalized to the Zig 0.17.0 formatter (`zig fmt --check`
  passes for `src/`, `bench/`, `build.zig`, `build.zig.zon`).
- Benchmark header now prints the real toolchain via
  `builtin.zig_version` instead of a hardcoded string.

### Validation (2026-10-09, `x86_64-windows`, Zig 0.17.0)

- `zig build` — clean.
- `zig build test --summary all` — **751/751 tests pass**, including a new
  test proving `tint` is wired directly and independently of `loaders`.
- `zig build build-all-examples` — all ~90 example targets compile.
- `zig build bench` — suite compiles and runs; results refreshed in
  `docs/reference/benchmarks.md`. `client_server_get` reported 6 failed
  iterations out of 8000 (the known loopback keep-alive reuse race), so
  the run exited non-zero by design and that row is marked.
- Runtime spot checks: `run-parse-html`, `run-html-transform`,
  `run-compression-demo` (HTTP 200, gzip/br decoded),
  `run-simple-get` (HTTP 200, wire `User-Agent: httpx/0.2.2`),
  `run-simple-server` (loopback `GET /` → 200, `GET /json` → 200),
  `run-health-check`, `run-template-basic` (200 + `Content-Encoding: zstd`).
- `zig fmt --check src/ bench/ build.zig build.zig.zon` — clean.

### Known limitations

- `zig build run-all-examples` runs every example sequentially; server
  examples block and several examples require external network
  (`httpbun.com`) or certificates, so the full run is environment
  dependent. Compilation of all examples is verified instead.
- No performance claims are made for this release; benchmark tables
  contain only numbers from the verified 2026-10-09 run.

## v0.2.1 and earlier

- v0.2.1: last release supporting Zig 0.16.0.
- v0.0.7: last release supporting Zig 0.15.
- Earlier history is unchanged; see Git tags and GitHub releases.
