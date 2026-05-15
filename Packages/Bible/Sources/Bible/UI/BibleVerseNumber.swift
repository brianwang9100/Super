import SwiftUI

/// Builds the small raised verse-number marker that precedes a verse.
///
/// Not a SwiftUI `View`: it vends a `Text` fragment so verses concatenate and
/// wrap inside a single paragraph `Text` rather than each laying out as a
/// separate, non-wrapping element.
struct BibleVerseNumber {
    let number: Int

    /// - Parameter color: resolved foreground (the theme's faint ink).
    func text(color: Color) -> Text {
        Text("\(number)")
            .font(.caption2)
            .foregroundStyle(color)
            .baselineOffset(4)
    }
}
