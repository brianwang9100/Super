import Core
import GRDBQuery
import SwiftUI

/// The scrolling chapter column: the chapter title, its heading / prose /
/// poetry paragraphs, and the prev / next footer.
///
/// Verse highlights are bound reactively here through GRDBQuery's `@Query`,
/// which observes the chapter's `bibleHighlight` rows: a highlight written
/// from the action sheet — or, later, restored by sync — repaints the verse
/// without this view reloading. `BibleScreen` gives the reader a fresh
/// identity per chapter, so the constant `@Query` request always carries the
/// on-screen position.
struct BibleChapterReader: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query<ChapterHighlightsRequest> private var highlights: [BibleHighlightRecord]

    private let chapter: BibleChapter
    private let bookName: String
    private let selectedVerses: Set<Int>
    private let previousLabel: String?
    private let nextLabel: String?
    private let currentNarratingVerse: Int?
    private let suppressNarrationScroll: Bool
    private let pendingScrollVerse: Int?
    private let bottomOverlayInset: CGFloat
    private let onTapVerse: (Int) -> Void
    private let onPrevious: () -> Void
    private let onNext: () -> Void
    private let onClearSelection: () -> Void
    private let onConsumeScroll: () -> Void

    /// Verse the user was reading just before the action sheet appeared.
    /// Set when the sheet first measures (`bottomOverlayInset` becomes
    /// non-zero) and consumed on dismiss to scroll the reader back to the
    /// same vertical anchor. `nil` while no sheet is up.
    @State private var preSheetSelectedVerse: Int? = nil

    /// - Parameters:
    ///   - bookId: the book whose highlights the `@Query` observes; paired
    ///     with `chapter.number` it scopes the observation to this chapter.
    ///   - currentNarratingVerse: verse currently spoken by the narrator —
    ///     drives the inline underline and the auto-scroll proxy. `nil`
    ///     when narration is idle.
    ///   - suppressNarrationScroll: when `true`, the reader keeps the
    ///     scroll offset stable as the narrator advances. Honored when
    ///     the user has selected verses — the spec disables auto-scroll
    ///     so the reader stays anchored to whatever the user is reading.
    ///   - bottomOverlayInset: extra space appended below the chat-pill
    ///     reserve when an applet-owned bottom overlay (e.g. the verse-
    ///     selection action sheet) is visible. Lets the last verses
    ///     scroll above the overlay instead of falling behind it.
    ///   - onClearSelection: invoked when a tap lands on the column but misses
    ///     every verse word.
    ///   - pendingScrollVerse: verse number to scroll to on appear and on
    ///     subsequent changes. Set by `BibleScreenViewModel.openReference`
    ///     for deep-link navigation; `nil` for normal browsing. The
    ///     reader consumes it once via `onConsumeScroll` so a later
    ///     manual chapter step doesn't re-snap to the old anchor.
    ///   - onConsumeScroll: called after the reader issues the pending
    ///     deep-link scroll so the view model can clear the target.
    init(
        chapter: BibleChapter,
        bookId: String,
        bookName: String,
        selectedVerses: Set<Int>,
        previousLabel: String?,
        nextLabel: String?,
        currentNarratingVerse: Int? = nil,
        suppressNarrationScroll: Bool = false,
        pendingScrollVerse: Int? = nil,
        bottomOverlayInset: CGFloat = 0,
        onTapVerse: @escaping (Int) -> Void,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onClearSelection: @escaping () -> Void,
        onConsumeScroll: @escaping () -> Void = {}
    ) {
        _highlights = Query(constant: ChapterHighlightsRequest(
            bookId: bookId,
            chapterNumber: chapter.number
        ))
        self.chapter = chapter
        self.bookName = bookName
        self.selectedVerses = selectedVerses
        self.previousLabel = previousLabel
        self.nextLabel = nextLabel
        self.currentNarratingVerse = currentNarratingVerse
        self.suppressNarrationScroll = suppressNarrationScroll
        self.pendingScrollVerse = pendingScrollVerse
        self.bottomOverlayInset = bottomOverlayInset
        self.onTapVerse = onTapVerse
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onClearSelection = onClearSelection
        self.onConsumeScroll = onConsumeScroll
    }

    /// Highlight colour keyed by verse number, decoded from the observed rows.
    private var highlightsByVerse: [Int: BibleHighlightColor] {
        var map: [Int: BibleHighlightColor] = [:]
        for record in highlights {
            guard let color = record.color else { continue }
            map[record.verseNumber] = color
        }
        return map
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(bookName) \(chapter.number)")
                        .font(.system(.largeTitle, design: .serif))
                        .italic()
                        .foregroundStyle(theme.ink)
                        .padding(.bottom, 6)

                    let highlightsByVerse = highlightsByVerse
                    let numberedEarlier = VerseTokenizer.priorlyNumberedVerses(chapter.paragraphs)
                    ForEach(Array(chapter.paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        BibleParagraphBlock(
                            paragraph: paragraph,
                            selectedVerses: selectedVerses,
                            highlightedVerses: highlightsByVerse,
                            numberedEarlier: numberedEarlier[index],
                            currentNarratingVerse: currentNarratingVerse,
                            onTapVerse: onTapVerse
                        )
                    }

                    BibleChapterFooter(
                        previousLabel: previousLabel,
                        nextLabel: nextLabel,
                        onPrevious: onPrevious,
                        onNext: onNext
                    )

                    // Bottom inset so the chat overlay's minimized pill doesn't
                    // obscure the footer — mirrors the shell's chat-pill reserve.
                    // `bottomOverlayInset` adds the action sheet's height on top
                    // when verses are selected, letting the last verses scroll
                    // clear of the sheet instead of vanishing behind it.
                    Color.clear.frame(height: Self.chatPillHeight + bottomOverlayInset)
                }
                .padding(.horizontal, 26)
                // Top inset clears the floating nav bar; the bar's gradient
                // fades over the first lines as they scroll up beneath it.
                .padding(.top, 68)
                .frame(maxWidth: .infinity, alignment: .leading)
                // A tap that misses every verse word clears the selection.
                .contentShape(Rectangle())
                .onTapGesture { onClearSelection() }
            }
            // Action-sheet appear / dismiss drives a paired scroll: on show
            // the just-selected verse is brought to `y = 0.35` (a third from
            // top — same anchor narration uses) so the sheet doesn't cover
            // it; on dismiss the reader scrolls back to that same verse at
            // `y = 0.65` (two-thirds down), which approximates the verse's
            // pre-sheet vertical position so the chapter visually returns
            // to where the user was reading.
            .onChange(of: bottomOverlayInset) { oldInset, newInset in
                let animation: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.3)
                switch Self.sheetTransition(oldInset: oldInset, newInset: newInset) {
                case .appearing:
                    guard let verse = selectedVerses.min() else { return }
                    preSheetSelectedVerse = verse
                    withAnimation(animation) {
                        proxy.scrollTo(
                            VerseAnchor(verseNumber: verse),
                            anchor: UnitPoint(x: 0.5, y: 0.35)
                        )
                    }
                case .dismissing:
                    guard let verse = preSheetSelectedVerse else { return }
                    preSheetSelectedVerse = nil
                    withAnimation(animation) {
                        proxy.scrollTo(
                            VerseAnchor(verseNumber: verse),
                            anchor: UnitPoint(x: 0.5, y: 0.65)
                        )
                    }
                case nil:
                    return
                }
            }
            // Keep the restore anchor aligned with the user's *current*
            // first-selected verse: if they extend or shift the selection
            // while the sheet is up, dismiss should return them near the
            // verse they ended on, not the one they started with.
            .onChange(of: selectedVerses) { _, newSelection in
                guard preSheetSelectedVerse != nil, let verse = newSelection.min() else { return }
                preSheetSelectedVerse = verse
            }
            .onChange(of: currentNarratingVerse) { _, new in
                guard let new, Self.shouldAutoScroll(suppressed: suppressNarrationScroll) else {
                    return
                }
                // y=0.35 puts the verse roughly a third from the top —
                // far enough below the floating nav bar to read cleanly,
                // with upcoming text still visible underneath. Honors
                // Reduce Motion via a `nil` animation.
                let animation: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.35)
                withAnimation(animation) {
                    proxy.scrollTo(
                        VerseAnchor(verseNumber: new),
                        anchor: UnitPoint(x: 0.5, y: 0.35)
                    )
                }
            }
            // Deep-link landing: scroll the first selected verse into
            // view. `.task(id:)` runs on first appear AND whenever the
            // target changes, so a same-chapter deep link (already on
            // Romans 8, tap a Romans 8:30 link) still snaps the verse
            // into view even though the reader's `.id(position)` didn't
            // change. The `onConsumeScroll` callback clears the target
            // on the view model so a later manual chapter step doesn't
            // re-trigger.
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

    /// Height of the shell's minimized chat-pill clearance the reader
    /// always reserves at the bottom of its scroll content. Surfaced as a
    /// constant so the screen-level inset math (`actionSheetHeight +
    /// bottomReserve - chatPillHeight`) and the picker sheets'
    /// `bottomInset:` arguments stay locked to the same number — change it
    /// here, not in four places.
    static let chatPillHeight: CGFloat = 76

    /// Decide whether a narration advance should auto-scroll. Factored
    /// out so a unit test can cover the predicate without standing up a
    /// SwiftUI host.
    static func shouldAutoScroll(suppressed: Bool) -> Bool {
        !suppressed
    }

    /// Sheet appear / dismiss is the only `bottomOverlayInset` change that
    /// drives a scroll — a mid-show remeasurement (Dynamic Type rotation,
    /// locale swap) changes the inset between two non-zero values and must
    /// not re-scroll, otherwise the chapter jolts under the user. Factored
    /// out as a pure predicate so a unit test can cover the three branches
    /// without standing up a SwiftUI host.
    static func sheetTransition(oldInset: CGFloat, newInset: CGFloat) -> BibleSheetTransition? {
        if oldInset == 0, newInset > 0 { return .appearing }
        if oldInset > 0, newInset == 0 { return .dismissing }
        return nil
    }
}

/// Classifies a change in the action-sheet inset so the reader knows when
/// to scroll the selected verse into view (`.appearing`) and when to
/// restore the user to their pre-sheet anchor (`.dismissing`). A `nil`
/// return from `BibleChapterReader.sheetTransition(…)` means the inset
/// changed but neither edge was crossed, and no scroll should fire.
enum BibleSheetTransition {
    case appearing
    case dismissing
}

/// Identity tag attached to each verse's first word so
/// `ScrollViewReader.scrollTo` can find it as narration advances. Lives
/// next to the reader since it's an implementation detail of the auto-
/// scroll wiring, not a public type.
struct VerseAnchor: Hashable {
    let verseNumber: Int
}
