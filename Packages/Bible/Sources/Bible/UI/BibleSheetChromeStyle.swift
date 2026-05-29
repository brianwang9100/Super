import CoreGraphics

/// Per-card layout tuning for ``BibleSheetChromeModifier``. A struct of scalars
/// so the chrome stays data with no behaviour of its own. The corner radius,
/// border, and shadow are *not* here — they're fixed so both cards share one
/// look; only the content padding and outer margin vary per card.
struct BibleSheetChromeStyle {
    var contentHorizontalPadding: CGFloat
    var contentTopPadding: CGFloat
    var contentBottomPadding: CGFloat
    /// Gap between the drag handle and the first content row.
    var handleToContentSpacing: CGFloat
    /// Horizontal margin applied outside the card background. Zero when the
    /// call site applies its own horizontal padding.
    var outerHorizontalPadding: CGFloat

    /// Verse-selection action sheet: tight insets, handle flush to the header,
    /// 8pt outer margin (the action sheet pads itself).
    static let actionSheet = BibleSheetChromeStyle(
        contentHorizontalPadding: 10,
        contentTopPadding: 4,
        contentBottomPadding: 10,
        handleToContentSpacing: 0,
        outerHorizontalPadding: 8
    )

    /// Narration transport card: roomier insets, an 18pt handle gap, no outer
    /// margin (the `BibleScreen` call site applies `.padding(.horizontal, 12)`).
    static let narration = BibleSheetChromeStyle(
        contentHorizontalPadding: 18,
        contentTopPadding: 4,
        contentBottomPadding: 16,
        handleToContentSpacing: 18,
        outerHorizontalPadding: 0
    )
}
