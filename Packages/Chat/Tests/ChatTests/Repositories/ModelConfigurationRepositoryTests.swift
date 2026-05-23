import Core
import Foundation
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
            kind: kind,
            name: name,
            baseURL: baseURL,
            apiKeyRef: apiKeyRef,
            modelId: modelId,
            supportsThinking: false,
            maxContextTokens: 16_000,
            isSelected: isSelected,
            createdAt: now.addingTimeInterval(createdOffset)
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
