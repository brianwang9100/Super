import CoreGraphics

/// Host-owned top clearance and base bottom reserve for a chapter column.
struct BibleChapterReaderLayout: Equatable {
    let topInset: CGFloat
    let bottomInset: CGFloat

    static let fullReader = Self(topInset: 68, bottomInset: 160)
    static let preview = Self(topInset: 0, bottomInset: 0)
}
