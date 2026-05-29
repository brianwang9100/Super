/// Which bottom-anchored overlay is currently driving the reader's content
/// inset, mirroring `BibleScreen.bottomOverlay`'s precedence: narration takes
/// precedence over the verse-selection action sheet.
///
/// The reader runs its paired selection auto-scroll only for `.selection`; a
/// `.narration` inset reserves space without triggering that scroll, leaving
/// narration's own current-verse follow-scroll the sole driver.
enum BibleBottomOverlayKind: Equatable {
    /// The verse-selection action sheet (`BibleActionSheet`).
    case selection
    /// The audio-narration transport card (`NarrationTransportSheet`).
    case narration
}
