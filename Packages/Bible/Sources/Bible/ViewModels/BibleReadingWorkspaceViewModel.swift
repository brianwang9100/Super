import Core
import Observation
import SwiftUI

@MainActor
@Observable
final class BibleReadingWorkspaceViewModel {
    struct PaginationStyle: Equatable {
        let size: CGSize
        let body: Font.Resolved
        let heading: Font.Resolved
        let number: Font.Resolved
    }

    struct ChapterPages {
        let source: BibleReadingSource
        let document: BiblePageDocument
        let pages: [BiblePage]
        let decorations: BiblePageDocument.Decorations
    }

    let reader: BibleScreenViewModel
    private let preferencesRepository: (any BibleReadingPreferencesRepository)?
    private(set) var mode: BibleReadingMode = .book
    private(set) var secondaryTranslation: BibleTranslation = .web
    private(set) var comparisonSource: BibleReadingSource?
    private(set) var comparisonError: String?
    private(set) var preferenceError: String?
    private(set) var isRestoring = true
    private(set) var pageError: String?
    private(set) var isPaginating = false
    private(set) var visiblePages: [BiblePage] = []
    private(set) var chapters: [BiblePosition: ChapterPages] = [:]
    private(set) var isFollowingNarration = true
    private(set) var canTurnPrevious = false
    private(set) var canTurnNext = false
    private(set) var pageCount = 2
    var startsWithBlankPage: Bool { pageCount == 2 && leadingIndex == -1 }
    var isAtBeginning: Bool {
        guard let first = visiblePages.first,
              BibleBookCatalog.standard.step(from: first.position, direction: .previous) == nil else { return false }
        return chapters[first.position]?.pages.first?.id == first.id
    }
    var isAtEnd: Bool {
        guard let last = visiblePages.last,
              BibleBookCatalog.standard.step(from: last.position, direction: .next) == nil else { return false }
        return chapters[last.position]?.pages.last?.id == last.id
    }

    private var style: PaginationStyle?
    private var current: BibleTextLocator?
    private var origin: BibleTextLocator?
    private var pages: [BiblePage] = []
    private var leadingIndex = 0
    private var generation = 0
    private var loadTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var preferenceLoadTask: Task<Void, Never>?
    private var preferencesLoaded = false
    private var pendingPreferences: BibleReadingPreferencesRecord?
    private var cachedStyle: PaginationStyle?
    private var decorations: [BiblePosition: BiblePageDocument.Decorations] = [:]
    private var lastFollowedVerse: BibleTextLocator?
    @ObservationIgnored private var paginationYieldObserver: (@MainActor () -> Void)?
    private var previousTranslation: BibleTranslation

    init(reader: BibleScreenViewModel, preferencesRepository: (any BibleReadingPreferencesRepository)? = nil) {
        self.reader = reader
        self.preferencesRepository = preferencesRepository
        previousTranslation = reader.translation
        secondaryTranslation = reader.translation == .web ? .kjv : .web
    }

    func load() async {
        if let preferenceLoadTask { await preferenceLoadTask.value; return }
        guard isRestoring else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await reader.load()
            await restorePreferences()
            previousTranslation = reader.translation
            current = reader.bookLocation?.current
            origin = reader.bookLocation?.spreadOrigin
            isRestoring = false
            refreshComparison()
            repaginate()
        }
        preferenceLoadTask = task
        await task.value
        preferenceLoadTask = nil
    }

    func selectMode(_ selected: BibleReadingMode) {
        guard !isRestoring, mode != selected else { return }
        cancelPagination()
        mode = selected
        reader.resetImmersive()
        if selected != .book, let current { reader.requestWorkspaceScroll(to: current.verseNumber) }
        if selected == .compare { refreshComparison() }
        if selected == .book {
            persistCurrentAnchor()
            repaginate()
        }
        savePreferences()
    }

    func selectSecondaryTranslation(_ translation: BibleTranslation) {
        guard !isRestoring, translation != reader.translation else { return }
        secondaryTranslation = translation
        refreshComparison()
        savePreferences()
    }

    func restoredNavigationChanged() {
        cancelPagination()
        reconcilePrimaryTranslation(persistPreferences: false)
        current = reader.bookLocation?.current ?? BibleTextLocator(
            position: reader.position, translation: reader.translation,
            verseNumber: reader.pendingScrollVerse ?? reader.chapter?.coalescedVerses().first?.number ?? 1)
        origin = reader.bookLocation?.spreadOrigin ?? current
        narrationSessionChanged()
        refreshComparison()
        if mode != .book, let current { reader.requestWorkspaceScroll(to: current.verseNumber) }
        repaginate()
    }

    private func reconcilePrimaryTranslation(persistPreferences: Bool = true) {
        if reader.translation != previousTranslation {
            if secondaryTranslation == reader.translation { secondaryTranslation = previousTranslation }
            previousTranslation = reader.translation
            if persistPreferences { savePreferences() }
        }
    }

    func explicitNavigationChanged() {
        reconcilePrimaryTranslation()
        current = BibleTextLocator(position: reader.position, translation: reader.translation,
                                   verseNumber: reader.pendingScrollVerse ?? reader.chapter?.coalescedVerses().first?.number ?? 1)
        origin = current
        if mode == .book { persistCurrentAnchor() }
        narrationSessionChanged()
        refreshComparison()
        repaginate()
    }

    func updateLayout(_ style: PaginationStyle, pageCount: Int) {
        guard style != self.style || pageCount != self.pageCount || visiblePages.isEmpty else { return }
        self.style = style
        self.pageCount = max(1, min(2, pageCount))
        repaginate()
    }

    func refreshComparison() {
        do {
            comparisonSource = try reader.loadReadingSource(position: reader.position, translation: secondaryTranslation)
            comparisonError = nil
        } catch {
            comparisonSource = nil
            comparisonError = "This translation's chapter couldn't be loaded."
        }
    }

    func retryPages() { repaginate() }

    func turn(_ direction: BibleChapterDirection) {
        guard mode == .book, !isPaginating else { return }
        isFollowingNarration = false
        let next = leadingIndex + (direction == .next ? pageCount : -pageCount)
        if next < pages.count, next >= (pairedIndex(containing: 0) == -1 ? -1 : 0) {
            show(at: next, persist: true)
            replenishIfNeeded()
        }
    }

    func narrationSessionChanged() {
        isFollowingNarration = true
        lastFollowedVerse = nil
    }

    func followNarration() {
        guard mode == .book, isFollowingNarration, reader.selectedVerses.isEmpty,
              let source = reader.narrationSource,
              let verse = reader.narration.currentVerseNumber,
              source.translation == reader.translation else { return }
        let target = BibleTextLocator(position: source.position, translation: source.translation, verseNumber: verse)
        guard target != lastFollowedVerse else { return }
        lastFollowedVerse = target
        if let chapter = chapters[source.position],
           let index = pages.firstIndex(where: { $0.contains(target, in: chapter.document) }) {
            guard !visiblePages.contains(where: { $0.id == pages[index].id }) else { return }
            show(at: pageCount == 2 ? pairedIndex(containing: index) : index, persist: true)
            replenishIfNeeded()
        } else {
            current = target
            origin = target
            repaginate(persist: true)
        }
    }

    func resumeFollowing() {
        isFollowingNarration = true
        lastFollowedVerse = nil
        followNarration()
    }

    func rememberVisibleVerses(_ verses: Set<Int>) {
        if let leading = verses.min() { rememberVisibleVerse(leading) }
    }

    func rememberVisibleVerse(_ verse: Int) {
        guard mode != .book, let source = reader.primarySource else { return }
        // A remounted scroll renderer reports its anchor verse again; keep its word offset.
        guard current?.position != source.position || current?.translationId != source.translation.rawValue
                || current?.verseNumber != verse else { return }
        current = BibleTextLocator(position: source.position, translation: source.translation, verseNumber: verse)
        origin = current
    }

    func updateDecorations(_ value: BiblePageDocument.Decorations, for position: BiblePosition) {
        guard decorations[position, default: .init()] != value else { return }
        decorations[position] = value
        if chapters[position] != nil || isPaginating { repaginate() }
    }

    private func persistCurrentAnchor() {
        guard let current, current.position == reader.position,
              current.translationId == reader.translation.rawValue else { return }
        let location = BibleBookLocation(current: current, spreadOrigin: origin ?? current)
        if reader.bookLocation != location { reader.saveBookLocation(location) }
    }

    private func cancelPagination() {
        generation += 1
        loadTask?.cancel()
        isPaginating = false
    }

    private func repaginate(persist: Bool = false) {
        guard mode == .book, let style, !reader.isRestoringNavigation, !isRestoring else { return }
        cancelPagination()
        let token = generation
        let location = current ?? reader.bookLocation?.current
            ?? BibleTextLocator(position: reader.position, translation: reader.translation)
        let spreadOrigin = origin ?? reader.bookLocation?.spreadOrigin ?? location
        let translation = reader.translation
        let reusable = cachedStyle == style ? chapters : [:]
        let chapterDecorations = decorations
        isPaginating = true
        pageError = nil
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                @MainActor func paginate(_ position: BiblePosition) throws -> ChapterPages {
                    let decoration = chapterDecorations[position, default: .init()]
                    if let cached = reusable[position], cached.source.translation == translation,
                       cached.decorations == decoration { return cached }
                    let source = try reader.loadReadingSource(position: position, translation: translation)
                    let document = BiblePageDocument(chapter: source.chapter, position: position, translation: translation,
                                                     bodyFont: style.body.ctFont, headingFont: style.heading.ctFont,
                                                     numberFont: style.number.ctFont,
                                                     decorations: decoration)
                    return ChapterPages(source: source, document: document,
                                        pages: try BiblePaginator.paginate(document, size: style.size), decorations: decoration)
                }
                let catalog = BibleBookCatalog.standard
                let active = try paginate(location.position)
                var loaded = [location.position: active]
                var ordered = active.pages
                var neighborFailed = false
                for direction in [BibleChapterDirection.previous, .next] {
                    var position = location.position
                    for _ in 0..<2 {
                        try Task.checkCancellation()
                        guard let adjacent = catalog.step(from: position, direction: direction) else { break }
                        do {
                            let chapter = try paginate(adjacent)
                            loaded[adjacent] = chapter
                            if direction == .previous { ordered.insert(contentsOf: chapter.pages, at: 0) } else { ordered.append(contentsOf: chapter.pages) }
                            position = adjacent
                        } catch {
                            neighborFailed = true
                            break // Never join pages across an unavailable chapter.
                        }
                        let observer = paginationYieldObserver
                        paginationYieldObserver = nil
                        observer?()
                        await Task.yield()
                    }
                }
                guard token == generation, !Task.isCancelled, mode == .book else { return }
                chapters = loaded
                pages = ordered
                cachedStyle = style
                decorations = decorations.filter { loaded[$0.key] != nil }
                current = location
                origin = spreadOrigin
                let index = pages.firstIndex { $0.contains(location, in: active.document) }
                    ?? pages.firstIndex { $0.position == location.position } ?? 0
                // Rebase parity to a nearby source anchor, keeping the chapter cache bounded.
                if loaded[spreadOrigin.position] == nil { origin = location }
                show(at: pageCount == 2 ? pairedIndex(containing: index) : index, persist: persist)
                pageError = neighborFailed ? "An adjacent chapter couldn't be loaded. Try again." : nil
                isPaginating = false
                _ = reader.consumePendingScrollVerse()
            } catch is CancellationError {
                return
            } catch {
                guard token == generation else { return }
                visiblePages = []
                canTurnPrevious = false
                canTurnNext = false
                pageError = error as? BiblePaginationError == .viewportTooSmall
                    ? "Make this window taller or wider to show a page at your text size."
                    : "This chapter couldn't be loaded. Try again."
                isPaginating = false
            }
        }
    }

    private func pairedIndex(containing index: Int) -> Int {
        guard let origin, let chapter = chapters[origin.position],
              let originIndex = pages.firstIndex(where: { $0.contains(origin, in: chapter.document) }) else { return index }
        let remainder = ((index - originIndex) % 2 + 2) % 2
        return index - remainder
    }

    private func show(at index: Int, persist: Bool) {
        let index = pageCount == 1 ? max(0, index) : index
        guard index >= -1, index < pages.count else { return }
        leadingIndex = index
        visiblePages = Array(pages[max(0, index)..<min(pages.count, index + pageCount)])
        canTurnPrevious = index > 0
        canTurnNext = index + pageCount < pages.count
        if persist, let page = visiblePages.first {
            current = page.locator
            let paired = pairedIndex(containing: index)
            if pages.indices.contains(paired) { origin = pages[paired].locator }
            let location = BibleBookLocation(current: page.locator, spreadOrigin: origin ?? page.locator)
            reader.saveBookLocation(location)
        }
    }

    private func replenishIfNeeded() {
        guard let current, let first = pages.first, let last = pages.last else { return }
        if current.position == first.position || visiblePages.last?.position == last.position {
            repaginate()
        }
    }

    private func restorePreferences() async {
        do {
            let saved = try await preferencesRepository?.load()
            preferencesLoaded = true
            preferenceError = nil
            if pendingPreferences == nil {
                mode = saved?.mode ?? .book
                secondaryTranslation = saved?.secondaryTranslation(primary: reader.translation)
                    ?? (reader.translation == .web ? .kjv : .web)
            }
        } catch {
            preferenceError = "Couldn't restore reading preferences. Try again."
        }
    }

    func retryPreferences() async {
        if !preferencesLoaded {
            cancelPagination()
            await restorePreferences()
            refreshComparison()
            repaginate()
        }
        if preferencesLoaded, pendingPreferences != nil { savePreferences() }
        await persistTask?.value
    }

    private func savePreferences() {
        guard !isRestoring, let preferencesRepository else { return }
        let record = BibleReadingPreferencesRecord(mode: mode, secondaryTranslation: secondaryTranslation)
        pendingPreferences = record
        guard preferencesLoaded else { return }
        let previous = persistTask
        persistTask = Task { [weak self] in
            await previous?.value
            do {
                try await preferencesRepository.save(record)
                if self?.pendingPreferences == record { self?.pendingPreferences = nil }
                self?.preferenceError = nil
            } catch { self?.preferenceError = "Couldn't save reading preferences. Try again." }
        }
    }

    func _onNextPaginationYield(_ observer: @escaping @MainActor () -> Void) { paginationYieldObserver = observer }
    func _waitForPendingPagination() async { await loadTask?.value }
    func _waitForPendingPreferences() async { await persistTask?.value }
}
