import Core
import Foundation
import GRDB
import Testing
@testable import Chat

@Suite("Model key staging")
@MainActor
struct ModelKeyStagingTests {
    @Test func failedUpdateAndRollbackRemainRecoverableAtNextLaunch() async throws {
        let fixture = try ModelKeyFixture()
        try await fixture.seed()
        try await fixture.rejectModelUpdates()
        await fixture.keys.setDeleteFailure(ref: "candidate-1")

        await fixture.rotate()

        #expect(try await fixture.repository.fetch(id: "model") == fixture.original)
        #expect(try await fixture.repository.loadAPIKey(ref: "original-ref") == "original")
        #expect(try await fixture.repository.loadAPIKey(ref: "candidate-1") == "candidate")
        #expect(try await fixture.pendingRefs() == ["candidate-1"])
        #expect(fixture.viewModel.lastSavedModel == nil)
        #expect(fixture.viewModel.modelEditError?.contains("Restart the app") == true)
        #expect(fixture.viewModel.modelEditError?.contains("candidate") == false)

        await fixture.keys.setDeleteFailure(ref: nil)
        let relaunched = GRDBModelConfigurationRepository(database: fixture.database, keychain: fixture.keys)
        try await relaunched.recoverStagedAPIKeysAtStartup()

        #expect(try await fixture.pendingRefs().isEmpty)
        #expect(try await relaunched.loadAPIKey(ref: "candidate-1") == nil)
        #expect(try await relaunched.fetch(id: "model") == fixture.original)
        #expect(try await relaunched.loadAPIKey(ref: "original-ref") == "original")
    }

    @Test func registrationFailureNeverWritesASecret() async throws {
        let fixture = try ModelKeyFixture()
        try await fixture.seed()
        try await fixture.database.queue.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER block_registration BEFORE INSERT ON modelStagedKey
                BEGIN SELECT RAISE(ABORT, 'Injected registration failure'); END
                """)
        }

        await fixture.rotate()

        #expect(await fixture.keys.writeCount == 1)
        #expect(try await fixture.pendingRefs().isEmpty)
        #expect(try await fixture.repository.fetch(id: "model") == fixture.original)
        #expect(fixture.viewModel.modelEditError != nil)
    }

    @Test(arguments: [false, true])
    func failedKeychainWriteRetainsCleanupOwnership(wroteBeforeFailure: Bool) async throws {
        let fixture = try ModelKeyFixture()
        try await fixture.seed()
        await fixture.keys.setWriteFailure(afterWriting: wroteBeforeFailure)
        await fixture.keys.setDeleteFailure(ref: "candidate-1")

        await fixture.rotate()

        #expect(try await fixture.pendingRefs() == ["candidate-1"])
        #expect(try await fixture.repository.fetch(id: "model") == fixture.original)
        #expect(try await fixture.repository.loadAPIKey(ref: "original-ref") == "original")
        await fixture.keys.setDeleteFailure(ref: nil)
        try await fixture.repository.recoverStagedAPIKeysAtStartup()
        #expect(try await fixture.pendingRefs().isEmpty)
        #expect(try await fixture.repository.loadAPIKey(ref: "candidate-1") == nil)
    }

    @Test(arguments: [false, true])
    func failedCreateCleansOrRetainsItsProvisionalKey(deleteFails: Bool) async throws {
        let fixture = try ModelKeyFixture()
        try await fixture.database.queue.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER block_creation BEFORE INSERT ON modelConfiguration
                BEGIN SELECT RAISE(ABORT, 'Injected save failure'); END
                """)
        }
        if deleteFails { await fixture.keys.setDeleteFailure(ref: "created-1") }
        let ids = DeterministicIDGenerator(prefix: "created-")

        await fixture.viewModel.createModel(
            name: "New", baseURL: fixture.original.baseURL!, modelId: "gpt", apiKey: "candidate",
            supportsThinking: false, maxContextTokens: 8_000,
            idGenerator: { ids.nextID() }, now: FixedClock().now()
        )

        #expect(try await fixture.repository.all().isEmpty)
        #expect(fixture.viewModel.lastSavedModel == nil)
        #expect(fixture.viewModel.modelEditError != nil)
        #expect(try await fixture.pendingRefs() == (deleteFails ? ["created-1"] : []))
        await fixture.keys.setDeleteFailure(ref: nil)
        try await fixture.repository.recoverStagedAPIKeysAtStartup()
        #expect(try await fixture.repository.loadAPIKey(ref: "created-1") == nil)
        #expect(try await fixture.pendingRefs().isEmpty)
    }

    @Test func successfulCreateReleasesItsMarkerAndPreservesItsSecret() async throws {
        let fixture = try ModelKeyFixture()
        let ids = DeterministicIDGenerator(prefix: "created-")
        await fixture.viewModel.createModel(
            name: "New", baseURL: fixture.original.baseURL!, modelId: "gpt", apiKey: "candidate",
            supportsThinking: false, maxContextTokens: 8_000,
            idGenerator: { ids.nextID() }, now: FixedClock().now()
        )
        #expect(fixture.viewModel.lastSavedModel?.apiKeyRef == "created-1")
        #expect(try await fixture.pendingRefs().isEmpty)
        try await fixture.repository.recoverStagedAPIKeysAtStartup()
        #expect(try await fixture.repository.loadAPIKey(ref: "created-1") == "candidate")
    }

    @Test func committedRotationTracksRetiredKeyBeforeCleanupAndRecoversAfterTermination() async throws {
        let fixture = try ModelKeyFixture()
        try await fixture.seed()
        try await fixture.stage(ref: "candidate-1")
        let next = fixture.replacement

        // The process can terminate immediately after this commit, before the VM's final cleanup.
        try await fixture.repository.update(next, expectedAPIKeyRef: "original-ref")

        #expect(try await fixture.repository.fetch(id: "model") == next)
        #expect(try await fixture.pendingRefs() == ["original-ref"])
        #expect(try await fixture.repository.loadAPIKey(ref: "original-ref") == "original")
        let relaunched = GRDBModelConfigurationRepository(database: fixture.database, keychain: fixture.keys)
        try await relaunched.recoverStagedAPIKeysAtStartup()
        #expect(try await fixture.pendingRefs().isEmpty)
        #expect(try await relaunched.loadAPIKey(ref: "original-ref") == nil)
        #expect(try await relaunched.loadAPIKey(ref: "candidate-1") == "candidate")
    }

    @Test func failedRetiredKeyDeletionDoesNotUndoTheCommittedModel() async throws {
        let fixture = try ModelKeyFixture()
        try await fixture.seed()
        await fixture.keys.setDeleteFailure(ref: "original-ref")

        await fixture.rotate()

        #expect(fixture.viewModel.lastSavedModel == fixture.replacement)
        #expect(fixture.viewModel.modelEditError == nil)
        #expect(try await fixture.pendingRefs() == ["original-ref"])
        #expect(try await fixture.repository.loadAPIKey(ref: "candidate-1") == "candidate")
        await fixture.keys.setDeleteFailure(ref: nil)
        try await fixture.repository.recoverStagedAPIKeysAtStartup()
        #expect(try await fixture.repository.loadAPIKey(ref: "original-ref") == nil)
        #expect(try await fixture.pendingRefs().isEmpty)
    }

    @Test func failedUntrackingAfterRetiredSecretDeletionRemainsRetryable() async throws {
        let fixture = try ModelKeyFixture()
        try await fixture.seed()
        try await fixture.database.queue.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER block_retired_untracking BEFORE DELETE ON modelStagedKey
                WHEN OLD.id = 'original-ref'
                BEGIN SELECT RAISE(ABORT, 'Injected cleanup metadata failure'); END
                """)
        }

        await fixture.rotate()

        #expect(fixture.viewModel.lastSavedModel == fixture.replacement)
        #expect(fixture.viewModel.modelEditError == nil)
        #expect(try await fixture.repository.loadAPIKey(ref: "original-ref") == nil)
        #expect(try await fixture.pendingRefs() == ["original-ref"])
        try await fixture.database.queue.write { try $0.execute(sql: "DROP TRIGGER block_retired_untracking") }
        try await fixture.repository.recoverStagedAPIKeysAtStartup()
        #expect(try await fixture.pendingRefs().isEmpty)
        #expect(try await fixture.repository.loadAPIKey(ref: "candidate-1") == "candidate")
    }

    @Test func markerRemovalFailureRollsBackModelCommitAndRetirementAtomically() async throws {
        let fixture = try ModelKeyFixture()
        try await fixture.seed()
        try await fixture.stage(ref: "candidate-1")
        try await fixture.database.queue.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER block_candidate_untracking BEFORE DELETE ON modelStagedKey
                WHEN OLD.id = 'candidate-1'
                BEGIN SELECT RAISE(ABORT, 'Injected cleanup metadata failure'); END
                """)
        }

        await #expect(throws: (any Error).self) {
            try await fixture.repository.update(fixture.replacement, expectedAPIKeyRef: "original-ref")
        }

        #expect(try await fixture.repository.fetch(id: "model") == fixture.original)
        #expect(try await fixture.pendingRefs() == ["candidate-1"])
    }

    @Test func staleCASPreservesTheCandidateMarkerUntilDiscard() async throws {
        let fixture = try ModelKeyFixture()
        try await fixture.seed()
        try await fixture.stage(ref: "candidate-1")

        await #expect(throws: ModelConfigurationRepositoryError.staleModel(id: "model")) {
            try await fixture.repository.update(fixture.replacement, expectedAPIKeyRef: "stale-ref")
        }

        #expect(try await fixture.pendingRefs() == ["candidate-1"])
        #expect(try await fixture.repository.fetch(id: "model") == fixture.original)
        try await fixture.repository.discardStagedAPIKey(ref: "candidate-1")
        #expect(try await fixture.pendingRefs().isEmpty)
    }

    @Test(arguments: [false, true])
    func recoveryPreservesAnyCommittedModelReference(unknownKind: Bool) async throws {
        let fixture = try ModelKeyFixture()
        try await fixture.seed()
        try await fixture.repository.registerStagedAPIKey(ref: "original-ref")
        if unknownKind {
            try await fixture.database.queue.write {
                try $0.execute(sql: "UPDATE modelConfiguration SET kind = 'future-kind' WHERE id = 'model'")
            }
            #expect(try await fixture.repository.all().isEmpty)
        }

        try await fixture.repository.recoverStagedAPIKeysAtStartup()

        #expect(try await fixture.repository.loadAPIKey(ref: "original-ref") == "original")
        #expect(try await fixture.pendingRefs().isEmpty)
        #expect(await fixture.keys.deletedRefs.isEmpty)
    }

    @Test func recoveryRetriesMissingSecretsAndContinuesPastOtherFailures() async throws {
        let fixture = try ModelKeyFixture()
        try await fixture.stage(ref: "a-failing")
        try await fixture.repository.registerStagedAPIKey(ref: "b-no-secret")
        try await fixture.stage(ref: "c-abandoned")
        await fixture.keys.setDeleteFailure(ref: "a-failing")

        await #expect(throws: ModelConfigurationRepositoryError.stagedKeyCleanupFailed) {
            try await fixture.repository.recoverStagedAPIKeysAtStartup()
        }

        #expect(try await fixture.pendingRefs() == ["a-failing"])
        #expect(try await fixture.repository.loadAPIKey(ref: "c-abandoned") == nil)
        await fixture.keys.setDeleteFailure(ref: nil)
        try await fixture.repository.recoverStagedAPIKeysAtStartup()
        #expect(try await fixture.pendingRefs().isEmpty)
    }

    @Test func liveFailedMutationDoesNotSweepAnotherSuspendedStagedKey() async throws {
        let fixture = try ModelKeyFixture()
        try await fixture.seed()
        await fixture.keys.suspendNextWrite()
        let pending = Task { await fixture.rotate() }
        await fixture.keys.waitUntilWriteSuspended()
        #expect(try await fixture.pendingRefs() == ["candidate-1"])
        #expect(try await fixture.repository.fetch(id: "model") == fixture.original)
        try await fixture.rejectModelUpdates()

        await fixture.rotate(prefix: "failing-")

        #expect(try await fixture.pendingRefs() == ["candidate-1"])
        #expect(try await fixture.repository.loadAPIKey(ref: "candidate-1") == "candidate")
        #expect(try await fixture.repository.loadAPIKey(ref: "original-ref") == "original")
        try await fixture.database.queue.write { try $0.execute(sql: "DROP TRIGGER block_model_update") }
        await fixture.keys.releaseWrite()
        await pending.value
        #expect(fixture.viewModel.lastSavedModel == fixture.replacement)
        #expect(try await fixture.pendingRefs().isEmpty)
        #expect(try await fixture.repository.loadAPIKey(ref: "candidate-1") == "candidate")
    }

    @Test func migrationPreservesExistingModelSelectionAndKeyReference() async throws {
        let queue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        registerChatMigrations(&migrator)
        try migrator.migrate(queue, upTo: "v11_modelProviderIdentity")
        var draft = ModelKeyFixture.original
        draft.isSelected = true
        let saved = draft
        try await queue.write { try saved.save($0) }

        try migrator.migrate(queue)

        #expect(try await queue.read { try ModelConfigurationRecord.fetchOne($0) } == saved)
        #expect(try await queue.read { try ModelStagedKeyRecord.fetchCount($0) } == 0)
    }
}

@MainActor
private struct ModelKeyFixture {
    let database: ChatDatabase
    let repository: GRDBModelConfigurationRepository
    let keys = ModelStagingKeychain()
    let viewModel: SettingsViewModel
    static var original: ModelConfigurationRecord {
        ModelConfigurationRecord(
            id: "model", name: "Original", baseURL: URL(string: "https://api.openai.com/v1")!,
            apiKeyRef: "original-ref", modelId: "gpt", createdAt: FixedClock().now(),
            maxContextTokens: 8_000, providerId: "openai"
        )
    }
    var original: ModelConfigurationRecord { Self.original }
    var replacement: ModelConfigurationRecord {
        var record = original
        record.name = "Renamed"
        record.apiKeyRef = "candidate-1"
        return record
    }
    init() throws {
        database = try ChatDatabase.makeInMemory()
        repository = GRDBModelConfigurationRepository(database: database, keychain: keys)
        viewModel = SettingsViewModel(
            appInfo: SuperAppInfo(bundleName: "Test", version: "1", build: "1"),
            settingRepository: GRDBSettingRepository(database: database), modelRepository: repository,
            conversationRepository: GRDBConversationRepository(database: database), toolRegistry: ToolRegistry(),
            userPersonalizationReceiver: FakeUserPersonalizationReceiver(),
            autoCompactPolicyReceiver: FakeAutoCompactPolicyReceiver(), webSearchPolicyReceiver: FakeWebSearchPolicyReceiver(),
            clock: FixedClock(), appleFoundationAvailability: .unavailable(.deviceNotEligible), appleFoundationContextTokens: 4_096
        )
    }
    func seed() async throws {
        try await repository.save(original)
        try await repository.storeAPIKey("original", ref: "original-ref")
    }
    func stage(ref: String) async throws {
        try await repository.registerStagedAPIKey(ref: ref)
        try await repository.storeAPIKey("candidate", ref: ref)
    }
    func rotate(prefix: String = "candidate-") async {
        await viewModel.updateModel(
            id: "model", name: "Renamed", baseURL: original.baseURL, modelId: "gpt", apiKey: "candidate",
            supportsThinking: false, maxContextTokens: 8_000, idGenerator: DeterministicIDGenerator(prefix: prefix)
        )
    }
    func pendingRefs() async throws -> [String] {
        try await database.queue.read { try ModelStagedKeyRecord.order(Column("id")).fetchAll($0).map(\.id) }
    }
    func rejectModelUpdates() async throws {
        try await database.queue.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER block_model_update BEFORE UPDATE ON modelConfiguration
                BEGIN SELECT RAISE(ABORT, 'Injected save failure'); END
                """)
        }
    }
}

private actor ModelStagingKeychain: KeychainClient {
    enum Failure: Error, Sendable { case write, deletion }
    private var values: [String: String] = [:]
    private var deleteFailureRef: String?
    private var writeFailureAfterWriting: Bool?
    private let writeGate = ModelStagingGate()
    private(set) var writeCount = 0
    private(set) var deletedRefs: [String] = []
    func setDeleteFailure(ref: String?) { deleteFailureRef = ref }
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
        if deleteFailureRef == ref { throw Failure.deletion }
        deletedRefs.append(ref)
        values[ref] = nil
    }
    func suspendNextWrite() async { await writeGate.arm() }
    func waitUntilWriteSuspended() async { await writeGate.waitUntilEntered() }
    func releaseWrite() async { await writeGate.release() }
}

private actor ModelStagingGate {
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
