import Core
import GRDBQuery
import SwiftUI

/// BibleChapterContent provides a fresh chapter identity so constant decoration queries observe the displayed position.
struct BibleChapterReader: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var verseBodySize: CGFloat = SuperTypography.readingBodySize
    @Query<ChapterHighlightsRequest> private var highlights: [BibleHighlightRecord]
    @Query<ChapterAnnotationsRequest> private var annotations: [BibleAnnotationRecord]
    @Query<ChapterNotesRequest> private var notes: [BibleNoteRecord]
    @Query<ChapterBookmarkRequest> private var chapterBookmark: BibleBookmarkRecord?

    private let chapter: BibleChapter
    private let bookId: String
    private let bookName: String
    private let selectedVerses: Set<Int>
    private let navigation: BibleChapterNavigation?
    private let layout: BibleChapterReaderLayout
    private let currentNarratingVerse: Int?
    private let suppressNarrationScroll: Bool
    private let pendingScrollVerse: Int?
    private let bottomOverlayKind: BibleBottomOverlayKind?
    private let onTapVerse: (Int) -> Void
    private let onBackgroundTap: () -> Void
    private let onConsumeScroll: () -> Void
    private let onAnnotationBubbleTap: ((BibleAnnotationTargetSpec) -> Void)?
    private let onRequestChapterAnnotation: ((BibleAnnotationTargetSpec) -> Void)?
    private let chapterDispatchStatus: BibleAnnotationDispatchStatus?
    private let onNoteGlyphTap: ((BibleNoteTargetSpec) -> Void)?
    private let onBookmarkTap: (() -> Void)?
    private let onScroll: (CGFloat, Bool) -> Void
    private let onFooterVisible: (Bool) -> Void

    // Programmatic scrolling must not toggle immersive chrome.
    @State private var scrollIsUserDriven = false

    /// Suppress narration scroll during user selection. Selection sheets get a separate
    /// one-time lift; narration sheets leave follow-scroll to playback. Both enlarge
    /// bottom clearance so the final verses can scroll above the sheet.
    /// Consume pendingScrollVerse after issuing its scroll to avoid replay on navigation.
    /// Nil note/bookmark callbacks omit their glyphs; nil annotation generation disables
    /// the empty bubble. Note taps open the list without automatically composing.
    init(
        chapter: BibleChapter,
        bookId: String,
        bookName: String,
        selectedVerses: Set<Int>,
        navigation: BibleChapterNavigation? = nil,
        layout: BibleChapterReaderLayout = .fullReader,
        currentNarratingVerse: Int? = nil,
        suppressNarrationScroll: Bool = false,
        pendingScrollVerse: Int? = nil,
        bottomOverlayKind: BibleBottomOverlayKind? = nil,
        onTapVerse: @escaping (Int) -> Void,
        onBackgroundTap: @escaping () -> Void,
        onConsumeScroll: @escaping () -> Void = {},
        onAnnotationBubbleTap: ((BibleAnnotationTargetSpec) -> Void)? = nil,
        onRequestChapterAnnotation: ((BibleAnnotationTargetSpec) -> Void)? = nil,
        chapterDispatchStatus: BibleAnnotationDispatchStatus? = nil,
        onNoteGlyphTap: ((BibleNoteTargetSpec) -> Void)? = nil,
        onBookmarkTap: (() -> Void)? = nil,
        onScroll: @escaping (CGFloat, Bool) -> Void = { _, _ in },
        onFooterVisible: @escaping (Bool) -> Void = { _ in }
    ) {
        _highlights = Query(constant: ChapterHighlightsRequest(
            bookId: bookId,
            chapterNumber: chapter.number
        ))
        _annotations = Query(constant: ChapterAnnotationsRequest(
            bookId: bookId,
            chapterNumber: chapter.number
        ))
        _notes = Query(constant: ChapterNotesRequest(
            bookId: bookId,
            chapterNumber: chapter.number
        ))
        _chapterBookmark = Query(constant: ChapterBookmarkRequest(
            bookId: bookId,
            chapterNumber: chapter.number
        ))
        self.chapter = chapter
        self.bookId = bookId
        self.bookName = bookName
        self.selectedVerses = selectedVerses
        self.navigation = navigation
        self.layout = layout
        self.currentNarratingVerse = currentNarratingVerse
        self.suppressNarrationScroll = suppressNarrationScroll
        self.pendingScrollVerse = pendingScrollVerse
        self.bottomOverlayKind = bottomOverlayKind
        self.onTapVerse = onTapVerse
        self.onBackgroundTap = onBackgroundTap
        self.onConsumeScroll = onConsumeScroll
        self.onAnnotationBubbleTap = onAnnotationBubbleTap
        self.onRequestChapterAnnotation = onRequestChapterAnnotation
        self.chapterDispatchStatus = chapterDispatchStatus
        self.onNoteGlyphTap = onNoteGlyphTap
        self.onBookmarkTap = onBookmarkTap
        self.onScroll = onScroll
        self.onFooterVisible = onFooterVisible
    }

    private var highlightsByVerse: [Int: BibleHighlightColor] {
        var map: [Int: BibleHighlightColor] = [:]
        for record in highlights {
            guard let color = record.color else { continue }
            map[record.verseNumber] = color
        }
        return map
    }

    /// Deduplicate ranges per ending verse while retaining stable insertion order.
    private var annotationsByVerseEnd: [Int: [BibleAnnotationTargetSpec]] {
        var map: [Int: [BibleAnnotationTargetSpec]] = [:]
        var seen: Set<String> = []
        for record in annotations {
            guard record.target == .verse,
                  let start = record.verseStart,
                  let end = record.verseEnd else { continue }
            let spec = BibleAnnotationTargetSpec.verseRange(
                bookId: bookId,
                chapterNumber: chapter.number,
                verseStart: start,
                verseEnd: end
            )
            if seen.insert(spec.id).inserted {
                map[end, default: []].append(spec)
            }
        }
        return map
    }

    private var hasChapterAnnotation: Bool {
        annotations.contains { $0.target == .chapter }
    }

    /// Deduplicate note ranges per ending verse, preserving query order after annotation bubbles.
    private var notesByVerseEnd: [Int: [BibleNoteTargetSpec]] {
        var map: [Int: [BibleNoteTargetSpec]] = [:]
        var seen: Set<String> = []
        for record in notes {
            guard record.target == .verse,
                  let start = record.verseStart,
                  let end = record.verseEnd else { continue }
            let spec = BibleNoteTargetSpec.verseRange(
                bookId: bookId,
                chapterNumber: chapter.number,
                verseStart: start,
                verseEnd: end
            )
            if seen.insert(spec.id).inserted {
                map[end, default: []].append(spec)
            }
        }
        return map
    }

    private var hasChapterNote: Bool {
        notes.contains { $0.target == .chapter }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: BibleReadingMetrics.paragraphSpacing(bodySize: verseBodySize, fontScale: typography.fontScale)) {
                    chapterTitle
                        .padding(.bottom, 6)

                    let highlightsByVerse = highlightsByVerse
                    let annotationsByVerseEnd = annotationsByVerseEnd
                    let notesByVerseEnd = notesByVerseEnd
                    let numberedEarlier = VerseTokenizer.priorlyNumberedVerses(chapter.paragraphs)
                    let verseEndsByParagraph = VerseTokenizer.verseEndsByParagraph(chapter.paragraphs)
                    ForEach(Array(chapter.paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        BibleParagraphBlock(
                            paragraph: paragraph,
                            selectedVerses: selectedVerses,
                            highlightedVerses: highlightsByVerse,
                            numberedEarlier: numberedEarlier[index],
                            verseEndsHere: verseEndsByParagraph[index],
                            annotationsByVerseEnd: annotationsByVerseEnd,
                            notesByVerseEnd: notesByVerseEnd,
                            currentNarratingVerse: currentNarratingVerse,
                            onTapVerse: onTapVerse,
                            onAnnotationBubbleTap: onAnnotationBubbleTap,
                            onNoteGlyphTap: onNoteGlyphTap
                        )
                    }

                    if let navigation {
                        BibleChapterFooter(
                            previousLabel: navigation.previousLabel,
                            nextLabel: navigation.nextLabel,
                            onPrevious: navigation.onPrevious,
                            onNext: navigation.onNext
                        )
                    }

                    // Reserve room for footer content to scroll above the host chrome or floating study sheet.
                    Color.clear.frame(height: Self.bottomClearHeight(for: bottomOverlayKind, layout: layout))
                }
                .padding(.horizontal, 26)
                // Clear the floating nav bar while allowing text to scroll beneath its gradient.
                .padding(.top, layout.topInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onBackgroundTap() }
            }
            .onScrollPhaseChange { _, newPhase in
                scrollIsUserDriven = newPhase == .interacting || newPhase == .decelerating
            }
            // Read the live phase flag; phase and geometry modifiers have no ordering guarantee.
            // A false boundary sample only updates the reducer baseline and cannot toggle chrome.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, newOffset in
                onScroll(newOffset, scrollIsUserDriven)
            }
            // Hide redundant hovering arrows when footer cards enter view, including programmatic scrolls.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                Self.isFooterVisible(
                    hasNavigation: navigation != nil,
                    contentHeight: geometry.contentSize.height,
                    containerHeight: geometry.containerSize.height,
                    offsetY: geometry.contentOffset.y
                )
            } action: { _, footerVisible in
                onFooterVisible(footerVisible)
            }
            // Lift selected text when actions appear. Dismissal preserves the resulting place;
            // narration uses its own follow-scroll and must not compete with this path.
            .onChange(of: bottomOverlayKind) { oldKind, newKind in
                guard Self.shouldScrollSelectionIntoView(oldKind: oldKind, newKind: newKind),
                      let verse = selectedVerses.min() else { return }
                let animation: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.3)
                withAnimation(animation) {
                    proxy.scrollTo(
                        VerseAnchor(verseNumber: verse),
                        anchor: UnitPoint(x: 0.5, y: 0.35)
                    )
                }
            }
            .onChange(of: currentNarratingVerse) { _, new in
                guard let new, Self.shouldAutoScroll(suppressed: suppressNarrationScroll) else {
                    return
                }
                // A 0.35 anchor clears the nav bar while leaving upcoming text visible.
                let animation: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.35)
                withAnimation(animation) {
                    proxy.scrollTo(
                        VerseAnchor(verseNumber: new),
                        anchor: UnitPoint(x: 0.5, y: 0.35)
                    )
                }
            }
            // task(id:) handles same-chapter links too; consume after scrolling so later navigation cannot replay it.
            .task(id: pendingScrollVerse) {
                guard let target = pendingScrollVerse else { return }
                let animation: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.35)
                withAnimation(animation) {
                    proxy.scrollTo(
                        VerseAnchor(verseNumber: target),
                        anchor: UnitPoint(x: 0.5, y: 0.35)
                    )
                }
                onConsumeScroll()
            }
        }
    }

    private var isChapterGenerating: Bool {
        if case .running = chapterDispatchStatus { return true }
        return false
    }

    @ViewBuilder
    private var chapterTitle: some View {
        let title = Text("\(bookName) \(chapter.number)")
            .font(typography.display(34, relativeTo: .largeTitle))
            .foregroundStyle(theme.ink)
        if onAnnotationBubbleTap != nil || onNoteGlyphTap != nil || onBookmarkTap != nil {
            HStack(alignment: .center, spacing: 14) {
                title
                // Canvas icons have no text baseline; center the cluster.
                HStack(alignment: .center, spacing: 7) {
                    chapterBookmarkGlyph
                    chapterAnnotationBubble
                    chapterNoteGlyph
                }
            }
        } else {
            title
        }
    }

    @ViewBuilder
    private var chapterBookmarkGlyph: some View {
        if let onBookmarkTap {
            let color = chapterBookmark?.color
            let glyphState: BookmarkGlyph.GlyphState =
                color.map { .filled($0) } ?? .outline
            Button {
                onBookmarkTap()
            } label: {
                BookmarkGlyph(state: glyphState, size: 24)
                    // Reach the 44pt tap height without widening the visible icon gap.
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.chapterBookmarkLabel(for: color))
        }
    }

    @ViewBuilder
    private var chapterAnnotationBubble: some View {
        if let onAnnotationBubbleTap {
            let spec = BibleAnnotationTargetSpec.chapter(
                bookId: bookId, chapterNumber: chapter.number
            )
            let state = AnnotationBubble.state(
                hasAnnotation: hasChapterAnnotation, isGenerating: isChapterGenerating
            )
            Button {
                switch state {
                case .filled: onAnnotationBubbleTap(spec)
                case .empty: onRequestChapterAnnotation?(spec)
                case .generating: break
                }
            } label: {
                AnnotationBubble(state: state, size: 24)
                    // Reach the 44pt tap height without widening the visible icon gap.
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Disable empty bubbles without a host to avoid inert controls in previews.
            .disabled(state == .generating || (state == .empty && onRequestChapterAnnotation == nil))
            .accessibilityLabel(Self.chapterBubbleLabel(for: state))
        }
    }

    @ViewBuilder
    private var chapterNoteGlyph: some View {
        if let onNoteGlyphTap {
            let spec = BibleNoteTargetSpec.chapter(
                bookId: bookId, chapterNumber: chapter.number
            )
            let glyphState: NoteGlyph.GlyphState = hasChapterNote ? .filled : .outline
            Button {
                onNoteGlyphTap(spec)
            } label: {
                NoteGlyph(state: glyphState, size: 24)
                    // Reach the 44pt tap height without widening the visible icon gap.
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.chapterNoteGlyphLabel(hasNote: hasChapterNote))
        }
    }

    static func chapterBubbleLabel(for state: AnnotationBubble.BubbleState) -> String {
        switch state {
        case .filled: return "View chapter annotations"
        case .empty: return "Generate chapter annotations"
        case .generating: return "Generating chapter annotations"
        }
    }

    static func chapterNoteGlyphLabel(hasNote: Bool) -> String {
        hasNote ? "View chapter notes" : "Open chapter notes"
    }

    static func chapterBookmarkLabel(for color: BibleBookmarkColor?) -> String {
        guard let color else { return "Bookmark this chapter" }
        return "Chapter bookmarked \(color.displayName) — edit bookmark"
    }

    /// Clears the chat pill and accessory row. Keep this stable while immersive chrome
    /// hides or returns so scroll extent does not jump.
    static let bottomChromeClearance: CGFloat = 160

    /// Includes bottom clearance and footer height so visibility changes as cards enter view.
    static let footerRevealThreshold: CGFloat = bottomChromeClearance + 120

    /// Extra clearance above the floating sheet, in points.
    static let overlayBottomReserve: CGFloat = 100

    /// Reserve host clearance or the active study sheet's height plus margin, keeping the footer reachable.
    static func bottomClearHeight(
        for kind: BibleBottomOverlayKind?,
        layout: BibleChapterReaderLayout = .fullReader
    ) -> CGFloat {
        guard let kind else { return layout.bottomInset }
        return max(layout.bottomInset, kind.estimatedSheetHeight + overlayBottomReserve)
    }

    /// Footer visibility is meaningful only when the host contributes navigation.
    static func isFooterVisible(
        hasNavigation: Bool, contentHeight: CGFloat, containerHeight: CGFloat, offsetY: CGFloat
    ) -> Bool {
        let maxY = contentHeight - containerHeight
        return hasNavigation && maxY > 0 && offsetY >= maxY - footerRevealThreshold
    }

    static func shouldAutoScroll(suppressed: Bool) -> Bool {
        !suppressed
    }

    /// Only nil-to-selection lifts selected text; dismissal preserves place and narration owns its own scroll.
    static func shouldScrollSelectionIntoView(
        oldKind: BibleBottomOverlayKind?,
        newKind: BibleBottomOverlayKind?
    ) -> Bool {
        oldKind == nil && newKind == .selection
    }
}

// Shared by verse words and the reader's scroll proxy.
struct VerseAnchor: Hashable {
    let verseNumber: Int
}
