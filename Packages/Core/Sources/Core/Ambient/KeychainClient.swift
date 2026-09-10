import Foundation
import os
#if canImport(Security)
import Security
#endif

/// Persist opaque references in applet databases, never secret values.
public protocol KeychainClient: Sendable {
    func getString(ref: String) async throws -> String?
    func setString(_ value: String, ref: String) async throws
    /// No-op for a missing reference.
    func delete(ref: String) async throws
}

public enum KeychainError: Error, Sendable, Equatable {
    case unhandledStatus(OSStatus)
    case unexpectedData
}

#if canImport(Security)
/// Generic-password items scoped by service and account reference.
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

    /// Uses WhenUnlockedThisDeviceOnly: no locked access, iCloud sync, or migration to another device.
    public func setString(_ value: String, ref: String) async throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ref,
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            // Upgrade older items to the current accessibility class on their next write.
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
