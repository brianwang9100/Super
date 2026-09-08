import Core
import Foundation
import GRDB
import Testing
@testable import Bible

/// Dedicated narration key failures retain durable cleanup ownership without changing the active credential.
@Suite("Narration key staging")
@MainActor
struct NarrationKeyStagingTests {
    @Test func failedSaveAndRollbackRecoverAfterControllerReload() async throws {
        let fixture = try KeyStagingFixture()
        try await fixture.configureBorrowedKey()
        let previous = fixture.settings.record
        await fixture.repository.setSaveFailure(true)
        await fixture.keys.setDeleteFailure(true)

        await #expect(throws: NarrationSettingsError.persistence) {
            try await fixture.settings.saveDedicatedKey("staged-secret", enabled: true, expecting: previous.revision)
        }

        #expect(fixture.settings.record == previous)
        #expect(try await fixture.settings.apiKey() == "original")
        #expect(try await fixture.keys.getString(ref: "key-2") == "staged-secret")
        #expect(fixture.settings.errorMessage != nil)
        #expect(fixture.settings.errorMessage?.contains("staged-secret") == false)
        #expect(try await fixture.repository.stagedKeyRefs() == ["key-2"])
        await fixture.keys.setDeleteFailure(false)
        let reloaded = fixture.makeController()
        await reloaded.load()

        #expect(try await fixture.keys.getString(ref: "key-2") == nil)
        #expect(try await fixture.repository.stagedKeyRefs().isEmpty)
        #expect(reloaded.record == previous)
        #expect(try await reloaded.apiKey() == "original")
    }

    @Test func registrationFailureNeverWritesASecret() async throws {
        let fixture = try KeyStagingFixture()
        try await fixture.configureBorrowedKey()
        let previous = fixture.settings.record
        await fixture.repository.setRegistrationFailure(true)

        await #expect(throws: NarrationSettingsError.persistence) {
            try await fixture.settings.saveDedicatedKey("candidate", enabled: true, expecting: previous.revision)
        }

        #expect(await fixture.keys.writeCount == 0)
        #expect(try await fixture.repository.stagedKeyRefs().isEmpty)
        #expect(fixture.settings.record == previous)
        #expect(!fixture.settings.isSaving)
    }

    @Test(arguments: [false, true])
    func failedKeychainWriteRetainsCleanupOwnership(wroteBeforeFailure: Bool) async throws {
        let fixture = try KeyStagingFixture()
        try await fixture.configureBorrowedKey()
        let previous = fixture.settings.record
        await fixture.keys.setWriteFailure(afterWriting: wroteBeforeFailure)
        await fixture.keys.setDeleteFailure(true)

        await #expect(throws: NarrationSettingsError.secureStorage) {
            try await fixture.settings.saveDedicatedKey("candidate", enabled: true, expecting: previous.revision)
        }

        #expect(try await fixture.repository.stagedKeyRefs() == ["key-2"])
        #expect(fixture.settings.record == previous)
        #expect(try await fixture.settings.apiKey() == "original")
        await fixture.keys.setDeleteFailure(false)
        await fixture.makeController().load()
        #expect(try await fixture.repository.stagedKeyRefs().isEmpty)
        #expect(try await fixture.keys.getString(ref: "key-2") == nil)
    }

    @Test func successfulKeyDeletionWithFailedUntrackingRemainsRetryable() async throws {
        let fixture = try KeyStagingFixture()
        try await fixture.configureBorrowedKey()
        let previous = fixture.settings.record
        await fixture.repository.setSaveFailure(true)
        await fixture.repository.setRemovalFailure(true)

        await #expect(throws: NarrationSettingsError.persistence) {
            try await fixture.settings.saveDedicatedKey("candidate", enabled: true, expecting: previous.revision)
        }

        #expect(try await fixture.keys.getString(ref: "key-2") == nil)
        #expect(try await fixture.repository.stagedKeyRefs() == ["key-2"])
        #expect(fixture.settings.errorMessage != nil)
        await fixture.repository.setRemovalFailure(false)
        let reloaded = fixture.makeController()
        await reloaded.load()
        #expect(try await fixture.repository.stagedKeyRefs().isEmpty)
        #expect(reloaded.record == previous)
        #expect(await fixture.keys.deletedRefs == ["key-2", "key-2"])
    }

    @Test func reloadPreservesACommittedOwnedKeyEvenWithStaleLedgerMetadata() async throws {
        let fixture = try KeyStagingFixture()
        try await fixture.settings.saveDedicatedKey("committed", enabled: true, expecting: 0)
        let committed = fixture.settings.record
        let ref = try #require(committed.keyRef)
        #expect(try await fixture.repository.stagedKeyRefs().isEmpty)
        try await fixture.repository.registerStagedKey(ref: ref)

        let reloaded = fixture.makeController()
        await reloaded.load()

        #expect(reloaded.record == committed)
        #expect(try await reloaded.apiKey() == "committed")
        #expect(try await fixture.repository.stagedKeyRefs().isEmpty)
        #expect(await fixture.keys.deletedRefs.isEmpty)
    }

    @Test func reloadRemovesAnAbandonedRegistrationWithoutASecret() async throws {
        let fixture = try KeyStagingFixture()
        try await fixture.configureBorrowedKey()
        let previous = fixture.settings.record
        try await fixture.repository.registerStagedKey(ref: "abandoned")

        await fixture.settings.load()

        #expect(try await fixture.repository.stagedKeyRefs().isEmpty)
        #expect(fixture.settings.record == previous)
        #expect(await fixture.keys.deletedRefs == ["abandoned"])
    }

    @Test func reloadCannotCleanAnInFlightStagedKeyOrAdvanceItsActiveRevision() async throws {
        let fixture = try KeyStagingFixture()
        try await fixture.configureBorrowedKey()
        let previous = fixture.settings.record
        var invalidations = 0
        fixture.settings.onInvalidated = { invalidations += 1 }
        await fixture.keys.suspendNextWrite()
        let save = Task {
            try await fixture.settings.saveDedicatedKey("candidate", enabled: true, expecting: previous.revision)
        }
        await fixture.keys.waitUntilWriteSuspended()
        #expect(fixture.settings.isSaving)
        #expect(try await fixture.repository.stagedKeyRefs() == ["key-2"])

        await fixture.settings.load()

        #expect(fixture.settings.record == previous)
        #expect(try await fixture.settings.apiKey() == "original")
        #expect(try await fixture.keys.getString(ref: "key-2") == "candidate")
        #expect(invalidations == 0)
        await #expect(throws: NarrationSettingsError.staleDraft) { try await fixture.settings.setEnabled(false) }
        await fixture.keys.releaseWrite()
        try await save.value
        #expect(try await fixture.settings.apiKey() == "candidate")
        #expect(fixture.settings.record.revision == previous.revision + 1)
        #expect(try await fixture.repository.stagedKeyRefs().isEmpty)
        #expect(invalidations == 1)
        #expect(!fixture.settings.isSaving)
    }

    @Test func pendingCleanupHoldsTheMutationGateUntilCompletion() async throws {
        let fixture = try KeyStagingFixture()
        try await fixture.configureBorrowedKey()
        let previous = fixture.settings.record
        try await fixture.repository.registerStagedKey(ref: "abandoned")
        try await fixture.keys.setString("abandoned-secret", ref: "abandoned")
        await fixture.keys.suspendNextDelete()
        let reload = Task { await fixture.settings.load() }
        await fixture.keys.waitUntilDeleteSuspended()

        #expect(fixture.settings.isSaving)
        await #expect(throws: NarrationSettingsError.staleDraft) {
            try await fixture.settings.saveDedicatedKey("candidate", enabled: true, expecting: previous.revision)
        }
        #expect(try await fixture.settings.apiKey() == "original")
        await fixture.keys.releaseDelete()
        await reload.value
        #expect(try await fixture.repository.stagedKeyRefs().isEmpty)
        #expect(fixture.settings.record == previous)
        #expect(!fixture.settings.isSaving)
    }

    @Test func cleanupFailureCannotUndoASuccessfullyCommittedReplacement() async throws {
        let fixture = try KeyStagingFixture()
        try await fixture.settings.saveDedicatedKey("first", enabled: true, expecting: 0)
        let previous = fixture.settings.record
        await fixture.keys.setDeleteFailure(true)

        try await fixture.settings.saveDedicatedKey("replacement", enabled: true, expecting: previous.revision)

        #expect(try await fixture.settings.apiKey() == "replacement")
        #expect(fixture.settings.record.keyRef != previous.keyRef)
        #expect(fixture.settings.record.retiredKeyRefs == [try #require(previous.keyRef)])
        #expect(try await fixture.repository.stagedKeyRefs().isEmpty)
        #expect(fixture.settings.errorMessage != nil)
        #expect(!fixture.settings.isSaving)
    }

    @Test func stagingRegistrationAndRevisionFailureDoNotMutateActiveSettings() async throws {
        let fixture = try KeyStagingFixture()
        try await fixture.configureBorrowedKey()
        let previous = fixture.settings.record
        let repository = GRDBNarrationSettingsRepository(database: fixture.database)
        try await repository.registerStagedKey(ref: "candidate")
        #expect(try await repository.load() == previous)
        var next = previous
        next.keyRef = "candidate"
        next.ownsKey = true
        next.revision += 1

        await #expect(throws: NarrationSettingsError.staleDraft) { try await repository.save(next, expecting: 0) }

        #expect(try await repository.load() == previous)
        #expect(try await repository.stagedKeyRefs() == ["candidate"])
        try await repository.save(next, expecting: previous.revision)
        #expect(try await repository.load() == next)
        #expect(try await repository.stagedKeyRefs().isEmpty)
    }

    @Test func ledgerRemovalFailureRollsBackTheSettingsCommitAtomically() async throws {
        let fixture = try KeyStagingFixture()
        try await fixture.configureBorrowedKey()
        let previous = fixture.settings.record
        let repository = GRDBNarrationSettingsRepository(database: fixture.database)
        try await repository.registerStagedKey(ref: "candidate")
        try await fixture.database.queue.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER block_staged_key_delete BEFORE DELETE ON narrationStagedKey
                BEGIN SELECT RAISE(ABORT, 'Injected cleanup metadata failure'); END
                """)
        }
        var next = previous
        next.keyRef = "candidate"
        next.ownsKey = true
        next.revision += 1

        await #expect(throws: (any Error).self) { try await repository.save(next, expecting: previous.revision) }

        #expect(try await repository.load() == previous)
        #expect(try await repository.stagedKeyRefs() == ["candidate"])
    }

    @Test func migrationPreservesExistingNarrationPreferences() async throws {
        let queue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        registerBibleMigrations(&migrator)
        try migrator.migrate(queue, upTo: "v10_narrationSettings")
        var previous = NarrationSettingsRecord(id: "existing", updatedAt: Date(timeIntervalSince1970: 1))
        previous.enabled = false
        previous.keyRef = "existing-ref"
        previous.ownsKey = true
        previous.revision = 7
        let saved = previous
        // Seed the historical schema explicitly; current record encoding also
        // includes preferences introduced by later migrations.
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO narrationSettings (id, scope, enabled, keyRef, ownsKey, rate, revision, retiredKeyRefs, updatedAt)
                VALUES (?, 'narration', ?, ?, ?, ?, ?, '[]', ?)
                """, arguments: [saved.id, saved.enabled, saved.keyRef, saved.ownsKey, saved.rate, saved.revision, saved.updatedAt])
        }

        try migrator.migrate(queue)

        #expect(try await queue.read { try NarrationSettingsRecord.fetchOne($0) } == previous)
        #expect(try await queue.read { try NarrationStagedKeyRecord.fetchCount($0) } == 0)
    }
}

@MainActor
private struct KeyStagingFixture {
    let source = ProviderAudioCredential(id: "chat-model", name: "OpenAI", keyRef: "borrowed-ref")
    let database: BibleDatabase
    let repository: FaultingNarrationSettingsRepository
    let keys = FaultingNarrationKeychain()
    let ids = DeterministicIDGenerator(prefix: "key-")
    let settings: NarrationSettingsController

    init() throws {
        database = try BibleDatabase.makeInMemory()
        repository = FaultingNarrationSettingsRepository(base: GRDBNarrationSettingsRepository(database: database))
        let source = source
        settings = NarrationSettingsController(
            repository: repository, keychain: keys, listSources: { [source] }, clock: FixedClock(), ids: ids
        )
    }

    func configureBorrowedKey() async throws {
        try await settings.configure(credential: source, enabled: true, useThisKey: true, expecting: 0)
    }

    func makeController() -> NarrationSettingsController {
        let source = source
        return NarrationSettingsController(
            repository: repository, keychain: keys, listSources: { [source] }, clock: FixedClock(), ids: ids
        )
    }
}

/// Delegates durable storage to GRDB while failing only the requested persistence stage.
private actor FaultingNarrationSettingsRepository: NarrationSettingsRepository {
    let base: GRDBNarrationSettingsRepository
    private var saveFails = false
    private var registrationFails = false
    private var removalFails = false
    init(base: GRDBNarrationSettingsRepository) { self.base = base }
    func setSaveFailure(_ value: Bool) { saveFails = value }
    func setRegistrationFailure(_ value: Bool) { registrationFails = value }
    func setRemovalFailure(_ value: Bool) { removalFails = value }
    func load() async throws -> NarrationSettingsRecord? { try await base.load() }
    func save(_ record: NarrationSettingsRecord, expecting revision: Int) async throws {
        if saveFails { throw NarrationSettingsError.persistence }
        try await base.save(record, expecting: revision)
    }
    func registerStagedKey(ref: String) async throws {
        if registrationFails { throw NarrationSettingsError.persistence }
        try await base.registerStagedKey(ref: ref)
    }
    func stagedKeyRefs() async throws -> [String] { try await base.stagedKeyRefs() }
    func removeStagedKey(ref: String) async throws {
        if removalFails { throw NarrationSettingsError.persistence }
        try await base.removeStagedKey(ref: ref)
    }
}

/// In-memory secrets with deterministic failure injection; never calls the system Keychain.
private actor FaultingNarrationKeychain: KeychainClient {
    enum Failure: Error, Sendable { case write, deletion }
    private var values = ["borrowed-ref": "original"]
    private var deleteFails = false
    private var writeFailureAfterWriting: Bool?
    private let writeGate = StagingOperationGate()
    private let deleteGate = StagingOperationGate()
    private(set) var writeCount = 0
    private(set) var deletedRefs: [String] = []
    func setDeleteFailure(_ value: Bool) { deleteFails = value }
    func setWriteFailure(afterWriting: Bool) { writeFailureAfterWriting = afterWriting }
    func getString(ref: String) async throws -> String? { values[ref] }
    func setString(_ value: String, ref: String) async throws {
        writeCount += 1
        if writeFailureAfterWriting == false { throw Failure.write }
        values[ref] = value
        await writeGate.enter()
        if writeFailureAfterWriting == true { throw Failure.write }
    }
    func delete(ref: String) async throws {
        await deleteGate.enter()
        if deleteFails { throw Failure.deletion }
        deletedRefs.append(ref)
        values[ref] = nil
    }
    func suspendNextWrite() async { await writeGate.arm() }
    func waitUntilWriteSuspended() async { await writeGate.waitUntilEntered() }
    func releaseWrite() async { await writeGate.release() }
    func suspendNextDelete() async { await deleteGate.arm() }
    func waitUntilDeleteSuspended() async { await deleteGate.waitUntilEntered() }
    func releaseDelete() async { await deleteGate.release() }
}

private actor StagingOperationGate {
    private var armed = false
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    func arm() { armed = true; entered = false }
    func enter() async {
        guard armed else { return }
        armed = false
        entered = true
        entry?.resume(); entry = nil
        await withCheckedContinuation { completion = $0 }
    }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { entry = $0 } } }
    func release() { completion?.resume(); completion = nil }
}
