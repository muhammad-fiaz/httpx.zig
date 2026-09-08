# Security Architecture

HTTPX is engineered from the ground up with secure defaults, memory safety, and defense-in-depth design.

## Core Security Pillars

1. **Memory Safety by Construction**: Built in Zig with bounds-checked slices, explicit allocators, and zero use-after-free or buffer overflows.
2. **Strict Protocol Validation**: HTTP/1.1 and HTTP/2 parsers reject malformed frames, invalid transfer encodings, and request smuggling attempts.
3. **Transport Encryption**: Strict TLS 1.2 and TLS 1.3 enforcement with SNI, ALPN, and default CA validation.
4. **Path Traversal Defenses**: Static file servers reject all encoded traversal sequences (`../`, `%2e%2e/`, Windows UNC paths).
5. **Secret Redaction**: Logging mechanisms redact `Authorization`, `Cookie`, and token headers by default.

## Defense in Depth

```text
               Untrusted Internet Request
                           │
                           ▼
               [ TLS 1.3 Termination ]
               (Certificate & SNI validation)
                           │
                           ▼
               [ Connection & Rate Limits ]
               (Max concurrency, Token bucket)
                           │
                           ▼
               [ Protocol Syntax Parsing ]
               (Header length, Transfer-Encoding checks)
                           │
                           ▼
               [ Application Security Middleware ]
               (Auth, CORS, Security Headers, CSRF)
                           │
                           ▼
               [ Safe Route Handlers ]
```

## Security Checklist for Production

* [ ] Use TLS 1.3 / HTTPS for all public endpoints.
* [ ] Configure request size limits (`max_body_size`) to prevent denial-of-service memory exhaustion.
* [ ] Attach rate limiting middleware to authentication and API endpoints.
* [ ] Ensure all cookies specify `Secure`, `HttpOnly`, and `SameSite=Strict`.
* [ ] Validate and sanitize all user input before routing or template rendering.

## Related

* [Security: TLS](/security/tls)
* [Security: Rate Limiting](/security/rate-limiting)
* [Security: Request Limits](/security/request-limits)
