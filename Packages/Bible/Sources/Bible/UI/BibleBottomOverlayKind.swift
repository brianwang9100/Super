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

    var id: Self { self }
}
