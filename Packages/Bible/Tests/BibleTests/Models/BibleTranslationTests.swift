import Testing
@testable import Bible

/// Tests for `BibleTranslation` — code/name metadata and the `named(_:)`
/// lookup's fallback when a stored code is unknown.
@Suite("BibleTranslation")
struct BibleTranslationTests {
    @Test("the four bundled translations are exposed in order")
    func allCases() {
        #expect(BibleTranslation.allCases == [.web, .kjv, .asv, .bsb])
    }

    @Test("each translation carries a full display name")
    func displayNames() {
        #expect(BibleTranslation.web.name == "World English Bible")
        #expect(BibleTranslation.kjv.name == "King James Version")
        #expect(BibleTranslation.asv.name == "American Standard Version")
        #expect(BibleTranslation.bsb.name == "Berean Standard Bible")
    }

    @Test("named resolves a known stored code")
    func namedResolvesKnownCode() {
        #expect(BibleTranslation.named("ASV") == .asv)
        #expect(BibleTranslation.named("BSB") == .bsb)
    }

    @Test("named falls back to the default for an unknown code")
    func namedFallsBackForUnknownCode() {
        #expect(BibleTranslation.named("ESV") == .defaultTranslation)
        #expect(BibleTranslation.named("") == .web)
    }
}
