import Testing
@testable import Core

/// Coverage for `LLMProviderKind.hasProviderAdapter` — the flag callers use
/// to decide whether the running binary can build a live provider for a
/// persisted row's kind.
@Suite("LLMProviderKind.hasProviderAdapter")
struct LLMProviderKindTests {
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
}
