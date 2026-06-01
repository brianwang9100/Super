import Core
import Foundation
import Testing
@testable import Bible

/// Tests for the annotation surface on `BibleScreenViewModel`:
///
/// - disclaimer-gated `triggerAnnotationGeneration(for:)`
/// - `acknowledgeAnnotationDisclaimer()` / `discardAnnotationDisclaimer()`
/// - sheet presentation toggle
/// - `selectedAnnotationRanges` contiguous-range derivation
/// - `citationLabel(for:)` formatting
/// - `navigateToVerseReference(_:)` routing
/// - `makeAnnotation{Card,Group}Reference(_:)`
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
        at position: BiblePosition = BiblePosition(bookId: "ROM", chapterNumber: 8)
    ) -> BibleScreenViewModel {
        BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
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

    // MARK: - Citation label

    @Test("citationLabel for book uses the book's display name")
    func citationBook() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        #expect(viewModel.citationLabel(for: .book(bookId: "ROM")) == "Romans")
    }

    @Test("citationLabel for chapter joins book and chapter")
    func citationChapter() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        #expect(viewModel.citationLabel(for: .chapter(bookId: "ROM", chapterNumber: 8)) == "Romans 8")
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

    @Test("navigateToVerseReference moves the reader to the parsed target and dismisses the sheet")
    func navigationDismissesAndMoves() async {
        let viewModel = makeViewModel(at: BiblePosition(bookId: "1PE", chapterNumber: 2))
        await viewModel.load()
        viewModel.presentAnnotationSheet(for: .chapter(bookId: "1PE", chapterNumber: 2))
        viewModel.navigateToVerseReference(
            BibleCitationParser.ParsedCitation(
                position: BiblePosition(bookId: "JHN", chapterNumber: 1),
                verseStart: 14, verseEnd: 14
            )
        )
        #expect(viewModel.presentedAnnotationTarget == nil)
        #expect(viewModel.position == BiblePosition(bookId: "JHN", chapterNumber: 1))
        #expect(viewModel.selectedVerses == [14])
    }

    // MARK: - References built for chat hand-off

    @Test("makeAnnotationCardReference encodes the card target's citation")
    func cardReferenceCarriesCitation() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        let record = BibleAnnotationRecord(
            id: "rec-1", target: .verse, bookId: "ROM",
            chapterNumber: 8, verseStart: 28, verseEnd: 30,
            category: .clarification, title: "In context",
            body: "Suffering is the backdrop, not the contradiction.",
            source: .user, modelId: "afm-3.0", createdAt: now
        )
        let reference = viewModel.makeAnnotationCardReference(record)
        #expect(reference.appletID == "bible")
        #expect(reference.kind == "annotation")
        #expect(reference.sourceID == "rec-1")
        #expect(reference.citation == "Romans 8:28-30")
        #expect(reference.displayLabel == "Romans 8:28-30 annotation")
        #expect(reference.snapshot.contains("Suffering is the backdrop"))
    }

    @Test("makeAnnotationGroupReference returns nil for an empty card list")
    func groupReferenceNilOnEmpty() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        let reference = viewModel.makeAnnotationGroupReference(
            [],
            for: .chapter(bookId: "ROM", chapterNumber: 8)
        )
        #expect(reference == nil)
    }

    @Test("presentDeleteAnnotationFailedToast raises the documented copy")
    func deleteFailedToast() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.presentDeleteAnnotationFailedToast()
        #expect(viewModel.toast == "Couldn't delete the annotation.")
    }

    @Test("makeAnnotationGroupReference joins ids and stamps the count")
    func groupReferenceCarriesCount() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        let records = [
            BibleAnnotationRecord(
                id: "a", target: .chapter, bookId: "ROM", chapterNumber: 8,
                category: .author, title: "Author", body: "Paul.",
                source: .user, modelId: "m", createdAt: now
            ),
            BibleAnnotationRecord(
                id: "b", target: .chapter, bookId: "ROM", chapterNumber: 8,
                category: .summary, title: "Summary", body: "Golden chain.",
                source: .user, modelId: "m", createdAt: now
            ),
        ]
        let reference = viewModel.makeAnnotationGroupReference(
            records,
            for: .chapter(bookId: "ROM", chapterNumber: 8)
        )
        #expect(reference?.kind == "annotationGroup")
        #expect(reference?.sourceID == "a,b")
        #expect(reference?.displayLabel == "Romans 8 annotations (2)")
        #expect(reference?.citation == "Romans 8")
    }
}
