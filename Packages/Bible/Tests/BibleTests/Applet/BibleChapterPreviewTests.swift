import Core
import Foundation
import Testing
@testable import Bible

/// Preview readers isolate navigation while preserving accepted study writes and exact handoffs.
@Suite("Bible chapter preview")
@MainActor
struct BibleChapterPreviewTests {
    private struct AckedDisclaimer: AnnotationDisclaimerStore {
        var isAcknowledged: Bool { true }
        func setAcknowledged(_ value: Bool) {}
    }

    private let link = BibleDeepLink(bookId: "ROM", chapter: 8, verseStart: 28, verseEnd: 30)

    private func source(textLoader: any BibleTextLoader = BundledBibleTextLoader()) -> BibleScreenViewModel {
        BibleScreenViewModel(textLoader: textLoader, disclaimerStore: AckedDisclaimer(),
                             initialTranslation: .web, narration: NarrationController(service: FakeNarrationService()))
    }

    @Test("factory rejects unsupported references without changing the full reader")
    func factoryValidation() {
        let reader = source()
        let applet = BibleApplet(viewModel: reader)
        #expect(applet.recordPreview(for: link.recordReference, onFinish: { _ in }) != nil)
        let invalid = RecordReference(appletID: "bible", kind: "verseRange", sourceID: "ROM/99",
                                  displayLabel: "", citation: "", snapshot: "")
        #expect(applet.recordPreview(for: invalid, onFinish: { _ in }) == nil)
        let internalReference = BibleReaderReference(position: reader.position, translation: .web, selectedVerses: [])
        #expect(applet.recordPreview(for: internalReference.recordReference, onFinish: { _ in }) == nil)
        #expect(reader.position == BibleScreenViewModel.defaultPosition)
    }

    @Test("fresh previews retain full chapter text and captured translation without restoring or saving position")
    func isolatedReader() async throws {
        let database = try BibleDatabase.makeInMemory()
        let repository = GRDBBibleReadingPositionRepository(database: database)
        var history = BibleNavigationHistory(initialPosition: BiblePosition(bookId: "GEN", chapterNumber: 1))
        history.visit(BibleScreenViewModel.defaultPosition)
        history.visit(BiblePosition(bookId: "JHN", chapterNumber: 3))
        history.goBack()
        let saved = BibleReadingPositionRecord(bookId: "1PE", chapterNumber: 2, translationId: "WEB", updatedAt: .distantPast,
                                               navigationHistoryJSON: try BibleNavigationHistoryPayload.encode(history))
        try await repository.save(saved)
        let full = BibleScreenViewModel(textLoader: BundledBibleTextLoader(), positionRepository: repository,
                                       narration: NarrationController(service: FakeNarrationService()))
        await full.load()
        await full._waitForPendingPersist()
        let restored = try #require(try await repository.load())
        #expect(full.canGoBack && full.canGoForward)
        full.toggleVerse(4)
        let reader = full.makePreviewReader(for: link)
        #expect(reader.position == BiblePosition(bookId: "ROM", chapterNumber: 8))
        #expect(reader.translation == .web)
        #expect(reader.chapter?.paragraphs == (try BundledBibleTextLoader().loadChapter(bookId: "ROM", chapterNumber: 8, translation: .web))?.paragraphs)
        #expect(reader.selectedVerses == [28, 29, 30])
        #expect(reader.pendingScrollVerse == 28)
        #expect(!reader.isActionSheetPresented)
        #expect(reader.narration !== full.narration)
        #expect(!reader.isRestoringNavigation)
        #expect(!reader.canGoBack && !reader.canGoForward)
        await reader.load()
        #expect(reader.selectedVerses == [28, 29, 30])
        reader.clearSelection()
        let reopened = full.makePreviewReader(for: link)
        #expect(reopened !== reader)
        #expect(reopened.selectedVerses == [28, 29, 30])
        #expect(full.position == BibleScreenViewModel.defaultPosition)
        #expect(full.selectedVerses == [4])
        await reader._waitForPendingPersist()
        #expect(full.canGoBack && full.canGoForward)
        #expect(try await repository.load() == restored)
    }

    @Test("native readiness is identity guarded and one shot, preserving the scroll request")
    func readiness() {
        let preview = BibleChapterPreviewViewModel(reader: source().makePreviewReader(for: link), onFinish: { _ in })
        preview.presentationDidComplete(identity: UUID())
        #expect(!preview.reader.isActionSheetPresented)
        preview.presentationDidComplete(identity: preview.identity)
        #expect(preview.reader.isActionSheetPresented)
        #expect(preview.reader.pendingScrollVerse == 28)
        preview.reader.dismissActionSheet()
        preview.presentationDidComplete(identity: preview.identity)
        #expect(!preview.reader.isActionSheetPresented)
        preview.reopenActions()
        #expect(preview.reader.isActionSheetPresented)
    }

    @Test("cancelled or unmounted previews cannot present late actions or finish again", arguments: [false, true])
    func cancellation(unmount: Bool) {
        var completions: [RecordPreviewCompletion] = []
        let preview = BibleChapterPreviewViewModel(reader: source().makePreviewReader(for: link), onFinish: { completions.append($0) })
        if unmount { preview.invalidate() } else { preview.cancel() }
        preview.presentationDidComplete(identity: preview.identity)
        preview.reopenActions()
        preview.openInBible()
        #expect(!preview.reader.isActionSheetPresented)
        #expect(completions == (unmount ? [] : [.cancel]))
    }

    @Test("finishing before requested actions mount completes without a native dismissal", arguments: [false, true])
    func finishBeforeActionsMount(open: Bool) {
        var completions: [RecordPreviewCompletion] = []
        let preview = BibleChapterPreviewViewModel(reader: source().makePreviewReader(for: link), onFinish: { completions.append($0) })
        preview.presentationDidComplete(identity: preview.identity)
        #expect(preview.reader.isActionSheetPresented)
        let expected = BibleReaderReference(position: preview.reader.position, translation: preview.reader.translation,
                                            selectedVerses: preview.reader.selectedVerses)

        if open { preview.openInBible() } else { preview.cancel() }

        // SwiftUI may coalesce the request away: neither didPresent nor didDismiss occurs.
        #expect(!preview.reader.isActionSheetPresented)
        #expect(completions == (open ? [.openRecord(reference: expected.recordReference)] : [.cancel]))
        preview.reopenActions()
        preview.presentationDidComplete(identity: preview.identity)
        preview.cancel()
        preview.openInBible()
        #expect(!preview.reader.isActionSheetPresented)
        #expect(completions.count == 1)
    }

    @Test("Open in Bible captures exact current verses and waits for the native study dismissal", arguments: [Set([28, 29]), Set([28, 30]), Set<Int>()])
    func currentSelection(selection: Set<Int>) throws {
        var completions: [RecordPreviewCompletion] = []
        let preview = BibleChapterPreviewViewModel(reader: source().makePreviewReader(for: link), onFinish: { completions.append($0) })
        preview.presentationDidComplete(identity: preview.identity)
        preview.study.didPresent(.bottom, identity: preview.study.identity)
        preview.reader.clearSelection()
        for verse in selection { preview.reader.toggleVerse(verse) }
        preview.openInBible()
        #expect(completions.isEmpty)
        preview.reader.clearSelection()
        preview.study.didDismiss(.bottom, identity: preview.study.identity)
        let expected = BibleReaderReference(position: BiblePosition(bookId: "ROM", chapterNumber: 8), translation: .web, selectedVerses: selection)
        #expect(completions == [.openRecord(reference: expected.recordReference)])
        preview.cancel()
        #expect(completions.count == 1)
    }

    @Test("missing text never presents initial actions but still supports Open in Bible")
    func unavailable() {
        var completion: RecordPreviewCompletion?
        let preview = BibleChapterPreviewViewModel(reader: source(textLoader: ThrowingBibleTextLoader()).makePreviewReader(for: link), onFinish: { completion = $0 })
        preview.presentationDidComplete(identity: preview.identity)
        #expect(preview.reader.chapter == nil)
        #expect(preview.reader.selectedVerses.isEmpty)
        #expect(!preview.reader.isActionSheetPresented)
        preview.openInBible()
        #expect(completion == .openRecord(reference: BibleReaderReference(position: BiblePosition(bookId: "ROM", chapterNumber: 8), translation: .web, selectedVerses: []).recordReference))
    }

    @Test("Add to chat and New chat complete only after the study stack closes", arguments: [false, true])
    func chatHandoff(startNew: Bool) throws {
        var completion: RecordPreviewCompletion?
        let preview = BibleChapterPreviewViewModel(reader: source().makePreviewReader(for: link), onFinish: { completion = $0 })
        preview.presentationDidComplete(identity: preview.identity)
        preview.study.didPresent(.bottom, identity: preview.study.identity)
        let reference = try #require(preview.reader.makeVerseReference())
        preview.addToChat(reference: reference, startNewConversation: startNew)
        #expect(completion == nil)
        preview.study.didDismiss(.bottom, identity: preview.study.identity)
        #expect(completion == .addToChat(reference: reference, startNewConversation: startNew))
    }

    @Test("highlight and note writes target the preview chapter and survive cancellation")
    func acceptedWrites() async throws {
        let database = try BibleDatabase.makeInMemory()
        let highlights = GRDBBibleHighlightRepository(database: database, ids: DeterministicIDGenerator())
        let notes = GRDBBibleNoteRepository(database: database)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let clipboard = FakeClipboard()
        let haptics = RecordingHapticsEngine()
        let full = BibleScreenViewModel(textLoader: BundledBibleTextLoader(), highlightRepository: highlights,
                                       noteRepository: notes, clock: FixedClock(now), clipboard: clipboard,
                                       idGenerator: DeterministicIDGenerator(prefix: "preview-"), hapticsEngine: haptics)
        await full.load()
        let reader = full.makePreviewReader(for: link)
        let preview = BibleChapterPreviewViewModel(reader: reader, onFinish: { _ in })
        reader.applyHighlight(.yellow)
        reader.createNote(target: try #require(reader.selectionNoteSpec), body: "Keep this note")
        reader.copySelection()
        preview.cancel()
        await reader._waitForPendingHighlightWrite()
        await reader._waitForPendingNoteWrite()
        let rows = try await highlights.activeHighlights(bookId: "ROM", chapterNumber: 8)
        #expect(rows.map(\.verseNumber) == [28, 29, 30])
        #expect(rows.allSatisfy { $0.createdAt == now })
        #expect(try await highlights.activeHighlights(bookId: "1PE", chapterNumber: 2).isEmpty)
        let savedNotes = try await notes.list(target: .verse, bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30)
        #expect(savedNotes.count == 1)
        #expect(savedNotes.first?.body == "Keep this note")
        #expect(savedNotes.first?.createdAt == now)
        #expect(savedNotes.first?.id.hasPrefix("preview-") == true)
        #expect(clipboard.lastWritten?.contains("Romans 8:28") == true)
        #expect(haptics.played.contains(.deselection))
        #expect(full.position == BibleScreenViewModel.defaultPosition)
        #expect(full.selectedVerses.isEmpty)
    }

    @Test("preview cancellation preserves shared annotation dispatch and suppresses duplicate requests")
    func sharedAnnotationLifetime() async throws {
        let bus = SuperEventBus()
        let full = source()
        await full.attach(to: bus)
        let preview = BibleChapterPreviewViewModel(reader: full.makePreviewReader(for: link), onFinish: { _ in })
        let target = BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)
        preview.reader.triggerAnnotationGeneration(for: target)
        guard case .running(let requestId) = full.dispatchStatus(for: target) else {
            Issue.record("Preview must use the applet's shared dispatcher")
            return
        }
        preview.invalidate()
        let reopened = full.makePreviewReader(for: link)
        reopened.triggerAnnotationGeneration(for: target)
        #expect(reopened.dispatchStatus(for: target) == .running(requestId: requestId))
        await withCheckedContinuation { continuation in
            full._onNextDispatchCompletion { continuation.resume() }
            Task { await bus.publish(.bibleAnnotateCompleted(requestId: requestId, result: .failure(message: "Retry later"))) }
        }
        #expect(reopened.dispatchStatus(for: target) == .failed(message: "Retry later"))
        #expect(full.dispatchStatus(for: target) == .failed(message: "Retry later"))
    }

    @Test("chapter citations and clipped ranges never manufacture selection", arguments: [
        (BibleDeepLink(bookId: "ROM", chapter: 8), Set<Int>()),
        (BibleDeepLink(bookId: "ROM", chapter: 8, verseStart: 39, verseEnd: Int.max), Set([39])),
        (BibleDeepLink(bookId: "ROM", chapter: 8, verseStart: 40, verseEnd: Int.max), Set<Int>()),
    ])
    func boundedSelection(link: BibleDeepLink, expected: Set<Int>) {
        let preview = BibleChapterPreviewViewModel(reader: source().makePreviewReader(for: link), onFinish: { _ in })
        #expect(preview.reader.selectedVerses == expected)
        #expect(preview.reader.pendingScrollVerse == expected.min())
        preview.presentationDidComplete(identity: preview.identity)
        #expect(preview.reader.isActionSheetPresented == !expected.isEmpty)
    }
}
