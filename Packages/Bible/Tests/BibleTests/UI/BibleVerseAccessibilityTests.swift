import SwiftUI
import Testing
@testable import Bible

@Suite("Shared Bible verse accessibility")
@MainActor
struct BibleVerseAccessibilityTests {
    @Test("Selection is announced consistently in paginated and scrolling readers", arguments: [false, true])
    func selectionTraits(selected: Bool) {
        let accessibility = BibleVerseAccessibility(verseNumber: 1, verseText: "Text", highlight: nil,
                                                    isSelected: selected, onTap: {})
        #expect(accessibility.traits.contains(.isButton))
        #expect(accessibility.traits.contains(.isSelected) == selected)
        #expect(accessibility.hint == (selected
            ? "Removes the verse from the selection"
            : "Selects the verse for highlight, copy, and share"))
    }
}
