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

    private let textLoader: any BibleTextLoader
    private let catalog: BibleBookCatalog
    private let positionRepository: (any BibleReadingPositionRepository)?
    private let highlightRepository: (any BibleHighlightRepository)?
    private let clock: any Clock
    private let clipboard: any ClipboardWriter
    private let idGenerator: any IDGenerator

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

    /// Confirm a verse selection was handed to Chat: show a toast and
    /// leave selection mode. Mirrors `copySelection()`'s cleanup.
    public func confirmAddedToChat(citation: String) {
        toast = "Added \(citation) to chat."
        clearSelection()
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
