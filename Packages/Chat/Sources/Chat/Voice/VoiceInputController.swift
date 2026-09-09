import Core
import Foundation

/// One ordered voice update. Consumers append `appendedText` to their own draft
/// and render `preview` separately. State, append, and preview change atomically.
public struct VoiceInputUpdate: Sendable, Equatable {
    /// Monotonic delivery revision, including updates across recording sessions.
    public let revision: Int
    /// New completed phrase only; never an accumulated transcript or replacement.
    public let appendedText: String
    /// Revisable current utterance, separate from previously completed phrases.
    public let preview: String
    /// State after this update's phrase has been committed.
    public let state: VoiceInputController.State
}

/// Independent microphone component. Owns recognition and capture lifetime and
/// publishes append-only phrases through `updates()`, without knowing composer text.
@Observable
@MainActor
public final class VoiceInputController {
    /// Capture and permission state projected by subscribers into their UI.
    public enum State: Equatable, Sendable {
        case idle
        case listening
        case stopping
        case denied
        case unavailable
        case failed(String)

        /// Keeps recording controls active while captured events finish draining.
        public var isRecording: Bool { self == .listening || self == .stopping }
    }

    /// Immediate capture state; text consumers use the state in their ordered updates.
    public private(set) var state: State = .idle {
        didSet {
            if state == .listening && oldValue != .listening { audioActivity?.beginCapture() }
            if state != .listening && oldValue == .listening { audioActivity?.endCapture() }
        }
    }

    /// Current provisional utterance, excluding all already-published phrases.
    public var partialTranscript: String { accumulator.partialTranscript }

    private let audioActivity: AudioActivity?
    private let service: any VoiceInputService
    private var accumulator = DictationTranscriptAccumulator()
    private var streamTask: Task<Void, Never>?
    private var isStarting = false
    private var generation = 0
    private var startIntent = 0
    private var nextSubscriberID = 0
    private var subscribers: [Int: AsyncStream<VoiceInputUpdate>.Continuation] = [:]
    private(set) var revision = 0

    /// Creates a component with an injectable recognition service and capture gate.
    public init(service: any VoiceInputService, audioActivity: AudioActivity? = nil) {
        self.service = service
        self.audioActivity = audioActivity
        if !service.isAvailable(locale: .current) { state = .unavailable }
    }

    isolated deinit {
        streamTask?.cancel()
        service.stopRecognition()
        if state == .listening { audioActivity?.endCapture() }
        for continuation in subscribers.values { continuation.finish() }
        processedEventSignal?.finish()
    }

    /// Subscribe before starting capture. Unbounded buffering preserves every phrase.
    /// Only state/preview replay on subscription; previous additions never replay.
    /// Cancelling a subscription removes it without affecting another consumer.
    public func updates() -> AsyncStream<VoiceInputUpdate> {
        nextSubscriberID += 1
        let id = nextSubscriberID
        let (stream, continuation) = AsyncStream<VoiceInputUpdate>.makeStream()
        subscribers[id] = continuation
        continuation.yield(update(appending: ""))
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in self?.subscribers[id] = nil }
        }
        return stream
    }

    /// Starts capture, or stops if already listening. Concurrent permission requests
    /// cannot double-start, and a stop invalidates a still-pending permission result.
    public func toggle(locale: Locale = .current) async {
        let intent = startIntent
        if state == .listening {
            stop()
            await streamTask?.value
            return
        }
        if state == .stopping {
            await streamTask?.value
            // Another pending toggle may already have started the next session.
            guard startIntent == intent, !state.isRecording, !Task.isCancelled else { return }
        }
        guard !isStarting else { return }
        if state == .unavailable && !service.isAvailable(locale: locale) { return }
        generation += 1
        let session = generation
        isStarting = true
        defer { if generation == session { isStarting = false } }

        let permission = await service.requestPermissions()
        guard generation == session, startIntent == intent, !Task.isCancelled else { return }
        guard permission == .granted else {
            state = .denied
            publish()
            return
        }
        guard service.isAvailable(locale: locale) else {
            state = .unavailable
            publish()
            return
        }
        accumulator = DictationTranscriptAccumulator()
        state = .listening
        publish()
        startStream(locale: locale, session: session)
    }

    /// Releases capture immediately, then drains already-buffered recognition events.
    /// The stopping state holds Send disabled until the final phrase is delivered.
    public func stop() {
        startIntent += 1
        guard state != .stopping else { return }
        if state == .listening {
            service.stopRecognition()
            state = .stopping
            publish()
        } else {
            // Invalidate pending permissions without discarding queued speech.
            generation += 1
            isStarting = false
        }
    }

    /// Test drain seam for a stop that has released audio but still has buffered events.
    func _waitForPendingStop() async {
        if state == .stopping { await streamTask?.value }
    }

    private func startStream(locale: Locale, session: Int) {
        let stream = service.startRecognition(locale: locale)
        streamTask = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self, !Task.isCancelled, self.generation == session else { return }
                    self.handle(event)
                    self.signalProcessedEvent()
                    if self.generation != session { return }
                }
                guard let self, !Task.isCancelled, self.generation == session else { return }
                self.finish(with: .idle)
                self.signalProcessedEvent()
            } catch {
                guard let self, !Task.isCancelled, self.generation == session else { return }
                self.finish(with: Self.terminalState(for: error))
                self.signalProcessedEvent()
            }
        }
    }

    private func handle(_ event: VoiceInputEvent) {
        switch event {
        case .partial(let text):
            accumulator.ingestPartial(text)
            publish()
        case .utterance(let text):
            publish(appending: accumulator.commitCurrentUtterance(text))
        case .final(let text):
            finish(with: .idle, finalText: text)
        }
    }

    private func finish(with terminalState: State, finalText: String = "") {
        let phrase = accumulator.commitCurrentUtterance(finalText)
        generation += 1
        isStarting = false
        // Explicit service teardown precedes releasing the shared audio gate.
        service.stopRecognition()
        streamTask?.cancel()
        streamTask = nil
        state = terminalState
        publish(appending: phrase)
    }

    private static func terminalState(for error: Error) -> State {
        switch error {
        case VoiceInputError.silenceTimeout, is CancellationError: .idle
        case VoiceInputError.permissionDenied: .denied
        case VoiceInputError.unavailable: .unavailable
        case VoiceInputError.recognizerFailed(let reason), VoiceInputError.audioEngineFailed(let reason): .failed(reason)
        default: .failed(error.localizedDescription)
        }
    }

    private func update(appending text: String) -> VoiceInputUpdate {
        VoiceInputUpdate(revision: revision, appendedText: text, preview: partialTranscript, state: state)
    }

    private func publish(appending text: String = "") {
        revision += 1
        let event = update(appending: text)
        for continuation in subscribers.values { continuation.yield(event) }
    }

    private var processedEventSignal: AsyncStream<Void>.Continuation?

    /// Deterministic test seam: one signal after each handled service event or ending.
    func _observeProcessedEvents() -> AsyncStream<Void> {
        processedEventSignal?.finish()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        processedEventSignal = continuation
        return stream
    }

    private func signalProcessedEvent() { processedEventSignal?.yield(()) }
}
