import Core
import Foundation

/// Downloaded verse narration with cancellation-safe generations and a bounded verse-prefetch queue.
@MainActor public final class OpenAINarrationService: NarrationService {
    private let downloads: NarrationPrefetchQueue
    private let prefetchVerseCount: @MainActor () -> Int
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
    private var sessionID = 0
    private var pausedReadyWaiter: CheckedContinuation<Void, Never>?
    private var readyWhilePaused = false
    private var resumeWaiter: CheckedContinuation<Void, Never>?
    private var continuation: AsyncStream<NarrationEvent>.Continuation?

    public init(generator: any SpeechGenerating, player: any NarrationAudioPlaying, cache: any NarrationAudioCaching,
                prefetchVerseCount: @escaping @MainActor () -> Int = { 2 },
                key: @escaping @MainActor @Sendable () async throws -> String) {
        self.downloads = NarrationPrefetchQueue(generator: generator, cache: cache, credential: key)
        self.prefetchVerseCount = prefetchVerseCount
        self.player = player
        self.cache = cache
        self.key = key
    }
    public func isAvailable() -> Bool { true }
    nonisolated public func bestAvailableVoice(locale: Locale) -> NarrationVoice? { .marin }
    public func startSpeaking(_ utterances: [NarrationVerseUtterance], rate: Float, voice: NarrationVoice?, startingAt: Int = 0) -> AsyncStream<NarrationEvent> {
        stop()
        self.utterances = utterances
        self.index = max(0, startingAt)
        self.rate = rate
        self.voice = voice?.openAI ?? .marin
        self.paused = false
        downloads.setPaused(false)
        let (stream, continuation) = AsyncStream<NarrationEvent>.makeStream()
        self.continuation = continuation
        let session = sessionID
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.sessionID == session else { return }
                self.stop()
            }
        }
        begin()
        return stream
    }
    public func pause() { guard continuation != nil else { return }; paused = true; downloads.setPaused(true); player.pause(); continuation?.yield(.paused) }
    public func resume() {
        guard paused else { return }
        paused = false
        downloads.setPaused(false)
        player.resume()
        resumeWaiter?.resume()
        resumeWaiter = nil
        if isPlaying { continuation?.yield(.resumed) } else if index < utterances.count {
            continuation?.yield(.preparing(verseNumber: utterances[index].verseNumber))
        }
    }
    public func stop() {
        sessionID += 1
        invalidate()
        continuation?.yield(.cancelled)
        continuation?.finish()
        continuation = nil
    }
    public func skipForward() {
        guard continuation != nil else { return }
        index += 1
        restart(preservingDownloads: true)
    }
    public func skipBackward() {
        guard continuation != nil else { return }
        restart(preservingDownloads: true)
    }
    public func skipToPreviousVerse() {
        guard continuation != nil, index > 0 else { return }
        index -= 1
        restart(preservingDownloads: true)
    }
    public func setRate(_ rate: Float) { self.rate = rate; player.setRate(rate) }
    public func setVoice(_ voice: NarrationVoice?) {
        guard let new = voice?.openAI, self.voice != new else { return }
        self.voice = new
        if continuation != nil { restart() }
    }
    private func invalidate(preservingDownloads: Bool = false) {
        generation += 1
        task?.cancel()
        task = nil
        if preservingDownloads { downloads.retain(windowKeys) } else { downloads.cancel() }
        resumeWaiter?.resume()
        resumeWaiter = nil
        player.stop()
        isPlaying = false
    }
    private func restart(preservingDownloads: Bool = false) { invalidate(preservingDownloads: preservingDownloads); begin() }
    private func begin() {
        guard index < utterances.count else { finish(.completed); return }
        let current = generation
        task = Task { [weak self] in
            guard let self else { return }
            var attemptedVerseNumber: Int?
            do {
                while self.index < self.utterances.count {
                    // Retain only this playback window, including when speculation is off.
                    self.downloads.retain(self.windowKeys)
                    let utterance = self.utterances[self.index]
                    attemptedVerseNumber = utterance.verseNumber
                    let segments = Self.segments(utterance.text)
                    var started = false
                    for (segmentIndex, text) in segments.enumerated() {
                        _ = try await self.key()
                        try self.check(current)
                        let cacheKey = NarrationAudioCache.key(text: text, voice: self.voice)
                        let cached = try? await self.cache.audio(for: cacheKey)
                        try self.check(current)
                        if cached == nil && !self.paused {
                            self.continuation?.yield(.preparing(verseNumber: utterance.verseNumber))
                        }
                        let bytes: Data
                        if let cached { bytes = cached } else {
                            bytes = try await self.downloads.audio(for: .init(text: text, voice: self.voice))
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
                        var finished = false
                        for await event in events {
                            try self.check(current)
                            switch event {
                            case .started:
                                self.prefetchNext(afterSegment: segmentIndex)
                                if !started {
                                    started = true
                                    self.continuation?.yield(.started(verseNumber: utterance.verseNumber))
                                } else {
                                    self.continuation?.yield(.resumed)
                                }
                            case .finished: finished = true
                            case .interrupted:
                                self.finish(.cancelled)
                                return
                            case .unavailable:
                                self.finish(.failed(
                                    .audioSessionFailed("Audio playback is unavailable."),
                                    verseNumber: utterance.verseNumber
                                ))
                                return
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
                self.finish(.failed(
                    .speech(error as? SpeechGenerationError ?? .unavailable),
                    verseNumber: attemptedVerseNumber
                ))
            }
        }
    }
    private var lookAheadCount: Int { min(10, max(0, prefetchVerseCount())) }
    private var windowKeys: Set<String> {
        guard utterances.indices.contains(index) else { return [] }
        let end = min(utterances.count, index + lookAheadCount + 1)
        return Set(utterances[index..<end].flatMap { Self.segments($0.text) }.map {
            NarrationAudioCache.key(text: $0, voice: voice)
        })
    }
    private func prefetchNext(afterSegment segment: Int) {
        guard lookAheadCount > 0, utterances.indices.contains(index) else { return }
        let end = min(utterances.count, index + lookAheadCount + 1)
        let current = Array(Self.segments(utterances[index].text).dropFirst(segment + 1))
        let following = utterances[(index + 1)..<end].flatMap { Self.segments($0.text) }
        downloads.prefetch((current + following).map { .init(text: $0, voice: voice) }, retaining: windowKeys)
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
    var _pendingPrefetch: NarrationPrefetchQueue.Download? {
        guard utterances.indices.contains(index + 1),
              let text = Self.segments(utterances[index + 1].text).first else { return nil }
        return downloads.download(for: NarrationAudioCache.key(text: text, voice: voice))
    }
    func _waitForPrefetch() async { await downloads.waitForPendingDownloads() }
    func _waitUntilReadyWhilePaused() async {
        if !readyWhilePaused { await withCheckedContinuation { pausedReadyWaiter = $0 } }
    }
    func _waitForPendingTask() async { await task?.value }
}
