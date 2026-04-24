import Testing
@testable import Core

/// Tests for `InMemoryKeychainClient`'s set / get / delete semantics. The
/// real `AppleKeychainClient` isn't tested here because it requires a
/// signed test target with keychain entitlements.
@Suite("InMemoryKeychainClient")
struct KeychainClientTests {
    @Test func setAndGetRoundTrips() async throws {
        let keychain = InMemoryKeychainClient()
        try await keychain.setString("sk-secret", ref: "openai")
        let value = try await keychain.getString(ref: "openai")
        #expect(value == "sk-secret")
    }

    @Test func getReturnsNilForMissingKey() async throws {
        let keychain = InMemoryKeychainClient()
        let value = try await keychain.getString(ref: "missing")
        #expect(value == nil)
    }

    @Test func setOverwritesExistingValue() async throws {
        let keychain = InMemoryKeychainClient()
        try await keychain.setString("old", ref: "k")
        try await keychain.setString("new", ref: "k")
        #expect(try await keychain.getString(ref: "k") == "new")
    }

    @Test func deleteRemovesKey() async throws {
        let keychain = InMemoryKeychainClient(initial: ["x": "y"])
        try await keychain.delete(ref: "x")
        #expect(try await keychain.getString(ref: "x") == nil)
    }

    @Test func deleteIsIdempotent() async throws {
        let keychain = InMemoryKeychainClient()
        try await keychain.delete(ref: "missing")
    }
}
