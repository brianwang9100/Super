struct BibleChapterComparison {
    let primaryTranslation: BibleTranslation
    let secondaryTranslation: BibleTranslation
    let chapter: BibleChapter?
    let selectedVerses: Set<Int>
    let currentNarratingVerse: Int?
    let stacked: Bool
    let error: String?
    let onSelectTranslation: (BibleTranslation) -> Void
    let onTapVerse: (Int) -> Void
    let onAnnotation: (BibleAnnotationTargetSpec) -> Void
    let onRetry: () -> Void
}
