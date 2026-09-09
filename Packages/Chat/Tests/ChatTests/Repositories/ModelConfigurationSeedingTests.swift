import Core
import Foundation
import Testing
@testable import Chat

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
        #expect(record.name == AppleFoundationLLMProvider.defaultModelDisplayName)
        #expect(record.createdAt == clock.now())

        let all = try await repository.all()
        #expect(all.count == 1)
        let selected = try await repository.selected()
        #expect(selected?.id == record.id)
    }

    @Test
    func seedDoesNothingWhenAnyRowAlreadyExists() async throws {
        let database = try ChatDatabase.makeInMemory()
        let repository = GRDBModelConfigurationRepository(
            database: database,
            keychain: InMemoryKeychainClient()
        )
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
            idGenerator: DeterministicIDGenerator(prefix: "afm-"),
            clock: FixedClock(Date(timeIntervalSinceReferenceDate: 0))
        )

        #expect(seeded == nil)
        let all = try await repository.all()
        #expect(all.map(\.id) == ["user-row"])
        let selected = try await repository.selected()
        #expect(selected?.id == "user-row")
    }

    @Test
    func noOpSeedDoesNotConsumeAnIDFromTheGenerator() async throws {
        // A no-op seed must not consume a deterministic ID.
        let database = try ChatDatabase.makeInMemory()
        let repository = GRDBModelConfigurationRepository(
            database: database,
            keychain: InMemoryKeychainClient()
        )
        let idGenerator = DeterministicIDGenerator(prefix: "afm-")
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
        #expect(idGenerator.nextID() == "afm-1")
    }

    @Test
    func seedRunsAtomicallyInOneWriteTransaction() async throws {
        // The emptiness check and insert must share one write transaction.
        let database = try ChatDatabase.makeInMemory()
        let repository = GRDBModelConfigurationRepository(
            database: database,
            keychain: InMemoryKeychainClient()
        )

        async let firstSeed = ModelConfigurationSeeding.seedDefaultIfEmpty(
            repository: repository,
            idGenerator: DeterministicIDGenerator(prefix: "a-"),
            clock: FixedClock(Date(timeIntervalSinceReferenceDate: 0))
        )
        async let secondSeed = ModelConfigurationSeeding.seedDefaultIfEmpty(
            repository: repository,
            idGenerator: DeterministicIDGenerator(prefix: "b-"),
            clock: FixedClock(Date(timeIntervalSinceReferenceDate: 0))
        )
        let (a, b) = try await (firstSeed, secondSeed)

        let landed = [a, b].compactMap { $0 }
        #expect(landed.count == 1)
        let all = try await repository.all()
        #expect(all.count == 1)
        #expect(all[0].id == landed[0].id)
    }

    @Test
    func seedIsIdempotentAcrossBackToBackCalls() async throws {
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
