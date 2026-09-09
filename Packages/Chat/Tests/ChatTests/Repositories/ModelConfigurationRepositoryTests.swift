import Core
import Foundation
import GRDB
import Testing
@testable import Chat

@Suite("GRDBModelConfigurationRepository")
struct ModelConfigurationRepositoryTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // Simulate a known kind without an adapter; production Gemini is buildable.
    private static let geminiTreatedAsUnbuildable: @Sendable (LLMProviderKind) -> Bool = {
        $0 != .geminiNative && $0.hasProviderAdapter
    }

    private func makeRepo() throws -> (GRDBModelConfigurationRepository, InMemoryKeychainClient) {
        let db = try ChatDatabase.makeInMemory()
        let keychain = InMemoryKeychainClient()
        return (
            GRDBModelConfigurationRepository(
                database: db, keychain: keychain, isKindBuildable: Self.geminiTreatedAsUnbuildable
            ),
            keychain
        )
    }

    private func makeRepoExposingQueue() throws -> (GRDBModelConfigurationRepository, DatabaseQueue, InMemoryKeychainClient) {
        let db = try ChatDatabase.makeInMemory()
        let keychain = InMemoryKeychainClient()
        return (
            GRDBModelConfigurationRepository(
                database: db, keychain: keychain, isKindBuildable: Self.geminiTreatedAsUnbuildable
            ),
            db.queue,
            keychain
        )
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

    @Test("Compare-and-update accepts a matching reference and rejects stale metadata or rotation")
    func updateRejectsStaleCredentialReference() async throws {
        let (repo, _) = try makeRepo()
        let original = makeRecord(id: "model", apiKeyRef: "old-ref")
        try await repo.save(original)
        var committed = original
        committed.apiKeyRef = "new-ref"
        committed.name = "Committed"
        try await repo.update(committed, expectedAPIKeyRef: "old-ref")

        for staleRef in ["old-ref", "other-rotation"] {
            var stale = original
            stale.apiKeyRef = staleRef
            await #expect(throws: ModelConfigurationRepositoryError.staleModel(id: "model")) {
                try await repo.update(stale, expectedAPIKeyRef: "old-ref")
            }
        }
        #expect(try await repo.fetch(id: "model") == committed)
    }

    @Test("Compare-and-update cannot recreate a deleted model")
    func updateDoesNotResurrectDeletedModel() async throws {
        let (repo, _) = try makeRepo()
        let original = makeRecord(id: "model")
        try await repo.save(original)
        try await repo.delete(id: "model")

        await #expect(throws: ModelConfigurationRepositoryError.staleModel(id: "model")) {
            try await repo.update(original, expectedAPIKeyRef: original.apiKeyRef)
        }
        #expect(try await repo.fetch(id: "model") == nil)
    }

    @Test("Compare-and-update treats a missing key reference as a value to match")
    func updateMatchesNilCredentialReference() async throws {
        let (repo, _) = try makeRepo()
        var record = makeRecord(id: "model", apiKeyRef: nil)
        try await repo.save(record)
        record.name = "Renamed"
        try await repo.update(record, expectedAPIKeyRef: nil)

        await #expect(throws: ModelConfigurationRepositoryError.staleModel(id: "model")) {
            try await repo.update(record, expectedAPIKeyRef: "different-ref")
        }
        #expect(try await repo.fetch(id: "model") == record)
    }

    @Test("Key rollback can remove a newly inserted secret without deleting its model")
    func deleteAPIKeyPreservesModelRow() async throws {
        let (repo, keychain) = try makeRepo()
        let record = makeRecord(id: "model")
        try await repo.save(record)
        try await repo.storeAPIKey("test-secret", ref: "ref-1")

        try await repo.deleteAPIKey(ref: "ref-1")

        #expect(try await keychain.getString(ref: "ref-1") == nil)
        #expect(try await repo.fetch(id: "model") == record)
    }

    @Test("Retired key cleanup removes only unreferenced secrets, including unknown-kind references")
    func deleteAPIKeyIfUnreferencedPreservesEveryModelKind() async throws {
        let (repo, queue, keychain) = try makeRepoExposingQueue()
        try await repo.save(makeRecord(id: "known", apiKeyRef: "known-ref"))
        try await insertUnknownKindRow(queue: queue, id: "future", apiKeyRef: "future-ref")
        for ref in ["known-ref", "future-ref", "unused-ref"] {
            try await repo.storeAPIKey("test-secret", ref: ref)
            try await repo.deleteAPIKeyIfUnreferenced(ref: ref)
        }

        #expect(try await keychain.getString(ref: "known-ref") == "test-secret")
        #expect(try await keychain.getString(ref: "future-ref") == "test-secret")
        #expect(try await keychain.getString(ref: "unused-ref") == nil)
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

    @Test("selected() excludes a native-kind row whose adapter hasn't shipped")
    func selectedExcludesUnbuildableNativeKind() async throws {
        // An unbuildable row stays editable but cannot claim active selection and
        // prevent the registered-provider fallback.
        let (repo, _) = try makeRepo()
        try await repo.save(makeRecord(
            id: "native", kind: .geminiNative, apiKeyRef: "kn", isSelected: true
        ))

        #expect(try await repo.selected() == nil)
        #expect(try await repo.all().map(\.id) == ["native"])
        #expect(try await repo.fetch(id: "native")?.kind == .geminiNative)
    }

    @Test("selected() still returns a buildable row alongside a native one")
    func selectedReturnsBuildableRowDespiteNativeSibling() async throws {
        let (repo, _) = try makeRepo()
        try await repo.save(makeRecord(
            id: "native", kind: .geminiNative, apiKeyRef: "kn", createdOffset: 0
        ))
        try await repo.save(makeRecord(
            id: "compat", kind: .openAICompatible, apiKeyRef: "kc",
            isSelected: true, createdOffset: 60
        ))

        #expect(try await repo.selected()?.id == "compat")
    }

    @Test func setSelectedThrowsForUnknownID() async throws {
        let (repo, _) = try makeRepo()
        try await repo.save(makeRecord(id: "a", apiKeyRef: "ka"))

        await #expect(throws: ModelConfigurationRepositoryError.unknownModel(id: "missing")) {
            try await repo.setSelected(id: "missing")
        }
    }

    /// Reject unbuildable selections before demoting the current one.
    @Test func setSelectedRefusesUnbuildableNativeKind() async throws {
        let (repo, _) = try makeRepo()
        try await repo.save(makeRecord(id: "compat", kind: .openAICompatible, apiKeyRef: "kc", isSelected: true))
        try await repo.save(makeRecord(id: "native", kind: .geminiNative, apiKeyRef: "kn"))

        await #expect(
            throws: ModelConfigurationRepositoryError.unselectableKind(
                id: "native", kind: LLMProviderKind.geminiNative.rawValue
            )
        ) {
            try await repo.setSelected(id: "native")
        }

        #expect(try await repo.selected()?.id == "compat")
        #expect(try await repo.all().filter(\.isSelected).map(\.id) == ["compat"])
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
        #expect(fetched?.configuration.kind == .appleFoundation)
        #expect(fetched?.configuration.baseURL == nil)
        #expect(fetched?.configuration.apiKeyRef == nil)
    }

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

    /// Bypass kind filtering to inspect the physical selection slot.
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

    /// A Release build may inherit DEBUG or newer-binary kinds. Filter them before decoding.
    @Test func readsFilterOutRowsWithUnrecognisedKindValue() async throws {
        let (repo, queue, _) = try makeRepoExposingQueue()
        try await repo.save(makeRecord(id: "known", apiKeyRef: "ka", isSelected: true))
        try await insertUnknownKindRow(queue: queue, id: "future")

        #expect(try await repo.all().map(\.id) == ["known"])
        #expect(try await repo.fetch(id: "future") == nil)
        #expect(try await repo.fetch(id: "known")?.id == "known")
        #expect(try await repo.selected()?.id == "known")
    }

    /// Unknown kinds must not prevent seeding a usable provider.
    @Test func insertIfEmptyTreatsUnknownKindRowsAsAbsent() async throws {
        let (repo, queue, _) = try makeRepoExposingQueue()
        try await insertUnknownKindRow(queue: queue, id: "orphan")

        let seeded = try await repo.insertIfEmpty {
            self.makeRecord(id: "seeded", kind: .openAICompatible, apiKeyRef: "ks")
        }

        #expect(seeded?.id == "seeded")
        #expect(try await repo.all().map(\.id) == ["seeded"])
    }

    /// Filtered-out rows still need deletion and associated keychain cleanup.
    @Test func deleteWorksForRowsWithUnrecognisedKindValue() async throws {
        let (repo, queue, keychain) = try makeRepoExposingQueue()
        try await repo.storeAPIKey("sk-orphan", ref: "ko")
        try await insertUnknownKindRow(queue: queue, id: "orphan", apiKeyRef: "ko")

        let raw: Int? = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT 1 FROM modelConfiguration WHERE id = 'orphan'")
        }
        #expect(raw == 1)

        try await repo.delete(id: "orphan")

        let rawAfter: Int? = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT 1 FROM modelConfiguration WHERE id = 'orphan'")
        }
        #expect(rawAfter == nil)
        #expect(try await keychain.getString(ref: "ko") == nil)
    }

    /// The partial unique index includes unknown kinds; demote their selections before seeding.
    @Test func insertIfEmptyDemotesUnknownKindSelectedRowBeforeSeeding() async throws {
        let (repo, queue, _) = try makeRepoExposingQueue()
        try await insertUnknownKindRow(queue: queue, id: "future-selected", isSelected: true)

        let seeded = try await repo.insertIfEmpty {
            self.makeRecord(id: "seeded", apiKeyRef: "ks", isSelected: true)
        }

        #expect(seeded?.id == "seeded")
        #expect(try await repo.all().map(\.id) == ["seeded"])
        #expect(try await rawIsSelected(queue: queue, id: "future-selected") == false)
        #expect(try await rawIsSelected(queue: queue, id: "seeded") == true)
        #expect(try await repo.selected()?.id == "seeded")
    }

    /// Seed and selected() must agree on buildability or the registry can stay empty.
    @Test func insertIfEmptySeedsWhenOnlyUnbuildableNativeRowExists() async throws {
        let (repo, _, _) = try makeRepoExposingQueue()
        try await repo.save(
            makeRecord(id: "native", kind: .geminiNative, apiKeyRef: "kn")
        )

        let seeded = try await repo.insertIfEmpty {
            self.makeRecord(id: "seeded", kind: .openAICompatible, apiKeyRef: "ks", isSelected: true)
        }

        #expect(seeded?.id == "seeded")
        #expect(try await repo.selected()?.id == "seeded")
        #expect(try await repo.all().map(\.id).sorted() == ["native", "seeded"])
    }

    @Test func insertIfEmptyDemotesSelectedNativeRowBeforeSeeding() async throws {
        let (repo, queue, _) = try makeRepoExposingQueue()
        try await repo.save(
            makeRecord(id: "native-selected", kind: .geminiNative, apiKeyRef: "kn", isSelected: true)
        )

        let seeded = try await repo.insertIfEmpty {
            self.makeRecord(id: "seeded", apiKeyRef: "ks", isSelected: true)
        }

        #expect(seeded?.id == "seeded")
        #expect(try await rawIsSelected(queue: queue, id: "native-selected") == false)
        #expect(try await rawIsSelected(queue: queue, id: "seeded") == true)
        #expect(try await repo.selected()?.id == "seeded")
    }

    #if DEBUG
    @Test func insertDebugIfMissingTakesSelectionWhenOnlyUnknownKindRowIsSelected() async throws {
        let (repo, queue, _) = try makeRepoExposingQueue()
        try await insertUnknownKindRow(queue: queue, id: "future-selected", isSelected: true)

        let inserted = try await repo.insertDebugRowIfMissing(id: "debug-canned", selectable: true) { shouldSelect in
            self.makeRecord(
                id: "debug-canned",
                kind: .debug,
                baseURL: nil,
                apiKeyRef: nil,
                isSelected: shouldSelect
            )
        }

        #expect(inserted?.id == "debug-canned")
        #expect(try await rawIsSelected(queue: queue, id: "future-selected") == false)
        #expect(try await rawIsSelected(queue: queue, id: "debug-canned") == true)
        #expect(try await repo.selected()?.id == "debug-canned")
    }

    @Test func insertDebugIfMissingTakesSelectionWhenOnlyNativeKindRowIsSelected() async throws {
        let (repo, queue, _) = try makeRepoExposingQueue()
        try await repo.save(
            makeRecord(id: "native-selected", kind: .geminiNative, apiKeyRef: "kn", isSelected: true)
        )

        let inserted = try await repo.insertDebugRowIfMissing(id: "debug-canned", selectable: true) { shouldSelect in
            self.makeRecord(
                id: "debug-canned",
                kind: .debug,
                baseURL: nil,
                apiKeyRef: nil,
                isSelected: shouldSelect
            )
        }

        #expect(inserted?.id == "debug-canned")
        #expect(try await rawIsSelected(queue: queue, id: "native-selected") == false)
        #expect(try await rawIsSelected(queue: queue, id: "debug-canned") == true)
        #expect(try await repo.selected()?.id == "debug-canned")
    }

    @Test func insertDebugIfMissingLeavesKnownSelectionAlone() async throws {
        let (repo, queue, _) = try makeRepoExposingQueue()
        try await repo.save(makeRecord(id: "afm", kind: .appleFoundation, baseURL: nil, apiKeyRef: nil, isSelected: true))

        let inserted = try await repo.insertDebugRowIfMissing(id: "debug-canned", selectable: true) { shouldSelect in
            self.makeRecord(
                id: "debug-canned",
                kind: .debug,
                baseURL: nil,
                apiKeyRef: nil,
                isSelected: shouldSelect
            )
        }

        #expect(inserted?.id == "debug-canned")
        #expect(try await rawIsSelected(queue: queue, id: "afm") == true)
        #expect(try await rawIsSelected(queue: queue, id: "debug-canned") == false)
        #expect(try await repo.selected()?.id == "afm")
    }

    @Test func insertDebugRowIfMissingNeverSelectsWhenNotSelectable() async throws {
        let (repo, queue, _) = try makeRepoExposingQueue()

        let inserted = try await repo.insertDebugRowIfMissing(id: "debug-annotate", selectable: false) { shouldSelect in
            self.makeRecord(
                id: "debug-annotate", kind: .debug, baseURL: nil, apiKeyRef: nil, isSelected: shouldSelect
            )
        }

        #expect(inserted?.id == "debug-annotate")
        #expect(try await rawIsSelected(queue: queue, id: "debug-annotate") == false)
        #expect(try await repo.selected() == nil)
    }

    @Test func insertDebugRowIfMissingIsIdempotentPerID() async throws {
        let (repo, _, _) = try makeRepoExposingQueue()
        let make: @Sendable (Bool) -> ModelConfigurationRecord = { shouldSelect in
            self.makeRecord(id: "debug-canned", kind: .debug, baseURL: nil, apiKeyRef: nil, isSelected: shouldSelect)
        }

        let first = try await repo.insertDebugRowIfMissing(id: "debug-canned", selectable: true, make: make)
        let second = try await repo.insertDebugRowIfMissing(id: "debug-canned", selectable: true, make: make)

        #expect(first?.id == "debug-canned")
        #expect(second == nil)
        #expect(try await repo.all().filter { $0.id == "debug-canned" }.count == 1)
    }
    #endif

    @Test func deleteOnUnknownIDDoesNotDeleteAnythingOrThrow() async throws {
        let (repo, _) = try makeRepo()
        try await repo.delete(id: "ghost")
        #expect(try await repo.all().isEmpty)
    }

    @Test func deletingAppleFoundationRowDoesNotTouchKeychain() async throws {
        let (repo, keychain) = try makeRepo()
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
