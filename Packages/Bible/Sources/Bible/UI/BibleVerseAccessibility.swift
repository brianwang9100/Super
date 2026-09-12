import SwiftUI

struct BibleVerseAccessibility: ViewModifier {
    let verseNumber: Int
    let verseText: String
    let highlight: BibleHighlightColor?
    let isSelected: Bool
    let onTap: () -> Void

    var traits: AccessibilityTraits { isSelected ? [.isButton, .isSelected] : .isButton }
    var hint: String {
        isSelected
            ? "Removes the verse from the selection"
            : "Selects the verse for highlight, copy, and share"
    }

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(BibleVerseAnnouncement.label(verseNumber: verseNumber, verseText: verseText))
            .accessibilityValue(BibleVerseAnnouncement.highlightValue(highlight))
            .accessibilityHint(hint)
            .accessibilityAddTraits(traits)
            .accessibilityAction(.default, onTap)
    }
}
