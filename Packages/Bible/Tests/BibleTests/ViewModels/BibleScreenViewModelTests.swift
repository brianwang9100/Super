import Core
import Foundation
import Testing
@testable import Bible

/// Tests for `BibleScreenViewModel` — default and restored reading position,
/// chapter stepping (within a book, across book boundaries, and the no-op at
/// the canon's ends), and that each step persists.
@Suite("BibleScreenViewModel")
@MainActor
struct BibleScreenViewModelTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeViewModel(
        repository: (any BibleReadingPositionRepository)? = nil,
        at position: BiblePosition = BibleScreenViewModel.defaultPosition
    ) -> BibleScreenViewModel {
        BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
            positionRepository: repository,
            clock: FixedClock(now),
            initialPosition: position
        )
    }

    @Test("load with no persisted position opens the default chapter")
    func loadDefault() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        #expect(viewModel.position == BibleScreenViewModel.defaultPosition)
        #expect(viewModel.bookName == "1 Peter")
        #expect(viewModel.chapter?.number == 2)
    }

    @Test("load restores a persisted position")
    func loadPersisted() async throws {
        let repository = GRDBBibleReadingPositionRepository(
            database: try BibleDatabase.makeInMemory()
        )
        try await repository.save(BibleReadingPositionRecord(
            bookId: "ROM", chapterNumber: 8, translationId: "WEB", updatedAt: now
        ))
        let viewModel = makeViewModel(repository: repository)
        await viewModel.load()
        #expect(viewModel.position == BiblePosition(bookId: "ROM", chapterNumber: 8))
        #expect(viewModel.bookName == "Romans")
        #expect(viewModel.chapter?.number == 8)
    }

    @Test("stepping forward advances the chapter and persists it")
    func stepForwardPersists() async throws {
        let repository = GRDBBibleReadingPositionRepository(
            database: try BibleDatabase.makeInMemory()
        )
        let viewModel = makeViewModel(repository: repository)
        await viewModel.load()                         // 1 Peter 2
        viewModel.stepChapter(.next)                    // 1 Peter 3
        #expect(viewModel.position == BiblePosition(bookId: "1PE", chapterNumber: 3))
        #expect(viewModel.chapter?.number == 3)

        await viewModel._waitForPendingPersist()
        let saved = try await repository.load()
        #expect(saved?.bookId == "1PE")
        #expect(saved?.chapterNumber == 3)
        #expect(saved?.updatedAt == now)
    }

    @Test("rapid steps persist the final position once drained")
    func rapidStepsPersistFinalPosition() async throws {
        let repository = GRDBBibleReadingPositionRepository(
            database: try BibleDatabase.makeInMemory()
        )
        let viewModel = makeViewModel(repository: repository)
        await viewModel.load()                          // 1 Peter 2
        viewModel.stepChapter(.next)                     // 1 Peter 3
        viewModel.stepChapter(.next)                     // 1 Peter 4
        await viewModel._waitForPendingPersist()
        let saved = try await repository.load()
        #expect(saved?.bookId == "1PE")
        #expect(saved?.chapterNumber == 4)
    }

    @Test("stepping forward past the last chapter crosses into the next book")
    func stepForwardCrossesBook() async {
        let viewModel = makeViewModel()
        await viewModel.load()
        // 1 Peter has 5 chapters; step from 2 to its last, then once more.
        for _ in 0..<3 { viewModel.stepChapter(.next) }   // 1PE 2 → 5
        #expect(viewModel.position == BiblePosition(bookId: "1PE", chapterNumber: 5))
        viewModel.stepChapter(.next)
        #expect(viewModel.position == BiblePosition(bookId: "2PE", chapterNumber: 1))
        #expect(viewModel.bookName == "2 Peter")
    }

    @Test("Genesis 1 cannot step backward and a step there is a no-op")
    func genesisStartCannotStepBackward() async {
        let viewModel = makeViewModel(at: BiblePosition(bookId: "GEN", chapterNumber: 1))
        await viewModel.load()
        #expect(viewModel.canStepBackward == false)
        #expect(viewModel.previousChapterLabel == nil)
        viewModel.stepChapter(.previous)
        #expect(viewModel.position == BiblePosition(bookId: "GEN", chapterNumber: 1))
    }

    @Test("Revelation 22 cannot step forward and a step there is a no-op")
    func revelationEndCannotStepForward() async {
        let viewModel = makeViewModel(at: BiblePosition(bookId: "REV", chapterNumber: 22))
        await viewModel.load()
        #expect(viewModel.canStepForward == false)
        #expect(viewModel.nextChapterLabel == nil)
        viewModel.stepChapter(.next)
        #expect(viewModel.position == BiblePosition(bookId: "REV", chapterNumber: 22))
    }

    @Test("footer labels name the adjacent chapters")
    func footerLabels() async {
        let viewModel = makeViewModel()
        await viewModel.load()                          // 1 Peter 2
        #expect(viewModel.previousChapterLabel == "1 Peter 1")
        #expect(viewModel.nextChapterLabel == "1 Peter 3")
    }

    @Test("a failing text loader leaves the chapter unavailable")
    func failedLoadLeavesChapterNil() async {
        let viewModel = BibleScreenViewModel(textLoader: ThrowingBibleTextLoader())
        await viewModel.load()
        #expect(viewModel.chapter == nil)
    }
}
