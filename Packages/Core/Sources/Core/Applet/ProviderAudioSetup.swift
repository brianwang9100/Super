import Foundation

/// Safe reference to an explicitly configured provider credential; never contains secret material.
public struct ProviderAudioCredential: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let keyRef: String
    public init(id: String, name: String, keyRef: String) {
        self.id = id
        self.name = name
        self.keyRef = keyRef
    }

    /// Protocol compatibility alone does not identify OpenAI as the credential's company.
    public static func isDirectOpenAI(providerId: String?, baseURL: URL?) -> Bool {
        guard providerId == "openai", let url = baseURL else { return false }
        return url.scheme == "https" && url.host == "api.openai.com"
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil && ["/v1", "/v1/"].contains(url.path)
    }
}

/// Immutable defaults used by an inline provider-audio setup draft.
public struct ProviderAudioSnapshot: Sendable {
    public let enabled: Bool?
    public let source: ProviderAudioCredential?
    public let revision: Int
    public init(enabled: Bool?, source: ProviderAudioCredential?, revision: Int) {
        self.enabled = enabled
        self.source = source
        self.revision = revision
    }
}

/// Composition-root contribution to provider setup, committed only after the credential save succeeds.
@MainActor
public struct ProviderAudioSetup {
    public let snapshot: () -> ProviderAudioSnapshot
    public let commit: (ProviderAudioCredential, Bool, Bool, Int) async throws -> Void
    public init(
        snapshot: @escaping () -> ProviderAudioSnapshot,
        commit: @escaping (ProviderAudioCredential, Bool, Bool, Int) async throws -> Void
    ) {
        self.snapshot = snapshot
        self.commit = commit
    }
}
