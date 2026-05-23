import Core
import Foundation
import GRDB
import Testing
@testable import Chat

/// Tests for `GRDBModelConfigurationRepository` — selected-exclusive
/// invariant, Keychain pairing on delete, and ordering.
@Suite("GRDBModelConfigurationRepository")
struct ModelConfigurationRepositoryTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRepo() throws -> (GRDBModelConfigurationRepository, InMemoryKeychainClient) {
        let db = try ChatDatabase.makeInMemory()
        let keychain = InMemoryKeychainClient()
        return (GRDBModelConfigurationRepository(database: db, keychain: keychain), keychain)
    }

    private func makeRepoExposingQueue() throws -> (GRDBModelConfigurationRepository, DatabaseQueue, InMemoryKeychainClient) {
        let db = try ChatDatabase.makeInMemory()
        let keychain = InMemoryKeychainClient()
        return (GRDBModelConfigurationRepository(database: db, keychain: keychain), db.queue, keychain)
    }

    private func makeRecord(
        id: String,
        kind: LLMProviderKind = .openAICompatible,
        name: String = "Model",
        baseURL: URL? = URL(string: "https://api.example.com/v1")!,
        apiKeyRef: String? = "ref-1",
        modelId: String = "model-x",
        isSelected: Bool = false,
        createdOffset: TimeInterval = 0
    ) -> ModelConfigurationRecord {
        ModelConfigurationRecord(
            id: id,
            name: name,
            baseURL: baseURL,
            apiKeyRef: apiKeyRef,
            modelId: modelId,
            createdAt: now.addingTimeInterval(createdOffset),
            kind: kind,
            supportsThinking: false,
            maxContextTokens: 16_000,
            isSelected: isSelected
        )
    }

    @Test func allReturnsRowsInCreatedOrder() async throws {
        let (repo, _) = try makeRepo()
        try await repo.save(makeRecord(id: "b", apiKeyRef: "kb", createdOffset: 60))
        try await repo.save(makeRecord(id: "a", apiKeyRef: "ka", createdOffset: 0))
        try await repo.save(makeRecord(id: "c", apiKeyRef: "kc", createdOffset: 120))

        #expect(try await repo.all().map(\.id) == ["a", "b", "c"])
    }

    @Test func setSelectedClearsPriorSelection() async throws {
        let (repo, _) = try makeRepo()
        try await repo.save(makeRecord(id: "a", apiKeyRef: "ka", isSelected: true))
        try await repo.save(makeRecord(id: "b", apiKeyRef: "kb"))
        try await repo.save(makeRecord(id: "c", apiKeyRef: "kc"))

        try await repo.setSelected(id: "b")

        let selectedIDs = try await repo.all().filter(\.isSelected).map(\.id)
        #expect(selectedIDs == ["b"])
        #expect(try await repo.selected()?.id == "b")
    }

    @Test func setSelectedThrowsForUnknownID() async throws {
        let (repo, _) = try makeRepo()
        try await repo.save(makeRecord(id: "a", apiKeyRef: "ka"))

        await #expect(throws: ModelConfigurationRepositoryError.unknownModel(id: "missing")) {
            try await repo.setSelected(id: "missing")
        }
    }

    @Test func deleteAlsoRemovesKeychainEntry() async throws {
        let (repo, keychain) = try makeRepo()
        try await repo.storeAPIKey("sk-secret", ref: "ka")
        try await repo.save(makeRecord(id: "a", apiKeyRef: "ka"))

        try await repo.delete(id: "a")

        #expect(try await repo.fetch(id: "a") == nil)
        #expect(try await keychain.getString(ref: "ka") == nil)
    }

    @Test func deleteOnUnknownIDDoesNotTouchKeychain() async throws {
        let (repo, keychain) = try makeRepo()
        try await keychain.setString("sk-keep", ref: "ka")
        try await repo.delete(id: "ghost")
        #expect(try await keychain.getString(ref: "ka") == "sk-keep")
    }

    @Test func storeAndLoadAPIKeyRoundTripThroughKeychain() async throws {
        let (repo, _) = try makeRepo()
        try await repo.storeAPIKey("sk-roundtrip", ref: "ka")
        #expect(try await repo.loadAPIKey(ref: "ka") == "sk-roundtrip")
    }

    @Test func configurationProjectionMatchesRowFields() async throws {
        let (repo, _) = try makeRepo()
        let record = makeRecord(id: "a", name: "GPT-4", apiKeyRef: "ka")
        try await repo.save(record)
        let fetched = try await repo.fetch(id: "a")!
        #expect(fetched.configuration.id == record.id)
        #expect(fetched.configuration.name == "GPT-4")
        #expect(fetched.configuration.modelID == "model-x")
        #expect(fetched.configuration.maxContextTokens == 16_000)
    }

    @Test func baseURLRoundTripsThroughCodec() async throws {
        let (repo, _) = try makeRepo()
        let url = URL(string: "https://api.example.com:8443/v1/responses?stream=1")!
        try await repo.save(makeRecord(id: "a", baseURL: url, apiKeyRef: "ka"))
        let fetched = try await repo.fetch(id: "a")
        #expect(fetched?.baseURL == url)
    }

    @Test func savingSecondSelectedRowViolatesPartialUniqueIndex() async throws {
        let (repo, _) = try makeRepo()
        try await repo.save(makeRecord(id: "a", apiKeyRef: "ka", isSelected: true))

        await #expect(throws: (any Error).self) {
            try await repo.save(makeRecord(id: "b", apiKeyRef: "kb", isSelected: true))
        }

        // The first row remains the unique selection.
        let selectedIDs = try await repo.all().filter(\.isSelected).map(\.id)
        #expect(selectedIDs == ["a"])
    }

    @Test func appleFoundationRowRoundTripsWithNilURLAndKey() async throws {
        let (repo, _) = try makeRepo()
        let record = makeRecord(
            id: "afm",
            kind: .appleFoundation,
            name: "Apple Intelligence",
            baseURL: nil,
            apiKeyRef: nil,
            modelId: "system-default"
        )
        try await repo.save(record)

        let fetched = try await repo.fetch(id: "afm")
        #expect(fetched?.kind == .appleFoundation)
        #expect(fetched?.baseURL == nil)
        #expect(fetched?.apiKeyRef == nil)
        #expect(fetched?.modelId == "system-default")
        // Projection carries the kind through to the Core value.
        #expect(fetched?.configuration.kind == .appleFoundation)
        #expect(fetched?.configuration.baseURL == nil)
        #expect(fetched?.configuration.apiKeyRef == nil)
    }

    /// Insert a row with an arbitrary unknown `kind` value via raw SQL.
    /// Returned closure runs synchronously from a `queue.write` block.
    private func insertUnknownKindRow(
        queue: DatabaseQueue,
        id: String,
        kind: String = "future-unknown-kind",
        apiKeyRef: String? = nil,
        isSelected: Bool = false
    ) async throws {
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO modelConfiguration
                (id, kind, name, baseURL, apiKeyRef, modelId, supportsThinking, maxContextTokens, isSelected, createdAt)
                VALUES
                (?, ?, 'Unknown', NULL, ?, 'm', 0, 8192, ?, ?)
                """,
                arguments: [id, kind, apiKeyRef, isSelected, self.now.timeIntervalSince1970]
            )
        }
    }

    /// Read `isSelected` for `id` via raw SQL so the assertion works
    /// even when the row's `kind` would be filtered out by reads.
    private func rawIsSelected(queue: DatabaseQueue, id: String) async throws -> Bool? {
        try await queue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT isSelected FROM modelConfiguration WHERE id = ?",
                arguments: [id]
            )
            return row.map { ($0["isSelected"] as Int? ?? 0) != 0 }
        }
    }

    /// Rows whose `kind` column holds a string the running binary
    /// doesn't recognise must be skipped by every read, not surfaced as
    /// decode errors. The Release-build crash this guards against
    /// (DEBUG seeds `kind = "debug"`; same simulator installs a Release
    /// build that has no `.debug` case → decode trap on every read) is
    /// the exact shape simulated here by inserting an arbitrary unknown
    /// `kind` value via raw SQL.
    @Test func readsFilterOutRowsWithUnrecognisedKindValue() async throws {
        let (repo, queue, _) = try makeRepoExposingQueue()
        try await repo.save(makeRecord(id: "known", apiKeyRef: "ka", isSelected: true))
        try await insertUnknownKindRow(queue: queue, id: "future")

        // `all()` returns only the recognised row.
        #expect(try await repo.all().map(\.id) == ["known"])
        // `fetch(id:)` returns nil for the unrecognised row even though
        // it's physically present in the table.
        #expect(try await repo.fetch(id: "future") == nil)
        #expect(try await repo.fetch(id: "known")?.id == "known")
        // `selected()` projects through the same filter (defensive — in
        // practice an unknown-kind row with isSelected=1 would only
        // surface if a future binary downgrade happened).
        #expect(try await repo.selected()?.id == "known")
    }

    /// `insertIfEmpty` must apply the same known-kind filter as the
    /// read paths. Otherwise a leftover `kind = "debug"` row in a
    /// Release build makes the table look non-empty, the AFM seed
    /// no-ops, and the provider registry ends up empty — bug
    /// #3293413130 on PR #92.
    @Test func insertIfEmptyTreatsUnknownKindRowsAsAbsent() async throws {
        let (repo, queue, _) = try makeRepoExposingQueue()
        // Seed the DB with only an unknown-kind row.
        try await insertUnknownKindRow(queue: queue, id: "orphan")

        let seeded = try await repo.insertIfEmpty {
            self.makeRecord(id: "seeded", kind: .openAICompatible, apiKeyRef: "ks")
        }

        // The seed runs because the unknown-kind row doesn't count
        // toward emptiness from the binary's perspective.
        #expect(seeded?.id == "seeded")
        #expect(try await repo.all().map(\.id) == ["seeded"])
    }

    /// `delete(id:)` must work for rows whose `kind` the binary doesn't
    /// recognise — otherwise a leftover DEBUG `kind = "debug"` row is
    /// permanently orphaned because `fetch(id:)` filters it out. Bug
    /// #3293413328 on PR #92.
    @Test func deleteWorksForRowsWithUnrecognisedKindValue() async throws {
        let (repo, queue, keychain) = try makeRepoExposingQueue()
        try await repo.storeAPIKey("sk-orphan", ref: "ko")
        try await insertUnknownKindRow(queue: queue, id: "orphan", apiKeyRef: "ko")

        // Sanity: the row is physically present even though it doesn't
        // show through the filtered read paths.
        let raw: Int? = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT 1 FROM modelConfiguration WHERE id = 'orphan'")
        }
        #expect(raw == 1)

        try await repo.delete(id: "orphan")

        // Both the row and its keychain entry are gone.
        let rawAfter: Int? = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT 1 FROM modelConfiguration WHERE id = 'orphan'")
        }
        #expect(rawAfter == nil)
        #expect(try await keychain.getString(ref: "ko") == nil)
    }

    /// `insertIfEmpty` must not UNIQUE-violate when a downgraded binary
    /// finds an unknown-kind row already holding the `isSelected = 1`
    /// slot (the schema's partial unique index covers every row
    /// regardless of kind). Bug #3293450824 on PR #92.
    @Test func insertIfEmptyDemotesUnknownKindSelectedRowBeforeSeeding() async throws {
        let (repo, queue, _) = try makeRepoExposingQueue()
        try await insertUnknownKindRow(queue: queue, id: "future-selected", isSelected: true)

        let seeded = try await repo.insertIfEmpty {
            self.makeRecord(id: "seeded", apiKeyRef: "ks", isSelected: true)
        }

        // The seed lands without UNIQUE-violating.
        #expect(seeded?.id == "seeded")
        #expect(try await repo.all().map(\.id) == ["seeded"])
        // The previously-selected unknown row is demoted so the new
        // seed can hold the selection slot.
        #expect(try await rawIsSelected(queue: queue, id: "future-selected") == false)
        #expect(try await rawIsSelected(queue: queue, id: "seeded") == true)
        // `selected()` reports the seed as the active model.
        #expect(try await repo.selected()?.id == "seeded")
    }

    #if DEBUG
    /// `insertDebugIfMissing` must use the filtered selection check so
    /// the debug row claims the selection slot when no recognised row
    /// is selected — even when an unknown-kind row holds the partial
    /// unique slot. Bug #3293450647 on PR #92.
    @Test func insertDebugIfMissingTakesSelectionWhenOnlyUnknownKindRowIsSelected() async throws {
        let (repo, queue, _) = try makeRepoExposingQueue()
        try await insertUnknownKindRow(queue: queue, id: "future-selected", isSelected: true)

        let inserted = try await repo.insertDebugIfMissing { shouldSelect in
            self.makeRecord(
                id: "debug-canned",
                kind: .debug,
                baseURL: nil,
                apiKeyRef: nil,
                isSelected: shouldSelect
            )
        }

        #expect(inserted?.id == "debug-canned")
        // The unknown-kind row is demoted; the debug row holds selection.
        #expect(try await rawIsSelected(queue: queue, id: "future-selected") == false)
        #expect(try await rawIsSelected(queue: queue, id: "debug-canned") == true)
        // `selected()` now reports the debug row.
        #expect(try await repo.selected()?.id == "debug-canned")
    }

    @Test func insertDebugIfMissingLeavesKnownSelectionAlone() async throws {
        let (repo, queue, _) = try makeRepoExposingQueue()
        try await repo.save(makeRecord(id: "afm", kind: .appleFoundation, baseURL: nil, apiKeyRef: nil, isSelected: true))

        let inserted = try await repo.insertDebugIfMissing { shouldSelect in
            self.makeRecord(
                id: "debug-canned",
                kind: .debug,
                baseURL: nil,
                apiKeyRef: nil,
                isSelected: shouldSelect
            )
        }

        #expect(inserted?.id == "debug-canned")
        // AFM keeps the slot; debug is inserted unselected.
        #expect(try await rawIsSelected(queue: queue, id: "afm") == true)
        #expect(try await rawIsSelected(queue: queue, id: "debug-canned") == false)
        #expect(try await repo.selected()?.id == "afm")
    }
    #endif

    @Test func deleteOnUnknownIDDoesNotDeleteAnythingOrThrow() async throws {
        let (repo, _) = try makeRepo()
        // No rows in the DB; delete is a no-op (matches the prior
        // `delete(id: "ghost")` test that already covers the no-keychain
        // branch — this complements it by exercising the new raw-probe
        // path on an absent row).
        try await repo.delete(id: "ghost")
        #expect(try await repo.all().isEmpty)
    }

    @Test func deletingAppleFoundationRowDoesNotTouchKeychain() async throws {
        let (repo, keychain) = try makeRepo()
        // A pre-existing unrelated key — it must survive the delete since
        // the AFM row references no keychain entry.
        try await keychain.setString("unrelated-secret", ref: "ka")
        try await repo.save(makeRecord(
            id: "afm",
            kind: .appleFoundation,
            baseURL: nil,
            apiKeyRef: nil
        ))

        try await repo.delete(id: "afm")

        #expect(try await repo.fetch(id: "afm") == nil)
        #expect(try await keychain.getString(ref: "ka") == "unrelated-secret")
    }
}
