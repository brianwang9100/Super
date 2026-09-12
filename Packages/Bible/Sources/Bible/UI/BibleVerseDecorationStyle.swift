import SwiftUI

struct BibleVerseDecorationStyle {
    enum Underline { case none, selection, narration }

    /// Rendered body size, including Dynamic Type and the app font scale.
    let bodySize: CGFloat
    let isSelected: Bool
    let isNarrating: Bool

    var baselineDrop: CGFloat { bodySize * 0.22 }
    var highlightBandHeight: CGFloat { bodySize + baselineDrop }
    var underlineWeight: CGFloat { max(1, (bodySize * 0.10).rounded()) }
    var underline: Underline { isSelected ? .selection : isNarrating ? .narration : .none }
    var underlineOpacity: Double { underline == .narration ? 0.65 : 1 }
    var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: underlineWeight, dash: underline == .narration ? [3, 3] : [])
    }
}
