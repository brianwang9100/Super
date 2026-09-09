import Core
import Foundation
import Observation

/// Loads bundled chapter text synchronously; reading-position writes are asynchronous.
@MainActor
@Observable
public final class BibleScreenViewModel {
    public static let defaultPosition = BiblePosition(bookId: "1PE", chapterNumber: 2)

    public private(set) var position: BiblePosition
    public private(set) var bookName: String
    public private(set) var chapter: BibleChapter?
    public private(set) var translation: BibleTranslation = .defaultTranslation

    public private(set) var bookSheet: BibleBookSheetViewModel?

    public private(set) var isTranslationSheetPresented = false

    /// Selection survives action-sheet dismissal.
    public private(set) var selectedVerses: Set<Int> = []

    public private(set) var isActionSheetPresented = false

    /// Consumed after deep-link scrolling; also changes for same-chapter links.
    public private(set) var pendingScrollVerse: Int?

    public private(set) var toast: String?

    public private(set) var narration: NarrationController

    /// Whether narration controls are on screen. Dismiss through
    /// ``dismissNarrationSheet()`` to stop playback and downloads together.
    public var isNarrationSheetPresented = false

    public var presentedAnnotationTarget: BibleAnnotationTargetSpec?

    /// During restore, relative navigation is disabled; absolute references and translations queue for reconciliation.
    public private(set) var isRestoringNavigation = true

    public private(set) var navigationPersistenceError: String?

    public var isAnnotationDisclaimerPresented = false

    // Queue every contiguous selection range so later intents cannot overwrite earlier
    // ones during the disclaimer. Acknowledge drains FIFO; dismissal discards all.
    public private(set) var pendingAnnotationIntents: [BibleAnnotationTargetSpec] = []

    /// Shared per-target dispatch state forwarded from the applet-lifetime dispatcher.
    public var dispatchStatusByTarget: [BibleAnnotationTargetSpec: BibleAnnotationDispatchStatus] {
        annotationDispatchViewModel.statusByTargetSnapshot
    }

    /// autoCompose opens the editor as soon as the note list mounts.
    public var presentedNoteList: BibleNoteListPresentation?

    public var presentedBookmarkSheet: BibleBookmarkPresentation?

    private let textLoader: any BibleTextLoader
    private let catalog: BibleBookCatalog
    private let positionRepository: (any BibleReadingPositionRepository)?
    private let highlightRepository: (any BibleHighlightRepository)?
    private let noteRepository: (any BibleNoteRepository)?
    private let bookmarkRepository: (any BibleBookmarkRepository)?
    private let clock: any Clock
    private let clipboard: any ClipboardWriter
    private let idGenerator: any IDGenerator
    private let disclaimerStore: any AnnotationDisclaimerStore
    let annotationDispatchViewModel: BibleAnnotationDispatchViewModel
    private let hapticsEngine: any HapticsEngine
    private let initialPosition: BiblePosition

    private var navigationHistory: BibleNavigationHistory

    private enum QueuedNavigationIntent {
        case reference(bookId: String, chapterNumber: Int, verseStart: Int?, verseEnd: Int?)
        case exactReference(BibleReaderReference)
        case translation(BibleTranslation)
    }

    private var queuedNavigationIntents: [QueuedNavigationIntent] = []
    private var restorationTask: Task<Void, Never>?
    private var restorationGeneration = 0
    private var activeRestorationGeneration: Int?
    private var didCompleteInitialRestore = false
    private var didReadingPositionLoadFail = false
    private var canPersistNavigation = false
    private var provisionalNavigationOccurred = false
    private var latestExplicitTranslation: BibleTranslation?
    private var latestPersistSequence = 0

    private var sidebarSubscriptionTask: Task<Void, Never>?

    private var sidebarDismissCallbacks: [@MainActor () -> Void] = []

    private var persistTask: Task<Void, Never>?

    private var highlightTask: Task<Void, Never>?

    private var noteTask: Task<Void, Never>?

    private var bookmarkTask: Task<Void, Never>?

    /// Nil repositories disable their writes while reading remains available. initialPosition
    /// applies until restore; annotation dispatch state is shared across readers.
    public init(
        textLoader: any BibleTextLoader,
        catalog: BibleBookCatalog = .standard,
        positionRepository: (any BibleReadingPositionRepository)? = nil,
        highlightRepository: (any BibleHighlightRepository)? = nil,
        noteRepository: (any BibleNoteRepository)? = nil,
        bookmarkRepository: (any BibleBookmarkRepository)? = nil,
        clock: any Clock = SystemClock(),
        clipboard: any ClipboardWriter = SystemClipboard(),
        idGenerator: any IDGenerator = UUIDGenerator(),
        disclaimerStore: any AnnotationDisclaimerStore = UserDefaultsAnnotationDisclaimerStore(),
        initialPosition: BiblePosition = BibleScreenViewModel.defaultPosition,
        initialTranslation: BibleTranslation = .defaultTranslation,
        narration: NarrationController? = nil,
        hapticsEngine: any HapticsEngine = NoOpHapticsEngine(),
        annotationDispatchViewModel: BibleAnnotationDispatchViewModel = BibleAnnotationDispatchViewModel()
    ) {
        self.textLoader = textLoader
        self.catalog = catalog
        self.positionRepository = positionRepository
        self.highlightRepository = highlightRepository
        self.noteRepository = noteRepository
        self.bookmarkRepository = bookmarkRepository
        self.clock = clock
        self.clipboard = clipboard
        self.idGenerator = idGenerator
        self.disclaimerStore = disclaimerStore
        self.hapticsEngine = hapticsEngine
        self.initialPosition = initialPosition
        self.navigationHistory = BibleNavigationHistory(initialPosition: initialPosition)
        self.annotationDispatchViewModel = annotationDispatchViewModel
        self.position = initialPosition
        self.translation = initialTranslation
        self.bookName = catalog.book(id: initialPosition.bookId)?.name ?? ""
        self.narration = narration ?? NarrationController(
            service: AVSpeechSynthesizerNarrationService()
        )
    }

    /// Creates an isolated reader with the active translation and shared study services.
    /// Position persistence and narration lifecycle remain exclusive to the full reader.
    func makePreviewReader(for link: BibleDeepLink) -> BibleScreenViewModel {
        let reader = BibleScreenViewModel(
            textLoader: textLoader,
            catalog: catalog,
            positionRepository: nil,
            highlightRepository: highlightRepository,
            noteRepository: noteRepository,
            bookmarkRepository: bookmarkRepository,
            clock: clock,
            clipboard: clipboard,
            idGenerator: idGenerator,
            disclaimerStore: disclaimerStore,
            initialPosition: BiblePosition(bookId: link.bookId, chapterNumber: link.chapter),
            initialTranslation: translation,
            hapticsEngine: hapticsEngine,
            annotationDispatchViewModel: annotationDispatchViewModel
        )
        // This nonpersistent reader has no saved history to restore. Initialize
        // synchronously so selection is ready before its native sheet appears.
        reader.didCompleteInitialRestore = true
        reader.isRestoringNavigation = false
        reader.openReference(bookId: link.bookId, chapterNumber: link.chapter,
                             verseStart: link.verseStart, verseEnd: link.verseEnd)
        // Keep the exact selection and pending scroll, but wait for the native
        // chapter presentation to complete before opening its child action sheet.
        reader.dismissActionSheet()
        return reader
    }

    public var canStepBackward: Bool {
        !isRestoringNavigation && catalog.step(from: position, direction: .previous) != nil
    }

    public var canStepForward: Bool {
        !isRestoringNavigation && catalog.step(from: position, direction: .next) != nil
    }

    public var previousChapterLabel: String? { label(for: .previous) }
    public var nextChapterLabel: String? { label(for: .next) }

    public var canGoBack: Bool { !isRestoringNavigation && navigationHistory.canGoBack }
    public var canGoForward: Bool { !isRestoringNavigation && navigationHistory.canGoForward }

    /// The preceding history destination, or ``nil`` at the start or while restoring.
    public var backDestination: BiblePosition? {
        guard canGoBack else { return nil }
        return navigationHistory.entries[navigationHistory.currentIndex - 1]
    }

    /// The following history destination, or ``nil`` at the end or while restoring.
    public var forwardDestination: BiblePosition? {
        guard canGoForward else { return nil }
        return navigationHistory.entries[navigationHistory.currentIndex + 1]
    }

    /// Concurrent and repeated appearance calls share the first reading-position restore.
    public func load() async {
        if didCompleteInitialRestore {
            await restorationTask?.value
            return
        }
        if let restorationTask {
            await restorationTask.value
            return
        }
        restorationGeneration += 1
        let generation = restorationGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performInitialNavigationRestore()
        }
        activeRestorationGeneration = generation
        restorationTask = task
        await task.value
        clearRestorationTask(ifCurrent: generation)
    }

    /// Stops narration and updates text synchronously, then persists asynchronously.
    /// Crosses book boundaries; no-op at canon edges.
    public func stepChapter(_ direction: BibleChapterDirection) {
        guard !isRestoringNavigation else { return }
        guard let next = catalog.step(from: position, direction: direction) else { return }
        visitChapter(next)
    }

    /// Traverse to the preceding chapter visit without appending history.
    public func goBack() {
        guard !isRestoringNavigation, navigationHistory.goBack() else { return }
        traverseHistory(to: navigationHistory.current)
    }

    /// Traverse to the following chapter visit without appending history.
    public func goForward() {
        guard !isRestoringNavigation, navigationHistory.goForward() else { return }
        traverseHistory(to: navigationHistory.current)
    }

    public func presentBookSheet() {
        guard !isRestoringNavigation else { return }
        bookSheet = BibleBookSheetViewModel(currentPosition: position, catalog: catalog)
    }

    public func dismissBookSheet() {
        bookSheet = nil
    }

    public func presentTranslationSheet() {
        guard !isRestoringNavigation else { return }
        isTranslationSheetPresented = true
    }

    public func dismissTranslationSheet() {
        isTranslationSheetPresented = false
    }

    /// Closes the picker. A changed translation stops narration, reloads text, and persists;
    /// reselecting the current translation only closes.
    public func selectTranslation(_ selected: BibleTranslation) {
        isTranslationSheetPresented = false
        latestExplicitTranslation = selected
        if isRestoringNavigation {
            queuedNavigationIntents.append(.translation(selected))
            return
        }
        applyTranslationSelection(selected)
    }

    private func applyTranslationSelection(_ selected: BibleTranslation) {
        guard selected != translation else { return }
        narration.stop()
        translation = selected
        clearSelection()
        applyCurrentChapter()
        persist()
    }

    /// Unknown books or invalid chapters are a no-op. Valid selection stops narration,
    /// closes the picker, and persists the new position.
    public func selectChapter(bookId: String, chapterNumber: Int) {
        guard !isRestoringNavigation else { return }
        guard let book = catalog.book(id: bookId),
              (1...book.chapterCount).contains(chapterNumber) else { return }
        if didReadingPositionLoadFail { provisionalNavigationOccurred = true }
        let destination = BiblePosition(bookId: bookId, chapterNumber: chapterNumber)
        if destination == position {
            narration.stop()
            clearSelection()
            pendingScrollVerse = nil
            applyCurrentChapter()
            persist()
        } else {
            visitChapter(destination)
        }
        bookSheet = nil
    }

    /// Navigates with an inclusive 1-based verse range. Unknown books, invalid chapters,
    /// nonpositive starts, and inverted ranges are ignored. Nil start opens the chapter
    /// unselected; nil end selects only the start verse.
    public func openReference(bookId: String, chapterNumber: Int, verseStart: Int?, verseEnd: Int?) {
        guard let book = catalog.book(id: bookId),
              (1...book.chapterCount).contains(chapterNumber) else { return }
        if let verseStart, verseStart < 1 { return }
        if let verseStart, let verseEnd, verseEnd < verseStart { return }

        if isRestoringNavigation {
            queuedNavigationIntents.append(.reference(
                bookId: bookId,
                chapterNumber: chapterNumber,
                verseStart: verseStart,
                verseEnd: verseEnd
            ))
            return
        }
        applyReference(
            bookId: bookId,
            chapterNumber: chapterNumber,
            verseStart: verseStart,
            verseEnd: verseEnd
        )
    }

    /// Opens an internal handoff with its captured translation and exact, potentially disjoint selection.
    func openReference(_ reference: BibleReaderReference) {
        guard isValidPosition(reference.position) else { return }
        // Retry snapshots explicit translation before its read. Register the
        // handoff now, including when initial restoration has already failed.
        latestExplicitTranslation = reference.translation
        if isRestoringNavigation {
            queuedNavigationIntents.append(.exactReference(reference))
            return
        }
        applyReference(reference)
    }

    private func applyReference(_ reference: BibleReaderReference) {
        applyReference(position: reference.position, translation: reference.translation) {
            reference.selectedVerses.contains($0)
        }
    }

    private func applyReference(
        bookId: String,
        chapterNumber: Int,
        verseStart: Int?,
        verseEnd: Int?
    ) {
        // Public ranges use the active translation when the queued intent executes.
        applyReference(
            position: BiblePosition(bookId: bookId, chapterNumber: chapterNumber),
            translation: translation
        ) { verse in
            guard let verseStart else { return false }
            return verse >= verseStart && verse <= (verseEnd ?? verseStart)
        }
    }

    private func applyReference(
        position destination: BiblePosition,
        translation targetTranslation: BibleTranslation,
        selectsVerse: (Int) -> Bool
    ) {
        if didReadingPositionLoadFail { provisionalNavigationOccurred = true }

        if destination == position {
            narration.stop()
        } else {
            prepareForChapterTransition()
            navigationHistory.visit(destination)
            position = destination
        }
        translation = targetTranslation
        applyCurrentChapter()
        // Iterate only real chapter verses, bounding both huge ranges and exact sets.
        selectedVerses = Set(verseTextsByNumber().keys.filter(selectsVerse))
        // Changing the pending verse also scrolls same-chapter links; chapter-only navigation leaves it nil.
        pendingScrollVerse = selectedVerses.min()
        isActionSheetPresented = !selectedVerses.isEmpty
        persist()
        bookSheet = nil
    }

    /// Call after issuing the scroll so later navigation cannot replay it.
    public func consumePendingScrollVerse() -> Int? {
        defer { pendingScrollVerse = nil }
        return pendingScrollVerse
    }

    // MARK: - Immersive reading (scroll-driven chrome)

    public private(set) var isImmersive = false

    public private(set) var isChapterFooterVisible = false

    /// Point offset at or above which user scrolling always reveals chrome.
    static let immersiveTopRevealThreshold: CGFloat = 8
    /// Downward travel in points since reversal; ignores small settling jitter.
    static let immersiveHideThreshold: CGFloat = 12
    /// Upward travel in points since reversal needed to reveal chrome.
    static let immersiveRevealThreshold: CGFloat = 8
    static let immersiveMinOffsetToHide: CGFloat = 64

    private var lastScrollOffsetY: CGFloat?
    private var scrollTravelSinceReversal: CGFloat = 0

    /// Programmatic samples only refresh the baseline; user scrolling alone changes
    /// immersive state. Travel resets at reversals so old movement cannot resist a new
    /// direction. Only actual flips notify observers.
    public func updateScroll(offsetY: CGFloat, userDriven: Bool) {
        guard userDriven else {
            lastScrollOffsetY = offsetY
            return
        }
        defer { lastScrollOffsetY = offsetY }

        if offsetY <= Self.immersiveTopRevealThreshold {
            scrollTravelSinceReversal = 0
            setImmersive(false)
            return
        }

        guard let last = lastScrollOffsetY else { return }
        let delta = offsetY - last
        guard delta != 0 else { return }

        if (delta > 0) != (scrollTravelSinceReversal > 0) {
            scrollTravelSinceReversal = 0
        }
        scrollTravelSinceReversal += delta

        if scrollTravelSinceReversal >= Self.immersiveHideThreshold,
           offsetY > Self.immersiveMinOffsetToHide {
            setImmersive(true)
        } else if scrollTravelSinceReversal <= -Self.immersiveRevealThreshold {
            setImmersive(false)
        }
    }

    /// Restores chrome and clears scroll/footer state when leaving or changing chapters.
    public func resetImmersive() {
        scrollTravelSinceReversal = 0
        lastScrollOffsetY = nil
        setImmersive(false)
        updateFooterVisibility(false)
    }

    public func updateFooterVisibility(_ visible: Bool) {
        guard isChapterFooterVisible != visible else { return }
        isChapterFooterVisible = visible
    }

    private func setImmersive(_ value: Bool) {
        guard isImmersive != value else { return }
        isImmersive = value
    }

    /// First selection opens actions; subsequent taps preserve visibility until selection empties.
    public func toggleVerse(_ number: Int) {
        let startsSelection = selectedVerses.isEmpty
        if selectedVerses.contains(number) {
            selectedVerses.remove(number)
            hapticsEngine.play(.deselection)
        } else {
            selectedVerses.insert(number)
            hapticsEngine.play(.selection)
        }
        if selectedVerses.isEmpty {
            dismissActionSheet()
        } else if startsSelection {
            isActionSheetPresented = true
        }
    }

    /// Reopens without changing selection; stops and replaces narration controls.
    public func presentActionSheet() {
        guard !selectedVerses.isEmpty else { return }
        dismissNarrationSheet()
        isActionSheetPresented = true
    }

    /// Keeps selected verses.
    public func dismissActionSheet() {
        isActionSheetPresented = false
    }

    public func clearSelection() {
        dismissActionSheet()
        guard !selectedVerses.isEmpty else { return }
        selectedVerses.removeAll()
        hapticsEngine.play(.deselection)
    }

    public var selectionCitation: String? {
        let verses = selectedVerses.sorted()
        guard !verses.isEmpty else { return nil }
        return BibleCitationFormatter.cite(
            bookName: bookName, chapterNumber: position.chapterNumber, verses: verses
        )
    }

    /// Text followed by citation; nil without selected, available text.
    public var selectionShareText: String? {
        let verses = selectedVerses.sorted()
        guard !verses.isEmpty else { return nil }
        let texts = verseTextsByNumber()
        let body = verses.compactMap { texts[$0] }.joined(separator: " ")
        guard !body.isEmpty else { return nil }
        let citation = BibleCitationFormatter.cite(
            bookName: bookName, chapterNumber: position.chapterNumber, verses: verses
        )
        return "\(body)\n— \(citation) (\(translation.rawValue))"
    }

    /// Copies then clears selection.
    public func copySelection() {
        guard let text = selectionShareText else { return }
        clipboard.write(text)
        clearSelection()
    }

    /// Clears if every selected verse already has this color; otherwise colors them all.
    /// Keeps selection/actions open. No-op without storage or selection.
    public func applyHighlight(_ color: BibleHighlightColor) {
        writeHighlights(failureMessage: "Couldn't save the highlight.") {
            repository, verses, bookId, chapterNumber, now in
            let current = try await repository.activeHighlightColors(
                bookId: bookId, chapterNumber: chapterNumber, verseNumbers: verses
            )
            let clearing = verses.allSatisfy { current[$0] == color }
            for verse in verses {
                if clearing {
                    try await repository.clearHighlight(
                        bookId: bookId, chapterNumber: chapterNumber, verseNumber: verse, at: now
                    )
                } else {
                    try await repository.setHighlight(
                        bookId: bookId, chapterNumber: chapterNumber, verseNumber: verse,
                        color: color, at: now
                    )
                }
            }
        }
    }

    /// Clears persisted highlights while retaining selection/actions.
    public func clearHighlight() {
        writeHighlights(failureMessage: "Couldn't clear the highlight.") {
            repository, verses, bookId, chapterNumber, now in
            for verse in verses {
                try await repository.clearHighlight(
                    bookId: bookId, chapterNumber: chapterNumber, verseNumber: verse, at: now
                )
            }
        }
    }

    // Serialize mutations and report asynchronous failures so unchanged query results
    // cannot silently look like successful writes.
    private func writeHighlights(
        failureMessage: String,
        _ mutate: @escaping @Sendable (
            any BibleHighlightRepository, [Int], String, Int, Date
        ) async throws -> Void
    ) {
        guard let highlightRepository, !selectedVerses.isEmpty else { return }
        let verses = selectedVerses.sorted()
        let bookId = position.bookId
        let chapterNumber = position.chapterNumber
        let now = clock.now()
        let previous = highlightTask
        highlightTask = Task { [weak self] in
            await previous?.value
            do {
                try await mutate(highlightRepository, verses, bookId, chapterNumber, now)
            } catch {
                self?.toast = failureMessage
            }
        }
    }

    /// Captures translation, citation, and verbatim text for Chat. Nil without usable selection;
    /// the screen publishes the returned reference.
    public func makeVerseReference() -> RecordReference? {
        let verses = selectedVerses.sorted()
        guard !verses.isEmpty else { return nil }
        let texts = verseTextsByNumber()
        let snapshot = verses.compactMap { texts[$0] }.joined(separator: " ")
        guard !snapshot.isEmpty else { return nil }
        let citation = BibleCitationFormatter.cite(
            bookName: bookName, chapterNumber: position.chapterNumber, verses: verses
        )
        let label = "\(citation) (\(translation.rawValue))"
        return RecordReference(
            appletID: BibleApplet.appletID,
            kind: "verseRange",
            sourceID: "\(translation.rawValue)/\(position.bookId)/\(position.chapterNumber)/"
                + verses.map(String.init).joined(separator: ","),
            displayLabel: label,
            citation: label,
            snapshot: snapshot,
            id: idGenerator.nextID()
        )
    }

    public func presentChatComingSoon() {
        toast = "Chat integration ships in a later update."
        clearSelection()
    }

    /// Captures the chapter using verseRange encoding with every present verse number,
    /// preserving compatibility with the Chat receiver.
    public func makeChapterReference() -> RecordReference? {
        guard let chapter, !chapter.paragraphs.isEmpty else { return nil }
        let texts = verseTextsByNumber()
        let verses = texts.keys.sorted()
        guard !verses.isEmpty else { return nil }
        let snapshot = verses.compactMap { texts[$0] }.joined(separator: " ")
        guard !snapshot.isEmpty else { return nil }
        let citation = "\(bookName) \(chapter.number) (\(translation.rawValue))"
        return RecordReference(
            appletID: BibleApplet.appletID,
            kind: "verseRange",
            sourceID: "\(translation.rawValue)/\(position.bookId)/\(chapter.number)/"
                + verses.map(String.init).joined(separator: ","),
            displayLabel: citation,
            citation: citation,
            snapshot: snapshot,
            id: idGenerator.nextID()
        )
    }

    // MARK: - Annotations

    /// Viewing existing annotations does not require generation acknowledgement.
    public func presentAnnotationSheet(for spec: BibleAnnotationTargetSpec) {
        presentedAnnotationTarget = spec
    }

    public func dismissAnnotationSheet() {
        presentedAnnotationTarget = nil
    }

    /// Before first acknowledgement, queues every intent behind the disclaimer;
    /// subsequent triggers dispatch immediately.
    public func triggerAnnotationGeneration(for spec: BibleAnnotationTargetSpec) {
        guard disclaimerStore.isAcknowledged else {
            pendingAnnotationIntents.append(spec)
            isAnnotationDisclaimerPresented = true
            return
        }
        performAnnotationGeneration(for: spec)
    }

    /// Persists acknowledgement and drains all queued intents in FIFO order.
    public func acknowledgeAnnotationDisclaimer() {
        disclaimerStore.setAcknowledged(true)
        isAnnotationDisclaimerPresented = false
        let queue = pendingAnnotationIntents
        pendingAnnotationIntents.removeAll()
        for spec in queue {
            performAnnotationGeneration(for: spec)
        }
    }

    /// Discards the queue without acknowledgement; the next trigger asks again.
    public func discardAnnotationDisclaimer() {
        isAnnotationDisclaimerPresented = false
        pendingAnnotationIntents.removeAll()
    }

    /// Dismisses annotations and follows the same selection/scroll path as external links.
    public func navigateToDeepLink(_ link: BibleDeepLink) {
        presentedAnnotationTarget = nil
        openReference(
            bookId: link.bookId,
            chapterNumber: link.chapter,
            verseStart: link.verseStart,
            verseEnd: link.verseEnd ?? link.verseStart
        )
    }

    /// Uses a fresh request ID so stale completions cannot affect this attempt.
    /// Preserve selection to avoid dismissing and re-presenting the sheet during retry.
    public func retryAnnotationGeneration(for spec: BibleAnnotationTargetSpec) {
        publishDispatchRequest(for: spec)
    }

    // Reference.id correlates completion; routing fields cross the applet boundary without Bible imports.
    private func makeAnnotateRequestReference(for spec: BibleAnnotationTargetSpec) -> RecordReference {
        let citation = citationLabel(for: spec)
        let kind: String
        switch spec {
        case .book: kind = "book"
        case .chapter: kind = "chapter"
        case .verseRange: kind = "verseRange"
        }
        return RecordReference(
            appletID: BibleApplet.appletID,
            kind: kind,
            sourceID: spec.id,
            displayLabel: citation,
            citation: "\(citation) (\(translation.rawValue))",
            snapshot: snapshotText(for: spec),
            id: idGenerator.nextID()
        )
    }

    // Omit whole-book text to bound prompt size; chapter/range snapshots ground generation
    // in the selected translation. Unavailable text degrades to citation-only input.
    private func snapshotText(for spec: BibleAnnotationTargetSpec) -> String {
        BibleVerseTextFormatter.numbered(verses(for: spec))
    }

    private func verses(for spec: BibleAnnotationTargetSpec) -> [BibleVerse] {
        guard let chapterNumber = spec.chapterNumber,
              let chapter = (try? textLoader.loadChapter(
                  bookId: spec.bookId, chapterNumber: chapterNumber, translation: translation
              )) ?? nil else { return [] }
        let verses = chapter.coalescedVerses()
        guard let start = spec.verseStart, let end = spec.verseEnd else { return verses }
        return verses.filter { $0.number >= start && $0.number <= end }
    }

    private func performAnnotationGeneration(for spec: BibleAnnotationTargetSpec) {
        clearSelection()
        publishDispatchRequest(for: spec)
    }

    /// Forward a request into the shared dispatcher while retaining this reader's presentation.
    private func publishDispatchRequest(for spec: BibleAnnotationTargetSpec) {
        if case .running = annotationDispatchViewModel.status(for: spec) {
            presentedAnnotationTarget = spec
            return
        }
        let reference = makeAnnotateRequestReference(for: spec)
        switch annotationDispatchViewModel.request(reference: reference, for: spec) {
        case .started, .alreadyRunning:
            presentedAnnotationTarget = spec
        case .unavailable:
            toast = "Annotation generation ships in a later update."
        }
    }

    /// Attach the shared dispatcher and this reader's independent sidebar subscriber.
    public func attach(to bus: SuperEventBus) async {
        await annotationDispatchViewModel.attach(to: bus)
        await attachSidebar(to: bus)
    }

    func attachSidebar(to bus: SuperEventBus) async {
        guard sidebarSubscriptionTask == nil else { return }
        let stream = await bus.events()
        sidebarSubscriptionTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                guard case .sidebarOpened = event else { continue }
                self.dismissPresentedSheets()
                let callbacks = self.sidebarDismissCallbacks
                self.sidebarDismissCallbacks.removeAll()
                for callback in callbacks { callback() }
            }
        }
    }

    /// Native sheets cover the shell drawer. Preserve the disclaimer, whose dismissal would discard queued intents.
    private func dismissPresentedSheets() {
        dismissActionSheet()
        dismissNarrationSheet()
        dismissBookSheet()
        dismissTranslationSheet()
        dismissAnnotationSheet()
        dismissNoteList()
    }

    /// Fires once after processing sidebarOpened and dismissing sheets.
    func _onNextSidebarDismiss(_ callback: @escaping @MainActor () -> Void) {
        sidebarDismissCallbacks.append(callback)
    }

    /// Fires after completion state updates; request echoes cannot satisfy this test seam.
    func _onNextDispatchCompletion(_ callback: @escaping @MainActor () -> Void) {
        annotationDispatchViewModel._onNextCompletionProcessed(callback)
    }

    /// Fires once after processing the next progress envelope.
    func _onNextDispatchProgress(_ callback: @escaping @MainActor () -> Void) {
        annotationDispatchViewModel._onNextProgressProcessed(callback)
    }

    /// Current accumulated text for the target, including a completed query bridge.
    public func annotationDraft(for spec: BibleAnnotationTargetSpec) -> BibleAnnotationDraft? {
        annotationDispatchViewModel.draft(for: spec)
    }

    /// Clears only a matching settled request after query acknowledgement, deletion,
    /// or an explicit return to the saved response. Late callbacks cannot erase retries.
    public func clearAnnotationDraft(for spec: BibleAnnotationTargetSpec, requestID: String) {
        annotationDispatchViewModel.clearDraft(for: spec, requestID: requestID)
    }

    /// Nil when no dispatch is running or failed for this target.
    public func dispatchStatus(for spec: BibleAnnotationTargetSpec) -> BibleAnnotationDispatchStatus? {
        annotationDispatchViewModel.status(for: spec)
    }

    public func presentDeleteAnnotationFailedToast() {
        toast = "Couldn't delete the annotation."
    }

    /// Clears failed status without discarding its draft; running requests remain intact.
    /// The study UI uses request-scoped ``clearAnnotationDraft(for:requestID:)``.
    public func clearFailedDispatchStatus(for spec: BibleAnnotationTargetSpec) {
        annotationDispatchViewModel.clearFailure(for: spec)
    }

    public func citationLabel(for spec: BibleAnnotationTargetSpec) -> String {
        let bookName = catalog.book(id: spec.bookId)?.name ?? spec.bookId
        switch spec {
        case .book:
            return bookName
        case .chapter(_, let chapterNumber):
            return "\(bookName) \(chapterNumber)"
        case .verseRange(_, let chapterNumber, let verseStart, let verseEnd):
            if verseStart == verseEnd {
                return "\(bookName) \(chapterNumber):\(verseStart)"
            }
            return "\(bookName) \(chapterNumber):\(verseStart)-\(verseEnd)"
        }
    }

    public var currentChapterAnnotationSpec: BibleAnnotationTargetSpec {
        .chapter(bookId: position.bookId, chapterNumber: position.chapterNumber)
    }

    /// One target per contiguous selection run, e.g. 1,2,5 becomes 1-2 and 5-5.
    public var selectedAnnotationRanges: [BibleAnnotationTargetSpec] {
        let verses = selectedVerses.sorted()
        guard !verses.isEmpty else { return [] }
        var ranges: [(Int, Int)] = []
        var start = verses[0]
        var previous = verses[0]
        for verse in verses.dropFirst() {
            if verse == previous + 1 {
                previous = verse
            } else {
                ranges.append((start, previous))
                start = verse
                previous = verse
            }
        }
        ranges.append((start, previous))
        return ranges.map { range in
            .verseRange(
                bookId: position.bookId,
                chapterNumber: position.chapterNumber,
                verseStart: range.0,
                verseEnd: range.1
            )
        }
    }

    public func makeAnnotationReference(_ record: BibleAnnotationRecord) -> RecordReference {
        let spec = targetSpec(for: record)
        let citation = citationLabel(for: spec)
        return RecordReference(
            appletID: BibleApplet.appletID,
            kind: "annotation",
            sourceID: record.id,
            displayLabel: "\(citation) annotation",
            citation: citation,
            snapshot: AnnotationSnapshotComposer.compose(annotation: record, citation: citation),
            id: idGenerator.nextID()
        )
    }

    /// Dismisses the annotation sheet and returns a reference for the screen to publish.
    public func addAnnotationToChat(_ record: BibleAnnotationRecord) -> RecordReference {
        let reference = makeAnnotationReference(record)
        dismissAnnotationSheet()
        return reference
    }

    /// Quotes only verse ranges using the current translation; records store none.
    /// Nil for other targets or missing text. Memoize by target/translation to avoid
    /// repeated synchronous decoding during sheet-body evaluation; cache writes must
    /// not themselves notify observers.
    public func annotationVerseText(for spec: BibleAnnotationTargetSpec) -> String? {
        guard spec.verseStart != nil, spec.verseEnd != nil else { return nil }
        let key = "\(spec.id)|\(translation.rawValue)"
        if let cached = annotationVerseTextCache, cached.key == key {
            return cached.text
        }
        let selected = verses(for: spec)
        let text = selected.isEmpty ? nil : BibleVerseTextFormatter.plain(selected)
        annotationVerseTextCache = (key, text)
        return text
    }

    @ObservationIgnored private var annotationVerseTextCache: (key: String, text: String?)?

    // Missing required positions indicate malformed persisted records. Fail rather than
    // fabricate verse/chapter zero and navigate to the wrong target.
    private func targetSpec(for record: BibleAnnotationRecord) -> BibleAnnotationTargetSpec {
        switch record.target {
        case .book:
            return .book(bookId: record.bookId)
        case .chapter:
            guard let chapterNumber = record.chapterNumber else {
                preconditionFailure(
                    "chapter-target record \(record.id) has nil chapterNumber — schema constraint violated"
                )
            }
            return .chapter(bookId: record.bookId, chapterNumber: chapterNumber)
        case .verse:
            guard let chapterNumber = record.chapterNumber,
                  let verseStart = record.verseStart,
                  let verseEnd = record.verseEnd else {
                preconditionFailure(
                    "verse-target record \(record.id) has nil chapter/verse columns — schema constraint violated"
                )
            }
            return .verseRange(
                bookId: record.bookId,
                chapterNumber: chapterNumber,
                verseStart: verseStart,
                verseEnd: verseEnd
            )
        }
    }

    // MARK: - Notes

    /// Opens the list even when empty; glyph taps do not auto-compose.
    public func presentNoteList(for spec: BibleNoteTargetSpec) {
        presentedNoteList = BibleNoteListPresentation(spec: spec, autoCompose: false)
    }

    /// Opens create mode over the list so saving returns to the populated list.
    public func composeNote(for spec: BibleNoteTargetSpec) {
        presentedNoteList = BibleNoteListPresentation(spec: spec, autoCompose: true)
    }

    /// Uses the selection's bounding span, including gaps, then clears selection.
    /// Unlike annotation generation, a note is one free-text response to the whole passage.
    public func composeNoteForSelection() {
        guard let spec = selectionNoteSpec else { return }
        clearSelection()
        composeNote(for: spec)
    }

    /// Captures the bounding span without side effects so the sheet can dismiss before composing.
    public var selectionNoteSpec: BibleNoteTargetSpec? {
        let verses = selectedVerses.sorted()
        guard let first = verses.first, let last = verses.last else { return nil }
        return .verseRange(
            bookId: position.bookId,
            chapterNumber: position.chapterNumber,
            verseStart: first,
            verseEnd: last
        )
    }

    public func dismissNoteList() {
        presentedNoteList = nil
    }

    /// Trims text, ignores blanks, and writes asynchronously; no-op without storage.
    public func createNote(target spec: BibleNoteTargetSpec, body: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = clock.now()
        let record = BibleNoteRecord(
            id: idGenerator.nextID(),
            target: spec.target,
            bookId: spec.bookId,
            chapterNumber: spec.chapterNumber,
            verseStart: spec.verseStart,
            verseEnd: spec.verseEnd,
            body: trimmed,
            source: .user,
            modelId: nil,
            createdAt: now,
            updatedAt: now
        )
        writeNote(failureMessage: "Couldn't save the note.") { repository in
            try await repository.insert(record)
        }
    }

    /// Trims text and ignores blanks; stamps a fresh updatedAt.
    public func updateNote(id: String, body: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = clock.now()
        writeNote(failureMessage: "Couldn't save the note.") { repository in
            try await repository.update(id: id, body: trimmed, updatedAt: now)
        }
    }

    public func deleteNote(id: String) {
        writeNote(failureMessage: "Couldn't delete the note.") { repository in
            try await repository.deleteOne(id: id)
        }
    }

    // Chain rapid writes in issue order and expose a toast on failure. Awaiting the
    // latest task drains every earlier mutation.
    private func writeNote(
        failureMessage: String,
        _ mutate: @escaping @Sendable (any BibleNoteRepository) async throws -> Void
    ) {
        guard let noteRepository else { return }
        let previous = noteTask
        noteTask = Task { [weak self] in
            await previous?.value
            do {
                try await mutate(noteRepository)
            } catch {
                self?.toast = failureMessage
            }
        }
    }

    // MARK: - Bookmarks

    /// Captures this chapter/citation and clears selection. With actions open, the screen
    /// must defer this presentation until their dismissal completes.
    public func presentBookmarkSheet() {
        clearSelection()
        presentedBookmarkSheet = BibleBookmarkPresentation(
            bookId: position.bookId,
            chapterNumber: position.chapterNumber,
            citation: chapterCitation(bookId: position.bookId, chapterNumber: position.chapterNumber)
        )
    }

    public func chapterCitation(bookId: String, chapterNumber: Int) -> String {
        let name = catalog.book(id: bookId)?.name ?? bookId
        return "\(name) \(chapterNumber)"
    }

    public func dismissBookmarkSheet() {
        presentedBookmarkSheet = nil
    }

    /// Uses the presented chapter, not current navigation. No-op without a sheet or store.
    public func toggleBookmark(color: BibleBookmarkColor) {
        guard let presentation = presentedBookmarkSheet,
              let bookmarkRepository else { return }
        let now = clock.now()
        let previous = bookmarkTask
        bookmarkTask = Task { [weak self] in
            await previous?.value
            do {
                try await bookmarkRepository.toggle(
                    color: color,
                    bookId: presentation.bookId,
                    chapterNumber: presentation.chapterNumber,
                    at: now
                )
            } catch {
                self?.toast = "Couldn't update the bookmark."
            }
        }
    }

    public func citationLabel(for spec: BibleNoteTargetSpec) -> String {
        let bookName = catalog.book(id: spec.bookId)?.name ?? spec.bookId
        switch spec {
        case .book:
            return bookName
        case .chapter(_, let chapterNumber):
            return "\(bookName) \(chapterNumber)"
        case .verseRange(_, let chapterNumber, let verseStart, let verseEnd):
            if verseStart == verseEnd {
                return "\(bookName) \(chapterNumber):\(verseStart)"
            }
            return "\(bookName) \(chapterNumber):\(verseStart)-\(verseEnd)"
        }
    }

    /// Drains all note writes queued so far.
    public func _waitForPendingNoteWrite() async {
        await noteTask?.value
    }

    /// Drains all bookmark toggles queued so far.
    public func _waitForPendingBookmarkWrite() async {
        await bookmarkTask?.value
    }

    // MARK: - Narration

    /// Narrates the selection or whole chapter and opens transport. No-op without text;
    /// preserves the chosen voice.
    public func startNarration() {
        let utterances = narrationUtterances()
        guard !utterances.isEmpty else { return }
        isNarrationSheetPresented = true
        narration.start(utterances: utterances)
    }

    /// Installs the composition root's optional cloud narration before the reader is presented.
    public func installNarration(_ controller: NarrationController) {
        narration.stop()
        narration = controller
    }

    public func presentNarrationSheet() {
        isNarrationSheetPresented = true
    }

    /// Closing narration also cancels playback and speculative downloads.
    public func dismissNarrationSheet() {
        narration.stop()
        isNarrationSheetPresented = false
    }

    public var narrationCitation: String? {
        guard let verse = narration.currentVerseNumber else { return nil }
        return "\(bookName) \(position.chapterNumber):\(verse)"
    }

    private func narrationUtterances() -> [NarrationVerseUtterance] {
        let texts = verseTextsByNumber()
        guard !texts.isEmpty else { return [] }
        let verses: [Int]
        if selectedVerses.isEmpty {
            verses = texts.keys.sorted()
        } else {
            verses = selectedVerses.sorted()
        }
        return verses.compactMap { number in
            guard let text = texts[number] else { return nil }
            return NarrationVerseUtterance(verseNumber: number, text: text)
        }
    }

    public func dismissToast() {
        toast = nil
    }

    private func verseTextsByNumber() -> [Int: String] {
        guard let chapter else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: chapter.coalescedVerses().map { ($0.number, $0.text) }
        )
    }

    /// Drains all reading-position writes queued so far.
    public func _waitForPendingPersist() async {
        await persistTask?.value
    }

    /// Flushes the newest complete navigation snapshot after any pending restore.
    public func flushNavigationPersistence() async {
        if !didCompleteInitialRestore {
            await load()
        } else {
            await restorationTask?.value
        }
        persist()
        await persistTask?.value
    }

    /// Retry a failed restore read, or retry the latest complete snapshot
    /// after a write failure. Concurrent restore retries share one read.
    public func retryNavigationPersistence() async {
        if isRestoringNavigation {
            await restorationTask?.value
            return
        }
        guard didReadingPositionLoadFail else {
            persist()
            await persistTask?.value
            return
        }
        restorationGeneration += 1
        let generation = restorationGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRetryNavigationRestore()
        }
        isRestoringNavigation = true
        activeRestorationGeneration = generation
        restorationTask = task
        await task.value
        clearRestorationTask(ifCurrent: generation)
    }

    /// Read failures keep their only recovery action visible until restoration succeeds.
    public var canDismissNavigationPersistenceError: Bool { !didReadingPositionLoadFail }

    /// Dismiss a save error; unresolved read failures retain their Retry affordance.
    public func dismissNavigationPersistenceError() {
        guard canDismissNavigationPersistenceError else { return }
        navigationPersistenceError = nil
    }

    /// Drains all highlight writes queued so far.
    public func _waitForPendingHighlightWrite() async {
        await highlightTask?.value
    }

    private func applyCurrentChapter() {
        // Catalog metadata keeps navigation usable when chapter text cannot load.
        bookName = catalog.book(id: position.bookId)?.name ?? bookName
        chapter = (try? textLoader.loadChapter(
            bookId: position.bookId,
            chapterNumber: position.chapterNumber,
            translation: translation
        )) ?? nil
    }

    private func label(for direction: BibleChapterDirection) -> String? {
        guard let next = catalog.step(from: position, direction: direction),
              let book = catalog.book(id: next.bookId) else { return nil }
        return "\(book.name) \(next.chapterNumber)"
    }

    private func performInitialNavigationRestore() async {
        guard let positionRepository else {
            applyCurrentChapter()
            didCompleteInitialRestore = true
            isRestoringNavigation = false
            drainQueuedNavigationIntents()
            return
        }

        do {
            let saved = try await positionRepository.load()
            applyRestoredRecord(saved)
            canPersistNavigation = true
            didReadingPositionLoadFail = false
            navigationPersistenceError = nil
        } catch {
            navigationHistory = BibleNavigationHistory(initialPosition: initialPosition)
            position = initialPosition
            translation = .defaultTranslation
            applyCurrentChapter()
            canPersistNavigation = false
            didReadingPositionLoadFail = true
            navigationPersistenceError = "Couldn't restore reading history."
        }

        didCompleteInitialRestore = true
        isRestoringNavigation = false
        drainQueuedNavigationIntents()
        persist()
    }

    private func performRetryNavigationRestore() async {
        guard let positionRepository else {
            isRestoringNavigation = false
            return
        }
        let sessionPosition = position
        let shouldAppendSessionPosition = provisionalNavigationOccurred
        let explicitTranslation = latestExplicitTranslation

        do {
            let saved = try await positionRepository.load()
            prepareForChapterTransition()
            applyRestoredRecord(saved)
            if shouldAppendSessionPosition {
                navigationHistory.visit(sessionPosition)
                position = sessionPosition
                applyCurrentChapter()
            }
            if let explicitTranslation {
                translation = explicitTranslation
                applyCurrentChapter()
            }
            canPersistNavigation = true
            didReadingPositionLoadFail = false
            provisionalNavigationOccurred = false
            latestExplicitTranslation = nil
            navigationPersistenceError = nil
        } catch {
            navigationPersistenceError = "Couldn't restore reading history."
        }

        isRestoringNavigation = false
        drainQueuedNavigationIntents()
        persist()
        await persistTask?.value
    }

    private func applyRestoredRecord(_ saved: BibleReadingPositionRecord?) {
        guard let saved else {
            position = initialPosition
            translation = .defaultTranslation
            navigationHistory = BibleNavigationHistory(initialPosition: initialPosition)
            applyCurrentChapter()
            return
        }

        let storedPosition = BiblePosition(
            bookId: saved.bookId,
            chapterNumber: saved.chapterNumber
        )
        translation = BibleTranslation.named(saved.translationId)
        if isValidPosition(storedPosition) {
            position = storedPosition
            navigationHistory = BibleNavigationHistoryPayload.restore(
                from: saved.navigationHistoryJSON,
                position: storedPosition,
                catalog: catalog
            )
        } else {
            position = initialPosition
            navigationHistory = BibleNavigationHistory(initialPosition: initialPosition)
        }
        applyCurrentChapter()
    }

    private func clearRestorationTask(ifCurrent generation: Int) {
        guard activeRestorationGeneration == generation else { return }
        restorationTask = nil
        activeRestorationGeneration = nil
    }

    private func drainQueuedNavigationIntents() {
        let intents = queuedNavigationIntents
        queuedNavigationIntents.removeAll()
        for intent in intents {
            switch intent {
            case .reference(let bookId, let chapterNumber, let verseStart, let verseEnd):
                applyReference(
                    bookId: bookId,
                    chapterNumber: chapterNumber,
                    verseStart: verseStart,
                    verseEnd: verseEnd
                )
            case .exactReference(let reference):
                applyReference(reference)
            case .translation(let selected):
                applyTranslationSelection(selected)
            }
        }
    }

    private func isValidPosition(_ position: BiblePosition) -> Bool {
        guard let book = catalog.book(id: position.bookId) else { return false }
        return (1...book.chapterCount).contains(position.chapterNumber)
    }

    private func visitChapter(_ destination: BiblePosition) {
        guard destination != position else { return }
        if didReadingPositionLoadFail { provisionalNavigationOccurred = true }
        prepareForChapterTransition()
        navigationHistory.visit(destination)
        position = destination
        applyCurrentChapter()
        persist()
    }

    private func traverseHistory(to destination: BiblePosition) {
        if didReadingPositionLoadFail { provisionalNavigationOccurred = true }
        prepareForChapterTransition()
        position = destination
        applyCurrentChapter()
        persist()
    }

    private func prepareForChapterTransition() {
        narration.stop()
        isNarrationSheetPresented = false
        clearSelection()
        pendingScrollVerse = nil
        bookSheet = nil
        isTranslationSheetPresented = false
        presentedAnnotationTarget = nil
        presentedNoteList = nil
        presentedBookmarkSheet = nil
        resetImmersive()
    }

    private func persist() {
        guard canPersistNavigation, let positionRepository else { return }
        let historyJSON: String
        do {
            historyJSON = try BibleNavigationHistoryPayload.encode(navigationHistory)
        } catch {
            navigationPersistenceError = "Couldn't save reading history."
            return
        }
        let record = BibleReadingPositionRecord(
            bookId: position.bookId,
            chapterNumber: position.chapterNumber,
            translationId: translation.rawValue,
            updatedAt: clock.now(),
            navigationHistoryJSON: historyJSON
        )
        // Chain each write on the prior so rapid steps persist in order and
        // awaiting the latest task drains every pending write.
        latestPersistSequence += 1
        let sequence = latestPersistSequence
        let previous = persistTask
        persistTask = Task { [weak self, positionRepository] in
            await previous?.value
            do {
                try await positionRepository.save(record)
                guard let self, self.latestPersistSequence == sequence else { return }
                self.navigationPersistenceError = nil
            } catch {
                guard let self, self.latestPersistSequence == sequence else { return }
                self.navigationPersistenceError = "Couldn't save reading history."
            }
        }
    }
}
