import Core
import Foundation
import Observation

/// Drives the Bible reading surface: which chapter is on screen, the text
/// for it, and stepping forward and backward through the canon.
///
/// The chapter text loads synchronously from the bundled resources, so
/// stepping updates the screen immediately; only the reading-position
/// persistence is asynchronous, fired off the main thread after each step.
@MainActor
@Observable
public final class BibleScreenViewModel {
    /// Where a fresh install opens — 1 Peter 2, the design's demo chapter.
    public static let defaultPosition = BiblePosition(bookId: "1PE", chapterNumber: 2)

    /// The book and chapter currently on screen.
    public private(set) var position: BiblePosition
    /// Display name of the current book, e.g. `"1 Peter"`.
    public private(set) var bookName: String
    /// The current chapter's text, or `nil` if its resource failed to load.
    public private(set) var chapter: BibleChapter?
    /// The translation the chapter is read in — drives both the nav-bar pill
    /// and which bundled resource the text loads from.
    public private(set) var translation: BibleTranslation = .defaultTranslation

    /// The book picker's view model while its sheet is presented; `nil`
    /// closes the sheet. Non-nil acts as the presentation flag.
    public private(set) var bookSheet: BibleBookSheetViewModel?

    /// Whether the translation picker is on screen. The sheet is stateless —
    /// it renders `BibleTranslation.allCases` against `translation` — so a
    /// flag is all the presentation state it needs.
    public private(set) var isTranslationSheetPresented = false

    /// Verse numbers the reader has tapped to select. Non-empty drives the
    /// nav bar into selection mode and presents the action sheet.
    public private(set) var selectedVerses: Set<Int> = []

    /// First verse to scroll into view the next time the chapter reader
    /// renders. Set by ``openReference(bookId:chapterNumber:verseStart:verseEnd:)``
    /// for deep-link navigation; the reader consumes it on appear (and on
    /// any subsequent change for same-chapter deep links) and clears it
    /// via ``consumePendingScrollVerse()`` so the next user-driven chapter
    /// step doesn't re-snap to the old anchor.
    public private(set) var pendingScrollVerse: Int?

    /// A transient message shown in the chat-attach toast, or `nil` when no
    /// toast is up. Used only for the "chat ships later" stub until hand-off
    /// lands; the toast is dismissed by a tap, never on a timer.
    public private(set) var toast: String?

    /// The narration session driver — held here so its playback survives
    /// `BibleScreen` rebuilds and so the nav bar, reader, and transport
    /// sheet all observe the same `currentVerseNumber`.
    public let narration: NarrationController

    /// Whether the ``NarrationTransportSheet`` is on screen. The sheet
    /// can be dismissed without stopping narration — the nav-bar
    /// "Narrating" pill replaces the spark button so the user can
    /// re-present it.
    public var isNarrationSheetPresented = false

    /// The annotation target whose sheet is currently presented, or `nil`
    /// when no sheet is up. Drives the iOS `.sheet(item:)` modifier in
    /// `BibleScreen`. Setting this to a non-nil spec presents the sheet;
    /// dragging-to-dismiss or calling `dismissAnnotationSheet()` clears it.
    public var presentedAnnotationTarget: BibleAnnotationTargetSpec?

    /// Whether the first-run liability disclaimer is on screen. Set true
    /// the first time the user triggers an annotation-generation intent;
    /// `acknowledgeAnnotationDisclaimer()` clears it and fires any queued
    /// `pendingAnnotationIntent`.
    public var isAnnotationDisclaimerPresented = false

    /// Generation intents queued while the disclaimer is up. A gapped
    /// verse selection (e.g. 28, 30) decomposes into multiple
    /// contiguous-range intents; before the user acknowledges the
    /// disclaimer they all arrive synchronously in `handleAnnotateSelection`
    /// and must each be replayed once the user taps "Got it". A scalar
    /// would let the second arrival overwrite the first and silently
    /// drop it. Drained in FIFO order on acknowledgement; discarded on
    /// drag-down dismiss.
    public private(set) var pendingAnnotationIntents: [BibleAnnotationTargetSpec] = []

    /// Per-target dispatch state. `.running` for a target whose
    /// headless `bible.annotate` turn is in flight; `.failed` for one
    /// whose turn returned `BibleAnnotateResult.failure`. Successful
    /// dispatches drop their entry — the new rows surface through the
    /// reactive `@Query` and the sheet flips to its populated state.
    /// `AnnotationSheetContainer` reads the entry for the target it's
    /// presenting to pick between generating, failed-with-retry, and
    /// the regular empty / populated layouts.
    public private(set) var dispatchStatusByTarget: [BibleAnnotationTargetSpec: BibleAnnotationDispatchStatus] = [:]

    /// The note range whose list sheet is presented, or `nil` when no sheet
    /// is up. Drives the `.sheet(item:)` in `BibleScreen`. Setting it to a
    /// non-nil presentation opens the list; dragging-to-dismiss or
    /// `dismissNoteList()` clears it. `autoCompose` opens the editor in
    /// create mode the moment the list mounts — the entry point for the
    /// "Add note" tile, the action-sheet outline glyphs, and the chapter /
    /// book outline glyphs, all of which mean "write a note here" rather than
    /// "browse this range's notes".
    public var presentedNoteList: BibleNoteListPresentation?

    /// The chapter whose bookmark sheet is presented, or `nil` when no sheet
    /// is up. Drives the `.sheet(item:)` in `BibleScreen`. Captures the
    /// chapter and citation at presentation time so the sheet's writes stay
    /// pinned to the chapter it is titled with.
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
    /// Shared app-wide haptics engine. Fires `.selection` when a verse is
    /// selected and `.deselection` when one is removed. Defaults to a no-op
    /// so tests/previews stay silent.
    private let hapticsEngine: any HapticsEngine

    /// The shared event bus, set when `attach(to:)` is called once at
    /// applet bootstrap. `nil` for tests that don't exercise the
    /// headless dispatch path — those keep getting the PR 3 toast
    /// fallback so view-model tests written against the disclaimer
    /// gate stay green without a bus fixture.
    private var eventBus: SuperEventBus?

    /// Subscription task draining `bibleAnnotateCompleted` envelopes.
    /// Owned so a future tear-down can cancel it.
    private var dispatchSubscriptionTask: Task<Void, Never>?

    /// One-shot callbacks fired after the dispatch-subscription task
    /// processes a `bibleAnnotateCompleted` envelope. Test seam — kept
    /// specific to *completion* envelopes because the view model also
    /// receives its own `bibleAnnotateRequested` echo through the bus;
    /// a "next event" seam would fire on that echo before the actual
    /// completion arrives, racing assertions ahead of the state
    /// update. Never observed in production.
    private var dispatchCompletionCallbacks: [@MainActor () -> Void] = []

    /// One-shot callbacks fired after the dispatch-subscription task
    /// processes a `sidebarOpened` envelope (and the resulting sheet
    /// dismissal). Test seam — lets a test await the bus-driven dismiss
    /// deterministically instead of polling. Never observed in production.
    private var sidebarDismissCallbacks: [@MainActor () -> Void] = []

    /// In-flight reading-position write, retained so tests can await it.
    private var persistTask: Task<Void, Never>?

    /// In-flight highlight write, retained so tests can await it.
    private var highlightTask: Task<Void, Never>?

    /// In-flight note write (insert / update / delete), retained so tests can
    /// await it. Each write chains on the prior so awaiting the latest drains
    /// them all — the same shape as `highlightTask`.
    private var noteTask: Task<Void, Never>?

    /// In-flight bookmark toggle, retained so tests can await it. Chained
    /// like `noteTask` so rapid card taps stay ordered.
    private var bookmarkTask: Task<Void, Never>?

    /// In-flight first-Narrate voice pick + start, retained so tests
    /// can await its completion. Production has no need to observe it
    /// — the user sees the card slide in immediately and the first
    /// verse plays once the off-main voice scan returns.
    private var narrationStartTask: Task<Void, Never>?

    /// - Parameters:
    ///   - positionRepository: persists the reading position; `nil` disables
    ///     persistence (the applet passes `nil` only if its database fails
    ///     to open, so the reader still works, just without restore).
    ///   - highlightRepository: persists verse highlights; `nil` disables
    ///     highlighting for the same database-unavailable reason.
    ///   - noteRepository: persists verse notes; `nil` disables note
    ///     create / edit / delete for the same database-unavailable reason
    ///     (the note glyphs and list sheet still render from the reactive
    ///     `@Query`s, which fall back to empty).
    ///   - bookmarkRepository: persists the six chapter-bookmark slots; `nil`
    ///     disables toggling for the same database-unavailable reason (the
    ///     glyph and sheet still render from the reactive `@Query`s).
    ///   - initialPosition: the position before `load()` reads persisted
    ///     state — defaults to `defaultPosition`.
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
        narration: NarrationController? = nil,
        hapticsEngine: any HapticsEngine = NoOpHapticsEngine()
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
        self.position = initialPosition
        self.bookName = catalog.book(id: initialPosition.bookId)?.name ?? ""
        // Default to the production synth-backed controller so tests that
        // don't exercise narration don't need to construct one. Tests
        // that *do* exercise narration inject a FakeNarrationService.
        self.narration = narration ?? NarrationController(
            service: AVSpeechSynthesizerNarrationService()
        )
    }

    /// Whether a previous / next chapter exists — `false` only at Genesis 1
    /// and Revelation's final chapter, where the nav controls disable.
    public var canStepBackward: Bool {
        catalog.step(from: position, direction: .previous) != nil
    }
    public var canStepForward: Bool {
        catalog.step(from: position, direction: .next) != nil
    }

    /// Labels for the chapter footer's prev / next cards, e.g. `"Genesis 49"`
    /// — `nil` at the canon's two ends so the footer drops that card.
    public var previousChapterLabel: String? { label(for: .previous) }
    public var nextChapterLabel: String? { label(for: .next) }

    /// Read the persisted reading position (if any) and load its chapter
    /// text. Call once when the screen appears.
    public func load() async {
        if let repository = positionRepository,
           let saved = try? await repository.load() {
            position = BiblePosition(bookId: saved.bookId, chapterNumber: saved.chapterNumber)
            translation = BibleTranslation.named(saved.translationId)
        }
        applyCurrentChapter()
    }

    /// Step one chapter in `direction`, crossing book boundaries. A no-op at
    /// the canon's ends. The screen updates synchronously; the new position
    /// is persisted in the background. Stops any active narration —
    /// the queue is keyed to the chapter we're leaving.
    public func stepChapter(_ direction: BibleChapterDirection) {
        guard let next = catalog.step(from: position, direction: direction) else { return }
        narration.stop()
        position = next
        clearSelection()
        applyCurrentChapter()
        persist()
    }

    /// Open the book picker. It opens with the current book expanded and
    /// scrolled to so the highlighted chapter is on screen — passed in via
    /// `currentPosition` so the sheet doesn't have to reach back for it.
    public func presentBookSheet() {
        bookSheet = BibleBookSheetViewModel(currentPosition: position, catalog: catalog)
    }

    /// Close the book picker without changing the reading position.
    public func dismissBookSheet() {
        bookSheet = nil
    }

    /// Open the translation picker.
    public func presentTranslationSheet() {
        isTranslationSheetPresented = true
    }

    /// Close the translation picker without changing the translation.
    public func dismissTranslationSheet() {
        isTranslationSheetPresented = false
    }

    /// Switch the reading translation and close the picker. The chapter text
    /// reloads synchronously in the new translation; the choice is persisted
    /// like a chapter step. Selecting the current translation just closes.
    /// Stops any active narration — the queue is keyed to the old text.
    public func selectTranslation(_ selected: BibleTranslation) {
        isTranslationSheetPresented = false
        guard selected != translation else { return }
        narration.stop()
        translation = selected
        clearSelection()
        applyCurrentChapter()
        persist()
    }

    /// Jump straight to a book and chapter chosen in the picker, then close
    /// the sheet. Persists the new position like a step does. An unknown
    /// book or an out-of-range chapter is a no-op — the picker only offers
    /// valid pairs, but this guards future callers (deep links, hand-off).
    /// Stops any active narration — the queue is keyed to the chapter
    /// we're leaving.
    public func selectChapter(bookId: String, chapterNumber: Int) {
        guard let book = catalog.book(id: bookId),
              (1...book.chapterCount).contains(chapterNumber) else { return }
        narration.stop()
        position = BiblePosition(bookId: bookId, chapterNumber: chapterNumber)
        clearSelection()
        applyCurrentChapter()
        persist()
        bookSheet = nil
    }

    /// Open the reader at a specific verse range — switches book/chapter
    /// if needed, then pre-selects the verses so the reader lands with
    /// them highlighted (the same look as having just tapped them).
    ///
    /// Driven by Bible-citation taps inside the Chat transcript and by
    /// `super://bible/...` URLs at the scene root. Both paths go
    /// through `SuperEvent.openRecord(reference:)` → the Bible applet's
    /// event-bus subscriber → this method.
    ///
    /// - Parameters:
    ///   - bookId: Three-letter book code (`"GEN"`, `"1CO"`, `"SNG"`).
    ///     Unknown ids are a no-op.
    ///   - chapterNumber: 1-based chapter; out-of-range is a no-op.
    ///   - verseStart: First selected verse, or `nil` for a
    ///     chapter-only navigation (no pre-selection).
    ///   - verseEnd: Last selected verse, or `nil` for a single verse
    ///     when `verseStart` is set. An inverted range
    ///     (`verseEnd < verseStart`) is a no-op.
    public func openReference(bookId: String, chapterNumber: Int, verseStart: Int?, verseEnd: Int?) {
        guard let book = catalog.book(id: bookId),
              (1...book.chapterCount).contains(chapterNumber) else { return }
        if let verseStart, verseStart < 1 { return }
        if let verseStart, let verseEnd, verseEnd < verseStart { return }

        narration.stop()
        position = BiblePosition(bookId: bookId, chapterNumber: chapterNumber)
        if let verseStart {
            let upper = verseEnd ?? verseStart
            selectedVerses = Set(verseStart...upper)
        } else {
            selectedVerses.removeAll()
        }
        // Flag the first selected verse for the reader to scroll into
        // view once it mounts (or, for a same-chapter deep link, on the
        // next `pendingScrollVerse` change). Chapter-only navigation
        // leaves this `nil` so the new chapter just snaps to its top
        // like a manual nav.
        pendingScrollVerse = verseStart
        applyCurrentChapter()
        // The catalog bounds chapters but not per-chapter verse counts, so a
        // reference past a chapter's last verse (e.g. "Revelation 22:22", which
        // has 21) reaches here. Now that the chapter is loaded, drop any
        // pre-selected verses it doesn't actually contain — otherwise an
        // all-out-of-range selection would light up the action bar with nothing
        // highlighted and make Copy / Share silent no-ops.
        if !selectedVerses.isEmpty {
            selectedVerses.formIntersection(verseTextsByNumber().keys)
            if let scroll = pendingScrollVerse, !selectedVerses.contains(scroll) {
                pendingScrollVerse = selectedVerses.min()
            }
        }
        persist()
        bookSheet = nil
    }

    /// Read and clear the pending scroll target. The chapter reader calls
    /// this after it has issued the scroll so a subsequent user-driven
    /// chapter step doesn't re-trigger the snap.
    public func consumePendingScrollVerse() -> Int? {
        defer { pendingScrollVerse = nil }
        return pendingScrollVerse
    }

    // MARK: - Immersive reading (scroll-driven chrome)

    /// Whether the reader is in immersive mode: the user has scrolled down
    /// into the chapter, so the Bible nav bar slides up off screen and the
    /// shell hides its own chrome (hamburger + chat pill) in sympathy. Driven
    /// purely by ``updateScroll(offsetY:userDriven:)`` from the chapter
    /// reader's scroll geometry; `BibleScreen` animates its nav bar off this
    /// and republishes the change to the shell over the event bus.
    public private(set) var isImmersive = false

    /// Whether the chapter's previous/next footer cards are scrolled into view.
    /// Driven by ``updateFooterVisibility(_:)`` from the reader's scroll
    /// geometry; `BibleScreen` reads it to hide the hovering composer chevrons
    /// once the footer's own chapter-step controls are on screen (they'd be
    /// redundant). Resets to `false` on a chapter step via ``resetImmersive()``.
    public private(set) var isChapterFooterVisible = false

    /// At or above the top by this many points, chrome is always shown —
    /// reaching the top of a chapter reveals the bar regardless of the
    /// in-flight scroll direction.
    static let immersiveTopRevealThreshold: CGFloat = 8
    /// Net downward travel (points, since the last direction reversal)
    /// required to hide chrome. Small enough to feel responsive, large
    /// enough that a one-finger settle jitter doesn't trip it.
    static let immersiveHideThreshold: CGFloat = 12
    /// Net upward travel required to reveal chrome again — any deliberate
    /// upward scroll brings it back (standard immersive pattern).
    static let immersiveRevealThreshold: CGFloat = 8
    /// Chrome only hides once the reader is scrolled past this offset, so the
    /// first lines of a chapter keep the bar even on a quick downward flick.
    static let immersiveMinOffsetToHide: CGFloat = 64

    /// Last observed content offset, and the signed run of travel since the
    /// last direction reversal (`+` = scrolling down / content moving up).
    /// Scratch state for the direction hysteresis in ``updateScroll``.
    private var lastScrollOffsetY: CGFloat?
    private var scrollTravelSinceReversal: CGFloat = 0

    /// Fold a chapter-reader scroll sample into ``isImmersive``. Pure and
    /// synchronous so it's unit-testable without rendering: feed offsets +
    /// the user-driven flag and assert the transitions.
    ///
    /// - `userDriven == false` (programmatic `scrollTo` for narration
    ///   follow, selection-into-view, deep-link landing) only refreshes the
    ///   baseline offset — it never flips immersive, so an auto-scroll can't
    ///   hide or reveal the chrome out from under the user.
    /// - Reaching the top (`offsetY <= immersiveTopRevealThreshold`) always
    ///   reveals.
    /// - A net downward run past ``immersiveHideThreshold`` (once scrolled
    ///   past ``immersiveMinOffsetToHide``) hides; a net upward run past
    ///   ``immersiveRevealThreshold`` reveals. The run resets on each
    ///   direction reversal so a small jitter needn't overcome a long
    ///   opposite stretch.
    ///
    /// Idempotent: it only mutates ``isImmersive`` on a real flip, so the
    /// screen's `.onChange(of:)` publish fires once per transition.
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

        // Reset the run when direction reverses so the new direction starts
        // accumulating from zero rather than fighting the prior stretch.
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

    /// Force chrome back on and clear the scroll scratch state. The screen
    /// calls this when the reader disappears or steps chapters so chrome can
    /// never strand hidden after leaving a scrolled chapter. Also clears
    /// ``isChapterFooterVisible`` so a freshly stepped chapter (scroll reset to
    /// the top) starts with the composer chevrons shown.
    public func resetImmersive() {
        scrollTravelSinceReversal = 0
        lastScrollOffsetY = nil
        setImmersive(false)
        updateFooterVisibility(false)
    }

    /// Fold a chapter-reader "footer cards visible" sample into
    /// ``isChapterFooterVisible``. Idempotent — mutates only on a real flip so
    /// the screen's reactive readers fire once per transition.
    public func updateFooterVisibility(_ visible: Bool) {
        guard isChapterFooterVisible != visible else { return }
        isChapterFooterVisible = visible
    }

    private func setImmersive(_ value: Bool) {
        guard isImmersive != value else { return }
        isImmersive = value
    }

    /// Toggle a verse's membership in the selection. The first tap enters
    /// selection mode (the nav-bar citation pill and the action sheet);
    /// clearing the last verse leaves it.
    public func toggleVerse(_ number: Int) {
        if selectedVerses.contains(number) {
            selectedVerses.remove(number)
            // Distinct from selection so the user can feel the difference
            // between adding and removing a verse.
            hapticsEngine.play(.deselection)
        } else {
            selectedVerses.insert(number)
            hapticsEngine.play(.selection)
        }
    }

    /// Drop the whole selection, leaving selection mode. A no-op when empty.
    /// Plays the ``HapticPattern/deselection`` "disconnect" tap when it
    /// actually drops a selection — so dismissing the action sheet (its close
    /// button or a swipe-down, both of which route here) feels like releasing
    /// the verses. The non-empty guard also dedupes the double call the sheet's
    /// dismiss binding makes (clear → binding goes nil → clear again).
    public func clearSelection() {
        guard !selectedVerses.isEmpty else { return }
        selectedVerses.removeAll()
        hapticsEngine.play(.deselection)
    }

    /// The selection's citation, e.g. `"1 Peter 2:4-6, 9"`, or `nil` when no
    /// verse is selected. Drives the nav bar's selection-mode pill.
    public var selectionCitation: String? {
        let verses = selectedVerses.sorted()
        guard !verses.isEmpty else { return nil }
        return BibleCitationFormatter.cite(
            bookName: bookName, chapterNumber: position.chapterNumber, verses: verses
        )
    }

    /// The selected verses' text followed by their citation — the payload for
    /// Copy and Share. `nil` when nothing is selected or the chapter text is
    /// unavailable.
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

    /// Copy the selected verses to the clipboard, then leave selection mode.
    public func copySelection() {
        guard let text = selectionShareText else { return }
        clipboard.write(text)
        clearSelection()
    }

    /// Toggle `color` across the selection, leaving the selection (and the
    /// action sheet) intact so the user can keep adjusting. Tapping a colour
    /// paints every selected verse with it — *unless* every selected verse
    /// already carries exactly that colour, in which case the tap clears them
    /// (re-tapping the active colour is a natural way to remove a highlight).
    /// The write is asynchronous; the chapter's reactive `@Query` repaints once
    /// it lands. A no-op without a highlight store or with nothing selected.
    public func applyHighlight(_ color: BibleHighlightColor) {
        writeHighlights(failureMessage: "Couldn't save the highlight.") {
            repository, verses, bookId, chapterNumber, now in
            let current = try await repository.activeHighlightColors(
                bookId: bookId, chapterNumber: chapterNumber, verseNumbers: verses
            )
            // Clear only when the whole selection already carries this colour;
            // any other state (a different colour, or an unhighlighted verse)
            // means the tap applies the colour to all.
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

    /// Clear the highlight on every selected verse, leaving the selection (and
    /// the action sheet) intact so the user can keep adjusting.
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

    /// Run `mutate` for the selected verses on a background task chained after
    /// any prior highlight write. The selection (and the action sheet) is left
    /// intact so the user can keep adjusting the highlight. The highlight
    /// actions — toggle and clear — differ only in this mutation block and in
    /// the toast shown when it fails.
    ///
    /// - Parameter failureMessage: shown in the toast if the mutation throws.
    ///   The write is fire-and-forget, so without this a failed write would
    ///   read as success — the chapter just never repaints.
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
        // Chain on the prior write so awaiting the latest task drains them all.
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

    /// Build a `RecordReference` for the current verse selection — its
    /// citation, translation, and a verbatim text snapshot — for hand-off
    /// to the Chat composer. Returns nil when nothing is selected or the
    /// chapter text is unavailable. The view model stays bus-agnostic;
    /// `BibleScreen` publishes the returned reference.
    public func makeVerseReference() -> RecordReference? {
        let verses = selectedVerses.sorted()
        guard !verses.isEmpty else { return nil }
        let texts = verseTextsByNumber()
        let snapshot = verses.compactMap { texts[$0] }.joined(separator: " ")
        guard !snapshot.isEmpty else { return nil }
        let citation = BibleCitationFormatter.cite(
            bookName: bookName, chapterNumber: position.chapterNumber, verses: verses
        )
        // The translation is part of the user-facing label and citation —
        // a verse's exact wording is translation-specific.
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

    /// Stand-in for the still-deferred whole-chapter hand-off: the `+` nav
    /// button lands here, raising a "coming soon" toast. The action
    /// sheet's verse-selection chat rows now publish a real reference —
    /// see `BibleScreen.addSelectionToChat`.
    public func presentChatComingSoon() {
        toast = "Chat integration ships in a later update."
        clearSelection()
    }

    /// Build a `RecordReference` covering the entire current chapter — the
    /// payload the spark menu's `Add to chat` / `Start a new chat`
    /// actions publish when no verses are selected. Reuses the
    /// `verseRange` kind so the Chat receiver needs no change: the
    /// `sourceID` lists every verse 1..N, the citation drops the verse
    /// clause (e.g. `"1 Peter 2 (WEB)"`), and the snapshot carries the
    /// full chapter text.
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

    /// Present the annotation sheet for `spec`. Pure presentation — no
    /// disclaimer check fires here, because tapping a filled bubble only
    /// reveals existing cards (which were generated by an earlier
    /// disclaimer-acknowledged flow or by in-chat tool use). The
    /// disclaimer gate guards *generation*, not *viewing*.
    public func presentAnnotationSheet(for spec: BibleAnnotationTargetSpec) {
        presentedAnnotationTarget = spec
    }

    /// Dismiss the annotation sheet. Mirrors the iOS sheet's drag-down
    /// gesture so the binding remains a single source of truth.
    public func dismissAnnotationSheet() {
        presentedAnnotationTarget = nil
    }

    /// Trigger a user-initiated annotation-generation intent for `spec`.
    ///
    /// On the *first* call (per device install) the disclaimer modal goes
    /// up first and the intent is appended to `pendingAnnotationIntents`;
    /// `acknowledgeAnnotationDisclaimer()` drains the whole queue in FIFO
    /// order. Subsequent calls fire immediately.
    ///
    /// The queue is what makes a gapped multi-range selection survive the
    /// gate: `handleAnnotateSelection` in `BibleScreen` synchronously
    /// calls this method once per contiguous run; without the queue, the
    /// second call would overwrite the first while the disclaimer was
    /// still up, silently dropping it.
    ///
    /// **PR 3 contract**: "fires" means posting the toast
    /// `"Annotation generation ships in a later update."` — the headless
    /// LLM dispatch path lands in PR 4. The disclaimer gate, the pending
    /// intent queue, and the call paths are all production-ready around
    /// this stub; swapping the toast for the real dispatch is a one-line
    /// change.
    public func triggerAnnotationGeneration(for spec: BibleAnnotationTargetSpec) {
        guard disclaimerStore.isAcknowledged else {
            pendingAnnotationIntents.append(spec)
            isAnnotationDisclaimerPresented = true
            return
        }
        performAnnotationGeneration(for: spec)
    }

    /// Persist the disclaimer acknowledgement, dismiss the sheet, and
    /// fire every queued intent in FIFO order.
    public func acknowledgeAnnotationDisclaimer() {
        disclaimerStore.setAcknowledged(true)
        isAnnotationDisclaimerPresented = false
        let queue = pendingAnnotationIntents
        pendingAnnotationIntents.removeAll()
        for spec in queue {
            performAnnotationGeneration(for: spec)
        }
    }

    /// Dismiss the disclaimer without acknowledging it (drag-down). The
    /// whole intent queue is discarded — the user will be prompted again
    /// on the next generation trigger.
    public func discardAnnotationDisclaimer() {
        isAnnotationDisclaimerPresented = false
        pendingAnnotationIntents.removeAll()
    }

    /// Navigate the reader to a verse range parsed from an annotation
    /// reference card. Dismisses any presented annotation sheet on the
    /// way so the reader is unobscured. Routes through the existing
    /// `openReference(...)` path so the chapter swap, the pre-selection,
    /// and the scroll-to-verse anchor all behave identically to a
    /// `super://bible/` deep link.
    public func navigateToVerseReference(_ parsed: BibleCitationParser.ParsedCitation) {
        presentedAnnotationTarget = nil
        openReference(
            bookId: parsed.position.bookId,
            chapterNumber: parsed.position.chapterNumber,
            verseStart: parsed.verseStart,
            verseEnd: parsed.verseEnd
        )
    }

    /// Re-fire a failed dispatch with a fresh request id. Triggered by
    /// the retry button on the annotation sheet. The previous
    /// `.failed(...)` entry is replaced with a fresh `.running(...)`
    /// keyed on the new id; the bus completion event for the original
    /// id (if it ever arrives — typically it already has) is ignored
    /// because no entry matches.
    ///
    /// Skips the `clearSelection()` call the initial trigger does —
    /// on retry there's no live selection to clear (the dispatch is
    /// keyed on the captured `spec`), and clearing would briefly
    /// dismiss + re-present the sheet because the same animation
    /// chain re-evaluates `presentedAnnotationTarget`.
    public func retryAnnotationGeneration(for spec: BibleAnnotationTargetSpec) {
        publishDispatchRequest(for: spec)
    }

    /// Build the `RecordReference` envelope for a one-off
    /// `bible.annotate` dispatch request. The reference's `id` is the
    /// `requestId` the completion event will echo back. The `kind` /
    /// `sourceID` / `displayLabel` / `citation` fields let
    /// `BibleAnnotateDispatcher`'s prompt name the target without
    /// importing Bible.
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

    /// The verbatim, verse-numbered text for an annotation target, so the
    /// headless generator annotates the *actual* translation rather than its
    /// recollection (preventing cards that reference words not in the text).
    ///
    /// Chapter and verse-range targets carry their text; a whole-`book` target
    /// returns `""` — the full book would be an enormous prompt, and book-level
    /// cards (author/summary/historical) don't quote specific verses. Loaded
    /// off the bundled text, so an unavailable book degrades to no snapshot
    /// rather than failing the dispatch.
    private func snapshotText(for spec: BibleAnnotationTargetSpec) -> String {
        guard let chapterNumber = spec.chapterNumber,
              let chapter = (try? textLoader.loadChapter(
                  bookId: spec.bookId, chapterNumber: chapterNumber, translation: translation
              )) ?? nil else { return "" }
        let verses = chapter.coalescedVerses()
        let selected: [BibleVerse]
        if let start = spec.verseStart, let end = spec.verseEnd {
            selected = verses.filter { $0.number >= start && $0.number <= end }
        } else {
            selected = verses
        }
        return BibleVerseTextFormatter.numbered(selected)
    }

    /// Initial headless `bible.annotate` dispatch — called by the
    /// disclaimer-gated trigger from the spark button, the Annotate
    /// action tile, and empty book-picker bubbles.
    ///
    /// `clearSelection()` mirrors every other `BibleActionSheet`-reachable
    /// action (copy, chat hand-off, highlight): the selection-driven
    /// sheet is dismissed on completion so the user's next action
    /// starts fresh and the sheet isn't competing for the bottom edge.
    /// Retry skips this — see `retryAnnotationGeneration(for:)`.
    private func performAnnotationGeneration(for spec: BibleAnnotationTargetSpec) {
        clearSelection()
        publishDispatchRequest(for: spec)
    }

    /// Core dispatch publish — extracted so both the initial trigger
    /// and retry path share one wire site. When a `SuperEventBus` is
    /// wired through `attach(to:)`, publishes
    /// `SuperEvent.bibleAnnotateRequested(reference:)`, marks the
    /// target running in `dispatchStatusByTarget`, and presents the
    /// annotation sheet so the user sees the generating state. The
    /// matching `bibleAnnotateCompleted` envelope flips the entry to
    /// either gone (success — rows arrive through `@Query`) or
    /// `.failed(message)` (retry button appears).
    ///
    /// When no bus is wired (test fixtures pre-PR4), falls back to the
    /// PR 3 stub toast so existing view-model tests stay green without
    /// constructing a bus.
    private func publishDispatchRequest(for spec: BibleAnnotationTargetSpec) {
        guard let bus = eventBus else {
            toast = "Annotation generation ships in a later update."
            return
        }
        let reference = makeAnnotateRequestReference(for: spec)
        dispatchStatusByTarget[spec] = .running(requestId: reference.id)
        presentedAnnotationTarget = spec
        Task { await bus.publish(.bibleAnnotateRequested(reference: reference)) }
    }

    /// Subscribe the view model to the shared event bus so headless
    /// `bibleAnnotateCompleted` envelopes flip the per-target dispatch
    /// status. Symmetric with how `BibleApplet.attach(to:)` wires the
    /// `BibleReferenceInbox` — call once after the bus is constructed.
    /// Idempotent.
    public func attach(to bus: SuperEventBus) async {
        guard dispatchSubscriptionTask == nil else { return }
        eventBus = bus
        let stream = await bus.events()
        dispatchSubscriptionTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handleBusEvent(event)
            }
        }
    }

    private func handleBusEvent(_ event: SuperEvent) {
        switch event {
        case .bibleAnnotateCompleted(let requestId, let result):
            handleAnnotateCompleted(requestId: requestId, result: result)
        case .sidebarOpened:
            // The shell's navigation drawer is opening. Any native sheet
            // we're presenting sits in its own window above the in-view
            // drawer, so the menu would slide in behind it — dismiss them
            // all so the drawer is the topmost surface.
            dismissPresentedSheets()
            let callbacks = sidebarDismissCallbacks
            sidebarDismissCallbacks.removeAll()
            for callback in callbacks { callback() }
        default:
            break
        }
    }

    private func handleAnnotateCompleted(requestId: String, result: BibleAnnotateResult) {
        // Find the target whose running status carries this id. The
        // map is small (one entry per in-flight target) so a linear
        // scan is fine and avoids a parallel reverse map.
        let matching = dispatchStatusByTarget.first { _, status in
            if case .running(let id) = status, id == requestId { return true }
            return false
        }
        if let spec = matching?.key {
            switch result {
            case .success:
                dispatchStatusByTarget.removeValue(forKey: spec)
            case .failure(let message):
                dispatchStatusByTarget[spec] = .failed(message: message)
            }
        }
        // Callbacks fire *after* the state update and only on
        // completion envelopes — see `dispatchCompletionCallbacks`'s
        // doc for why a "next event" seam would race the request echo
        // ahead of the actual completion.
        let callbacks = dispatchCompletionCallbacks
        dispatchCompletionCallbacks.removeAll()
        for callback in callbacks { callback() }
    }

    /// Close the native sheets this screen presents so the shell's drawer
    /// (an in-view overlay that renders below a native sheet's window) wins
    /// the z-order when the sidebar opens. Each call is a no-op when that
    /// sheet isn't up, so dismissing all of them unconditionally is safe.
    ///
    /// The annotation *disclaimer* is deliberately excluded: it's a
    /// confirmation gate, not a passive sheet — flipping its binding fires
    /// `discardAnnotationDisclaimer()` and silently throws away the user's
    /// pending annotation intent. Leaving it up is the safer trade-off; the
    /// user just invoked it and is unlikely to reach for the hamburger mid-gate.
    private func dismissPresentedSheets() {
        clearSelection()
        dismissNarrationSheet()
        dismissBookSheet()
        dismissTranslationSheet()
        dismissAnnotationSheet()
        dismissNoteList()
    }

    /// Test seam: register a one-shot callback fired after the
    /// subscription processes a `sidebarOpened` envelope and dismisses
    /// the presented sheets. Lets tests await the bus-driven dismiss
    /// deterministically without `Task.yield()` polling (AGENTS.md §2).
    /// Underscored because it's not stable API.
    func _onNextSidebarDismiss(_ callback: @escaping @MainActor () -> Void) {
        sidebarDismissCallbacks.append(callback)
    }

    /// Test seam: register a one-shot callback fired after the
    /// dispatch subscription processes a `bibleAnnotateCompleted`
    /// envelope. Lets tests await completion-processing
    /// deterministically without `Task.yield()` polling (AGENTS.md
    /// §2). Scoped to completion events only — the request echo would
    /// otherwise race the callback ahead of the actual state update.
    /// Underscored because it's not stable API.
    func _onNextDispatchCompletion(_ callback: @escaping @MainActor () -> Void) {
        dispatchCompletionCallbacks.append(callback)
    }

    /// Dispatch status for `spec`, or `nil` when no headless dispatch
    /// is running or failed for it. `AnnotationSheetContainer` reads
    /// this to drive its generating / failed / populated layouts.
    public func dispatchStatus(for spec: BibleAnnotationTargetSpec) -> BibleAnnotationDispatchStatus? {
        dispatchStatusByTarget[spec]
    }

    /// Raise the toast shown when a per-card delete write fails — the
    /// `AnnotationSheet`'s @Query would otherwise leave the card visible
    /// with no signal that the tap did nothing. Routed from
    /// `AnnotationSheetContainer.onCardDeleteFailed`.
    public func presentDeleteAnnotationFailedToast() {
        toast = "Couldn't delete the annotation."
    }

    /// A regenerate failed while existing cards were on screen. Clear the
    /// lingering `.failed` status so the sheet keeps showing the
    /// still-present previous annotations (populated wins over the inline
    /// error layout) and never flips to a stale error+retry state if the
    /// user later deletes the remaining cards. Routed from
    /// `AnnotationSheetContainer.onRegenerateFailed`, which fires only when
    /// the failed target still has rows. Raises no toast by design — a
    /// regenerate that fails over present cards is silent (the cards stay).
    public func clearFailedDispatchStatus(for spec: BibleAnnotationTargetSpec) {
        dispatchStatusByTarget.removeValue(forKey: spec)
    }

    /// Human-readable citation for an annotation target, used as the
    /// sheet header. Examples: `"Romans"` for a book target,
    /// `"Romans 8"` for a chapter, `"Romans 8:28-30"` for a verse range,
    /// `"Romans 8:28"` when the range is one verse.
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

    /// The `.chapter` annotation target for the chapter currently on screen —
    /// the spark menu's Annotate target when no verses are selected, and the
    /// chapter reader's "generate" bubble target. Reflects the live `position`,
    /// so it tracks chapter stepping.
    public var currentChapterAnnotationSpec: BibleAnnotationTargetSpec {
        .chapter(bookId: position.bookId, chapterNumber: position.chapterNumber)
    }

    /// Annotation target specs for each contiguous range in the current
    /// verse selection. A single contiguous run produces one spec; a
    /// gapped selection (e.g. 1, 2, 5) produces multiple specs (1-2 and
    /// 5-5). Drives the spark-button and verse-action-tile annotate
    /// flows, which trigger one generation intent per range. Returns
    /// `[]` when no verses are selected.
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

    /// Build the `RecordReference` for a single annotation card's
    /// "Add to chat" tap. The composer renders the card into the
    /// markdown block the LLM receives (per spec §6). The citation
    /// reflects the card's underlying target (book / chapter / verse
    /// range) — derived from the record's `target` discriminator and
    /// its `verseStart` / `verseEnd`.
    public func makeAnnotationCardReference(_ record: BibleAnnotationRecord) -> RecordReference {
        let spec = targetSpec(for: record)
        let citation = citationLabel(for: spec)
        return RecordReference(
            appletID: BibleApplet.appletID,
            kind: "annotation",
            sourceID: record.id,
            displayLabel: "\(citation) annotation",
            citation: citation,
            snapshot: AnnotationSnapshotComposer.compose(annotation: record),
            id: idGenerator.nextID()
        )
    }

    /// Build the `RecordReference` for the popover's "Add all to chat"
    /// tap — one consolidated reference carrying all the cards in the
    /// sheet, rendered by the composer's multi-annotation overload.
    public func makeAnnotationGroupReference(
        _ records: [BibleAnnotationRecord],
        for spec: BibleAnnotationTargetSpec
    ) -> RecordReference? {
        guard !records.isEmpty else { return nil }
        let citation = citationLabel(for: spec)
        return RecordReference(
            appletID: BibleApplet.appletID,
            kind: "annotationGroup",
            sourceID: records.map(\.id).joined(separator: ","),
            displayLabel: "\(citation) annotations (\(records.count))",
            citation: citation,
            snapshot: AnnotationSnapshotComposer.compose(annotations: records),
            id: idGenerator.nextID()
        )
    }

    /// Map a stored `BibleAnnotationRecord` back to its target spec. The
    /// schema constraints make the column-`nil` arms unreachable when
    /// `target` matches (chapter/verse rows are written with their
    /// chapter / verse columns set), so a violation here means a
    /// migration regression. `preconditionFailure` surfaces the bug
    /// immediately rather than silently producing a `chapterNumber: 0`
    /// spec that opens the wrong sheet.
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

    /// Present the note list sheet for `spec` — the tap target of every note
    /// glyph (a verse trailer, the chapter title, or a book-picker row),
    /// whether filled or outline. Opens straight to the list; the user composes
    /// from the sheet's `+`, so an empty range lands on the list's empty state
    /// rather than auto-opening the editor.
    public func presentNoteList(for spec: BibleNoteTargetSpec) {
        presentedNoteList = BibleNoteListPresentation(spec: spec, autoCompose: false)
    }

    /// Present the note list for `spec` already composing. Reached only via the
    /// verse-selection action sheet's explicit "Add note" tile
    /// (`composeNoteForSelection`) — note glyphs route through `presentNoteList`
    /// instead. The list mounts behind the editor so a saved note lands the
    /// user back on the populated list.
    public func composeNote(for spec: BibleNoteTargetSpec) {
        presentedNoteList = BibleNoteListPresentation(spec: spec, autoCompose: true)
    }

    /// Compose a note on the current verse selection — the action sheet's
    /// "Add note" tile. The note's range is the selection's bounding span
    /// (`min…max`); a gapped selection (e.g. 16, 18) still yields one note on
    /// the whole passage rather than decomposing into multiple, because a note
    /// is free-text *about* the passage, not a per-range generation like an
    /// annotation. Clears the selection like every other action-sheet action.
    /// A no-op with nothing selected.
    public func composeNoteForSelection() {
        guard let spec = selectionNoteSpec else { return }
        clearSelection()
        composeNote(for: spec)
    }

    /// The note target spec for the current verse selection — its bounding span
    /// (`min…max`), or `nil` when nothing is selected. Exposed without side
    /// effects so the action sheet can capture it, dismiss itself, and present
    /// the editor from the sheet's `onDismiss` (avoiding a two-sheet race);
    /// `composeNoteForSelection()` reuses it for the clear-and-present path.
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

    /// Close the note list sheet (drag-down or programmatic).
    public func dismissNoteList() {
        presentedNoteList = nil
    }

    /// Insert a user-authored note on `spec`. The body is trimmed and a blank
    /// body is dropped (the editor already disables Save while blank — this
    /// guards programmatic callers). The write is asynchronous; the list
    /// sheet's `@Query` repaints once it lands. A no-op without a note store.
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

    /// Replace one note's body, stamping a fresh `updatedAt`. Blank bodies are
    /// dropped (same guard as `createNote`).
    public func updateNote(id: String, body: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = clock.now()
        writeNote(failureMessage: "Couldn't save the note.") { repository in
            try await repository.update(id: id, body: trimmed, updatedAt: now)
        }
    }

    /// Delete one note by id. The list sheet's `@Query` drops the card once
    /// the write lands; the failure toast covers a write that throws so the
    /// still-present card doesn't read as a successful delete.
    public func deleteNote(id: String) {
        writeNote(failureMessage: "Couldn't delete the note.") { repository in
            try await repository.deleteOne(id: id)
        }
    }

    /// Run `mutate` against the note store on a task chained after any prior
    /// note write, surfacing a toast if it throws. Chaining keeps rapid
    /// create / edit / delete ordered and lets a test drain them all by
    /// awaiting the latest — the same shape as `writeHighlights`.
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

    /// Present the bookmark sheet for the on-screen chapter — the tap target
    /// of the chapter-title bookmark glyph. Captures the position and its
    /// citation so the sheet stays pinned to this chapter. Clears any verse
    /// selection as a defense for direct callers; with the action sheet up,
    /// `BibleScreen` routes the tap through `handOffAfterSelectionDismiss`
    /// so this runs only after that sheet has fully dismissed.
    public func presentBookmarkSheet() {
        clearSelection()
        presentedBookmarkSheet = BibleBookmarkPresentation(
            bookId: position.bookId,
            chapterNumber: position.chapterNumber,
            citation: chapterCitation(bookId: position.bookId, chapterNumber: position.chapterNumber)
        )
    }

    /// `"John 3"`-style citation for any chapter, resolved through the same
    /// catalog every other citation surface uses. Falls back to the raw book
    /// code for an id outside the catalog.
    public func chapterCitation(bookId: String, chapterNumber: Int) -> String {
        let name = catalog.book(id: bookId)?.name ?? bookId
        return "\(name) \(chapterNumber)"
    }

    /// Close the bookmark sheet (drag-down or programmatic).
    public func dismissBookmarkSheet() {
        presentedBookmarkSheet = nil
    }

    /// Toggle `color` on the presented chapter — the sheet's single card-tap
    /// action; the repository resolves it to assign, move, or unassign (see
    /// `BibleBookmarkRepository.toggle`). The write is asynchronous; every
    /// bookmark surface repaints through its `@Query` once it lands. A no-op
    /// without a presented sheet or a bookmark store.
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

    /// Human-readable citation for a note target, used as the list sheet's
    /// header and the editor's "ON …" caption. Examples: `"Romans"` (book),
    /// `"Romans 8"` (chapter), `"Romans 8:28-30"` (range), `"Romans 8:28"`
    /// (single verse). Mirrors the annotation overload — kept separate so the
    /// two features stay decoupled.
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

    /// Awaits the pending background note writes. Test-only seam, with the
    /// same chained-drain behaviour as `_waitForPendingHighlightWrite()`.
    public func _waitForPendingNoteWrite() async {
        await noteTask?.value
    }

    /// Awaits the pending background bookmark toggles. Test-only seam, with
    /// the same chained-drain behaviour as `_waitForPendingNoteWrite()`.
    public func _waitForPendingBookmarkWrite() async {
        await bookmarkTask?.value
    }

    // MARK: - Narration

    /// Begin a Narrate session for the current selection if any, else
    /// the whole chapter. Pops the transport sheet so the user lands on
    /// the controls; a no-op when the chapter text failed to load.
    ///
    /// On the *first* Narrate of a session, picks the highest-quality
    /// installed voice for the user's locale (Premium > Enhanced) so
    /// new users don't land on the robotic Compact default. Subsequent
    /// calls keep whatever voice the user picked. If the user has only
    /// Compact voices installed, narration still proceeds with the
    /// system default — the transport sheet's voice picker surfaces the
    /// path to install better voices.
    public func startNarration() {
        let utterances = narrationUtterances()
        guard !utterances.isEmpty else { return }
        isNarrationSheetPresented = true
        // Fast path: voice already picked, start synchronously so the
        // first verse begins as the card slides in.
        if narration.voice != nil {
            narration.start(utterances: utterances)
            return
        }
        // First Narrate of the launch: `bestAvailableVoice()` calls
        // `AVSpeechSynthesisVoice.speechVoices()` — the same ~100-300 ms
        // synchronous file scan the transport card's voice loader
        // dispatches off main. Hop to a detached task so the menu →
        // card animation doesn't freeze; `start(...)` waits for the
        // voice to be set so the first verse plays with the user's
        // best installed voice rather than the Compact default.
        narrationStartTask = Task { [weak self] in
            let voice = await Task.detached(priority: .userInitiated) {
                NarrationController.bestAvailableVoice()
            }.value
            guard let self else { return }
            self.narration.voice = voice
            self.narration.start(utterances: utterances)
        }
    }

    /// Re-present the transport sheet — wired to the nav-bar pill the
    /// user taps after dismissing the sheet without stopping narration.
    public func presentNarrationSheet() {
        isNarrationSheetPresented = true
    }

    /// Dismiss the transport sheet without stopping narration — the
    /// nav-bar pill remains visible so the user can re-open it.
    public func dismissNarrationSheet() {
        isNarrationSheetPresented = false
    }

    /// Short human label for the verse currently being narrated, e.g.
    /// `"1 Peter 2:9"`. `nil` when narration is idle.
    public var narrationCitation: String? {
        guard let verse = narration.currentVerseNumber else { return nil }
        return "\(bookName) \(position.chapterNumber):\(verse)"
    }

    /// The utterances to feed the synthesizer for the active "Narrate"
    /// action — the selection if any, else every verse in reading order.
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

    /// Dismiss the chat-attach toast.
    public func dismissToast() {
        toast = nil
    }

    /// The chapter's verse text keyed by verse number — joining the fragments
    /// of a verse that straddles a paragraph boundary and flattening the `\n`
    /// line breaks poetry carries so copied text stays on one line.
    private func verseTextsByNumber() -> [Int: String] {
        guard let chapter else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: chapter.coalescedVerses().map { ($0.number, $0.text) }
        )
    }

    /// Awaits the pending background reading-position writes. Test-only seam
    /// — each write chains on the prior, so awaiting the latest drains them
    /// all. Production code never needs to observe the persistence task.
    public func _waitForPendingPersist() async {
        await persistTask?.value
    }

    /// Awaits the pending background highlight writes. Test-only seam, with
    /// the same chained-drain behaviour as `_waitForPendingPersist()`.
    public func _waitForPendingHighlightWrite() async {
        await highlightTask?.value
    }

    /// Awaits the in-flight first-Narrate voice-pick + start task spawned
    /// when `startNarration()` finds `narration.voice == nil`. Production
    /// never observes this — the user just sees the card slide in and the
    /// first verse begins once the off-main scan returns.
    public func _waitForPendingNarrationStart() async {
        await narrationStartTask?.value
    }

    private func applyCurrentChapter() {
        // The book name comes from the catalog (it matches the source text and is
        // always available), so the nav bar stays correct even when the chapter
        // text fails to load and the reader can still step to an adjacent chapter.
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

    private func persist() {
        let record = BibleReadingPositionRecord(
            bookId: position.bookId,
            chapterNumber: position.chapterNumber,
            translationId: translation.rawValue,
            updatedAt: clock.now()
        )
        // Chain each write on the prior so rapid steps persist in order and
        // awaiting the latest task drains every pending write.
        let previous = persistTask
        persistTask = Task { [positionRepository] in
            await previous?.value
            try? await positionRepository?.save(record)
        }
    }
}
