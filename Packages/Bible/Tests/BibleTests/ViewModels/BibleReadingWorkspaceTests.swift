import Core
import Foundation
import os
import SwiftUI
import Testing
@testable import Bible

@Suite("Bible reading workspace")
@MainActor
struct BibleReadingWorkspaceTests {
    private final class TextLoader: BibleTextLoader, Sendable {
        struct State {
            var unavailable: Set<BiblePosition> = []
            var calls: [BiblePosition: Int] = [:]
        }
        let state = OSAllocatedUnfairLock(initialState: State())
        let words: Int
        let verseCount: Int
        init(words: Int = 1, verseCount: Int = 1) {
            self.words = words
            self.verseCount = verseCount
        }
        func loadChapter(bookId: String, chapterNumber: Int, translation: BibleTranslation) throws -> BibleChapter? {
            let position = BiblePosition(bookId: bookId, chapterNumber: chapterNumber)
            let unavailable = state.withLock {
                $0.calls[position, default: 0] += 1
                return $0.unavailable.contains(position)
            }
            guard !unavailable else { throw BibleReadingSourceError.unavailable }
            return BibleChapter(number: chapterNumber, paragraphs: (1...verseCount).map {
                .prose([.init(number: $0, text: String(repeating: "beginning word ", count: words))])
            })
        }
    }

    private actor Preferences: BibleReadingPreferencesRepository {
        var record: BibleReadingPreferencesRecord?
        var failLoad = false
        var failSave = false
        var saves = 0
        init(_ record: BibleReadingPreferencesRecord? = nil) { self.record = record }
        func configure(failLoad: Bool = false, failSave: Bool = false) {
            self.failLoad = failLoad
            self.failSave = failSave
        }
        func load() throws -> BibleReadingPreferencesRecord? {
            if failLoad { throw BibleReadingSourceError.unavailable }
            return record
        }
        func save(_ record: BibleReadingPreferencesRecord) throws {
            saves += 1
            if failSave { throw BibleReadingSourceError.unavailable }
            self.record = record
        }
    }

    private func style(width: CGFloat = 300, height: CGFloat = 180) -> BibleReadingWorkspaceViewModel.PaginationStyle {
        let typography = SuperTypography.make(.serif)
        let context = EnvironmentValues().fontResolutionContext
        return .init(size: .init(width: width, height: height),
                     body: typography.reading(24, relativeTo: nil).resolve(in: context),
                     heading: typography.reading(28, relativeTo: nil).resolve(in: context),
                     number: typography.font(size: 13).resolve(in: context))
    }

    private func workspace(loader: TextLoader = TextLoader(), chapter: Int = 3,
                           repository: (any BibleReadingPositionRepository)? = nil,
                           preferences: (any BibleReadingPreferencesRepository)? = nil) -> BibleReadingWorkspaceViewModel {
        .init(reader: .init(textLoader: loader, positionRepository: repository,
                            clock: FixedClock(Date(timeIntervalSince1970: 1)),
                            initialPosition: .init(bookId: "GEN", chapterNumber: chapter)),
              preferencesRepository: preferences)
    }

    private func start(_ model: BibleReadingWorkspaceViewModel, pageCount: Int = 2) async {
        model.updateLayout(style(), pageCount: pageCount)
        await model.load()
        await model._waitForPendingPagination()
    }

    private func turn(_ model: BibleReadingWorkspaceViewModel, _ direction: BibleChapterDirection) async {
        model.turn(direction)
        await model._waitForPendingPagination()
    }

    @Test("Layout arriving before restore still paginates, and long chapters round trip")
    func longChapterRoundTrip() async throws {
        let model = workspace(loader: TextLoader(words: 200))
        await start(model)
        let initial = model.visiblePages
        #expect(initial.count == 2)
        #expect(try #require(model.chapters[model.reader.position]).pages.count > 4)
        await turn(model, .next)
        #expect(model.visiblePages.first?.locator.utf16Offset ?? 0 > 0)
        #expect(model.visiblePages != initial)
        await turn(model, .previous)
        #expect(model.visiblePages == initial)
        #expect(!model.reader.canGoBack)
    }

    @Test("Short chapters share a spread and retain pairing outside the original cache")
    func boundedChapterSpreads() async throws {
        let model = workspace()
        await start(model)
        #expect(model.visiblePages.map(\.position.chapterNumber) == [3, 4])
        let initial = model.visiblePages
        for _ in 0..<8 {
            await turn(model, .next)
            #expect(model.visiblePages.count == 2)
            #expect(model.chapters.count <= 5)
        }
        #expect(model.visiblePages.map(\.position.chapterNumber) == [19, 20])
        #expect(model.chapters[.init(bookId: "GEN", chapterNumber: 3)] == nil)
        for _ in 0..<8 { await turn(model, .previous) }
        #expect(model.visiblePages == initial)
        await turn(model, .previous)
        #expect(model.visiblePages.map(\.position.chapterNumber) == [1, 2])
        #expect(!model.canTurnPrevious)
        let beginning = model.visiblePages
        await turn(model, .previous)
        #expect(model.visiblePages == beginning)
    }

    @Test("Explicit chapter opens on left and Previous then Next returns to it")
    func explicitChapter() async {
        let model = workspace()
        await start(model)
        model.reader.selectChapter(bookId: "GEN", chapterNumber: 8)
        model.explicitNavigationChanged()
        await model._waitForPendingPagination()
        #expect(model.visiblePages.map(\.position.chapterNumber) == [8, 9])
        await turn(model, .previous)
        #expect(model.visiblePages.map(\.position.chapterNumber) == [6, 7])
        await turn(model, .next)
        #expect(model.visiblePages.map(\.position.chapterNumber) == [8, 9])
    }

    @Test("An odd origin has a single beginning page without wrapping or duplicating")
    func oddBeginningAndEnd() async {
        let model = workspace(chapter: 2)
        await start(model)
        await turn(model, .previous)
        #expect(model.visiblePages.map(\.position.chapterNumber) == [1])
        #expect(model.startsWithBlankPage)
        #expect(model.isAtBeginning)
        #expect(!model.isAtEnd)
        #expect(!model.canTurnPrevious)
        await turn(model, .next)
        #expect(model.visiblePages.map(\.position.chapterNumber) == [2, 3])
        model.reader.selectChapter(bookId: "REV", chapterNumber: 22)
        model.explicitNavigationChanged()
        await model._waitForPendingPagination()
        #expect(model.visiblePages.map(\.position.chapterNumber) == [22])
        #expect(!model.startsWithBlankPage)
        #expect(!model.isAtBeginning)
        #expect(model.isAtEnd)
        #expect(!model.canTurnNext)
        let last = model.visiblePages
        await turn(model, .next)
        #expect(model.visiblePages == last)
        await turn(model, .previous)
        #expect(model.visiblePages.map(\.position.chapterNumber) == [20, 21])
        await turn(model, .next)
        #expect(model.visiblePages == last)
    }

    @Test("Compact pagination visits each page then recovers wide pairing")
    func adaptivePairing() async {
        let model = workspace()
        await start(model)
        let wide = model.visiblePages
        model.updateLayout(style(), pageCount: 1)
        await model._waitForPendingPagination()
        #expect(model.visiblePages == [wide[0]])
        await turn(model, .next)
        #expect(model.visiblePages == [wide[1]])
        model.updateLayout(style(), pageCount: 2)
        await model._waitForPendingPagination()
        #expect(model.visiblePages == wide)
        await turn(model, .next)
        #expect(model.visiblePages.map(\.position.chapterNumber) == [5, 6])
    }

    @Test("Reference jumps locate the requested verse and only Book consumes its scroll request")
    func referenceJump() async throws {
        let model = workspace(loader: TextLoader(words: 15, verseCount: 20))
        await start(model)
        model.reader.openReference(bookId: "GEN", chapterNumber: 5, verseStart: 17, verseEnd: 17)
        model.explicitNavigationChanged()
        await model._waitForPendingPagination()
        let target = BibleTextLocator(position: model.reader.position, translation: model.reader.translation, verseNumber: 17)
        let document = try #require(model.chapters[model.reader.position]).document
        #expect(model.visiblePages.contains { $0.contains(target, in: document) })
        #expect(model.reader.pendingScrollVerse == nil)
        #expect(model.reader.bookLocation?.current == target)
        model.selectMode(.study)
        model.reader.openReference(bookId: "GEN", chapterNumber: 5, verseStart: 12, verseEnd: 12)
        model.explicitNavigationChanged()
        model.updateLayout(style(width: 250), pageCount: 1)
        await model._waitForPendingPagination()
        #expect(model.reader.pendingScrollVerse == 12)
    }

    @Test("Source offsets survive reflow, immediate mode changes, and persisted restore")
    func offsetRestoreAndModeChanges() async throws {
        let repository = GRDBBibleReadingPositionRepository(database: try BibleDatabase.makeInMemory())
        let loader = TextLoader(words: 200)
        let model = workspace(loader: loader, repository: repository)
        await start(model)
        await turn(model, .next)
        let saved = try #require(model.reader.bookLocation)
        #expect(saved.current.utf16Offset > 0)
        model.updateLayout(style(width: 450, height: 260), pageCount: 2)
        model.selectMode(.compare)
        model.rememberVisibleVerse(saved.current.verseNumber)
        model.selectMode(.book)
        await model._waitForPendingPagination()
        let document = try #require(model.chapters[saved.current.position]).document
        #expect(model.visiblePages.contains { $0.contains(saved.current, in: document) })
        #expect(model.reader.bookLocation == saved)
        await model.reader.flushNavigationPersistence()
        let restored = workspace(loader: loader, repository: repository)
        await start(restored)
        #expect(restored.reader.bookLocation == saved)
        let restoredDocument = try #require(restored.chapters[saved.current.position]).document
        #expect(restored.visiblePages.contains { $0.contains(saved.current, in: restoredDocument) })
        #expect(restored.reader.position == saved.current.position)
        #expect(!restored.reader.canGoBack)
    }

    @Test("A missing adjacent chapter preserves readable pages and Retry never skips it")
    func missingNeighborRetryAndCache() async throws {
        let loader = TextLoader()
        let missing = BiblePosition(bookId: "GEN", chapterNumber: 4)
        loader.state.withLock { $0.unavailable.insert(missing) }
        let model = workspace(loader: loader)
        await start(model)
        #expect(model.visiblePages.map(\.position.chapterNumber) == [3])
        #expect(model.pageError != nil)
        #expect(!model.canTurnNext)
        #expect(!model.isAtEnd)
        let document = try #require(model.chapters[model.reader.position]).document.text
        model.updateLayout(style(), pageCount: 1)
        await model._waitForPendingPagination()
        #expect(model.chapters[model.reader.position]?.document.text === document)
        loader.state.withLock { $0.unavailable.remove(missing) }
        model.retryPages()
        await model._waitForPendingPagination()
        #expect(model.pageError == nil)
        #expect(model.canTurnNext)
        await turn(model, .next)
        #expect(model.visiblePages.map(\.position.chapterNumber) == [4])
    }

    @Test("Preference restore swaps conflicting secondary and failed writes can retry")
    func preferencesRetry() async {
        let preferences = Preferences(.init(mode: .study, secondaryTranslation: .kjv))
        let model = workspace(preferences: preferences)
        await start(model)
        #expect(model.mode == .study)
        #expect(model.secondaryTranslation == .web)
        await preferences.configure(failSave: true)
        model.selectMode(.compare)
        await model._waitForPendingPreferences()
        #expect(model.preferenceError != nil)
        await preferences.configure()
        await model.retryPreferences()
        #expect(model.preferenceError == nil)
        #expect(await preferences.record?.mode == .compare)
        model.reader.selectTranslation(.web)
        model.explicitNavigationChanged()
        #expect(model.secondaryTranslation == .kjv)
        await model._waitForPendingPreferences()
        #expect(await preferences.record?.secondaryTranslationId == "KJV")
    }

    @Test("Failed preference reads never write defaults and retry preserves new user choices")
    func preferencesReadFailure() async {
        let preferences = Preferences(.init(mode: .study, secondaryTranslation: .asv))
        await preferences.configure(failLoad: true)
        let model = workspace(preferences: preferences)
        await start(model)
        #expect(model.preferenceError != nil)
        model.selectMode(.compare)
        await model._waitForPendingPreferences()
        #expect(await preferences.saves == 0)
        await preferences.configure()
        await model.retryPreferences()
        #expect(model.mode == .compare)
        #expect(await preferences.record?.mode == .compare)
        #expect(model.preferenceError == nil)
    }

    @Test("Only the leading visible scrolling verse becomes the next Book anchor")
    func leadingVisibleVerse() async throws {
        let model = workspace(loader: TextLoader(words: 15, verseCount: 20))
        await start(model)
        model.selectMode(.compare)
        model.rememberVisibleVerses([9, 10, 11])
        model.selectMode(.book)
        await model._waitForPendingPagination()
        let target = BibleTextLocator(position: model.reader.position, translation: model.reader.translation, verseNumber: 9)
        let document = try #require(model.chapters[model.reader.position]).document
        #expect(model.visiblePages.contains { $0.contains(target, in: document) })
    }

    @Test("Decoration changes preserve source anchors and reuse unaffected chapter documents")
    func decorationInvalidation() async throws {
        let model = workspace(loader: TextLoader(words: 200))
        await start(model)
        await turn(model, .next)
        let anchor = try #require(model.reader.bookLocation).current
        let oldDocument = try #require(model.chapters[anchor.position]).document.text
        let neighbor = BiblePosition(bookId: "GEN", chapterNumber: 4)
        let neighborDocument = try #require(model.chapters[neighbor]).document.text
        let decoration = BiblePageDocument.Decorations(annotations: [1: [.verseRange(
            bookId: "GEN", chapterNumber: 3, verseStart: 1, verseEnd: 1),],])
        model.updateDecorations(decoration, for: anchor.position)
        await model._waitForPendingPagination()
        let chapter = try #require(model.chapters[anchor.position])
        #expect(chapter.document.text !== oldDocument)
        #expect(chapter.document.trailers.count == 1)
        #expect(model.chapters[neighbor]?.document.text === neighborDocument)
        #expect(model.visiblePages.contains { $0.contains(anchor, in: chapter.document) })
        model.updateDecorations(decoration, for: anchor.position)
        await model._waitForPendingPagination()
        #expect(model.chapters[anchor.position]?.document.text === chapter.document.text)
        #expect(model.reader.bookLocation?.current == anchor)
    }

    @Test("Manual paging suspends narration following and Resume returns to the captured source")
    func narrationFollowing() async throws {
        let model = workspace()
        await start(model)
        model.reader.startNarration()
        model.reader.narration._simulateEvent(.started(verseNumber: 1))
        model.followNarration()
        let original = try #require(model.reader.narrationSource)
        for _ in 0..<4 { await turn(model, .next) }
        #expect(!model.isFollowingNarration)
        #expect(model.chapters[original.position] == nil)
        model.followNarration()
        #expect(model.visiblePages.first?.position.chapterNumber == 11)
        model.resumeFollowing()
        await model._waitForPendingPagination()
        #expect(model.isFollowingNarration)
        #expect(model.visiblePages.first?.position == original.position)
        #expect(model.reader.position == original.position)
        await turn(model, .next)
        #expect(!model.isFollowingNarration)
        model.narrationSessionChanged()
        #expect(model.isFollowingNarration)
        model.followNarration()
        await model._waitForPendingPagination()
        #expect(model.visiblePages.first?.position == original.position)
    }

    @Test("A decoration update to an interior neighbor rebuilds its pages before navigation")
    func nonvisibleDecorationInvalidation() async throws {
        let model = workspace()
        await start(model, pageCount: 1)
        let neighbor = BiblePosition(bookId: "GEN", chapterNumber: 4)
        #expect(!model.visiblePages.contains { $0.position == neighbor })
        model.updateDecorations(.init(notes: [1: [.verseRange(bookId: "GEN", chapterNumber: 4,
                                                            verseStart: 1, verseEnd: 1),],]), for: neighbor)
        await model._waitForPendingPagination()
        await turn(model, .next)
        #expect(model.visiblePages.first?.position == neighbor)
        let chapter = try #require(model.chapters[neighbor])
        #expect(chapter.document.trailers.count == 1)
        #expect(model.visiblePages == chapter.pages)
    }

    @Test("Decoration updates during a yielded generation cannot publish its older snapshot")
    func decorationsDuringPagination() async throws {
        let model = workspace()
        await model.load()
        let neighbor = BiblePosition(bookId: "GEN", chapterNumber: 4)
        model._onNextPaginationYield {
            model.updateDecorations(.init(notes: [1: [.verseRange(bookId: "GEN", chapterNumber: 4,
                                                                verseStart: 1, verseEnd: 1),],]), for: neighbor)
        }
        model.updateLayout(style(), pageCount: 1)
        await model._waitForPendingPagination()
        await model._waitForPendingPagination()
        let chapter = try #require(model.chapters[neighbor])
        #expect(chapter.document.trailers.count == 1)
        await turn(model, .next)
        #expect(model.visiblePages == chapter.pages)
    }

    @Test("Decoration-only pages remain reachable through turning, reflow and persisted restore")
    func decorationPageRestore() async throws {
        let repository = GRDBBibleReadingPositionRepository(database: try BibleDatabase.makeInMemory())
        let model = workspace(repository: repository)
        let position = model.reader.position
        let decoration = BiblePageDocument.Decorations(notes: [1: (1...6).map {
            .verseRange(bookId: "GEN", chapterNumber: 3, verseStart: 1, verseEnd: $0)
        },])
        let small = style(width: 150, height: 42)
        model.updateDecorations(decoration, for: position)
        model.updateLayout(small, pageCount: 1)
        await model.load()
        await model._waitForPendingPagination()
        let chapter = try #require(model.chapters[position])
        #expect(chapter.pages.contains { $0.fragments(in: chapter.document).isEmpty })
        for (index, page) in chapter.pages.enumerated() {
            if index > 0 { await turn(model, .next) }
            #expect(model.visiblePages.first?.id == page.id)
            #expect(page.contains(page.locator, in: chapter.document))
            model.updateLayout(style(width: 165, height: 43), pageCount: 1)
            await model._waitForPendingPagination()
            let reflowed = try #require(model.chapters[position])
            #expect(model.visiblePages.contains { $0.contains(page.locator, in: reflowed.document) })
            model.updateLayout(small, pageCount: 1)
            await model._waitForPendingPagination()
            #expect(model.visiblePages.first?.id == page.id)
            guard index > 0 else { continue }
            await model.reader.flushNavigationPersistence()
            let restored = workspace(repository: repository)
            restored.updateDecorations(decoration, for: position)
            restored.updateLayout(small, pageCount: 1)
            await restored.load()
            await restored._waitForPendingPagination()
            #expect(restored.visiblePages.first?.id == page.id)
        }
    }

    @Test("Navigation restore retry reconciles Book and Compare without clearing the saved anchor",
          arguments: [BibleReadingMode.book, .compare])
    func restoreRetryReconcilesWorkspace(mode: BibleReadingMode) async throws {
        let repository = GatedBibleReadingPositionRepository()
        let preferences = Preferences(.init(mode: .study, secondaryTranslation: .asv))
        await preferences.configure(failLoad: true)
        let model = workspace(loader: TextLoader(words: 200), repository: repository, preferences: preferences)
        model.updateLayout(style(), pageCount: 1)
        let loading = Task { await model.load() }
        await repository.waitForLoadCall(count: 1)
        await repository.releaseNextLoad(.failure)
        await loading.value
        await model._waitForPendingPagination()
        model.selectMode(mode)
        #expect(model.reader.position == .init(bookId: "GEN", chapterNumber: 3))
        #expect(model.reader.navigationRestorationGeneration == 0)
        let locator = BibleTextLocator(position: .init(bookId: "JHN", chapterNumber: 3),
                                       translation: .web, verseNumber: 1, utf16Offset: 400)
        let location = BibleBookLocation(current: locator, spreadOrigin: locator)
        let retry = Task { await model.reader.retryNavigationPersistence() }
        await repository.waitForLoadCall(count: 2)
        await repository.releaseNextLoad(.success(.init(bookId: "JHN", chapterNumber: 3, translationId: "WEB",
                                                       updatedAt: Date(timeIntervalSince1970: 1),
                                                       bookLocationJSON: location.encoded())))
        await retry.value
        #expect(model.reader.navigationRestorationGeneration == 1)
        model.restoredNavigationChanged()
        await model._waitForPendingPagination()
        #expect(model.reader.bookLocation == location)
        #expect(model.reader.explicitNavigationGeneration == 0)
        #expect(!model.reader.canGoBack)
        #expect(model.comparisonSource?.position == locator.position)
        #expect(model.secondaryTranslation != model.reader.translation)
        if mode == .book {
            let chapter = try #require(model.chapters[locator.position])
            #expect(model.visiblePages.contains { $0.contains(locator, in: chapter.document) })
            await preferences.configure()
            await model.retryPreferences()
            #expect(model.mode == .study)
            #expect(await preferences.saves == 0)
        } else {
            #expect(model.reader.pendingScrollVerse == locator.verseNumber)
            model.selectMode(.book)
            await model._waitForPendingPagination()
            #expect(model.reader.bookLocation == location)
        }
    }
}
