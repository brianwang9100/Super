import Foundation
import GRDB
import Testing
@testable import Bible

@Suite("GRDBBulkAnnotationLedger")
struct BulkAnnotationLedgerTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeFixture() throws -> GRDBBulkAnnotationLedger {
        try GRDBBulkAnnotationLedger(database: BibleDatabase.makeInMemory())
    }

    private func run(
        id: String,
        status: BulkRunStatus,
        haltReason: BulkRunHaltReason? = nil,
        completedAt: Date? = nil,
        createdAt: Date? = nil
    ) -> BulkAnnotationRunRecord {
        BulkAnnotationRunRecord(
            id: id,
            status: status,
            modelId: "test-model",
            haltReason: haltReason,
            createdAt: createdAt ?? t0,
            updatedAt: createdAt ?? t0,
            completedAt: completedAt
        )
    }

    private func unit(
        id: String,
        runId: String,
        ordinal: Int,
        kind: BulkRunUnitKind = .chapter,
        chapter: Int? = 1,
        state: BulkUnitState = .queued
    ) -> BulkAnnotationRunUnitRecord {
        BulkAnnotationRunUnitRecord(
            id: id,
            runId: runId,
            ordinal: ordinal,
            kind: kind,
            bookId: "ROM",
            bookName: "Romans",
            chapterNumber: chapter,
            state: state,
            updatedAt: t0
        )
    }

    // MARK: - Create + read

    @Test("createRun round-trips the run and its units in ordinal order")
    func createRoundTrips() async throws {
        let ledger = try makeFixture()
        try await ledger.createRun(
            run(id: "r1", status: .running),
            units: [
                unit(id: "u2", runId: "r1", ordinal: 2, chapter: 2),
                unit(id: "u0", runId: "r1", ordinal: 0, kind: .bookPrologue, chapter: nil),
                unit(id: "u1", runId: "r1", ordinal: 1, chapter: 1),
            ]
        )

        let fetched = try await ledger.run(id: "r1")
        #expect(fetched?.id == "r1")
        #expect(fetched?.status == .running)
        #expect(fetched?.modelId == "test-model")

        let units = try await ledger.units(runId: "r1")
        #expect(units.map(\.id) == ["u0", "u1", "u2"])
        #expect(units.first?.kind == .bookPrologue)
        #expect(units.first?.chapterNumber == nil)
    }

    @Test("run(id:) returns nil for an unknown id")
    func runUnknownIsNil() async throws {
        let ledger = try makeFixture()
        #expect(try await ledger.run(id: "missing") == nil)
    }

    @Test("createRun is atomic — a failing unit insert rolls back the run too")
    func createRunIsAtomic() async throws {
        let ledger = try makeFixture()
        // A duplicate key fails after the first unit insert; the run and every unit must roll back.
        await #expect(throws: (any Error).self) {
            try await ledger.createRun(run(id: "r1", status: .running), units: [
                unit(id: "dup", runId: "r1", ordinal: 0),
                unit(id: "dup", runId: "r1", ordinal: 1, chapter: 2),
            ])
        }
        #expect(try await ledger.run(id: "r1") == nil)
        #expect(try await ledger.units(runId: "r1").isEmpty)
    }

    @Test("the schema rejects a run whose completedAt disagrees with its status")
    func completedAtInvariantEnforced() async throws {
        let ledger = try makeFixture()
        await #expect(throws: (any Error).self) {
            try await ledger.createRun(
                run(id: "bad-active", status: .running, completedAt: t0), units: []
            )
        }
        await #expect(throws: (any Error).self) {
            try await ledger.createRun(
                run(id: "bad-terminal", status: .completed, completedAt: nil), units: []
            )
        }
    }

    // MARK: - Active run

    @Test("activeRun returns the running/paused run, nil when only terminal runs exist")
    func activeRunQuery() async throws {
        let ledger = try makeFixture()
        try await ledger.createRun(run(id: "done", status: .completed, completedAt: t0), units: [])
        #expect(try await ledger.activeRun() == nil)

        try await ledger.createRun(run(id: "live", status: .paused), units: [])
        let active = try await ledger.activeRun()
        #expect(active?.id == "live")
        #expect(active?.status == .paused)
    }

    // MARK: - Upserts

    @Test("saveUnit updates state, attempt, produced, and error")
    func saveUnitUpdates() async throws {
        let ledger = try makeFixture()
        try await ledger.createRun(run(id: "r1", status: .running), units: [
            unit(id: "u1", runId: "r1", ordinal: 0, state: .generating),
        ])

        var u = try #require(try await ledger.units(runId: "r1").first)
        u.state = .failed
        u.attemptCount = 3
        u.producedCount = 0
        u.errorMessage = "rate limited"
        try await ledger.saveUnit(u)

        let reread = try #require(try await ledger.units(runId: "r1").first)
        #expect(reread.state == .failed)
        #expect(reread.attemptCount == 3)
        #expect(reread.errorMessage == "rate limited")
    }

    @Test("saveRun transitions status and sets completedAt")
    func saveRunTransitions() async throws {
        let ledger = try makeFixture()
        try await ledger.createRun(run(id: "r1", status: .running), units: [])

        var r = try #require(try await ledger.run(id: "r1"))
        r.status = .completed
        r.completedAt = t0.addingTimeInterval(120)
        r.updatedAt = t0.addingTimeInterval(120)
        try await ledger.saveRun(r)

        let reread = try #require(try await ledger.run(id: "r1"))
        #expect(reread.status == .completed)
        #expect(reread.completedAt == t0.addingTimeInterval(120))
        #expect(try await ledger.activeRun() == nil)
    }

    // MARK: - Delete + cascade

    @Test("deleteRun removes the run and cascades to its units")
    func deleteCascades() async throws {
        let ledger = try makeFixture()
        try await ledger.createRun(run(id: "r1", status: .running), units: [
            unit(id: "u1", runId: "r1", ordinal: 0),
            unit(id: "u2", runId: "r1", ordinal: 1, chapter: 2),
        ])

        try await ledger.deleteRun(id: "r1")

        #expect(try await ledger.run(id: "r1") == nil)
        #expect(try await ledger.units(runId: "r1").isEmpty)
    }

    // MARK: - Completed-run sweep

    @Test("deleteRunsCompleted sweeps only terminal runs older than the cutoff")
    func sweepRespectsCutoffAndActiveRuns() async throws {
        let ledger = try makeFixture()
        let cutoff = t0.addingTimeInterval(24 * 60 * 60)
        try await ledger.createRun(run(id: "old", status: .completed, completedAt: cutoff.addingTimeInterval(-60)), units: [])
        // The cutoff is strict: a run completed exactly at the boundary must survive.
        try await ledger.createRun(run(id: "boundary", status: .completed, completedAt: cutoff), units: [])
        try await ledger.createRun(run(id: "fresh", status: .cancelled, completedAt: cutoff.addingTimeInterval(60)), units: [])
        try await ledger.createRun(run(id: "live", status: .running), units: [])

        try await ledger.deleteRunsCompleted(before: cutoff)

        #expect(try await ledger.run(id: "old") == nil)
        #expect(try await ledger.run(id: "boundary") != nil)
        #expect(try await ledger.run(id: "fresh") != nil)
        #expect(try await ledger.run(id: "live") != nil)
    }

    @Test("completedRuns returns terminal runs newest-completed first")
    func completedRunsOrdering() async throws {
        let ledger = try makeFixture()
        try await ledger.createRun(run(id: "early", status: .completed, completedAt: t0.addingTimeInterval(10)), units: [])
        try await ledger.createRun(run(id: "late", status: .failed, haltReason: .quota, completedAt: t0.addingTimeInterval(50)), units: [])
        try await ledger.createRun(run(id: "live", status: .running), units: [])

        let completed = try await ledger.completedRuns()
        #expect(completed.map(\.id) == ["late", "early"])
        #expect(completed.first?.haltReason == .quota)
    }
}
