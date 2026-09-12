import SwiftUI

struct BiblePageVerseTarget: View {
    let fragment: BiblePage.Fragment
    let isSelected: Bool
    let highlight: BibleHighlightColor?
    let onTap: () -> Void

    var body: some View {
        let bounds = fragment.frames.reduce(CGRect.null) { $0.union($1) }
        ZStack(alignment: .topLeading) {
            ForEach(fragment.frames.indices, id: \.self) { index in
                let rect = fragment.frames[index]
                Color.clear
                    .frame(width: rect.width, height: rect.height)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
                    .offset(x: rect.minX - bounds.minX, y: rect.minY - bounds.minY)
            }
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BibleVerseAnnouncement.label(verseNumber: fragment.verseNumber, verseText: fragment.text))
        .accessibilityValue(BibleVerseAnnouncement.highlightValue(highlight))
        .accessibilityHint(isSelected ? "Deselect verse" : "Select verse and show actions")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onTap)
        .offset(x: bounds.minX, y: bounds.minY)
    }
}
