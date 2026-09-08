# Path Traversal Protection

Path traversal attacks (CWE-22) occur when an attacker accesses files outside the intended root directory using dot-dot-slash (`../`) sequences or absolute paths.

## Built-In Protections in HTTPX

When mounting static assets via `server.static(url_prefix, root_dir)`:
1. **Lexical Normalization**: Resolves and cleans all relative segments (`.` and `..`).
2. **URL Decoding Validation**: Traversal sequences hidden within percent-encoded octets (`%2e%2e%2f` or `%252e%252e%252f`) are decoded and blocked before filesystem access.
3. **Prefix Containment**: Validates that the canonicalized target path remains strictly a subpath of the declared root directory.
4. **Symlink Boundary Checks**: Rejects symlinks pointing outside the designated root directory.
5. **Windows UNC & Device Path Rejection**: Blocks attempts to access `\?\C:` or `COM1`/`NUL` devices on Windows.

## Safe File Mounting Example

```zig
// Mount static directory securely
server.static("/public", "./static_assets");

// Requests such as:
//   GET /public/../../etc/passwd
//   GET /public/%2e%2e%2fwindows/win.ini
//   GET /public/..\..\boot.ini
// are immediately rejected with 403 Forbidden or 404 Not Found.
```

## Related

* [Guide: Static Files](/guide/static-files)
* [Security: Overview](/security/overview)
