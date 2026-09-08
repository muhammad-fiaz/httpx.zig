# TLS 1.3 Protocol

RFC 8446 defines Transport Layer Security Version 1.3, delivering major security and performance improvements over previous TLS versions.

## Key Improvements in TLS 1.3

1. **1-RTT Handshake**: Halves handshake latency compared to TLS 1.2 by guessing the key exchange algorithm in the initial ClientHello.
2. **Removed Deprecated Primitives**: Obsoletes static RSA key exchange, Diffie-Hellman static groups, SHA-1, MD5, and CBC ciphers in favor of Ephemeral Diffie-Hellman (ECDHE) with AEAD ciphers.
3. **Encrypted Handshake**: Certificate messages and extensions are encrypted immediately following the ServerHello.
4. **Resumption (0-RTT)**: Pre-shared key resumption allows early data transmission on the very first round trip.

## Handshake Diagram

```text
Client                                               Server
ClientHello (KeyShare, SNI, ALPN) -------->
                                              ServerHello (KeyShare)
                                              {EncryptedExtensions}
                                              {Certificate}
                                              {CertificateVerify}
                                  <--------   {Finished}
{Finished}                        -------->
[Application Data]                <------->   [Application Data]
```

## Related

* [Protocol: TLS 1.2](/protocols/tls-1.2)
* [Guide: TLS](/guide/tls)
* [Security: TLS](/security/tls)
