import Testing
@testable import Core

/// Coverage for `LLMProviderKind.hasProviderAdapter` — the flag callers use
/// to decide whether the running binary can build a live provider for a
/// persisted row's kind.
@Suite("LLMProviderKind.hasProviderAdapter")
struct LLMProviderKindTests {
    @Test("kinds with a shipped adapter report true")
    func shippedAdaptersAreBuildable() {
        #expect(LLMProviderKind.openAICompatible.hasProviderAdapter)
        #expect(LLMProviderKind.appleFoundation.hasProviderAdapter)
        #if DEBUG
        #expect(LLMProviderKind.debug.hasProviderAdapter)
        #endif
    }

    @Test("native-search kinds report false until their adapters ship")
    func nativeKindsAreNotYetBuildable() {
        #expect(!LLMProviderKind.anthropicNative.hasProviderAdapter)
        #expect(!LLMProviderKind.geminiNative.hasProviderAdapter)
        #expect(!LLMProviderKind.openAIResponses.hasProviderAdapter)
    }

    /// Every case is covered by the switch (no `default`), so a newly added
    /// kind forces an explicit buildable/not decision rather than silently
    /// inheriting one.
    @Test("every case resolves without trapping")
    func allCasesResolve() {
        for kind in LLMProviderKind.allCases {
            _ = kind.hasProviderAdapter
        }
    }
}
