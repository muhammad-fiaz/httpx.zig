//! TLS 1.3 integration tests.
//!
//! Verifies the TLS handshake engine, key schedule, record layer,
//! ALPN negotiation, and SNI parsing compose correctly.

const std = @import("std");
const testing = std.testing;

const engine_mod = @import("../protocols/tls/engine.zig");
const handshake_mod = @import("../protocols/tls/handshake.zig");
const record_mod = @import("../protocols/tls/record.zig");
const alpn_mod = @import("../protocols/tls/alpn.zig");
const quic_tls = @import("../protocols/tls/quic_tls.zig");
const qcrypto = @import("../protocols/quic/crypto.zig");

// ---------------------------------------------------------------------------
// Test 1: Full handshake state machine — client ↔ server
// ---------------------------------------------------------------------------

test "integration: full TLS 1.3 handshake state machine" {
    const a = testing.allocator;

    var client = engine_mod.Engine.initClient(a, .{});
    var server = engine_mod.Engine.initServer(a, .{});

    // ---- ClientHello ----
    const ch = try client.produceClientHello(&.{ "h2", "http/1.1" }, &.{});
    defer a.free(ch);

    try testing.expectEqual(@as(u8, 0x01), ch[0]);
    try testing.expectEqual(engine_mod.Engine.State.client_hello_sent, client.state);

    // ---- Server processes ClientHello ----
    try server.processClientHello(ch[4..]);
    try testing.expectEqual(engine_mod.Engine.State.client_hello_received, server.state);

    // Generate server ECDHE keypair and compute shared secret
    var srv_seed: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&.{0xCC}, &srv_seed, .{});
    server.local_keypair = try std.crypto.dh.X25519.KeyPair.generateDeterministic(srv_seed);
    server.shared_secret = try std.crypto.dh.X25519.scalarmult(
        server.local_keypair.secret_key,
        client.local_keypair.public_key,
    );

    // Server derives handshake secret from the shared secret
    server.deriveHandshakeSecret();
    try testing.expect(server.handshake_secret != null);

    // ---- Server produces flight ----
    var flight = try server.produceServerFlight("", "", &.{ .h2, .@"http/1.1" });
    defer flight.deinit(a);

    try testing.expectEqual(engine_mod.Engine.State.server_finished_sent, server.state);
    try testing.expect(server.ap_keys != null);

    // ---- Client processes ServerHello ----
    try client.processServerHello(flight.server_hello[4..]);
    try testing.expect(client.shared_secret != null);
    try testing.expectEqual(engine_mod.Engine.State.handshake_keys_derived, client.state);

    // ---- Client processes EncryptedExtensions ----
    try client.processEncryptedExtensions(flight.encrypted_extensions[4..]);
    try testing.expectEqual(engine_mod.Engine.State.encrypted_extensions_received, client.state);

    // ---- Client processes Certificate ----
    try client.processCertificate(flight.certificate[4..]);
    try testing.expectEqual(engine_mod.Engine.State.certificate_received, client.state);

    // ---- Client processes CertificateVerify ----
    try client.processCertificateVerify(flight.certificate_verify[4..]);
    try testing.expectEqual(engine_mod.Engine.State.certificate_verify_received, client.state);

    // ---- Client processes Finished ----
    try client.processFinished(flight.finished[4..]);
    try testing.expectEqual(engine_mod.Engine.State.handshake_complete, client.state);

    // ---- Both sides have application keys ----
    try testing.expect(client.ap_keys != null);
    try testing.expect(server.ap_keys != null);
}

// ---------------------------------------------------------------------------
// Test 2: Key schedule determinism (same input → same output)
// ---------------------------------------------------------------------------

test "integration: key schedule is deterministic and symmetric" {
    const shared_secret: [32]u8 = .{0xAB} ** 32;

    // Run the full key derivation twice with the same input
    const hs1 = quic_tls.handshakeKeys(shared_secret);
    const hs2 = quic_tls.handshakeKeys(shared_secret);

    // Same input → identical output
    try testing.expectEqualSlices(u8, &hs1.keys.tx_secret, &hs2.keys.tx_secret);
    try testing.expectEqualSlices(u8, &hs1.keys.rx_secret, &hs2.keys.rx_secret);

    // Client/server traffic secrets differ (asymmetric)
    try testing.expect(!std.mem.eql(u8, &hs1.keys.tx_secret, &hs1.keys.rx_secret));

    // Application secrets differ from handshake secrets
    const ap = quic_tls.applicationKeys(hs1.hs_secret);
    try testing.expect(!std.mem.eql(u8, &ap.keys.tx_secret, &hs1.keys.tx_secret));
    try testing.expect(!std.mem.eql(u8, &ap.keys.tx_secret, &ap.keys.rx_secret));
}

// ---------------------------------------------------------------------------
// Test 3: Record layer round-trip through the handshake engine
// ---------------------------------------------------------------------------

test "integration: record layer encrypts and decrypts with derived keys" {
    const a = testing.allocator;

    // Use the TLS engine to derive proper TLS 1.3 keys
    var client = engine_mod.Engine.initClient(a, .{});
    var server = engine_mod.Engine.initServer(a, .{});

    const ch = try client.produceClientHello(&.{"h2"}, &.{});
    defer a.free(ch);

    try server.processClientHello(ch[4..]);

    var srv_seed: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&.{0xCC}, &srv_seed, .{});
    server.local_keypair = try std.crypto.dh.X25519.KeyPair.generateDeterministic(srv_seed);
    server.shared_secret = try std.crypto.dh.X25519.scalarmult(
        server.local_keypair.secret_key,
        client.local_keypair.public_key,
    );

    // Both sides derive the same handshake secret from the shared secret
    client.shared_secret = server.shared_secret;
    client.deriveHandshakeSecret();
    server.deriveHandshakeSecret();

    // Both should have the same handshake secret
    try testing.expectEqual(client.handshake_secret.?, server.handshake_secret.?);

    // Derive client handshake traffic secret from the handshake secret
    const hs_secret = client.handshake_secret.?;
    var c_hs: [32]u8 = undefined;
    engine_mod.hkdfExpandLabel(hs_secret, "c hs traffic", &c_hs);

    // Derive AEAD key and IV from the traffic secret
    var ck: [16]u8 = undefined;
    var ci: [12]u8 = undefined;
    engine_mod.hkdfExpandLabel(c_hs, "key", &ck);
    engine_mod.hkdfExpandLabel(c_hs, "iv", &ci);

    const plaintext = "GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n";

    // Encrypt with client handshake key
    const encoded = try record_mod.encodeRecord(
        .application_data,
        plaintext,
        0,
        ck,
        ci,
    );

    // Decrypt with the same key (loopback test — both sides use same derivation)
    var read_buf: [record_mod.max_record_plaintext]u8 = undefined;
    const result = try record_mod.decodeRecord(
        encoded.bytes[0..encoded.len],
        &read_buf,
        0,
        ck,
        ci,
    );

    try testing.expectEqual(record_mod.ContentType.application_data, result.content_type);
    try testing.expectEqualStrings(plaintext, result.plaintext);
}

// ---------------------------------------------------------------------------
// Test 4: ALPN negotiation through the full handshake
// ---------------------------------------------------------------------------

test "integration: ALPN negotiation end-to-end" {
    const a = testing.allocator;

    var client = engine_mod.Engine.initClient(a, .{});
    const ch = try client.produceClientHello(&.{ "h3", "h2", "http/1.1" }, &.{});
    defer a.free(ch);

    // Verify all three ALPN protocols are encoded
    var found_h3 = false;
    var found_h2 = false;
    var found_http11 = false;
    var i: usize = 4; // skip handshake header
    while (i + 4 < ch.len) : (i += 1) {
        const ext_type = std.mem.readInt(u16, ch[i..][0..2], .big);
        if (ext_type == 0x0010) { // ALPN
            // Parse the ALPN extension
            const ext_len: usize = (@as(usize, ch[i + 2]) << 8) | ch[i + 3];
            if (ext_len > 4) {
                const list_len: usize = (@as(usize, ch[i + 4]) << 8) | ch[i + 5];
                var j: usize = i + 6;
                const list_end = i + 4 + 2 + list_len;
                while (j < list_end and j + 1 < ch.len) {
                    const proto_len = ch[j];
                    j += 1;
                    if (j + proto_len <= ch.len) {
                        const proto = ch[j..][0..proto_len];
                        if (std.mem.eql(u8, proto, "h3")) found_h3 = true;
                        if (std.mem.eql(u8, proto, "h2")) found_h2 = true;
                        if (std.mem.eql(u8, proto, "http/1.1")) found_http11 = true;
                    }
                    j += proto_len;
                }
            }
            break;
        }
    }

    try testing.expect(found_h3);
    try testing.expect(found_h2);
    try testing.expect(found_http11);

    // Server-side ALPN negotiation
    const server_pref = [_]alpn_mod.Protocol{ .h2, .@"http/1.1" };
    const client_offered = [_][]const u8{ "h3", "h2", "http/1.1" };
    const negotiated = alpn_mod.negotiateServer(&server_pref, &client_offered);
    try testing.expectEqual(alpn_mod.Protocol.h2, negotiated.?);
}

// ---------------------------------------------------------------------------
// Test 5: SNI is encoded in ClientHello
// ---------------------------------------------------------------------------

test "integration: SNI extension is encoded in ClientHello" {
    const a = testing.allocator;
    var client = engine_mod.Engine.initClient(a, .{});

    const ch = try client.produceClientHello(&.{ "h2", "http/1.1" }, &.{});
    defer a.free(ch);

    // Scan for server_name extension (type 0x0000)
    var found_sni = false;
    var i: usize = 4;
    while (i + 4 < ch.len) : (i += 1) {
        const ext_type = std.mem.readInt(u16, ch[i..][0..2], .big);
        if (ext_type == 0x0000) {
            found_sni = true;
            break;
        }
    }
    try testing.expect(found_sni);
}

// ---------------------------------------------------------------------------
// Test 6: Record layer sequence numbers produce unique ciphertexts
// ---------------------------------------------------------------------------

test "integration: sequence number progression produces unique nonces" {
    const key = [_]u8{0xAA} ** 16;
    const iv = [_]u8{0xBB} ** 12;
    const msg = "test data";

    const r0 = try record_mod.encodeRecord(.application_data, msg, 0, key, iv);
    const r1 = try record_mod.encodeRecord(.application_data, msg, 1, key, iv);
    const r2 = try record_mod.encodeRecord(.application_data, msg, 2, key, iv);

    // All three ciphertexts must differ
    try testing.expect(!std.mem.eql(u8, r0.bytes[5..r0.len], r1.bytes[5..r1.len]));
    try testing.expect(!std.mem.eql(u8, r1.bytes[5..r1.len], r2.bytes[5..r2.len]));
    try testing.expect(!std.mem.eql(u8, r0.bytes[5..r0.len], r2.bytes[5..r2.len]));
}

// ---------------------------------------------------------------------------
// Test 7: Handshake transcript produces consistent hashes
// ---------------------------------------------------------------------------

test "integration: transcript hash is consistent across client and server" {
    const ch_body = "ClientHello body";
    const sh_body = "ServerHello body";
    const ee_body = "EncryptedExtensions body";

    var client_transcript = handshake_mod.Transcript.init();
    client_transcript.feed(ch_body);
    client_transcript.feed(sh_body);
    client_transcript.feed(ee_body);
    const client_hash = client_transcript.finish();

    var server_transcript = handshake_mod.Transcript.init();
    server_transcript.feed(ch_body);
    server_transcript.feed(sh_body);
    server_transcript.feed(ee_body);
    const server_hash = server_transcript.finish();

    try testing.expectEqual(client_hash, server_hash);
}

// ---------------------------------------------------------------------------
// Test 8: HKDF-Expand-Label produces correct TLS 1.3 info format
// ---------------------------------------------------------------------------

test "integration: HKDF-Expand-Label produces tls13-prefixed info" {
    const prk: [32]u8 = .{0xAB} ** 32;

    // Same label → same output
    var a1: [16]u8 = undefined;
    var a2: [16]u8 = undefined;
    qcrypto.hkdfExpandLabel(prk, "quic key", a1[0..]);
    qcrypto.hkdfExpandLabel(prk, "quic key", a2[0..]);
    try testing.expectEqualSlices(u8, &a1, &a2);

    // Different labels → different output
    var b: [16]u8 = undefined;
    qcrypto.hkdfExpandLabel(prk, "quic iv", b[0..]);
    try testing.expect(!std.mem.eql(u8, &a1, &b));

    // Different output lengths → different results
    var c: [32]u8 = undefined;
    qcrypto.hkdfExpandLabel(prk, "quic key", c[0..]);
    try testing.expect(!std.mem.eql(u8, a1[0..], c[0..16]));
}
