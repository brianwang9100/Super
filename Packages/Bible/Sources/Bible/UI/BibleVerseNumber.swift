import SwiftUI

/// Builds the small raised verse-number marker that precedes a verse.
///
/// Not a SwiftUI `View`: it vends an `AttributedString` run so verses
/// concatenate and wrap inside a single paragraph `Text` rather than each
/// laying out as a separate, non-wrapping element. (Runs compose with
/// `AttributedString`'s `+`, not the deprecated `Text + Text` operator.)
struct BibleVerseNumber {
    let number: Int

    /// - Parameters:
    ///   - color: resolved foreground (the theme's faint ink).
    ///   - font: the resolved marker font. Passed in rather than read from the
    ///     environment so this type stays a pure value; the caller
    ///     (`BibleParagraphBlock`) resolves it through `SuperTypography` so the
    ///     number scales with the app font-scale slider and OS Dynamic Type
    ///     alongside the verse words it precedes.
    ///   - baselineOffset: how far to raise the marker, in points. The caller
    ///     derives it from the resolved marker size (rather than a constant) so
    ///     the superscript sits at a consistent height across both scale axes —
    ///     a fixed offset reads as floating-high once the slider shrinks the
    ///     marker.
    func attributedText(color: Color, font: Font, baselineOffset: CGFloat) -> AttributedString {
        var marker = AttributedString("\(number)")
        marker.font = font
        marker.foregroundColor = color
        marker.baselineOffset = baselineOffset
        return marker
    }
}
