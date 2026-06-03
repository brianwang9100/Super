import Testing
@testable import Bible

/// Tests for `FakeBulkAnnotationRunner` — the in-memory engine stand-in driving
/// the bulk UI. Stepped deterministically (`autoAdvance: false`, manual
/// `step()`), so there are no sleeps or yield-polling.
@Suite("FakeBulkAnnotationRunner")
@MainActor
struct FakeBulkAnnotationRunnerTests {
    private func plan() -> BulkRunPlan {
        BulkRunPlan(books: [
            BulkRunPlan.Book(bookID: "ROM", name: "Romans", chapters: [1, 2, 3])
        ])
    }

    @Test("starting seeds the first unit generating and the rest queued")
    func startsFirstGenerating() {
        let runner = FakeBulkAnnotationRunner(autoAdvance: false)
        runner.start(plan())
        let chapters = runner.snapshot?.books.first?.chapters ?? []
        #expect(chapters.map(\.state) == [.generating, .queued, .queued])
        #expect(runner.snapshot?.isRunning == true)
    }

    @Test("each step finishes the active unit and promotes the next")
    func stepsThrough() {
        let runner = FakeBulkAnnotationRunner(autoAdvance: false)
        runner.start(plan())
        runner.step()
        #expect(runner.snapshot?.books.first?.chapters.map(\.state) == [.done, .generating, .queued])
        runner.step()
        #expect(runner.snapshot?.books.first?.chapters.map(\.state) == [.done, .done, .generating])
        runner.step()
        #expect(runner.snapshot?.books.first?.chapters.map(\.state) == [.done, .done, .done])
    }

    @Test("a seeded chapter fails once, then succeeds on retry")
    func failsThenRetries() {
        let failing = ChapterRef(bookID: "ROM", number: 1)
        let runner = FakeBulkAnnotationRunner(autoAdvance: false, failOnce: [failing])
        runner.start(plan())
        runner.step() // chapter 1 was generating → fails
        #expect(runner.snapshot?.books.first?.chapters.first?.state == .failed)
        #expect(runner.snapshot?.failedCount == 1)

        runner.retry(failing)
        #expect(runner.snapshot?.books.first?.chapters.first?.state == .generating)
        runner.step()
        #expect(runner.snapshot?.books.first?.chapters.first?.state == .done)
    }

    @Test("retry-all re-queues every failed chapter")
    func retryAll() {
        let runner = FakeBulkAnnotationRunner(
            autoAdvance: false,
            failOnce: [ChapterRef(bookID: "ROM", number: 1), ChapterRef(bookID: "ROM", number: 2)]
        )
        runner.start(plan())
        runner.step() // ch1 fails → ch2 generating
        runner.step() // ch2 fails → ch3 generating
        #expect(runner.snapshot?.failedCount == 2)
        runner.retryAllFailed()
        #expect(runner.snapshot?.failedCount == 0)
    }

    @Test("toggling pause stops and resumes the running flag")
    func pause() {
        let runner = FakeBulkAnnotationRunner(autoAdvance: false)
        runner.start(plan())
        runner.togglePause()
        #expect(runner.snapshot?.isRunning == false)
        runner.togglePause()
        #expect(runner.snapshot?.isRunning == true)
    }

    @Test("cancel clears the job")
    func cancel() {
        let runner = FakeBulkAnnotationRunner(autoAdvance: false)
        runner.start(plan())
        runner.cancel()
        #expect(runner.snapshot == nil)
    }

    @Test("onSnapshotChange fires on every mutation")
    func notifies() {
        let runner = FakeBulkAnnotationRunner(autoAdvance: false)
        var count = 0
        runner.onSnapshotChange = { count += 1 }
        runner.start(plan())
        runner.step()
        #expect(count >= 2)
    }
}
