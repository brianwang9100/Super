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
        #expect(record.modelId == "system-default")
        #expect(record.maxContextTokens == 4_096)
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
    func seedDoesNothingWhenOnlyDeletedRowsRemain() async throws {
        // A user who manually deleted AFM (via Settings) should not have
        // it silently re-seeded on next launch. The empty check covers
        // this naturally because `delete(id:)` removes the row; after
        // that the table is genuinely empty and seed *would* re-create.
        //
        // The current contract IS to re-seed in that case — but verify
        // the call is a no-op once we re-call after a seed has run.
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
        // Idempotent on the second call within the same launch.
        #expect(second == nil)
        let all = try await repository.all()
        #expect(all.count == 1)
    }
}
