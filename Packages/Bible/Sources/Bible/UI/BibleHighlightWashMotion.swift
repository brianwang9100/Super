import SwiftUI

/// How the saved-highlight wash transitions when a verse's highlight is
/// applied, cleared, or recoloured — resolved from the system Reduce Motion
/// setting.
///
/// Kept as a standalone value, not inline in `VerseWord`, so the
/// reduce-motion branch can be unit-tested without rendering a verse — the
/// same shape as `BibleSheetMotion`.
enum BibleHighlightWashMotion: Equatable {
    /// The default: the wash cross-fades as its colour changes.
    case full
    /// Reduce Motion is on — the wash repaints in place with no transition.
    case reduced

    init(reduceMotion: Bool) {
        self = reduceMotion ? .reduced : .full
    }

    /// The animation the wash's `.animation(_, value: highlightColor)` runs
    /// under, or `nil` under Reduce Motion so the colour change applies
    /// instantly.
    var animation: Animation? {
        switch self {
        case .full: .easeInOut(duration: 0.25)
        case .reduced: nil
        }
    }
}
