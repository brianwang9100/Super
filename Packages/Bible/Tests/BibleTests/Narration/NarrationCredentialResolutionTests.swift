import Core
import Foundation
import Testing
@testable import Bible

/// Borrowed narration credentials follow only committed model projections across asynchronous refreshes.
@Suite("Narration credential resolution")
@MainActor
struct NarrationCredentialResolutionTests {
    @Test func unchangedAudioCommitAfterModelRenamePreservesPlaybackAndPendingLookup() async throws {
        let fixture = try CredentialFixture()
        try await fixture.configure()
        let revision = fixture.settings.record.revision
        var invalidations = 0
        fixture.settings.onInvalidated = { invalidations += 1 }
        await fixture.keys.suspendNextRead()
        let lookup = Task { try? await fixture.settings.apiKey() }
        await fixture.keys.waitUntilSuspended()

        // The model editor commits its audio draft after updating the model's metadata.
        let renamed = ProviderAudioCredential(id: "model", name: "Renamed model", keyRef: "old-ref")
        await fixture.projection.set([renamed])
        try await fixture.settings.providerSetup.commit(renamed, true, false, revision)
        await fixture.keys.release()

        #expect(await lookup.value == "original")
        #expect(invalidations == 0)
        #expect(fixture.settings.record.revision == revision)
        #expect(fixture.settings.snapshot.source == renamed)
    }

    @Test func borrowerFollowsCommittedReferenceAcrossRotationAndReload() async throws {
        let fixture = try CredentialFixture()
        try await fixture.configure()
        try await fixture.keys.setString("replacement", ref: "new-ref")
        #expect(try await fixture.settings.apiKey() == "original")
        let replacement = ProviderAudioCredential(id: "model", name: "Renamed", keyRef: "new-ref")
        await fixture.projection.set([replacement])
        #expect(try await fixture.settings.apiKey() == "replacement")
        await fixture.settings.refreshCredentials()
        #expect(fixture.settings.hasKey)
        #expect(fixture.settings.snapshot.source == replacement)
        let reloaded = fixture.makeController()
        await reloaded.load()
        #expect(try await reloaded.apiKey() == "replacement")
        await fixture.projection.set([])
        await reloaded.refreshCredentials()
        #expect(!reloaded.hasKey)
        // The stored old key still exists, but a missing source must never fall back to it.
        await #expect(throws: SpeechGenerationError.missingKey) { try await reloaded.apiKey() }
    }

    @Test func keyLookupRejectsASelectionChangedWhileProjectionWasSuspended() async throws {
        let fixture = try CredentialFixture()
        try await fixture.configure()
        await fixture.projection.suspendNextRead()
        let lookup = Task { try? await fixture.settings.apiKey() }
        await fixture.projection.waitUntilSuspended()
        try await fixture.settings.saveDedicatedKey("dedicated", enabled: true, expecting: fixture.settings.record.revision)
        await fixture.projection.release()
        #expect(await lookup.value == nil)
        #expect(try await fixture.settings.apiKey() == "dedicated")
    }

    @Test func staleRefreshCannotRestoreRemovedSourceAvailability() async throws {
        let fixture = try CredentialFixture()
        try await fixture.configure()
        await fixture.projection.suspendNextRead()
        let oldRefresh = Task { await fixture.settings.refreshCredentials() }
        await fixture.projection.waitUntilSuspended()
        await fixture.projection.set([])
        await fixture.settings.refreshCredentials()
        #expect(!fixture.settings.hasKey)
        await fixture.projection.release()
        await oldRefresh.value
        #expect(!fixture.settings.hasKey)
        #expect(fixture.settings.sources.isEmpty)
    }

    @Test func keyLookupRejectsSourceRemovedDuringKeychainRead() async throws {
        let fixture = try CredentialFixture()
        try await fixture.configure()
        await fixture.keys.suspendNextRead()
        let lookup = Task { try? await fixture.settings.apiKey() }
        await fixture.keys.waitUntilSuspended()
        await fixture.projection.set([])
        await fixture.keys.release()
        #expect(await lookup.value == nil)
    }
}

@MainActor
private struct CredentialFixture {
    let source = ProviderAudioCredential(id: "model", name: "OpenAI", keyRef: "old-ref")
    let projection: CredentialProjection
    let keys = GatedNarrationKeychain()
    let repository: GRDBNarrationSettingsRepository
    let settings: NarrationSettingsController

    init() throws {
        let projection = CredentialProjection([source])
        self.projection = projection
        repository = GRDBNarrationSettingsRepository(database: try BibleDatabase.makeInMemory())
        settings = NarrationSettingsController(repository: repository, keychain: keys, listSources: { await projection.read() }, clock: FixedClock(), ids: DeterministicIDGenerator())
    }
    func configure() async throws {
        try await settings.configure(credential: source, enabled: true, useThisKey: true, expecting: 0)
    }
    func makeController() -> NarrationSettingsController {
        let projection = projection
        return NarrationSettingsController(repository: repository, keychain: keys, listSources: { await projection.read() }, clock: FixedClock(), ids: DeterministicIDGenerator())
    }
}

private actor CredentialProjection {
    private var values: [ProviderAudioCredential]
    private let gate = CredentialReadGate()
    init(_ values: [ProviderAudioCredential]) { self.values = values }
    func set(_ values: [ProviderAudioCredential]) { self.values = values }
    func read() async -> [ProviderAudioCredential] {
        let captured = values
        await gate.enter()
        return captured
    }
    func suspendNextRead() async { await gate.arm() }
    func waitUntilSuspended() async { await gate.waitUntilEntered() }
    func release() async { await gate.release() }
}

private actor GatedNarrationKeychain: KeychainClient {
    private var values = ["old-ref": "original"]
    private let gate = CredentialReadGate()
    func getString(ref: String) async throws -> String? {
        let captured = values[ref]
        await gate.enter()
        return captured
    }
    func setString(_ value: String, ref: String) async throws { values[ref] = value }
    func delete(ref: String) async throws { values[ref] = nil }
    func suspendNextRead() async { await gate.arm() }
    func waitUntilSuspended() async { await gate.waitUntilEntered() }
    func release() async { await gate.release() }
}

private actor CredentialReadGate {
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
