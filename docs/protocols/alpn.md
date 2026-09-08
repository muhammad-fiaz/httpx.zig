# ALPN (Application-Layer Protocol Negotiation)

RFC 7301 defines the Application-Layer Protocol Negotiation (ALPN) extension for TLS, enabling client and server to negotiate application protocols (such as HTTP/2 vs HTTP/1.1) within the TLS handshake without extra network round trips.

## Wire Format

ALPN sends a `ProtocolNameList` in the TLS `ClientHello` extensions:
```text
Extension Type: 16 (0x0010)
List Length: 2 octets (16-bit vector)
Protocol Name: 1 octet length prefix + opaque ASCII string
```

## Supported Identifiers

* `h2`: HTTP/2 over TLS (RFC 7540 / RFC 9113)
* `http/1.1`: HTTP/1.1 (RFC 9112)
* `http/1.0`: HTTP/1.0 legacy
* `h3`: HTTP/3 over QUIC (RFC 9114)

## Negotiation Logic

1. **Client Proposal**: Client lists supported protocols in order of preference (e.g. `[h2, http/1.1]`).
2. **Server Decision**: Server evaluates client's list against its own preference order and selects the best mutual match.
3. **Server Response**: Server returns the selected protocol name in the `EncryptedExtensions` or `ServerHello`.
4. **Transport Dispatch**: Upon handshake completion, HTTPX immediately binds the connection to the negotiated protocol framing engine.

## Server Preference Order

HTTPX servers negotiate ALPN using the server's preferred order (`h2 > http/1.1 > http/1.0` for TCP transports). If the client does not advertise ALPN, HTTPX safely defaults to `http/1.1`.

## Related

* [Protocol: HTTP/2](/protocols/http-2)
* [Protocol: TLS 1.3](/protocols/tls-1.3)
* [Guide: TLS](/guide/tls)
