import Core
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

    private let textLoader: any BibleTextLoader
    private let catalog: BibleBookCatalog
    private let positionRepository: (any BibleReadingPositionRepository)?
    private let clock: any Clock

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
        initialPosition: BiblePosition = BibleScreenViewModel.defaultPosition
    ) {
        self.textLoader = textLoader
        self.catalog = catalog
        self.positionRepository = positionRepository
        self.clock = clock
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
        applyCurrentChapter()
        persist()
    }

    /// Open the book picker. It starts with every book collapsed; the
    /// reader taps a book to reveal its chapter grid.
    public func presentBookSheet() {
        bookSheet = BibleBookSheetViewModel(expandedBookId: nil, catalog: catalog)
    }

    public func dismissBookSheet() {
        bookSheet = nil
    }

    /// Open the translation picker.
    public func presentTranslationSheet() {
        isTranslationSheetPresented = true
    }

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
        applyCurrentChapter()
        persist()
        bookSheet = nil
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
