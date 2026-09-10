import CoreGraphics

struct BibleChapterReaderLayout: Equatable {
    let topInset: CGFloat
    let bottomInset: CGFloat

    static let fullReader = Self(topInset: 68, bottomInset: 160)
    static let preview = Self(topInset: 0, bottomInset: 0)

    // Scroll content clears the floating 44pt SelectionPill and its 8pt margins.
    static let previewWithSelection = Self(topInset: 0, bottomInset: 60)
}
