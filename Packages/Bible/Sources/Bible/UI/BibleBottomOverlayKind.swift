import CoreGraphics

/// Narration takes precedence over selection in the shared sheet. Changing kind re-presents it;
/// selection auto-scroll must not compete with narration follow-scroll.
enum BibleBottomOverlayKind: Equatable, Identifiable {
    case selection
    case narration

    var id: Self { self }

    /// Shared first-paint estimate for sheet sizing and reader scroll reserve. Start
    /// slightly generous so content contracts into place instead of clipping.
    var estimatedSheetHeight: CGFloat {
        switch self {
        case .selection: 280
        case .narration: 360
        }
    }
}
