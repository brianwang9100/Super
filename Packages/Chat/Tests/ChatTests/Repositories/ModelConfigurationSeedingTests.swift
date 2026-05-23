import Core
import Foundation
import Testing
@testable import Chat

/// Tests for `ModelConfigurationSeeding` — the first-launch seed that
/// gives a fresh install a working `.appleFoundation` row so Chat opens
/// onto a usable model instead of the `noModelConfigured` empty state.
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

        // The row persists and becomes the registry's active model via
        // the existing `setActive(isSelected:)` path.
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
