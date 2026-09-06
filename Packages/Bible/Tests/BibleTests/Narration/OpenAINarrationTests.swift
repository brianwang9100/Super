import Core
import Foundation
import GRDB
import Testing
@testable import Bible

/// Exercises opt-in persistence, credential ownership, bounded caching, and cancellation before audible playback.
@Suite("OpenAI narration")
@MainActor
struct OpenAINarrationTests {
    @Test func appleConnectionRechecksAfterVoiceDownload() async throws {
        let probe = InstalledVoiceProbe()
        let settings = NarrationSettingsController(
            repository: GRDBNarrationSettingsRepository(database: try BibleDatabase.makeInMemory()),
            keychain: InMemoryKeychainClient(), listSources: { [] },
            appleVoicesInstalled: { await probe.installed }
        )
        #expect(settings.appleEnhancedVoicesAvailable == nil)
        await settings.refreshAppleVoices()
        #expect(settings.appleEnhancedVoicesAvailable == false)
        await probe.setInstalled(true)
        await settings.refreshAppleVoices()
        #expect(settings.appleEnhancedVoicesAvailable == true)
        #expect(settings.record.enabled == nil)
        #expect(!settings.hasKey)
    }

    @Test func keychainWriteFailureLeavesConnectionUnconfigured() async throws {
        let repository = GRDBNarrationSettingsRepository(database: try BibleDatabase.makeInMemory())
        let settings = NarrationSettingsController(
            repository: repository, keychain: RejectingNarrationKeychain(), listSources: { [] },
            clock: FixedClock(), ids: DeterministicIDGenerator()
        )
        await #expect(throws: NarrationSettingsError.secureStorage) {
            try await settings.saveDedicatedKey("test-key", enabled: true, expecting: 0)
        }
        #expect(try await repository.load() == nil)
        #expect(settings.record.enabled == nil)
        #expect(settings.record.keyRef == nil)
        #expect(!settings.openAIAvailable)
    }

    @Test func freshInstallRequiresExplicitSaveAndPersistsOptOut() async throws {
        let fixture = try SettingsFixture()
        await fixture.settings.load()
        #expect(fixture.settings.record.enabled == nil)
        #expect(!fixture.settings.openAIAvailable)
        try await fixture.settings.configure(credential: fixture.source, enabled: true, useThisKey: true, expecting: 0)
        #expect(fixture.settings.openAIAvailable)
        #expect(fixture.settings.record.preferredVoiceId == NarrationVoice.marin.id)
        try await fixture.settings.setEnabled(false)
        let reloaded = fixture.makeController()
        await reloaded.load()
        #expect(reloaded.record.enabled == false)
        #expect(!reloaded.openAIAvailable)
    }

    @Test func addingSecondKeyPreservesExplicitNarrationSource() async throws {
        let fixture = try SettingsFixture()
        let second = ProviderAudioCredential(id: "other", name: "Other", keyRef: "other-ref")
        try await fixture.keychain.setString("other-test-key", ref: second.keyRef)
        try await fixture.settings.configure(credential: fixture.source, enabled: true, useThisKey: true, expecting: 0)
        try await fixture.settings.configure(credential: second, enabled: true, useThisKey: false, expecting: 1)
        #expect(fixture.settings.source?.id == fixture.source.id)
        #expect(try await fixture.settings.apiKey() == "test-key")
    }

    @Test func staleDraftCannotOverrideNewerOptOut() async throws {
        let fixture = try SettingsFixture()
        try await fixture.settings.configure(credential: fixture.source, enabled: false, useThisKey: true, expecting: 0)
        await #expect(throws: NarrationSettingsError.self) {
            try await fixture.settings.configure(credential: fixture.source, enabled: true, useThisKey: true, expecting: 0)
        }
        #expect(fixture.settings.record.enabled == false)
    }

    @Test func removingOwnedKeyDoesNotDeleteBorrowedChatKey() async throws {
        let fixture = try SettingsFixture()
        try await fixture.settings.saveDedicatedKey("audio-key", enabled: true, expecting: 0)
        let owned = try #require(fixture.settings.record.keyRef)
        try await fixture.settings.removeDedicatedKey()
        #expect(try await fixture.keychain.getString(ref: owned) == nil)
        #expect(try await fixture.keychain.getString(ref: fixture.source.keyRef) == "test-key")
        #expect(!fixture.settings.openAIAvailable)
    }

    @Test func missingCredentialStopsBeingAvailable() async throws {
        let fixture = try SettingsFixture()
        try await fixture.settings.configure(credential: fixture.source, enabled: true, useThisKey: true, expecting: 0)
        var invalidations = 0
        fixture.settings.onInvalidated = { invalidations += 1 }
        try await fixture.keychain.delete(ref: fixture.source.keyRef)
        await fixture.settings.refreshCredentials()
        #expect(invalidations == 1)
        #expect(!fixture.settings.openAIAvailable)
        await #expect(throws: SpeechGenerationError.missingKey) { try await fixture.settings.apiKey() }
    }

    @Test func cacheEvictsOldAudioAndClears() async throws {
        let clock = FixedClock()
        let cache = try NarrationAudioCache(queue: DatabaseQueue(), clock: clock, limit: 4)
        try await cache.save(Data([1, 2]), for: "a")
        clock.advance(by: 1)
        try await cache.save(Data([3, 4]), for: "b")
        clock.advance(by: 1)
        _ = try await cache.audio(for: "a")
        clock.advance(by: 1)
        try await cache.save(Data([5, 6]), for: "c")
        #expect(try await cache.audio(for: "b") == nil)
        #expect(try await cache.audio(for: "a") != nil)
        #expect(try await cache.byteCount() == 4)
        try await cache.clear()
        #expect(try await cache.byteCount() == 0)
    }

    @Test func clearingDownloadsStopsPlaybackAndPreservesTheConnection() async throws {
        let fixture = try SettingsFixture()
        try await fixture.settings.saveDedicatedKey("audio-key", enabled: true, expecting: 0)
        let cache = try NarrationAudioCache(queue: DatabaseQueue())
        try await cache.save(Data([1, 2, 3]), for: "cached-verse")
        let cloud = FakeNarrationService()
        let controller = NarrationController(service: FakeNarrationService(), cloudService: cloud, settings: fixture.settings, cache: cache)
        controller.voice = .marin
        controller.start(utterances: [.init(verseNumber: 1, text: "One")])
        controller._simulateEvent(.started(verseNumber: 1))

        try await controller.clearCachedAudio()

        #expect(controller.state == .idle)
        #expect(cloud.stopCallCount == 1)
        #expect(try await cache.byteCount() == 0)
        #expect(fixture.settings.openAIAvailable)
        #expect(try await fixture.settings.apiKey() == "audio-key")
    }

    @Test func segmentationPreservesUnicodeAndWordBoundaries() {
        let text = String(repeating: "In the beginning. 神愛世人 🌍 ", count: 100)
        let parts = OpenAINarrationService.segments(text)
        #expect(parts.joined() == text)
        #expect(parts.allSatisfy { $0.utf8.count <= 1600 })
        #expect(NarrationAudioCache.key(text: text, voice: .marin) != NarrationAudioCache.key(text: text, voice: .cedar))
    }

    @Test func stoppedDownloadCannotPlayOrCacheItsLateResult() async throws {
        let generator = GatedSpeech()
        let player = TestAudioPlayer()
        let cache = try NarrationAudioCache(queue: DatabaseQueue())
        let service = OpenAINarrationService(generator: generator, player: player, cache: cache) { "test-key" }
        let stream = service.startSpeaking([.init(verseNumber: 1, text: "One")], rate: 1, voice: .marin)
        let consumer = Task { var events: [NarrationEvent] = []; for await event in stream { events.append(event) }; return events }
        await generator.waitUntilStarted()
        let pending = service._pendingTask
        service.stop()
        await generator.complete()
        await pending?.value
        let events = await consumer.value
        #expect(events == [.preparing(verseNumber: 1), .cancelled])
        #expect(player.playCount == 0)
        #expect(try await cache.byteCount() == 0)
    }

    @Test func pauseDuringDownloadDefersPlayerUntilResume() async throws {
        let generator = GatedSpeech()
        let player = TestAudioPlayer()
        let cache = try NarrationAudioCache(queue: DatabaseQueue())
        let service = OpenAINarrationService(generator: generator, player: player, cache: cache) { "test-key" }
        let stream = service.startSpeaking([.init(verseNumber: 5, text: "One")], rate: 1.5, voice: .marin)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .preparing(verseNumber: 5))
        await generator.waitUntilStarted()
        service.pause()
        #expect(await iterator.next() == .paused)
        await generator.complete()
        // Wait until the service reaches its paused playback gate, with no scheduler polling.
        await service._waitUntilReadyWhilePaused()
        #expect(player.playCount == 0)
        service.resume()
        var events: [NarrationEvent] = []
        while let event = await iterator.next() { events.append(event) }
        #expect(events.contains(.started(verseNumber: 5)))
        #expect(events.last == .completed)
        #expect(player.rates == [1.5])
        service.setVoice(NarrationVoice(company: .openAI, identifier: "cedar"))
        #expect(player.playCount == 1)
    }

    @Test func cachedVersesDoNotAnnounceBufferingAtEveryBoundary() async throws {
        let player = TestAudioPlayer()
        let cache = try NarrationAudioCache(queue: DatabaseQueue())
        let verses: [NarrationVerseUtterance] = [.init(verseNumber: 1, text: "One"), .init(verseNumber: 2, text: "Two")]
        for verse in verses {
            try await cache.save(Data([1, 2, 3]), for: NarrationAudioCache.key(text: verse.text, voice: .marin))
        }
        let service = OpenAINarrationService(generator: UnexpectedSpeech(), player: player, cache: cache) { "test-key" }
        let stream = service.startSpeaking(verses, rate: 1, voice: .marin)
        var events: [NarrationEvent] = []
        for await event in stream { events.append(event) }
        #expect(events == [
            .started(verseNumber: 1), .finishedVerse(verseNumber: 1),
            .started(verseNumber: 2), .finishedVerse(verseNumber: 2), .completed,
        ])
        #expect(player.playCount == 2)
    }

    @Test func slowLookAheadAnnouncesBufferingBeforeWaitingAndCanPause() async throws {
        let generator = GatedSpeech()
        let player = ControlledAudioPlayer()
        let cache = try NarrationAudioCache(queue: DatabaseQueue())
        try await cache.save(Data([1]), for: NarrationAudioCache.key(text: "One", voice: .marin))
        let service = OpenAINarrationService(generator: generator, player: player, cache: cache) { "test-key" }
        var events = service.startSpeaking([.init(verseNumber: 1, text: "One"), .init(verseNumber: 2, text: "Two")], rate: 1, voice: .marin).makeAsyncIterator()
        #expect(await events.next() == .started(verseNumber: 1))
        await generator.waitUntilStarted()
        player.finishClip()
        #expect(await events.next() == .finishedVerse(verseNumber: 1))
        #expect(await events.next() == .preparing(verseNumber: 2))
        service.pause()
        #expect(await events.next() == .paused)
        await generator.complete()
        await service._waitUntilReadyWhilePaused()
        #expect(player.playCount == 1)
        service.resume()
        #expect(await events.next() == .preparing(verseNumber: 2))
        #expect(await events.next() == .started(verseNumber: 2))
        player.finishClip()
        #expect(await events.next() == .finishedVerse(verseNumber: 2))
        #expect(await events.next() == .completed)
        #expect(await events.next() == nil)
        #expect(player.playCount == 2)
    }

    @Test func longVerseReturnsToSpeakingAfterBufferingAnotherSegment() async throws {
        let generator = GatedSpeech()
        let player = ControlledAudioPlayer()
        let cache = try NarrationAudioCache(queue: DatabaseQueue())
        let text = String(repeating: "x", count: 1601)
        let firstSegment = try #require(OpenAINarrationService.segments(text).first)
        try await cache.save(Data([1]), for: NarrationAudioCache.key(text: firstSegment, voice: .marin))
        let service = OpenAINarrationService(generator: generator, player: player, cache: cache) { "test-key" }
        var events = service.startSpeaking([.init(verseNumber: 5, text: text)], rate: 1, voice: .marin).makeAsyncIterator()
        #expect(await events.next() == .started(verseNumber: 5))
        player.finishClip()
        #expect(await events.next() == .preparing(verseNumber: 5))
        await generator.waitUntilStarted()
        await generator.complete()
        #expect(await events.next() == .resumed)
        player.finishClip()
        #expect(await events.next() == .finishedVerse(verseNumber: 5))
        #expect(await events.next() == .completed)
        #expect(await events.next() == nil)
    }

    @Test func explicitAppleFallbackResumesFailedVerseAndRetainsSavedPreference() async throws {
        let fixture = try SettingsFixture()
        try await fixture.settings.configure(credential: fixture.source, enabled: true, useThisKey: true, expecting: 0)
        let apple = FakeNarrationService()
        let cloud = FakeNarrationService()
        let controller = NarrationController(service: apple, cloudService: cloud, settings: fixture.settings)
        controller.voice = .marin
        let queue: [NarrationVerseUtterance] = [.init(verseNumber: 1, text: "One"), .init(verseNumber: 2, text: "Two")]
        controller.start(utterances: queue)
        controller._simulateEvent(.preparing(verseNumber: 2))
        controller._simulateEvent(.failed(.speech(.unavailable)))
        controller.useAppleVoice()
        #expect(apple.lastStartArgs?.startingAt == 1)
        #expect(controller.voice?.company == .apple)
        controller.start(utterances: queue)
        #expect(controller.voice == .marin)
        #expect(cloud.startCallCount == 2)
    }

    @Test func capturePreemptsPlaybackAndBlocksRestart() {
        let audio = AudioActivity()
        let fake = FakeNarrationService()
        let controller = NarrationController(service: fake, audioActivity: audio)
        controller.start(utterances: [.init(verseNumber: 1, text: "One")])
        audio.beginCapture()
        #expect(controller.state == .idle)
        #expect(fake.stopCallCount == 1)
        controller.start(utterances: [.init(verseNumber: 1, text: "One")])
        #expect(controller.lastError == .preemptedByVoiceInput)
        #expect(fake.startCallCount == 1)
    }
}

@MainActor
private struct SettingsFixture {
    let repository: GRDBNarrationSettingsRepository
    let keychain = InMemoryKeychainClient(initial: ["chat-ref": "test-key"])
    let source = ProviderAudioCredential(id: "chat", name: "OpenAI Chat", keyRef: "chat-ref")
    let settings: NarrationSettingsController
    init() throws {
        repository = GRDBNarrationSettingsRepository(database: try BibleDatabase.makeInMemory())
        let source = source
        settings = NarrationSettingsController(repository: repository, keychain: keychain, listSources: { [source] }, clock: FixedClock(), ids: DeterministicIDGenerator())
    }
    func makeController() -> NarrationSettingsController {
        let source = source
        return NarrationSettingsController(repository: repository, keychain: keychain, listSources: { [source] })
    }
}

private actor GatedSpeech: SpeechGenerating {
    private var started = false
    private var entry: CheckedContinuation<Void, Never>?
    private var result: CheckedContinuation<Data, Never>?
    func generate(text: String, voice: OpenAISpeechVoice, apiKey: String) async throws -> Data {
        started = true
        entry?.resume(); entry = nil
        return await withCheckedContinuation { result = $0 }
    }
    func waitUntilStarted() async { if !started { await withCheckedContinuation { entry = $0 } } }
    func complete() { result?.resume(returning: Data([1, 2, 3])); result = nil }
}

private struct UnexpectedSpeech: SpeechGenerating {
    func generate(text: String, voice: OpenAISpeechVoice, apiKey: String) async throws -> Data {
        fatalError("Cached narration must not request speech.")
    }
}

@MainActor
private final class TestAudioPlayer: NarrationAudioPlaying {
    var playCount = 0
    var rates: [Float] = []
    func play(_ audio: Data, rate: Float) -> AsyncStream<NarrationAudioEvent> {
        playCount += 1; rates.append(rate)
        return AsyncStream { $0.yield(.started); $0.yield(.finished); $0.finish() }
    }
    func pause() {}
    func resume() {}
    func stop() {}
    func setRate(_ rate: Float) {}
}

@MainActor
private final class ControlledAudioPlayer: NarrationAudioPlaying {
    private var continuation: AsyncStream<NarrationAudioEvent>.Continuation?
    private(set) var playCount = 0

    func play(_ audio: Data, rate: Float) -> AsyncStream<NarrationAudioEvent> {
        precondition(continuation == nil, "Finish the current clip before playing another.")
        playCount += 1
        let (stream, continuation) = AsyncStream<NarrationAudioEvent>.makeStream()
        self.continuation = continuation
        continuation.yield(.started)
        return stream
    }
    func finishClip() {
        precondition(continuation != nil, "No clip is playing.")
        continuation?.yield(.finished)
        continuation?.finish()
        continuation = nil
    }
    func pause() {}
    func resume() {}
    func stop() { continuation?.finish(); continuation = nil }
    func setRate(_ rate: Float) {}
}

private actor InstalledVoiceProbe {
    private(set) var installed = false
    func setInstalled(_ value: Bool) { installed = value }
}

/// Reproduces an unsigned simulator app's rejected Keychain write without touching real credentials.
private struct RejectingNarrationKeychain: KeychainClient {
    func getString(ref: String) async throws -> String? { nil }
    func setString(_ value: String, ref: String) async throws {
        throw KeychainError.unhandledStatus(-34018)
    }
    func delete(ref: String) async throws { fatalError("A failed Keychain write must not delete any key.") }
}
