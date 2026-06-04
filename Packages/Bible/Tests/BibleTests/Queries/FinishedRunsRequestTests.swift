import Foundation
import GRDB
import Testing
@testable import Bible

/// Tests for `FinishedRunsRequest` — the hub's "Recently finished" source:
/// terminal, non-cancelled runs newest-completed-first, each projected with its
/// book names and unit tallies.
@Suite("FinishedRunsRequest")
struct FinishedRunsRequestTests {
    private func makeFixture() throws -> (GRDBBulkAnnotationLedger, BibleDatabase) {
        let database = try BibleDatabase.makeInMemory()
        return (GRDBBulkAnnotationLedger(database: database), database)
    }

    private func fetch(_ database: BibleDatabase) throws -> [FinishedRunSummary] {
        try database.queue.read { db in
            try FinishedRunsRequest().fetch(db)
        }
    }

    private func run(
        _ id: String, status: BulkRunStatus, completedAt: Date?,
        haltReason: BulkRunHaltReason? = nil
    ) -> BulkAnnotationRunRecord {
        BulkAnnotationRunRecord(
            id: id, status: status, modelId: "m", haltReason: haltReason,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: completedAt ?? Date(timeIntervalSince1970: 0),
            completedAt: completedAt
        )
    }

    private func unit(
        _ id: String, run: String, ordinal: Int, book: String, name: String,
        chapter: Int, state: BulkUnitState, produced: Int = 0
    ) -> BulkAnnotationRunUnitRecord {
        BulkAnnotationRunUnitRecord(
            id: id, runId: run, ordinal: ordinal, kind: .chapter, bookId: book,
            bookName: name, chapterNumber: chapter, state: state, producedCount: produced,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("empty database yields no finished runs")
    func empty() throws {
        let (_, database) = try makeFixture()
        #expect(try fetch(database).isEmpty)
    }

    @Test("a completed run aggregates book names and produced counts")
    func completedRunAggregates() async throws {
        let (ledger, database) = try makeFixture()
        try await ledger.createRun(
            run("r1", status: .completed, completedAt: Date(timeIntervalSince1970: 100)),
            units: [
                unit("u0", run: "r1", ordinal: 0, book: "ROM", name: "Romans", chapter: 1, state: .done, produced: 5),
                unit("u1", run: "r1", ordinal: 1, book: "ROM", name: "Romans", chapter: 2, state: .done, produced: 7),
                unit("u2", run: "r1", ordinal: 2, book: "GAL", name: "Galatians", chapter: 1, state: .done, produced: 3),
            ]
        )
        let summaries = try fetch(database)
        #expect(summaries.count == 1)
        let s = try #require(summaries.first)
        #expect(s.runID == "r1")
        #expect(s.status == .completed)
        #expect(s.bookNames == ["Romans", "Galatians"])  // distinct, in ordinal order
        #expect(s.producedCount == 15)
        #expect(s.failedCount == 0)
        #expect(s.isRetryable == false)
    }

    @Test("a halted run reports its reason and failed count and is retryable")
    func failedRunReportsFailures() async throws {
        let (ledger, database) = try makeFixture()
        try await ledger.createRun(
            run("r2", status: .failed, completedAt: Date(timeIntervalSince1970: 200), haltReason: .quota),
            units: [
                unit("u0", run: "r2", ordinal: 0, book: "ROM", name: "Romans", chapter: 1, state: .done, produced: 4),
                unit("u1", run: "r2", ordinal: 1, book: "ROM", name: "Romans", chapter: 2, state: .failed),
                unit("u2", run: "r2", ordinal: 2, book: "ROM", name: "Romans", chapter: 3, state: .queued),
            ]
        )
        let s = try #require(try fetch(database).first)
        #expect(s.status == .failed)
        #expect(s.haltReason == .quota)
        #expect(s.producedCount == 4)
        #expect(s.failedCount == 1)
        #expect(s.isRetryable)
    }

    @Test("active and cancelled runs are excluded; terminal runs sort newest-first")
    func excludesActiveAndCancelledAndSorts() async throws {
        let (ledger, database) = try makeFixture()
        // Active (running) — excluded.
        try await ledger.createRun(
            run("active", status: .running, completedAt: nil),
            units: [unit("a0", run: "active", ordinal: 0, book: "ROM", name: "Romans", chapter: 1, state: .generating)]
        )
        // Cancelled — terminal but a deliberate abort, excluded.
        try await ledger.createRun(
            run("cancelled", status: .cancelled, completedAt: Date(timeIntervalSince1970: 50)),
            units: [unit("c0", run: "cancelled", ordinal: 0, book: "GEN", name: "Genesis", chapter: 1, state: .done, produced: 2)]
        )
        // Two completed runs at different times.
        try await ledger.createRun(
            run("older", status: .completed, completedAt: Date(timeIntervalSince1970: 100)),
            units: [unit("o0", run: "older", ordinal: 0, book: "ROM", name: "Romans", chapter: 1, state: .done, produced: 1)]
        )
        try await ledger.createRun(
            run("newer", status: .completed, completedAt: Date(timeIntervalSince1970: 300)),
            units: [unit("n0", run: "newer", ordinal: 0, book: "GAL", name: "Galatians", chapter: 1, state: .done, produced: 1)]
        )

        let summaries = try fetch(database)
        #expect(summaries.map(\.runID) == ["newer", "older"])  // newest-completed first
    }
}
