# TLS Security & Best Practices

Transport Layer Security (TLS) encrypts application traffic and authenticates servers and clients. HTTPX provides native TLS 1.3 server and client support, plus TLS 1.2 interoperability through the standard-library HTTPS/1.1 client transport.

## Cryptographic Standards

* **Protocols**: TLS 1.3 (RFC 8446) on native client and server paths, plus TLS 1.2/1.3 on the standard-library HTTPS/1.1 client transport. Insecure legacy versions (SSLv3, TLS 1.0, TLS 1.1) are strictly disabled.
* **Ciphers**: AES-128-GCM, AES-256-GCM, and ChaCha20-Poly1305.
* **Key Exchange**: X25519 and hybrid X25519MLKEM768 ephemeral key agreement, providing Perfect Forward Secrecy (PFS). P-256 ECDSA is used for certificate signatures, not key exchange.

## Hostname Verification & SNI

The HTTPX client verifies that the certificate presented by the server contains a Subject Alternative Name (SAN) or Common Name (CN) matching the requested hostname.

* Wildcards (`*.example.com`) are supported only for single-level subdomains.
* Server Name Indication (SNI) is automatically included in every client handshake.

## Insecure Testing Modes

Disabling certificate verification is strictly for local unit tests and development:
```zig
// INSECURE: Tests and development only
var response = try client.get("https://localhost:8443", .{
    .tls = .{ .verify = .none },
});
defer response.deinit();
```

The HTTP client uses `.verify = .caBundle` by default and validates against system root trust anchors, even when no TLS options are supplied. TLS truncation is rejected by default; only enable `allowTruncation` when the application validates response completeness through message framing. Set `.verify = .none` only for controlled tests or development.

## Related

* [API: TLS](/api/tls)
* [Guide: TLS](/guide/tls)
* [Protocol: TLS 1.3](/protocols/tls-1.3)
