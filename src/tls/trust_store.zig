//! Trust Store & CA Bundle Management
//!
//! Provides a thin wrapper around `std.crypto.Certificate.Bundle`
//! for managing trusted CA certificates.

const std = @import("std");
const Certificate = std.crypto.Certificate;

pub const TrustStore = struct {
    bundle: Certificate.Bundle,
    loaded: bool = false,

    /// Initialize an empty trust store.
    pub fn init() TrustStore {
        return .{
            .bundle = .empty,
        };
    }

    /// Load the system trust store.
    pub fn loadSystem(self: *TrustStore, allocator: std.mem.Allocator) !void {
        self.bundle = .empty;
        self.bundle.rescan(allocator, std.Io{}, std.time.timestamp()) catch {};
        self.loaded = true;
    }

    /// Load a PEM file as a CA bundle.
    pub fn loadPem(self: *TrustStore, allocator: std.mem.Allocator, pem_data: []const u8) !void {
        self.bundle = .empty;
        try self.bundle.addCertsFromPem(allocator, pem_data);
        self.loaded = true;
    }

    /// Load a DER file as a CA certificate.
    pub fn loadDer(self: *TrustStore, allocator: std.mem.Allocator, der_data: []const u8) !void {
        _ = allocator;
        self.bundle = .empty;
        try self.bundle.addCert(der_data);
        self.loaded = true;
    }

    /// Add a single DER-encoded certificate to the trust store.
    pub fn addCert(self: *TrustStore, der_data: []const u8) !void {
        try self.bundle.addCert(der_data);
    }

    /// Deinitialize the trust store and free resources.
    pub fn deinit(self: *TrustStore, allocator: std.mem.Allocator) void {
        self.bundle.deinit(allocator);
    }

    /// Check if the trust store has any certificates loaded.
    pub fn isEmpty(self: *const TrustStore) bool {
        return self.bundle.bytes.len == 0;
    }

    /// Get a reference to the underlying bundle for verification.
    pub fn getBundle(self: *const TrustStore) Certificate.Bundle {
        return self.bundle;
    }
};

// Tests

test "TrustStore init is empty" {
    var store = TrustStore.init();
    try std.testing.expect(store.isEmpty());
}

test "TrustStore init returns valid bundle" {
    var store = TrustStore.init();
    const bundle = store.getBundle();
    try std.testing.expect(bundle.bytes.len == 0);
}

test "TrustStore init loaded is false" {
    const store = TrustStore.init();
    try std.testing.expect(!store.loaded);
}

test "TrustStore isEmpty after init" {
    const store = TrustStore.init();
    try std.testing.expect(store.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), store.bundle.bytes.len);
}

test "TrustStore getBundle returns empty bundle" {
    const store = TrustStore.init();
    const bundle = store.getBundle();
    try std.testing.expectEqual(@as(usize, 0), bundle.bytes.len);
    try std.testing.expectEqual(@as(usize, 0), bundle.certicates.len);
}

test "TrustStore init multiple times" {
    var store1 = TrustStore.init();
    var store2 = TrustStore.init();
    try std.testing.expect(store1.isEmpty());
    try std.testing.expect(store2.isEmpty());
    _ = &store1;
    _ = &store2;
}
