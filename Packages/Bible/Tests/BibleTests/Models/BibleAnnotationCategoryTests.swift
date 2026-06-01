import Testing
@testable import Bible

/// Tests for `BibleAnnotationCategory` — the semantic role that drives card
/// ordering, rendering, and the badge glyph.
@Suite("BibleAnnotationCategory")
struct BibleAnnotationCategoryTests {
    @Test("raw values encode the canonical display order")
    func canonicalOrder() {
        // These Int values are written to disk and used by `ORDER BY
        // category` — locking them guards against a silent reorder that
        // would scramble every persisted annotation's position.
        #expect(BibleAnnotationCategory.author.rawValue == 1)
        #expect(BibleAnnotationCategory.summary.rawValue == 2)
        #expect(BibleAnnotationCategory.historical.rawValue == 3)
        #expect(BibleAnnotationCategory.clarification.rawValue == 4)
        #expect(BibleAnnotationCategory.reference.rawValue == 5)
    }

    @Test("Comparable sorts author → summary → historical → clarification → reference")
    func comparableOrder() {
        let shuffled: [BibleAnnotationCategory] = [.reference, .author, .clarification, .summary, .historical]
        #expect(shuffled.sorted() == [.author, .summary, .historical, .clarification, .reference])
    }

    @Test("reference renders as a citation; every other category renders as prose")
    func renderingMapping() {
        #expect(BibleAnnotationCategory.reference.rendering == .citation)
        for category in BibleAnnotationCategory.allCases where category != .reference {
            #expect(category.rendering == .prose)
        }
    }

    @Test("each category exposes a non-empty SF Symbol glyph")
    func iconPerCase() {
        // The reference glyph is a diagonal arrow (design's `ArrowJump`);
        // the rest map to their nearest design-canvas glyph.
        #expect(BibleAnnotationCategory.author.iconSystemName == "person")
        #expect(BibleAnnotationCategory.summary.iconSystemName == "text.alignleft")
        #expect(BibleAnnotationCategory.historical.iconSystemName == "clock")
        #expect(BibleAnnotationCategory.clarification.iconSystemName == "lightbulb")
        #expect(BibleAnnotationCategory.reference.iconSystemName == "arrow.up.forward")
        for category in BibleAnnotationCategory.allCases {
            #expect(!category.iconSystemName.isEmpty)
            #expect(!category.displayName.isEmpty)
        }
    }

    @Test("tool tokens round-trip through the failable initializer")
    func toolTokenRoundTrip() {
        for category in BibleAnnotationCategory.allCases {
            #expect(BibleAnnotationCategory(toolToken: category.toolToken) == category)
        }
    }

    @Test("an unknown tool token returns nil")
    func unknownToolTokenIsNil() {
        #expect(BibleAnnotationCategory(toolToken: "audio") == nil)
        #expect(BibleAnnotationCategory(toolToken: "Author") == nil, "tokens are case-sensitive lowercase")
    }
}
