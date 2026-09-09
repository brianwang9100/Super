import Core
import Foundation
import Testing
@testable import Chat

/// Tests deterministic Apple model defaults, independent of OS/service readiness,
/// while preserving existing selections and the atomic empty-repository contract.
@Suite
struct ModelConfigurationSeedingTests {

    @Test
    func seedsAnAppleFoundationRowWhenRepositoryIsEmpty() async throws {
        let database = try ChatDatabase.makeInMemory()
        let repository = GRDBModelConfigurationRepository(
            database: database,
            keychain: InMemoryKeychainClient()
        )
        let idGenerator = DeterministicIDGenerator(prefix: "afm-")
        let clock = FixedClock(Date(timeIntervalSinceReferenceDate: 0))

        let seeded = try await ModelConfigurationSeeding.seedDefaultIfEmpty(
            repository: repository,
            idGenerator: idGenerator,
            clock: clock
        )

        let record = try #require(seeded)
        #expect(record.id == "afm-1")
        #expect(record.kind == .appleFoundation)
        #expect(record.baseURL == nil)
        #expect(record.apiKeyRef == nil)
        #expect(record.isSelected)
        #expect(record.modelId == AppleFoundationLLMProvider.defaultModelID)
        #expect(record.maxContextTokens == AppleFoundationLLMProvider.defaultMaxContextTokens)
        #expect(record.name == AppleFoundationModel.local.displayName)
        #expect(record.createdAt == clock.now())

        // The row persists and becomes the registry's active model via
        // the existing `setActive(isSelected:)` path.
        let all = try await repository.all()
        #expect(all.count == 1)
        let selected = try await repository.selected()
        #expect(selected?.id == record.id)
    }

    @Test(arguments: AppleFoundationModel.allCases)
    func seedsTheChosenVariantWithInjectedMetadata(model: AppleFoundationModel) async throws {
        let database = try ChatDatabase.makeInMemory()
        let repository = GRDBModelConfigurationRepository(
            database: database, keychain: InMemoryKeychainClient()
        )
        let clock = FixedClock(Date(timeIntervalSinceReferenceDate: 123))
        let contextTokens = model == .local ? 8_192 : 24_000

        let seeded = try await ModelConfigurationSeeding.seedDefaultIfEmpty(
            repository: repository,
            model: model,
            maxContextTokens: contextTokens,
            idGenerator: DeterministicIDGenerator(prefix: "chosen-"),
            clock: clock
        )

        let record = try #require(seeded)
        #expect(record.modelId == model.rawValue)
        #expect(record.name == model.displayName)
        #expect(record.maxContextTokens == contextTokens)
        #expect(record.kind == .appleFoundation)
        #expect(record.baseURL == nil)
        #expect(record.apiKeyRef == nil)
        #expect(!record.supportsThinking)
        #expect(record.searchBackend == nil)
        #expect(record.isSelected)
        #expect(record.createdAt == clock.now())
        #expect(try await repository.all() == [record])
        #expect(try await repository.selected() == record)
    }

    @Test
    func transientUnavailabilityDoesNotChangeTheChosenCloudDefault() async throws {
        let database = try ChatDatabase.makeInMemory()
        let repository = GRDBModelConfigurationRepository(
            database: database, keychain: InMemoryKeychainClient()
        )
        let statusProvider = FixedAppleFoundationModelStatusProvider(
            localAvailability: .available,
            supportsPrivateCloudCompute: true,
            privateCloudComputeStatus: AppleFoundationModelStatus(
                model: .privateCloudCompute, availability: .unavailable(.systemNotReady)
            )
        )
        let status = await statusProvider.status(for: .privateCloudCompute)
        #expect(!status.availability.isAvailable)

        let seeded = try await ModelConfigurationSeeding.seedDefaultIfEmpty(
            repository: repository,
            model: .privateCloudCompute,
            maxContextTokens: status.contextTokens,
            idGenerator: DeterministicIDGenerator(prefix: "pcc-"),
            clock: FixedClock(Date(timeIntervalSinceReferenceDate: 0))
        )

        #expect(seeded?.modelId == AppleFoundationModel.privateCloudCompute.rawValue)
        #expect(seeded?.maxContextTokens == AppleFoundationModel.privateCloudCompute.fallbackContextTokens)
        #expect(seeded?.isSelected == true)
    }

    @Test(arguments: AppleFoundationModel.allCases)
    func populatedAppleStorePreservesTheEntireRecord(model: AppleFoundationModel) async throws {
        let database = try ChatDatabase.makeInMemory()
        let repository = GRDBModelConfigurationRepository(
            database: database, keychain: InMemoryKeychainClient()
        )
        let existing = ModelConfigurationRecord(
            id: "existing-apple", name: "My chosen Apple model", baseURL: nil, apiKeyRef: nil,
            modelId: model.rawValue, createdAt: Date(timeIntervalSinceReferenceDate: 456),
            kind: .appleFoundation, maxContextTokens: 2_048, isSelected: true
        )
        try await repository.save(existing)
        let ids = DeterministicIDGenerator(prefix: "unused-")

        let seeded = try await ModelConfigurationSeeding.seedDefaultIfEmpty(
            repository: repository,
            model: .privateCloudCompute,
            idGenerator: ids,
            clock: FixedClock(Date(timeIntervalSinceReferenceDate: 789))
        )

        #expect(seeded == nil)
        #expect(try await repository.all() == [existing])
        #expect(try await repository.selected() == existing)
        #expect(ids.nextID() == "unused-1")
    }

    @Test
    func seedDoesNothingWhenAnyRowAlreadyExists() async throws {
        let database = try ChatDatabase.makeInMemory()
        let repository = GRDBModelConfigurationRepository(
            database: database,
            keychain: InMemoryKeychainClient()
        )
        // Pre-existing user-added row — Gemini via OpenAI shim.
        let userRow = ModelConfigurationRecord(
            id: "user-row",
            name: "Gemini",
            baseURL: URL(string: "https://example.com/v1"),
            apiKeyRef: "kc:gemini",
            modelId: "gemini-2.5-flash",
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            kind: .openAICompatible,
            isSelected: true
        )
        try await repository.save(userRow)

        let seeded = try await ModelConfigurationSeeding.seedDefaultIfEmpty(
            repository: repository,
            model: .privateCloudCompute,
            idGenerator: DeterministicIDGenerator(prefix: "afm-"),
            clock: FixedClock(Date(timeIntervalSinceReferenceDate: 0))
        )

        // Returns nil — already populated, so no seed performed.
        #expect(seeded == nil)
        let all = try await repository.all()
        #expect(all.map(\.id) == ["user-row"])
        // The pre-existing selection is preserved.
        let selected = try await repository.selected()
        #expect(selected?.id == "user-row")
    }

    @Test
    func noOpSeedDoesNotConsumeAnIDFromTheGenerator() async throws {
        // DeterministicIDGenerator is a counter — if the seed builds
        // the record before checking emptiness, every no-op call would
        // burn an id. Pin the contract: a no-op call leaves the
        // counter at 0, so a *subsequent* seed against an emptied
        // table starts at id-1.
        let database = try ChatDatabase.makeInMemory()
        let repository = GRDBModelConfigurationRepository(
            database: database,
            keychain: InMemoryKeychainClient()
        )
        let idGenerator = DeterministicIDGenerator(prefix: "afm-")
        // Pre-populated so the first seed is a no-op.
        try await repository.save(ModelConfigurationRecord(
            id: "user-row",
            name: "Gemini",
            baseURL: URL(string: "https://example.com/v1"),
            apiKeyRef: "kc:gemini",
            modelId: "gemini-2.5-flash",
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            kind: .openAICompatible
        ))
        _ = try await ModelConfigurationSeeding.seedDefaultIfEmpty(
            repository: repository,
            idGenerator: idGenerator,
            clock: FixedClock(Date(timeIntervalSinceReferenceDate: 0))
        )
        // Counter should still be at 0 (no id consumed). Verify by
        // taking an id and asserting it's the first in the sequence.
        #expect(idGenerator.nextID() == "afm-1")
    }

    @Test(arguments: AppleFoundationModel.allCases)
    func seedRunsAtomicallyInOneWriteTransaction(model: AppleFoundationModel) async throws {
        // When two callers race on first launch, only one row lands.
        // The repository's `insertIfEmpty` runs the empty-check and the
        // insert in a single `queue.write`, so the empty-table
        // precondition can't be invalidated between the read and the
        // write.
        let database = try ChatDatabase.makeInMemory()
        let repository = GRDBModelConfigurationRepository(
            database: database,
            keychain: InMemoryKeychainClient()
        )

        async let firstSeed = ModelConfigurationSeeding.seedDefaultIfEmpty(
            repository: repository,
            model: model,
            idGenerator: DeterministicIDGenerator(prefix: "a-"),
            clock: FixedClock(Date(timeIntervalSinceReferenceDate: 0))
        )
        async let secondSeed = ModelConfigurationSeeding.seedDefaultIfEmpty(
            repository: repository,
            model: model,
            idGenerator: DeterministicIDGenerator(prefix: "b-"),
            clock: FixedClock(Date(timeIntervalSinceReferenceDate: 0))
        )
        let (a, b) = try await (firstSeed, secondSeed)

        // Exactly one of the two calls landed a record; the other saw
        // a non-empty table and bailed.
        let landed = [a, b].compactMap { $0 }
        #expect(landed.count == 1)
        let all = try await repository.all()
        #expect(all.count == 1)
        #expect(all[0].id == landed[0].id)
        #expect(all[0].modelId == model.rawValue)
        #expect(all[0].isSelected)
    }

    @Test
    func seedIsIdempotentAcrossBackToBackCalls() async throws {
        // Two consecutive calls within the same launch must produce
        // exactly one seeded row — the second call sees the first
        // call's row and exits via the `existing.isEmpty` guard. This
        // is the in-process idempotency guarantee; deliberate
        // re-seeding after a user-driven `delete` is a separate
        // policy that is *not* covered here because, per the type doc,
        // deleting AFM and getting an empty table back *does* trigger
        // a fresh seed on next launch (a property the user can
        // disable by adding any other model first).
        let database = try ChatDatabase.makeInMemory()
        let repository = GRDBModelConfigurationRepository(
            database: database,
            keychain: InMemoryKeychainClient()
        )
        let idGenerator = DeterministicIDGenerator(prefix: "afm-")
        let clock = FixedClock(Date(timeIntervalSinceReferenceDate: 0))

        let first = try await ModelConfigurationSeeding.seedDefaultIfEmpty(
            repository: repository,
            idGenerator: idGenerator,
            clock: clock
        )
        #expect(first != nil)

        let second = try await ModelConfigurationSeeding.seedDefaultIfEmpty(
            repository: repository,
            idGenerator: idGenerator,
            clock: clock
        )
        #expect(second == nil)
        let all = try await repository.all()
        #expect(all.count == 1)
    }
}
