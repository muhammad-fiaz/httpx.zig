# TLS Mutual Authentication (mTLS)

The server requests and enforces client certificates; only clients with
a trusted certificate complete the handshake. See `examples/tlsMtls.zig`,
which runs the whole flow over loopback through the high-level API:
`client.get(url, .{ .tls = .{ .clientCertPem, .clientKeyPem } })`
performs HTTPS over mTLS, then a cert-less request is rejected during
the handshake.

## Client Configuration

```zig
var res = try client.get(url, .{
    .tls = .{
        .verify = .caBundle,
        .caPem = caPem,
        .clientCertPem = certPem, // presented when the server asks
        .clientKeyPem = keyPem,   // P-256 ECDSA key for the chain
    },
    .timeoutMs = 15_000,
});
defer res.deinit();
```

Setting the pair routes the request through the native TLS 1.3 client
(ALPN `http/1.1`, or `h2` with `.httpVersion = .http2`); without it the
request keeps the std transport, which cannot present certificates.

## Covers

- Server-side `CertificateRequest` (required / optional modes)
- Client certificate + `CertificateVerify` presentation
- Chain anchoring in a client CA bundle + expiry/trust validation
- Missing/untrusted/forged credential rejection (fail closed)
- mTLS use cases (service mesh, gRPC, databases)

## Server Configuration

```zig
var server = try httpx.Server.init(allocator, io, .{
    .host = "127.0.0.1",
    .port = 0,
    .enableDocs = false,
    .tls = .{
        .certificatePem = certPem,
        .privateKeyPem = keyPem,
        // Require every client to present a certificate chaining to caPem.
        // Use `.optional` to allow cert-less clients through instead.
        .clientAuth = .required,
        .clientCaPem = caPem,
    },
});
defer server.deinit();
```

Presented chains are verified with
`verifyCertificateChain` (expiry, CA-ness, anchor match; no hostname
check — client certificates identify a principal, not a host), the
`CertificateVerify` P-256 signature is checked over the live transcript,
and the client `Finished` MAC binds everything. Malformed DER fails
closed via structural validation, never a panic.

## Run

```bash
zig build run-tls-mtls
```

## Expected Output

```text
mTLS HTTPS: status=200 mutual-hello present
mTLS enforcement: empty-cert client rejected
```

The ephemeral loopback port varies per run; certificate material and handshake details vary by deployment. Loopback only with an embedded P-256 self-signed identity, no external service required.

## mTLS Flow

1. Server requests client certificate (CertificateRequest)
2. Client sends certificate + CertificateVerify
3. Server verifies client cert against its trust store
4. Both parties have authenticated

## Common Use Cases

- Service mesh (Istio, Linkerd)
- Kubernetes API server auth
- Database connections (PostgreSQL, MySQL)
- gRPC service-to-service
