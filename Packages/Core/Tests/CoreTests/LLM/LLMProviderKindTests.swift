import Testing
@testable import Core

@Suite("LLMProviderKind.hasProviderAdapter")
struct LLMProviderKindTests {
    @Test("every known kind currently reports buildable")
    func allKnownKindsAreCurrentlyBuildable() {
        let allBuildable = LLMProviderKind.allCases.allSatisfy(\.hasProviderAdapter)
        #expect(allBuildable)
    }
}
