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
        // `.openAIResponses` shipped its adapter in web-search PR3a.
        #expect(LLMProviderKind.openAIResponses.hasProviderAdapter)
        // `.anthropicNative` shipped its adapter in web-search PR3b.
        #expect(LLMProviderKind.anthropicNative.hasProviderAdapter)
        // `.geminiNative` shipped its adapter in web-search PR3c — the last
        // native-search kind to flip, so every known kind is now buildable.
        #expect(LLMProviderKind.geminiNative.hasProviderAdapter)
        #if DEBUG
        #expect(LLMProviderKind.debug.hasProviderAdapter)
        #endif
    }

    /// As of PR3c every shipping kind has an adapter, so the buildable set
    /// equals the full set. The flag isn't dead: a future native kind added
    /// ahead of its adapter would re-introduce a `false` arm. Pinning the
    /// current end-state guards against an accidental `false` regression and
    /// documents that the not-yet-buildable scenario is now reachable only
    /// via that future addition.
    @Test("every known kind currently reports buildable")
    func allKnownKindsAreCurrentlyBuildable() {
        let allBuildable = LLMProviderKind.allCases.allSatisfy(\.hasProviderAdapter)
        #expect(allBuildable)
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
