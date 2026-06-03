import CoreGraphics

/// Which bottom-anchored sheet is currently presented over the reader,
/// with narration taking precedence over the verse-selection action sheet.
///
/// Both render through a single `.sheet(item:)` on `BibleScreen`, so this is
/// the sheet's item — `Identifiable` (by `self`) so a `.selection` →
/// `.narration` swap re-presents the sheet with the other card. The reader
/// also reads it to run its paired selection auto-scroll only for
/// `.selection`, leaving narration's own current-verse follow-scroll the sole
/// driver while it plays.
enum BibleBottomOverlayKind: Equatable, Identifiable {
    /// The verse-selection action sheet (`BibleActionSheet`).
    case selection
    /// The audio-narration transport card (`NarrationTransportSheet`).
    case narration

    /// Identity is the case itself: same case ⇒ same id (no-op), different
    /// case ⇒ different id (re-present). `Identifiable` requires `ID: Hashable`;
    /// since this enum has no associated values, `Hashable` (and `Equatable`)
    /// is synthesized automatically, so `ID == Self` satisfies it for free.
    var id: Self { self }

    /// First-paint height for this kind's `.fitsContent` sheet, the single
    /// source the sheet's `estimatedHeight:` and the reader's bottom scroll
    /// reserve both read from. Slightly generous so the sheet contracts to fit
    /// rather than clipping a frame; the reader reserves this plus a margin so
    /// the last verses clear the floating sheet instead of hiding behind it.
    var estimatedSheetHeight: CGFloat {
        switch self {
        case .selection: 280
        case .narration: 360
        }
    }
}
