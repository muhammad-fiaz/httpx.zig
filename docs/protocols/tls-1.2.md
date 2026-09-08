# TLS 1.2 Protocol

RFC 5246 defines Transport Layer Security Version 1.2, providing cryptographic privacy and data integrity across computer networks.

## Compatibility in HTTPX

HTTPX supports TLS 1.2 for interoperability with legacy servers and enterprise load balancers that do not yet support TLS 1.3.

* **Cipher Suites**: Supports AES-128-GCM, AES-256-GCM, and ChaCha20-Poly1305 authenticated encryption.
* **Handshake**: 2-RTT handshake negotiating symmetric session keys and verifying X.509 certificate chains.
* **SNI & ALPN**: Fully supported in TLS 1.2 ClientHello extensions.

## Handshake Flow

```text
Client                                               Server
ClientHello (TLS 1.2, SNI, ALPN)  -------->
                                              ServerHello
                                              Certificate
                                              ServerKeyExchange
                                  <--------   ServerHelloDone
ClientKeyExchange
[ChangeCipherSpec]
Finished                          -------->
                                              [ChangeCipherSpec]
                                  <--------   Finished
Application Data                  <------->   Application Data
```

## Related

* [Protocol: TLS 1.3](/protocols/tls-1.3)
* [Guide: TLS](/guide/tls)
* [Security: TLS](/security/tls)
