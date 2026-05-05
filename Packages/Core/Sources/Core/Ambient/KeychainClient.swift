import Foundation
import os
#if canImport(Security)
import Security
#endif

/// Keychain abstraction for storing API (Application Programming Interface)
/// keys and other secrets.
///
/// Per BYOK (Bring Your Own Key), users supply their own LLM (Large Language
/// Model) keys. Those secrets live in the Apple Keychain and are referenced
/// by an opaque `ref` string (typically a UUID). Domain code stores the ref
/// in GRDB, never the secret itself.
public protocol KeychainClient: Sendable {
    /// Returns the stored value for `ref`, or nil if no entry exists.
    func getString(ref: String) async throws -> String?
    /// Inserts or updates the value for `ref`.
    func setString(_ value: String, ref: String) async throws
    /// Removes `ref` if present. No-op when missing.
    func delete(ref: String) async throws
}

/// Errors surfaced by `AppleKeychainClient`. `unhandledStatus` carries the
/// raw OSStatus when the Security framework returns something we don't
/// translate into a more specific case.
public enum KeychainError: Error, Sendable, Equatable {
    case unhandledStatus(OSStatus)
    case unexpectedData
}

#if canImport(Security)
/// Apple Keychain-backed conformer using `kSecClassGenericPassword`.
///
/// Items are scoped by the supplied `service` name plus the per-item `ref`
/// account string, so multiple Super installs and test runs don't clash.
public struct AppleKeychainClient: KeychainClient {
    public let service: String

    public init(service: String = "com.brianwang.Super") {
        self.service = service
    }

    public func getString(ref: String) async throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ref,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedData
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandledStatus(status)
        }
    }

    /// Insert or update the secret stored at `ref`.
    ///
    /// New items are written with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`,
    /// which (a) requires the device to be unlocked at access time, and (b)
    /// pins the entry to *this* device — it does not migrate via iCloud
    /// Keychain and does not survive an encrypted backup restored to a
    /// different device. This is the project-wide stance from
    /// `docs/SECURITY.md` §2.1.4: BYOK keys never leave the user's hardware.
    public func setString(_ value: String, ref: String) async throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ref,
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            // Fix-up for items written by older Super builds that didn't
            // pin the accessibility class — the next set rotates them onto
            // the strict policy.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unhandledStatus(addStatus) }
        default:
            throw KeychainError.unhandledStatus(updateStatus)
        }
    }

    public func delete(ref: String) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ref,
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainError.unhandledStatus(status)
        }
    }
}
#endif

/// In-memory conformer for previews, tests, and headless contexts. Shipped in
/// Core (not test-only) so the Chat module can use it without redeclaring.
public final class InMemoryKeychainClient: KeychainClient {
    private let store: OSAllocatedUnfairLock<[String: String]>

    public init(initial: [String: String] = [:]) {
        self.store = OSAllocatedUnfairLock(initialState: initial)
    }

    public func getString(ref: String) async throws -> String? {
        store.withLock { $0[ref] }
    }

    public func setString(_ value: String, ref: String) async throws {
        store.withLock { $0[ref] = value }
    }

    public func delete(ref: String) async throws {
        store.withLock { state in
            _ = state.removeValue(forKey: ref)
        }
    }
}
