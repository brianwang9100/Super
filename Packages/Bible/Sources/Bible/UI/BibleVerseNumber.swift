import SwiftUI

/// An attributed run keeps the marker and word inside one wrapping Text.
struct BibleVerseNumber {
    let number: Int

    /// Supply a resolved font and a baselineOffset in points, scaled with marker size.
    func attributedText(color: Color, font: Font, baselineOffset: CGFloat) -> AttributedString {
        var marker = AttributedString("\(number)")
        marker.font = font
        marker.foregroundColor = color
        marker.baselineOffset = baselineOffset
        return marker
    }
}
