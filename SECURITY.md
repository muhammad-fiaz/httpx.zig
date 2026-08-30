# Security Policy

## Supported Versions

| Version  | Supported |
| -------- | --------- |
| 0.1.9+   | :white_check_mark: |
| 0.1.8    | :white_check_mark: |
| 0.1.7    | :white_check_mark: |
| 0.1.6    | :white_check_mark: |
| < 0.1.5  | :x: |

Versions below 0.1.5 are considered end-of-life and will not receive
security fixes or updates.

---

## Security Features

`httpx.zig` includes the following built-in security mechanisms:

### TLS & Encryption

- **TLS 1.2 / 1.3** with full handshake support (RFC 5246 / RFC 8446)
- **X25519** key exchange for forward secrecy
- **AEAD cipher suites**: ChaCha20-Poly1305, AES-128-GCM, AES-256-GCM
- **ALPN negotiation** (RFC 7301) for automatic protocol selection
- **X.509 certificate parsing** and chain verification
- **mTLS** (mutual TLS) support for client certificate authentication
- Custom CA trust stores and certificate pinning options

### HTTP Security

- **CRLF injection defense** in header values and request paths
- **Path traversal rejection** in static file serving (`../` normalization)
- **Host header validation** to prevent DNS rebinding attacks
- **Request size limits** via `max_body` configuration (default 8 MB)
- **Connection limits** via `max_connections` to prevent resource exhaustion

### Authentication & Authorization

- **Bearer token extraction** and validation helpers
- **Basic authentication** parsing and verification
- **SSRF protection** in reverse proxy middleware
- **CSRF token validation** middleware
- **Security headers (Helmet)** middleware for HSTS, X-Frame-Options, CSP, etc.

### Network Security

- **DNS resolution with SSRF policy checks** to block internal network access
- **Rate limiting** middleware to prevent brute-force and DDoS
- **SOCKS5 proxy** support for privacy-preserving connections
- **Connection pooling** with health checking to prevent stale connections

### Data Integrity

- **Chunked transfer encoding** with proper termination validation
- **Content-Length enforcement** to prevent body injection
- **Multipart form parsing** with boundary validation (RFC 2046)
- **Cookie security** with proper attribute handling

---

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly.

### Where to Report

Preferred reporting method:

- **GitHub Security Advisory** (private, recommended for sensitive issues)
  https://github.com/muhammad-fiaz/httpx.zig/security/advisories/new

Other supported options:

- Open an issue on the repository
  https://github.com/muhammad-fiaz/httpx.zig/issues
- Create a Pull Request if you have already resolved the issue
  (avoid including sensitive exploit details in the PR description)

### What to Include

When reporting a vulnerability, please include:

- Affected version(s)
- Clear description of the issue
- Steps to reproduce (if applicable)
- Potential impact or severity
- Suggested fix or mitigation (optional)

### Response Timeline

- **Acknowledgement**: within 48 hours
- **Initial review**: within 5-7 business days
- **Resolution**: depends on severity and complexity
- **Disclosure**: coordinated disclosure after fix is released

### Accepted vs Declined Reports

**Accepted:**
- A fix will be released for supported versions
- A security advisory will be published
- Credit will be given upon request

**Declined:**
- Issues affecting unsupported versions (< 0.1.5)
- Expected or documented behavior
- Issues already fixed in a newer release
- Reports without sufficient detail to reproduce

---

## Security Best Practices for Users

When using `httpx.zig` in production:

1. **Always use HTTPS** in production (avoid `.verify = .none` in production)
2. **Set `max_connections`** to prevent resource exhaustion
3. **Enable rate limiting** for public-facing endpoints
4. **Use the Helmet middleware** to set security headers
5. **Validate and sanitize** all user input before processing
6. **Keep httpx.zig updated** to the latest supported version
7. **Use mTLS** for service-to-service communication when possible

---

Thank you for helping keep this project secure.
