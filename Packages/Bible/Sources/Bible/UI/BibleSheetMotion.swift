import SwiftUI

/// How the reading surface presents its sheets, toast, and action sheet —
/// resolved from the system Reduce Motion setting.
///
/// Kept as a standalone value, not inline in `BibleScreen`, so the
/// reduce-motion branch can be unit-tested without rendering the screen.
enum BibleSheetMotion: Equatable {
    /// The default: sheets slide up from the bottom edge with a spring curve.
    case full
    /// Reduce Motion is on — sheets cross-fade in place: no slide, no spring.
    case reduced

    init(reduceMotion: Bool) {
        self = reduceMotion ? .reduced : .full
    }

    /// The animation `withAnimation` runs sheet presentation under.
    var animation: Animation {
        switch self {
        case .full: .snappy(duration: 0.34)
        case .reduced: .easeInOut(duration: 0.2)
        }
    }

    /// The transition a sheet, the action sheet, or the toast enters and
    /// leaves with.
    var transition: AnyTransition {
        switch self {
        case .full: .move(edge: .bottom).combined(with: .opacity)
        case .reduced: .opacity
        }
    }
}
