import Core
import Foundation

/// An ordered speculative queue sharing paid requests with foreground playback.
/// Bookkeeping stays on the playback actor; generation and cache I/O are asynchronous.
@MainActor
final class NarrationPrefetchQueue {
    struct Request: Sendable {
        let text: String
        let voice: OpenAISpeechVoice
        var key: String { NarrationAudioCache.key(text: text, voice: voice) }
    }

    typealias Download = Task<Result<Data, Error>, Never>
    private struct Entry {
        let token: Int
        let task: Download
    }

    private let generator: any SpeechGenerating
    private let cache: any NarrationAudioCaching
    private let credential: @MainActor @Sendable () async throws -> String
    private var entries: [String: Entry] = [:]
    private var pending: [Request] = []
    private var active: (key: String, token: Int)?
    private var nextToken = 0
    private var paused = false

    init(generator: any SpeechGenerating, cache: any NarrationAudioCaching,
         credential: @escaping @MainActor @Sendable () async throws -> String) {
        self.generator = generator
        self.cache = cache
        self.credential = credential
    }

    /// A demand joins matching work, or bypasses pending speculation to start immediately.
    func audio(for request: Request) async throws -> Data {
        pending.removeAll { $0.key == request.key }
        if let entry = entries[request.key] {
            let result = await entry.task.value
            try Task.checkCancellation()
            if case .success(let audio) = result { return audio }
            // Only an explicit foreground demand retries a failed speculative download.
            if entries[request.key]?.token == entry.token { entries[request.key] = nil }
        }
        try Task.checkCancellation()
        let entry = start(request, speculative: false)
        let result = await entry.task.value
        try Task.checkCancellation()
        return try result.get()
    }

    /// Replaces pending work in reading order, retaining results needed by the current window.
    func prefetch(_ requests: [Request], retaining keys: Set<String>) {
        retain(keys)
        var seen: Set<String> = []
        pending = requests.filter { entries[$0.key] == nil && seen.insert($0.key).inserted }
        advance()
    }

    func retain(_ keys: Set<String>) {
        for key in entries.keys where !keys.contains(key) {
            entries.removeValue(forKey: key)?.task.cancel()
        }
        pending.removeAll { !keys.contains($0.key) }
        if let active, !keys.contains(active.key) { self.active = nil }
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        if !paused { advance() }
    }

    func cancel() {
        pending.removeAll()
        active = nil
        for entry in entries.values { entry.task.cancel() }
        entries.removeAll()
    }

    private func advance() {
        guard !paused, active == nil else { return }
        while !pending.isEmpty {
            let request = pending.removeFirst()
            guard entries[request.key] == nil else { continue }
            let entry = start(request, speculative: true)
            active = (request.key, entry.token)
            return
        }
    }

    private func start(_ request: Request, speculative: Bool) -> Entry {
        nextToken += 1
        let token = nextToken
        let task = Task(priority: speculative ? .utility : .userInitiated) { [generator, cache, credential, weak self] in
            let result: Result<Data, Error>
            do {
                result = .success(try await Self.download(request, generator: generator, cache: cache, credential: credential))
            } catch { result = .failure(error) }
            if self?.active?.token == token {
                self?.active = nil
                self?.advance()
            }
            return result
        }
        let entry = Entry(token: token, task: task)
        entries[request.key] = entry
        return entry
    }

    /// Nonisolated work keeps hashing, transport, and storage off playback's UI executor.
    private nonisolated static func download(
        _ request: Request, generator: any SpeechGenerating, cache: any NarrationAudioCaching,
        credential: @MainActor @Sendable () async throws -> String
    ) async throws -> Data {
        try Task.checkCancellation()
        let secret = try await credential()
        try Task.checkCancellation()
        if let audio = try? await cache.audio(for: request.key) {
            try Task.checkCancellation()
            return audio
        }
        try Task.checkCancellation()
        let audio = try await generator.generate(text: request.text, voice: request.voice, apiKey: secret)
        try Task.checkCancellation()
        try? await cache.save(audio, for: request.key)
        try Task.checkCancellation()
        return audio
    }

    func download(for key: String) -> Download? { entries[key]?.task }

    /// Drain the current speculative window without scheduler polling.
    func waitForPendingDownloads() async {
        while let active, let task = entries[active.key]?.task { _ = await task.value }
    }
}
