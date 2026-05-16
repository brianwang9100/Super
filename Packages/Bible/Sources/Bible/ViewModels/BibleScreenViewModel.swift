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

    private let textLoader: any BibleTextLoader
    private let catalog: BibleBookCatalog
    private let positionRepository: (any BibleReadingPositionRepository)?
    private let clock: any Clock
    private let clipboard: any ClipboardWriter

    /// In-flight reading-position write, retained so tests can await it.
    private var persistTask: Task<Void, Never>?

    /// - Parameters:
    ///   - positionRepository: persists the reading position; `nil` disables
    ///     persistence (the applet passes `nil` only if its database fails
    ///     to open, so the reader still works, just without restore).
    ///   - initialPosition: the position before `load()` reads persisted
    ///     state — defaults to `defaultPosition`.
    public init(
        textLoader: any BibleTextLoader,
        catalog: BibleBookCatalog = .standard,
        positionRepository: (any BibleReadingPositionRepository)? = nil,
        clock: any Clock = SystemClock(),
        clipboard: any ClipboardWriter = SystemClipboard(),
        initialPosition: BiblePosition = BibleScreenViewModel.defaultPosition
    ) {
        self.textLoader = textLoader
        self.catalog = catalog
        self.positionRepository = positionRepository
        self.clock = clock
        self.clipboard = clipboard
        self.position = initialPosition
        self.bookName = catalog.book(id: initialPosition.bookId)?.name ?? ""
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
    /// is persisted in the background.
    public func stepChapter(_ direction: BibleChapterDirection) {
        guard let next = catalog.step(from: position, direction: direction) else { return }
        position = next
        clearSelection()
        applyCurrentChapter()
        persist()
    }

    /// Open the book picker. It starts with every book collapsed; the
    /// reader taps a book to reveal its chapter grid.
    public func presentBookSheet() {
        bookSheet = BibleBookSheetViewModel(expandedBookId: nil, catalog: catalog)
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
    public func selectTranslation(_ selected: BibleTranslation) {
        isTranslationSheetPresented = false
        guard selected != translation else { return }
        translation = selected
        clearSelection()
        applyCurrentChapter()
        persist()
    }

    /// Jump straight to a book and chapter chosen in the picker, then close
    /// the sheet. Persists the new position like a step does. An unknown
    /// book or an out-of-range chapter is a no-op — the picker only offers
    /// valid pairs, but this guards future callers (deep links, hand-off).
    public func selectChapter(bookId: String, chapterNumber: Int) {
        guard let book = catalog.book(id: bookId),
              (1...book.chapterCount).contains(chapterNumber) else { return }
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

    /// Stand-in for the deferred chat hand-off: the `+` button, the floating
    /// bubble, and the action sheet's two chat rows all land here, raising a
    /// "coming soon" toast instead of attaching the passage to a chat.
    public func presentChatComingSoon() {
        toast = "Chat integration ships in a later update."
        clearSelection()
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
