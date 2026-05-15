import Testing
@testable import Bible

/// Tests for `BibleTranslation` — code/name metadata and the `named(_:)`
/// lookup's fallback when a stored code is unknown.
@Suite("BibleTranslation")
struct BibleTranslationTests {
    @Test("the three bundled translations are exposed in order")
    func allCases() {
        #expect(BibleTranslation.allCases == [.web, .kjv, .asv])
    }

    @Test("each translation carries a full display name")
    func displayNames() {
        #expect(BibleTranslation.web.name == "World English Bible")
        #expect(BibleTranslation.kjv.name == "King James Version")
        #expect(BibleTranslation.asv.name == "American Standard Version")
    }

    @Test("named resolves a known stored code")
    func namedResolvesKnownCode() {
        #expect(BibleTranslation.named("ASV") == .asv)
    }

    @Test("named falls back to the default for an unknown code")
    func namedFallsBackForUnknownCode() {
        #expect(BibleTranslation.named("ESV") == .defaultTranslation)
        #expect(BibleTranslation.named("") == .web)
    }
}
