import Foundation
import GRDB
import Testing
@testable import Bible

/// Integration tests for `GRDBBulkAnnotationLedger` against an in-memory
/// database — run/unit round-trip, the single-active-run query, unit and run
/// upserts, the FK cascade on delete, and the terminal-run sweep.
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
        // Insert out of order to prove `units(runId:)` sorts by `ordinal`.
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
        // The prologue unit carries no chapter number.
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
        // Two units share a primary key, so the second insert violates the
        // PK constraint mid-transaction. The whole `createRun` write must roll
        // back, leaving neither the run row nor the first unit behind.
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
        // Active status must not carry a completedAt.
        await #expect(throws: (any Error).self) {
            try await ledger.createRun(
                run(id: "bad-active", status: .running, completedAt: t0), units: []
            )
        }
        // Terminal status must carry a completedAt.
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
        // No active run yet.
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
        // No longer active.
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
        // FK cascade must have cleared the children too.
        #expect(try await ledger.units(runId: "r1").isEmpty)
    }

    // MARK: - Completed-run sweep

    @Test("deleteRunsCompleted sweeps only terminal runs older than the cutoff")
    func sweepRespectsCutoffAndActiveRuns() async throws {
        let ledger = try makeFixture()
        let cutoff = t0.addingTimeInterval(24 * 60 * 60)
        // Terminal, completed before the cutoff — should be swept.
        try await ledger.createRun(run(id: "old", status: .completed, completedAt: cutoff.addingTimeInterval(-60)), units: [])
        // Terminal, completed exactly at the cutoff — the sweep is strict
        // (`< cutoff`), so this boundary run must survive.
        try await ledger.createRun(run(id: "boundary", status: .completed, completedAt: cutoff), units: [])
        // Terminal, completed after the cutoff — should survive.
        try await ledger.createRun(run(id: "fresh", status: .cancelled, completedAt: cutoff.addingTimeInterval(60)), units: [])
        // Active — no completedAt — must never be swept.
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
        // A circuit-breaker halt — exercises the nullable `haltReason` enum
        // column being written non-nil and read back through GRDB coding.
        try await ledger.createRun(run(id: "late", status: .failed, haltReason: .quota, completedAt: t0.addingTimeInterval(50)), units: [])
        try await ledger.createRun(run(id: "live", status: .running), units: [])

        let completed = try await ledger.completedRuns()
        // Active run excluded; terminal runs newest-completed first.
        #expect(completed.map(\.id) == ["late", "early"])
        #expect(completed.first?.haltReason == .quota)
    }
}
