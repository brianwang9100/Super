import Core
import Foundation
import Testing
@testable import Bible

@Suite("Narration credential preferences")
@MainActor
struct NarrationCredentialPreferenceTests {
    @Test(arguments: [false, true], [NarrationVoice.appleDefault, NarrationVoice(company: .openAI, identifier: "cedar")])
    func committedVoiceChangeRejectsOldReadBeforeAvailabilityRefresh(ownsKey: Bool, choice: NarrationVoice) async throws {
        let fixture = try PreferenceCredentialFixture()
        try await fixture.configure(ownsKey: ownsKey)
        let generator = PreferenceSpeechGenerator()
        let player = PreferenceAudioPlayer()
        let service = OpenAINarrationService(
            generator: generator, player: player, cache: try NarrationAudioCache.makeInMemory(clock: FixedClock())
        ) { try await fixture.settings.apiKey() }
        let apple = FakeNarrationService()
        let controller = NarrationController(service: apple, cloudService: service, settings: fixture.settings)
        controller.voice = .marin
        await fixture.keys.suspendNextRead()
        controller.start(utterances: [.init(verseNumber: 1, text: "One")])
        await fixture.keys.waitUntilSuspended()
        let pending = try #require(service._pendingTask)
        await fixture.sources.suspendNextRead()
        let save = Task { try await fixture.settings.setPreference(voice: choice, rate: 1) }
        await fixture.sources.waitUntilSuspended()
        #expect(fixture.settings.record.preferredVoiceId == choice.id)
        #expect(controller.voice == .marin) // Availability refresh has not delivered onChange yet.

        await fixture.keys.release()
        await pending.value

        #expect(await generator.callCount == 0)
        #expect(player.playCount == 0)
        await fixture.sources.release()
        try await save.value
        #expect(controller.voice == choice)
        #expect(controller.lastError == nil)
        if choice.company == .apple {
            #expect(apple.lastStartArgs?.voiceIdentifier == choice.identifier)
            #expect(apple.startCallCount == 1)
        } else {
            await service._waitForPendingTask()
            #expect(await generator.callCount == 1)
            #expect(player.playCount == 1)
        }
        controller.stop()
    }

    @Test(arguments: [false, true])
    func rateSavePreservesPendingCredentialRead(ownsKey: Bool) async throws {
        let fixture = try PreferenceCredentialFixture()
        try await fixture.configure(ownsKey: ownsKey)
        let settings = fixture.settings
        let keys = fixture.keys
        let original = settings.record
        var invalidations = 0
        settings.onInvalidated = { invalidations += 1 }
        await keys.suspendNextRead()
        let lookup = Task { try? await settings.apiKey() }
        await keys.waitUntilSuspended()

        try await settings.setRate(1.25)

        #expect(settings.record.revision == original.revision + 1)
        #expect(settings.record.rate == 1.25)
        #expect(settings.record.keyRef == original.keyRef)
        #expect(settings.record.preferredVoiceId == original.preferredVoiceId)
        #expect(settings.openAIAvailable)
        #expect(invalidations == 0)
        await keys.release()
        #expect(await lookup.value == "configured")
    }

    @Test(arguments: [false, true])
    func disablingRejectsPendingCredentialRead(ownsKey: Bool) async throws {
        let fixture = try PreferenceCredentialFixture()
        try await fixture.configure(ownsKey: ownsKey)
        await fixture.keys.suspendNextRead()
        let lookup = Task { try? await fixture.settings.apiKey() }
        await fixture.keys.waitUntilSuspended()

        try await fixture.settings.setEnabled(false)

        await fixture.keys.release()
        #expect(await lookup.value == nil)
        #expect(!fixture.settings.openAIAvailable)
    }

    @Test(arguments: [false, true])
    func replacementRejectsPendingCredentialRead(ownsKey: Bool) async throws {
        let fixture = try PreferenceCredentialFixture()
        try await fixture.configure(ownsKey: ownsKey)
        await fixture.keys.suspendNextRead()
        let lookup = Task { try? await fixture.settings.apiKey() }
        await fixture.keys.waitUntilSuspended()

        try await fixture.settings.saveDedicatedKey(
            "replacement", enabled: true, expecting: fixture.settings.record.revision
        )

        await fixture.keys.release()
        #expect(await lookup.value == nil)
        #expect(try await fixture.settings.apiKey() == "replacement")
    }

    @Test(arguments: [false, true])
    func reenableCannotReviveCanceledSessionAfterCredentialRead(ownsKey: Bool) async throws {
        let fixture = try PreferenceCredentialFixture()
        try await fixture.configure(ownsKey: ownsKey)
        let generator = PreferenceSpeechGenerator()
        let player = PreferenceAudioPlayer()
        var resolvedKey: String?
        let service = OpenAINarrationService(
            generator: generator, player: player, cache: try NarrationAudioCache.makeInMemory(clock: FixedClock())
        ) {
            let key = try await fixture.settings.apiKey()
            resolvedKey = key
            return key
        }
        let controller = NarrationController(service: FakeNarrationService(), cloudService: service, settings: fixture.settings)
        controller.voice = .marin
        await fixture.keys.suspendNextRead()
        controller.start(utterances: [.init(verseNumber: 1, text: "One")])
        await fixture.keys.waitUntilSuspended()
        let pending = try #require(service._pendingTask)

        try await fixture.settings.setEnabled(false)
        try await fixture.settings.setEnabled(true)
        await fixture.keys.release()
        await pending.value

        // The credential is valid again, but the canceled service generation must not submit or play it.
        #expect(resolvedKey == "configured")
        #expect(await generator.callCount == 0)
        #expect(player.playCount == 0)
        #expect(controller.state == .idle)
        #expect(controller.lastError == nil)
    }
}

@MainActor
private struct PreferenceCredentialFixture {
    let keys = PreferenceKeychain()
    let sources = PreferenceSources()
    let source = ProviderAudioCredential(id: "model", name: "OpenAI", keyRef: "borrowed-ref")
    let settings: NarrationSettingsController
    init() throws {
        let source = source
        let sources = sources
        settings = NarrationSettingsController(
            repository: GRDBNarrationSettingsRepository(database: try BibleDatabase.makeInMemory()),
            keychain: keys, listSources: { await sources.read(source) }, clock: FixedClock(), ids: DeterministicIDGenerator()
        )
    }
    func configure(ownsKey: Bool) async throws {
        if ownsKey {
            try await settings.saveDedicatedKey("configured", enabled: true, expecting: 0)
        } else {
            try await settings.configure(credential: source, enabled: true, useThisKey: true, expecting: 0)
        }
    }
}

/// Gates one credential read while allowing preference-save availability refreshes.
private actor PreferenceKeychain: KeychainClient {
    private var values = ["borrowed-ref": "configured"]
    private var armed = false
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    func getString(ref: String) async throws -> String? {
        let captured = values[ref]
        if armed {
            armed = false
            entered = true
            entry?.resume(); entry = nil
            await withCheckedContinuation { completion = $0 }
        }
        return captured
    }
    func setString(_ value: String, ref: String) async throws { values[ref] = value }
    func delete(ref: String) async throws { values[ref] = nil }
    func suspendNextRead() { armed = true; entered = false }
    func waitUntilSuspended() async { if !entered { await withCheckedContinuation { entry = $0 } } }
    func release() { completion?.resume(); completion = nil }
}

private actor PreferenceSources {
    private var armed = false
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    func read(_ source: ProviderAudioCredential) async -> [ProviderAudioCredential] {
        if armed {
            armed = false
            entered = true
            entry?.resume(); entry = nil
            await withCheckedContinuation { completion = $0 }
        }
        return [source]
    }
    func suspendNextRead() { armed = true; entered = false }
    func waitUntilSuspended() async { if !entered { await withCheckedContinuation { entry = $0 } } }
    func release() { completion?.resume(); completion = nil }
}

private actor PreferenceSpeechGenerator: SpeechGenerating {
    private(set) var callCount = 0
    func generate(text: String, voice: OpenAISpeechVoice, apiKey: String) async throws -> Data {
        callCount += 1
        return Data([1])
    }
}

@MainActor
private final class PreferenceAudioPlayer: NarrationAudioPlaying {
    private(set) var playCount = 0
    func play(_ audio: Data, rate: Float) -> AsyncStream<NarrationAudioEvent> {
        playCount += 1
        return AsyncStream { $0.yield(.started); $0.yield(.finished); $0.finish() }
    }
    func pause() {}
    func resume() {}
    func stop() {}
    func setRate(_ rate: Float) {}
}
