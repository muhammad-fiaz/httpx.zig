# Transfer Checksum

Cryptographic verification happens inline during downloads via
`VerifyOptions`. See `examples/downloadVerify.zig`.

```zig
const res = try client.download(url, .{
    .path = "downloads/file.pdf",
    .verify = .{
        .sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        .minSize = 100,
        .maxSize = 50 * 1024 * 1024,
    },
    .atomic = true,
});
std.debug.print("verified={}\n", .{res.verified});
if (res.sha256Hex) |hex| std.debug.print("sha256={s}\n", .{&hex});
```

## Expected Output

```text
verified=true
sha256=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
```

The hash reflects the expected file content and the verified flag reflects a match; file size and hash vary by URL. Requires network access to the download URL. See `examples/downloadVerify.zig` (`run-download-verify`).

Supported hashes: `sha256`, `sha384`, `sha512`, `md5`, `sha1`, plus
`expectedSize`, `minSize`, `maxSize`, `etag`, `lastModified`, and
`checksumFileUrl` for remote checksum files.

## Run

```bash
zig build run-download-verify
```

## What to Verify

- Matching hashes verify and save the file.
- Mismatches return `ChecksumMismatch` without keeping corrupt output.
