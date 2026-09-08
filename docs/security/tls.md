# TLS Security & Best Practices

Transport Layer Security (TLS) encrypts application traffic and authenticates servers and clients. HTTPX supports TLS 1.2 and TLS 1.3 with modern cryptographic ciphers.

## Cryptographic Standards

* **Protocols**: TLS 1.3 (RFC 8446) and TLS 1.2 (RFC 5246). Insecure legacy versions (SSLv3, TLS 1.0, TLS 1.1) are strictly disabled.
* **Ciphers**: AES-128-GCM, AES-256-GCM, and ChaCha20-Poly1305.
* **Key Exchange**: Ephemeral Diffie-Hellman (X25519, P-256) providing Perfect Forward Secrecy (PFS).

## Hostname Verification & SNI

The HTTPX client verifies that the certificate presented by the server contains a Subject Alternative Name (SAN) or Common Name (CN) matching the requested hostname.

* Wildcards (`*.example.com`) are supported only for single-level subdomains.
* Server Name Indication (SNI) is automatically included in every client handshake.

## Insecure Testing Modes

Disabling certificate verification is strictly for local unit tests and development:
```zig
// INSECURE: Tests and development only
const response = try client.get("https://localhost:8443", .{
    .tls = .{ .verify = .none },
});
```

In production, leave `.verify = .caBundle` (the default) to validate against system root trust anchors.

## Related

* [API: TLS](/api/tls)
* [Guide: TLS](/guide/tls)
* [Protocol: TLS 1.3](/protocols/tls-1.3)
