import Core
import Foundation

/// Downloaded verse narration with cancellation-safe generations and one-verse look-ahead.
@MainActor public final class OpenAINarrationService: NarrationService {
    private let generator: any SpeechGenerating
    private let player: any NarrationAudioPlaying
    private let cache: any NarrationAudioCaching
    private let key: @MainActor () async throws -> String
    private var utterances: [NarrationVerseUtterance] = []
    private var index = 0
    private var voice: OpenAISpeechVoice = .marin
    private var rate: Float = 1
    private var paused = false
    private var isPlaying = false
    private var generation = 0
    private var task: Task<Void, Never>?
    private var prefetch: Task<Void, Never>?
    private var pausedReadyWaiter: CheckedContinuation<Void, Never>?
    private var readyWhilePaused = false
    private var resumeWaiter: CheckedContinuation<Void, Never>?
    private var continuation: AsyncStream<NarrationEvent>.Continuation?

    public init(generator: any SpeechGenerating, player: any NarrationAudioPlaying, cache: any NarrationAudioCaching, key: @escaping @MainActor () async throws -> String) {
        self.generator = generator
        self.player = player
        self.cache = cache
        self.key = key
    }
    public func isAvailable() -> Bool { true }
    nonisolated public func bestAvailableVoice(locale: Locale) -> NarrationVoice? { .openAI(.marin) }
    public func startSpeaking(_ utterances: [NarrationVerseUtterance], rate: Float, voice: NarrationVoice?, startingAt: Int = 0) -> AsyncStream<NarrationEvent> {
        stop()
        self.utterances = utterances
        self.index = max(0, startingAt)
        self.rate = rate
        self.voice = voice?.openAI ?? .marin
        self.paused = false
        let (stream, continuation) = AsyncStream<NarrationEvent>.makeStream()
        self.continuation = continuation
        let session = generation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == session else { return }
                self.stop()
            }
        }
        begin()
        return stream
    }
    public func pause() { guard continuation != nil else { return }; paused = true; player.pause(); continuation?.yield(.paused) }
    public func resume() {
        guard paused else { return }
        paused = false
        player.resume()
        resumeWaiter?.resume()
        resumeWaiter = nil
        if isPlaying { continuation?.yield(.resumed) } else if index < utterances.count {
            continuation?.yield(.preparing(verseNumber: utterances[index].verseNumber))
        }
    }
    public func stop() {
        invalidate()
        continuation?.yield(.cancelled)
        continuation?.finish()
        continuation = nil
    }
    public func skipForward() { index += 1; restart() }
    public func skipBackward() { restart() }
    public func skipToPreviousVerse() { index = max(0, index - 1); restart() }
    public func setRate(_ rate: Float) { self.rate = rate; player.setRate(rate) }
    public func setVoice(_ voice: NarrationVoice?) {
        guard let new = voice?.openAI, self.voice != new else { return }
        self.voice = new
        if continuation != nil { restart() }
    }
    private func invalidate() {
        generation += 1
        task?.cancel()
        task = nil
        prefetch?.cancel()
        prefetch = nil
        resumeWaiter?.resume()
        resumeWaiter = nil
        player.stop()
        isPlaying = false
    }
    private func restart() { invalidate(); begin() }
    private func begin() {
        guard index < utterances.count else { finish(.completed); return }
        let current = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                while self.index < self.utterances.count {
                    let utterance = self.utterances[self.index]
                    let segments = Self.segments(utterance.text)
                    var started = false
                    for (segmentIndex, text) in segments.enumerated() {
                        let secret = try await self.key()
                        try self.check(current)
                        let cacheKey = NarrationAudioCache.key(text: text, voice: self.voice)
                        var cached = try? await self.cache.audio(for: cacheKey)
                        if cached == nil && !self.paused {
                            self.continuation?.yield(.preparing(verseNumber: utterance.verseNumber))
                        }
                        // Announce a real buffer wait before joining look-ahead; a cache hit
                        // goes straight to playback without flashing a loading state.
                        if segmentIndex == 0, let prefetch = self.prefetch {
                            await prefetch.value
                            try self.check(current)
                            self.prefetch = nil
                            if cached == nil { cached = try? await self.cache.audio(for: cacheKey) }
                        }
                        let bytes: Data
                        if let cached { bytes = cached } else {
                            try self.check(current)
                            bytes = try await self.generator.generate(text: text, voice: self.voice, apiKey: secret)
                            try self.check(current)
                            try? await self.cache.save(bytes, for: cacheKey)
                        }
                        try self.check(current)
                        if self.paused {
                            self.readyWhilePaused = true
                            self.pausedReadyWaiter?.resume()
                            self.pausedReadyWaiter = nil
                            await withCheckedContinuation { self.resumeWaiter = $0 }
                            self.readyWhilePaused = false
                        }
                        try self.check(current)
                        self.isPlaying = true
                        let events = self.player.play(bytes, rate: self.rate)
                        self.prefetchNext(current: current)
                        var finished = false
                        for await event in events {
                            try self.check(current)
                            switch event {
                            case .started:
                                if !started {
                                    started = true
                                    self.continuation?.yield(.started(verseNumber: utterance.verseNumber))
                                } else {
                                    self.continuation?.yield(.resumed)
                                }
                            case .finished: finished = true
                            case .failed:
                                try? await self.cache.remove(cacheKey)
                                throw SpeechGenerationError.invalidAudio
                            }
                        }
                        try self.check(current)
                        self.isPlaying = false
                        guard finished else { throw SpeechGenerationError.invalidAudio }
                    }
                    self.continuation?.yield(.finishedVerse(verseNumber: utterance.verseNumber))
                    self.index += 1
                }
                self.finish(.completed)
            } catch is CancellationError {
                // Replacement/Stop owns the terminal event; stale work is discarded.
            } catch {
                guard current == self.generation else { return }
                self.finish(.failed(.speech(error as? SpeechGenerationError ?? .unavailable)))
            }
        }
    }
    private func prefetchNext(current: Int) {
        guard !paused, prefetch == nil, index + 1 < utterances.count else { return }
        let next = Self.segments(utterances[index + 1].text).first ?? ""
        let voice = voice
        prefetch = Task { [weak self] in
            guard let self else { return }
            do {
                let secret = try await self.key()
                try self.check(current)
                let cacheKey = NarrationAudioCache.key(text: next, voice: voice)
                if (try? await self.cache.audio(for: cacheKey)) != nil { return }
                try self.check(current)
                let data = try await self.generator.generate(text: next, voice: voice, apiKey: secret)
                try self.check(current)
                try await self.cache.save(data, for: cacheKey)
            } catch { /* Foreground playback presents recoverable errors. */ }
        }
    }
    private func check(_ expected: Int) throws {
        try Task.checkCancellation()
        guard expected == generation else { throw CancellationError() }
    }
    private func finish(_ event: NarrationEvent) {
        continuation?.yield(event)
        continuation?.finish()
        continuation = nil
        invalidate()
    }
    /// Conservative byte segmentation preserves every character and prefers word boundaries.
    nonisolated public static func segments(_ text: String, limit: Int = 1_600) -> [String] {
        guard limit > 0 else { return [] }
        var result: [String] = []
        var remaining = text[...]
        while !remaining.isEmpty {
            var end = remaining.startIndex
            var boundary: String.Index?
            var bytes = 0
            while end < remaining.endIndex {
                let next = remaining.index(after: end)
                let size = remaining[end..<next].utf8.count
                if bytes + size > limit { break }
                bytes += size
                if remaining[end].isWhitespace { boundary = next }
                end = next
            }
            if end == remaining.startIndex { end = remaining.index(after: end) }
            if end != remaining.endIndex, let boundary { end = boundary }
            result.append(String(remaining[..<end]))
            remaining = remaining[end...]
        }
        return result
    }
    var _pendingTask: Task<Void, Never>? { task }
    func _waitUntilReadyWhilePaused() async {
        if !readyWhilePaused { await withCheckedContinuation { pausedReadyWaiter = $0 } }
    }
    func _waitForPendingTask() async { await task?.value }
}
