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

    private let textLoader: any BibleTextLoader
    private let catalog: BibleBookCatalog
    private let positionRepository: (any BibleReadingPositionRepository)?
    private let highlightRepository: (any BibleHighlightRepository)?
    private let clock: any Clock
    private let clipboard: any ClipboardWriter
    private let idGenerator: any IDGenerator
    private let disclaimerStore: any AnnotationDisclaimerStore

    /// In-flight reading-position write, retained so tests can await it.
    private var persistTask: Task<Void, Never>?

    /// In-flight highlight write, retained so tests can await it.
    private var highlightTask: Task<Void, Never>?

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
    ///   - initialPosition: the position before `load()` reads persisted
    ///     state — defaults to `defaultPosition`.
    public init(
        textLoader: any BibleTextLoader,
        catalog: BibleBookCatalog = .standard,
        positionRepository: (any BibleReadingPositionRepository)? = nil,
        highlightRepository: (any BibleHighlightRepository)? = nil,
        clock: any Clock = SystemClock(),
        clipboard: any ClipboardWriter = SystemClipboard(),
        idGenerator: any IDGenerator = UUIDGenerator(),
        disclaimerStore: any AnnotationDisclaimerStore = UserDefaultsAnnotationDisclaimerStore(),
        initialPosition: BiblePosition = BibleScreenViewModel.defaultPosition,
        narration: NarrationController? = nil
    ) {
        self.textLoader = textLoader
        self.catalog = catalog
        self.positionRepository = positionRepository
        self.highlightRepository = highlightRepository
        self.clock = clock
        self.clipboard = clipboard
        self.idGenerator = idGenerator
        self.disclaimerStore = disclaimerStore
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

    /// Toggle a verse's membership in the selection. The first tap enters
    /// selection mode (the nav-bar citation pill and the action sheet);
    /// clearing the last verse leaves it.
    public func toggleVerse(_ number: Int) {
        if selectedVerses.contains(number) {
            selectedVerses.remove(number)
        } else {
            selectedVerses.insert(number)
        }
    }

    /// Drop the whole selection, leaving selection mode. A no-op when empty.
    public func clearSelection() {
        selectedVerses.removeAll()
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

    /// Paint `color` onto every selected verse, then leave selection mode. The
    /// write is asynchronous; the chapter's reactive `@Query` repaints once it
    /// lands. A no-op without a highlight store or with nothing selected.
    public func applyHighlight(_ color: BibleHighlightColor) {
        writeHighlights(failureMessage: "Couldn't save the highlight.") {
            repository, bookId, chapterNumber, verseNumber, now in
            try await repository.setHighlight(
                bookId: bookId,
                chapterNumber: chapterNumber,
                verseNumber: verseNumber,
                color: color,
                at: now
            )
        }
    }

    /// Clear the highlight on every selected verse, then leave selection mode.
    public func clearHighlight() {
        writeHighlights(failureMessage: "Couldn't clear the highlight.") {
            repository, bookId, chapterNumber, verseNumber, now in
            try await repository.clearHighlight(
                bookId: bookId,
                chapterNumber: chapterNumber,
                verseNumber: verseNumber,
                at: now
            )
        }
    }

    /// Run `write` for every selected verse on a background task chained after
    /// any prior highlight write, then clear the selection. The two highlight
    /// actions — apply and clear — differ only in this per-verse operation and
    /// in the toast shown when a write fails.
    ///
    /// - Parameter failureMessage: shown in the toast if any verse's write
    ///   throws. The selection clears synchronously, so without this a failed
    ///   write would read as success — the chapter just never repaints.
    private func writeHighlights(
        failureMessage: String,
        _ write: @escaping @Sendable (
            any BibleHighlightRepository, String, Int, Int, Date
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
            var anyFailed = false
            for verse in verses {
                do {
                    try await write(highlightRepository, bookId, chapterNumber, verse, now)
                } catch {
                    anyFailed = true
                }
            }
            if anyFailed { self?.toast = failureMessage }
        }
        clearSelection()
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

    /// PR 3 placeholder for the real generation dispatch (PR 4).
    /// Centralized so the disclaimer-gated and ungated call paths share
    /// one swap site.
    ///
    /// `clearSelection()` mirrors every other `BibleActionSheet`-reachable
    /// action (copy, chat hand-off, highlight): the selection-driven sheet
    /// is dismissed on completion so the user's next action starts fresh
    /// and the toast isn't competing with the sheet for the bottom edge.
    /// When PR 4 swaps the toast for the real dispatch, the selection
    /// still needs to clear here — the LLM call works off the spec, not
    /// the live selection.
    private func performAnnotationGeneration(for spec: BibleAnnotationTargetSpec) {
        _ = spec
        clearSelection()
        toast = "Annotation generation ships in a later update."
    }

    /// Raise the toast shown when a per-card delete write fails — the
    /// `AnnotationSheet`'s @Query would otherwise leave the card visible
    /// with no signal that the tap did nothing. Routed from
    /// `AnnotationSheetContainer.onCardDeleteFailed`.
    public func presentDeleteAnnotationFailedToast() {
        toast = "Couldn't delete the annotation."
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
        var fragments: [Int: [String]] = [:]
        for paragraph in chapter.paragraphs {
            switch paragraph {
            case .heading:
                continue
            case .prose(let verses), .poetry(let verses):
                for verse in verses {
                    fragments[verse.number, default: []].append(verse.text)
                }
            }
        }
        return fragments.mapValues {
            $0.joined(separator: " ").replacingOccurrences(of: "\n", with: " ")
        }
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
        if let book = try? textLoader.loadBook(id: position.bookId, translation: translation) {
            bookName = book.name
            chapter = book.chapter(position.chapterNumber)
        } else {
            // Keep the nav bar's book name correct even when the text fails
            // to load, so the reader can still step to an adjacent chapter.
            bookName = catalog.book(id: position.bookId)?.name ?? bookName
            chapter = nil
        }
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
