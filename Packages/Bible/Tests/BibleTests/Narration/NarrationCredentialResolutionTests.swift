import Core
import Foundation
import Testing
@testable import Bible

@Suite("Narration credential resolution")
@MainActor
struct NarrationCredentialResolutionTests {
    @Test func sameNameChoicesResolveTheirOwnKeysAcrossRefreshes() async throws {
        let fixture = try CredentialFixture()
        let second = ProviderAudioCredential(id: "second-model", name: fixture.source.name, keyRef: "second-ref")
        try await fixture.keys.setString("second-key", ref: second.keyRef)
        await fixture.projection.set([second, fixture.source])
        await fixture.settings.refreshCredentials()
        let firstLabel = NarrationKeySourceLabel.make(for: fixture.source, among: fixture.settings.sources)
        let secondLabel = NarrationKeySourceLabel.make(for: second, among: fixture.settings.sources)
        #expect(firstLabel != secondLabel)

        try await fixture.configure()
        #expect(try await fixture.settings.apiKey() == "original")
        try await fixture.settings.configure(
            credential: second, enabled: true, useThisKey: true, expecting: fixture.settings.record.revision
        )
        #expect(fixture.settings.record.sourceId == second.id)
        #expect(try await fixture.settings.apiKey() == "second-key")

        await fixture.projection.set([fixture.source, second])
        await fixture.settings.refreshCredentials()
        #expect(NarrationKeySourceLabel.make(for: fixture.source, among: fixture.settings.sources) == firstLabel)
        #expect(NarrationKeySourceLabel.make(for: second, among: fixture.settings.sources) == secondLabel)
        #expect(try await fixture.settings.apiKey() == "second-key")
    }

    @Test("A new model draft replaces a removed borrowed source while preserving opt-out", arguments: [false, true])
    func modelDraftDefaultsToNewKeyAfterBorrowedSourceRemoval(enabled: Bool) async throws {
        let fixture = try CredentialFixture()
        try await fixture.configure()
        if !enabled { try await fixture.settings.setEnabled(false) }
        await fixture.projection.set([])
        try await fixture.keys.delete(ref: "old-ref")
        await fixture.settings.refreshCredentials()
        let setup = fixture.settings.providerSetup
        let snapshot = setup.snapshot()

        #expect(fixture.settings.source == fixture.source) // Retain the recovery label.
        #expect(snapshot.source == nil)
        #expect(snapshot.enabled == enabled)
        let editingId: String? = nil
        // Match the model registration draft's default selection for a newly created model.
        let useThisKey = snapshot.source == nil || snapshot.source?.id == editingId
        #expect(useThisKey)
        let replacement = ProviderAudioCredential(id: "new-model", name: "New OpenAI model", keyRef: "new-ref")
        try await fixture.keys.setString("replacement", ref: replacement.keyRef)
        await fixture.projection.set([replacement])

        try await setup.commit(replacement, snapshot.enabled ?? true, useThisKey, snapshot.revision)

        #expect(fixture.settings.record.sourceId == replacement.id)
        #expect(fixture.settings.record.keyRef == replacement.keyRef)
        #expect(fixture.settings.record.enabled == enabled)
        #expect(fixture.settings.hasKey)
        #expect(fixture.settings.snapshot.source == replacement)
        if enabled { #expect(try await fixture.settings.apiKey() == "replacement") }
    }

    @Test("A new model draft preserves an available selected source even when narration is disabled",
          arguments: [false, true])
    func modelDraftPreservesAvailableSource(enabled: Bool) async throws {
        let fixture = try CredentialFixture()
        try await fixture.configure()
        if !enabled { try await fixture.settings.setEnabled(false) }
        let setup = fixture.settings.providerSetup
        let snapshot = setup.snapshot()

        #expect(snapshot.source == fixture.source)
        #expect(snapshot.enabled == enabled)
        let editingId: String? = nil
        let useThisKey = snapshot.source == nil || snapshot.source?.id == editingId
        #expect(!useThisKey)
        let newSource = ProviderAudioCredential(id: "new-model", name: "Another OpenAI model", keyRef: "new-ref")
        try await fixture.keys.setString("another-key", ref: newSource.keyRef)
        await fixture.projection.set([fixture.source, newSource])

        try await setup.commit(newSource, snapshot.enabled ?? true, useThisKey, snapshot.revision)

        #expect(fixture.settings.record.sourceId == fixture.source.id)
        #expect(fixture.settings.record.keyRef == fixture.source.keyRef)
        #expect(fixture.settings.record.enabled == enabled)
        #expect(fixture.settings.record.revision == snapshot.revision)
        #expect(fixture.settings.snapshot.source == fixture.source)
    }

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
