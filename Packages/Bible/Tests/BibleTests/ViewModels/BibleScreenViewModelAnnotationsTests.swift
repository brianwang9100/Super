import Core
import Foundation
import Testing
@testable import Bible

/// Tests for the annotation surface on `BibleScreenViewModel`:
///
/// - disclaimer-gated `triggerAnnotationGeneration(for:)`
/// - `acknowledgeAnnotationDisclaimer()` / `discardAnnotationDisclaimer()`
/// - sheet presentation toggle
/// - `currentChapterAnnotationSpec` / `selectedAnnotationRanges` derivation
/// - `citationLabel(for:)` formatting
/// - `navigateToDeepLink(_:)` routing
/// - `makeAnnotationReference(_:)` / `annotationVerseText(for:)`
///
/// The wider view model is covered by `BibleScreenViewModelTests`; this
/// suite is annotation-scoped to keep both files readable.
@Suite("BibleScreenViewModel annotations")
@MainActor
struct BibleScreenViewModelAnnotationsTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Strict in-memory disclaimer-store double. Defaults to
    /// unacknowledged so each test can opt into the acknowledged path
    /// via `setAcknowledged(true)` before construction.
    private final class FakeDisclaimerStore: AnnotationDisclaimerStore, @unchecked Sendable {
        private var value: Bool
        init(initial: Bool = false) { self.value = initial }
        var isAcknowledged: Bool { value }
        func setAcknowledged(_ value: Bool) { self.value = value }
    }

    private func makeViewModel(
        disclaimerStore: AnnotationDisclaimerStore = FakeDisclaimerStore(),
        at position: BiblePosition = BiblePosition(bookId: "ROM", chapterNumber: 8),
        textLoader: any BibleTextLoader = BundledBibleTextLoader()
    ) -> BibleScreenViewModel {
        BibleScreenViewModel(
            textLoader: textLoader,
            clock: FixedClock(now),
            idGenerator: DeterministicIDGenerator(),
            disclaimerStore: disclaimerStore,
            initialPosition: position,
            narration: NarrationController(service: FakeNarrationService())
        )
    }

    // MARK: - Sheet presentation

    @Test("presentAnnotationSheet sets the presented target")
    func presentSetsTarget() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        let spec = BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)
        viewModel.presentAnnotationSheet(for: spec)
        #expect(viewModel.presentedAnnotationTarget == spec)
    }

    @Test("dismissAnnotationSheet clears the presented target")
    func dismissClearsTarget() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.presentAnnotationSheet(for: .chapter(bookId: "ROM", chapterNumber: 8))
        viewModel.dismissAnnotationSheet()
        #expect(viewModel.presentedAnnotationTarget == nil)
    }

    // MARK: - Disclaimer gate

    @Test("first triggerAnnotationGeneration call presents the disclaimer and stashes the intent")
    func firstRunGatesOnDisclaimer() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        let spec = BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)
        viewModel.triggerAnnotationGeneration(for: spec)
        #expect(viewModel.isAnnotationDisclaimerPresented)
        #expect(viewModel.pendingAnnotationIntents == [spec])
        // The generation stub (toast) does NOT fire while the disclaimer
        // is up — the queued intent fires on acknowledgement.
        #expect(viewModel.toast == nil)
    }

    @Test("acknowledgeAnnotationDisclaimer persists the flag and replays the pending intent")
    func acknowledgeReplaysPending() async {
        let store = FakeDisclaimerStore()
        let viewModel = makeViewModel(disclaimerStore: store)
        await viewModel.load()
        viewModel.triggerAnnotationGeneration(for: .chapter(bookId: "ROM", chapterNumber: 8))
        viewModel.acknowledgeAnnotationDisclaimer()
        #expect(viewModel.isAnnotationDisclaimerPresented == false)
        #expect(viewModel.pendingAnnotationIntents.isEmpty)
        #expect(store.isAcknowledged == true)
        // Stub generation produces the deferred-dispatch toast.
        #expect(viewModel.toast == "Annotation generation ships in a later update.")
    }

    @Test("multi-range pre-ack intents are all queued and all fire on acknowledgement")
    func multiRangeIntentsAllFire() async {
        let store = FakeDisclaimerStore()
        let viewModel = makeViewModel(disclaimerStore: store)
        await viewModel.load()
        let a = BibleAnnotationTargetSpec.verseRange(bookId: "ROM", chapterNumber: 8, verseStart: 1, verseEnd: 2)
        let b = BibleAnnotationTargetSpec.verseRange(bookId: "ROM", chapterNumber: 8, verseStart: 5, verseEnd: 5)
        viewModel.triggerAnnotationGeneration(for: a)
        viewModel.triggerAnnotationGeneration(for: b)
        // Both queued; disclaimer up; no toast yet.
        #expect(viewModel.pendingAnnotationIntents == [a, b])
        #expect(viewModel.isAnnotationDisclaimerPresented)
        #expect(viewModel.toast == nil)
        viewModel.acknowledgeAnnotationDisclaimer()
        // Both drained; toast reflects the last replay (the stub toast
        // text is identical per spec — both fired, the last one's toast
        // is what the user sees, which is fine).
        #expect(viewModel.pendingAnnotationIntents.isEmpty)
        #expect(viewModel.toast == "Annotation generation ships in a later update.")
    }

    @Test("a second trigger after acknowledgement skips the disclaimer and fires immediately")
    func secondRunSkipsDisclaimer() async {
        let store = FakeDisclaimerStore(initial: true)
        let viewModel = makeViewModel(disclaimerStore: store)
        await viewModel.load()
        viewModel.triggerAnnotationGeneration(for: .chapter(bookId: "ROM", chapterNumber: 8))
        #expect(viewModel.isAnnotationDisclaimerPresented == false)
        #expect(viewModel.pendingAnnotationIntents.isEmpty)
        #expect(viewModel.toast == "Annotation generation ships in a later update.")
    }

    @Test("a generation trigger fired from the action sheet path clears the selection")
    func generationClearsSelection() async {
        // Reproduces the BibleActionSheet "Annotate" tile path: the user
        // has verses selected, taps Annotate, the spec is built from the
        // selection and fired through the gate. After the toast, the
        // action sheet should dismiss (selectedVerses empty) so it
        // doesn't compete with the toast for the bottom edge — matches
        // every other action-sheet action (copy, chat, highlight).
        let store = FakeDisclaimerStore(initial: true)
        let viewModel = makeViewModel(disclaimerStore: store)
        await viewModel.load()
        viewModel.toggleVerse(28)
        viewModel.toggleVerse(29)
        viewModel.toggleVerse(30)
        viewModel.triggerAnnotationGeneration(
            for: .verseRange(bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30)
        )
        #expect(viewModel.selectedVerses.isEmpty)
        #expect(viewModel.toast == "Annotation generation ships in a later update.")
    }

    @Test("discardAnnotationDisclaimer clears the whole queue without acknowledging")
    func discardDoesNotAcknowledge() async {
        let store = FakeDisclaimerStore()
        let viewModel = makeViewModel(disclaimerStore: store)
        await viewModel.load()
        viewModel.triggerAnnotationGeneration(for: .chapter(bookId: "ROM", chapterNumber: 8))
        viewModel.triggerAnnotationGeneration(for: .chapter(bookId: "ROM", chapterNumber: 9))
        viewModel.discardAnnotationDisclaimer()
        #expect(viewModel.isAnnotationDisclaimerPresented == false)
        #expect(viewModel.pendingAnnotationIntents.isEmpty)
        #expect(store.isAcknowledged == false)
        // No queued intent fires — no toast.
        #expect(viewModel.toast == nil)
    }

    // MARK: - Selected ranges

    @Test("empty selection yields no annotation ranges")
    func emptySelectionEmptyRanges() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        #expect(viewModel.selectedAnnotationRanges.isEmpty)
    }

    @Test("a single contiguous selection yields one range")
    func contiguousSelectionOneRange() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.toggleVerse(28)
        viewModel.toggleVerse(29)
        viewModel.toggleVerse(30)
        let ranges = viewModel.selectedAnnotationRanges
        #expect(ranges.count == 1)
        #expect(ranges.first == .verseRange(bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30))
    }

    @Test("a gapped selection yields one range per contiguous run")
    func gappedSelectionMultipleRanges() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.toggleVerse(1)
        viewModel.toggleVerse(2)
        viewModel.toggleVerse(5)
        let ranges = viewModel.selectedAnnotationRanges
        #expect(ranges.count == 2)
        #expect(ranges.contains(.verseRange(bookId: "ROM", chapterNumber: 8, verseStart: 1, verseEnd: 2)))
        #expect(ranges.contains(.verseRange(bookId: "ROM", chapterNumber: 8, verseStart: 5, verseEnd: 5)))
    }

    // MARK: - Current-chapter spec

    @Test("currentChapterAnnotationSpec is the chapter target for the loaded position")
    func currentChapterSpecReflectsPosition() async {
        let viewModel = makeViewModel(at: BiblePosition(bookId: "ROM", chapterNumber: 8))
        await viewModel.load()
        // This is the spark menu's Annotate target when no verses are selected.
        #expect(viewModel.currentChapterAnnotationSpec == .chapter(bookId: "ROM", chapterNumber: 8))
    }

    @Test("currentChapterAnnotationSpec tracks chapter stepping")
    func currentChapterSpecTracksStepping() async {
        let viewModel = makeViewModel(at: BiblePosition(bookId: "ROM", chapterNumber: 8))
        await viewModel.load()
        viewModel.stepChapter(.next)
        #expect(viewModel.currentChapterAnnotationSpec == .chapter(bookId: "ROM", chapterNumber: 9))
    }

    // MARK: - Citation label

    @Test("citationLabel for book uses the book's display name")
    func citationBook() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        #expect(viewModel.citationLabel(for: BibleAnnotationTargetSpec.book(bookId: "ROM")) == "Romans")
    }

    @Test("citationLabel for chapter joins book and chapter")
    func citationChapter() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        #expect(viewModel.citationLabel(for: BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)) == "Romans 8")
    }

    @Test("citationLabel for a multi-verse range uses a dash")
    func citationVerseRange() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        let spec = BibleAnnotationTargetSpec.verseRange(
            bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30
        )
        #expect(viewModel.citationLabel(for: spec) == "Romans 8:28-30")
    }

    @Test("citationLabel for a single-verse range collapses to one number")
    func citationSingleVerse() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        let spec = BibleAnnotationTargetSpec.verseRange(
            bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 28
        )
        #expect(viewModel.citationLabel(for: spec) == "Romans 8:28")
    }

    // MARK: - Navigation

    @Test("navigateToDeepLink moves the reader to the linked range and dismisses the sheet")
    func deepLinkDismissesAndMoves() async {
        let viewModel = makeViewModel(at: BiblePosition(bookId: "1PE", chapterNumber: 2))
        await viewModel.load()
        viewModel.presentAnnotationSheet(for: .chapter(bookId: "1PE", chapterNumber: 2))
        viewModel.navigateToDeepLink(
            BibleDeepLink(bookId: "JHN", chapter: 1, verseStart: 14, verseEnd: 16)
        )
        #expect(viewModel.presentedAnnotationTarget == nil)
        #expect(viewModel.position == BiblePosition(bookId: "JHN", chapterNumber: 1))
        #expect(viewModel.selectedVerses == [14, 15, 16])
    }

    @Test("a single-verse deep link (nil verseEnd) selects exactly that verse")
    func deepLinkSingleVerseFallsBackToStart() async {
        let viewModel = makeViewModel(at: BiblePosition(bookId: "1PE", chapterNumber: 2))
        await viewModel.load()
        // `verseEnd` is nil for a single-verse link (`John 1:14`); the
        // router must fall back to `verseStart` rather than treat the
        // link as chapter-only.
        viewModel.navigateToDeepLink(
            BibleDeepLink(bookId: "JHN", chapter: 1, verseStart: 14)
        )
        #expect(viewModel.position == BiblePosition(bookId: "JHN", chapterNumber: 1))
        #expect(viewModel.selectedVerses == [14])
    }

    @Test("a chapter-only deep link opens the chapter with nothing selected")
    func deepLinkChapterOnlyClearsSelection() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        // A leftover selection in the current chapter must not survive the hop.
        viewModel.toggleVerse(28)
        viewModel.navigateToDeepLink(BibleDeepLink(bookId: "PSA", chapter: 23))
        #expect(viewModel.position == BiblePosition(bookId: "PSA", chapterNumber: 23))
        #expect(viewModel.selectedVerses.isEmpty)
    }

    // MARK: - References built for chat hand-off

    @Test("makeAnnotationReference encodes the record target's citation and snapshot")
    func annotationReferenceCarriesCitation() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        let record = BibleAnnotationRecord(
            id: "rec-1", target: .verse, bookId: "ROM",
            chapterNumber: 8, verseStart: 28, verseEnd: 30,
            summary: "Suffering is the backdrop, not the contradiction.",
            source: .user, modelId: "afm-3.0", createdAt: now
        )
        let reference = viewModel.makeAnnotationReference(record)
        #expect(reference.appletID == "bible")
        #expect(reference.kind == "annotation")
        #expect(reference.sourceID == "rec-1")
        #expect(reference.citation == "Romans 8:28-30")
        #expect(reference.displayLabel == "Romans 8:28-30 annotation")
        // The snapshot is the composer's block: citation heading + summary.
        #expect(reference.snapshot.hasPrefix("## Romans 8:28-30 — annotation"))
        #expect(reference.snapshot.contains("Suffering is the backdrop"))
    }

    @Test("makeAnnotationReference derives a chapter citation from a chapter-target record")
    func annotationReferenceChapterCitation() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        let record = BibleAnnotationRecord(
            id: "rec-2", target: .chapter, bookId: "ROM", chapterNumber: 8,
            summary: "Golden chain.", source: .user, modelId: "m", createdAt: now
        )
        let reference = viewModel.makeAnnotationReference(record)
        #expect(reference.citation == "Romans 8")
        #expect(reference.displayLabel == "Romans 8 annotation")
    }

    @Test("presentDeleteAnnotationFailedToast raises the documented copy")
    func deleteFailedToast() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.presentDeleteAnnotationFailedToast()
        #expect(viewModel.toast == "Couldn't delete the annotation.")
    }

    // MARK: - Verse text quoted above the summary

    @Test("annotationVerseText joins the range's verse texts plainly, without numbers")
    func verseTextJoinsRange() async {
        let viewModel = makeViewModel(textLoader: FixtureBibleTextLoader())
        await viewModel.load()
        let text = viewModel.annotationVerseText(
            for: .verseRange(bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30)
        )
        #expect(text == "All things work together. Whom he foreknew. Whom he justified.")
    }

    @Test("annotationVerseText is nil for chapter and book specs")
    func verseTextNilForWiderScopes() async {
        let viewModel = makeViewModel(textLoader: FixtureBibleTextLoader())
        await viewModel.load()
        #expect(viewModel.annotationVerseText(for: .chapter(bookId: "ROM", chapterNumber: 8)) == nil)
        #expect(viewModel.annotationVerseText(for: .book(bookId: "ROM")) == nil)
    }

    @Test("annotationVerseText is nil when the text fails to load")
    func verseTextNilOnLoadFailure() async {
        let viewModel = makeViewModel(textLoader: ThrowingBibleTextLoader())
        await viewModel.load()
        let text = viewModel.annotationVerseText(
            for: .verseRange(bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30)
        )
        #expect(text == nil)
    }

    @Test("annotationVerseText is nil when the range matches no verses")
    func verseTextNilOnEmptyRange() async {
        let viewModel = makeViewModel(textLoader: FixtureBibleTextLoader())
        await viewModel.load()
        // Verses past the fixture chapter's end — the slice is empty, so the
        // card degrades to summary-only rather than quoting an empty string.
        let text = viewModel.annotationVerseText(
            for: .verseRange(bookId: "ROM", chapterNumber: 8, verseStart: 40, verseEnd: 41)
        )
        #expect(text == nil)
    }
}

/// A `BibleTextLoader` serving one fixed Romans 8 fragment with known verse
/// texts, so `annotationVerseText` assertions are exact rather than coupled
/// to the bundled WEB translation.
private struct FixtureBibleTextLoader: BibleTextLoader {
    func loadChapter(
        bookId: String, chapterNumber: Int, translation: BibleTranslation
    ) throws -> BibleChapter? {
        guard bookId == "ROM", chapterNumber == 8 else { return nil }
        return BibleChapter(number: 8, paragraphs: [
            .heading("More than conquerors"),
            .prose([
                BibleVerse(number: 28, text: "All things work together."),
                BibleVerse(number: 29, text: "Whom he foreknew."),
                BibleVerse(number: 30, text: "Whom he justified."),
            ]),
        ])
    }
}
