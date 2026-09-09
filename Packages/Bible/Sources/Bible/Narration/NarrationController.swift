import AVFoundation
import Core
import Foundation
import Observation

/// Owns one narration session. Service events drive reader state; terminal events
/// return to idle, and stop() also tears down synchronously.
@Observable
@MainActor
public final class NarrationController {
    public enum State: Equatable, Sendable {
        case idle
        case preparing
        case speaking
        case paused
    }

    public private(set) var state: State = .idle
    public private(set) var currentVerseNumber: Int?
    /// Most recent terminal error; cleared on the next start or stop.
    public private(set) var lastError: NarrationError?
    /// User-facing multiple of normal speech (1.0 = normal), mapped by the service to its native rate.
    public var rate: Float = 1.0 {
        didSet {
            // Re-selecting the same rate must not audibly stop and requeue the current verse.
            guard rate != oldValue else { return }
            activeService.setRate(rate)
        }
    }
    /// Nil selects the system default. Live changes are forwarded immediately to the service.
    public var voice: NarrationVoice? {
        didSet {
            // Re-selecting the same voice must not requeue playback.
            guard voice != oldValue else { return }
            if state != .idle, oldValue?.company != voice?.company {
                let wasPaused = state == .paused
                playback(for: oldValue).stop()
                let index = lastUtterances.firstIndex { $0.verseNumber == (currentVerseNumber ?? recoveryVerseNumber) } ?? 0
                start(utterances: lastUtterances, startingAt: index)
                if wasPaused { pause() }
            } else { activeService.setVoice(voice) }
        }
    }

    /// Fires once when a session reaches idle through a terminal event.
    public var onCompletion: (@MainActor () -> Void)?

    private let service: any NarrationService
    private let cache: (any NarrationAudioCaching)?
    private let cloudService: (any NarrationService)?
    public let settings: NarrationSettingsController?
    private let audioActivity: AudioActivity?
    public var isCaptureActive: Bool { audioActivity?.isCapturing == true }
    private var restorePreferredVoiceOnNextStart = false
    private var recoveryVerseNumber: Int?
    private var lastUtterances: [NarrationVerseUtterance] = []
    private var appliedVoiceId: String?
    private var configurationLoaded = false
    private var activeService: any NarrationService { playback(for: voice) }
    private func playback(for voice: NarrationVoice?) -> any NarrationService {
        voice?.company == .openAI ? (cloudService ?? service) : service
    }
    private var streamTask: Task<Void, Never>?
    private let now: @MainActor () -> Date
    private var lastSkipPreviousAt: Date?

    /// Seconds within which a second back tap jumps to the previous verse.
    public static let skipPreviousDoubleTapWindow: TimeInterval = 1.0

    public init(
        service: any NarrationService,
        cloudService: (any NarrationService)? = nil,
        settings: NarrationSettingsController? = nil,
        cache: (any NarrationAudioCaching)? = nil,
        audioActivity: AudioActivity? = nil,
        now: @MainActor @escaping () -> Date = { Date() }
    ) {
        self.service = service
        self.cloudService = cloudService
        self.cache = cache
        self.settings = settings
        self.audioActivity = audioActivity
        self.now = now
        audioActivity?.stopPlayback = { [weak self] in self?.stop() }
        settings?.onInvalidated = { [weak self] in self?.stop() }
        settings?.onChange = { [weak self] in self?.applyConfiguration() }
    }

    private func applyConfiguration() {
        guard let settings else { return }
        let requested = settings.record.preferredVoiceId.flatMap(NarrationVoice.init(id:))
        let resolved: NarrationVoice?
        if requested?.company == .openAI && !settings.openAIAvailable {
            resolved = settings.record.lastAppleVoiceId.flatMap(NarrationVoice.init(id:)) ?? .appleDefault
        } else { resolved = requested }
        if !configurationLoaded || appliedVoiceId != resolved?.id {
            appliedVoiceId = resolved?.id
            voice = resolved
        }
        if !configurationLoaded { rate = Float(settings.record.rate) }
        configurationLoaded = true
    }

    /// Resolves the initial Apple voice off the main actor without replacing a saved choice.
    public func prepareDefaultVoice() async {
        guard voice == nil else { return }
        let best = await Task.detached { self.bestAvailableVoice() }.value
        if voice == nil { voice = best }
    }

    public func selectVoice(_ choice: NarrationVoice) async {
        restorePreferredVoiceOnNextStart = false
        do {
            try await settings?.setPreference(voice: choice, rate: rate)
            voice = choice
        } catch { settings?.errorMessage = "Voice preference could not be saved. Try again." }
    }

    public func selectRate(_ value: Float) async {
        do {
            try await settings?.setRate(value)
            rate = value
        } catch { settings?.errorMessage = "Playback speed could not be saved. Try again." }
    }

    /// Explicit recovery keeps the saved OpenAI preference for the next user-started session.
    public func useAppleVoice() {
        restorePreferredVoiceOnNextStart = false
        let index = lastUtterances.firstIndex { $0.verseNumber == (currentVerseNumber ?? recoveryVerseNumber) } ?? 0
        stop()
        voice = settings?.record.lastAppleVoiceId.flatMap(NarrationVoice.init(id:)) ?? .appleDefault
        start(utterances: lastUtterances, startingAt: index)
        restorePreferredVoiceOnNextStart = true
    }

    /// Retry the failed verse in the existing queue without replaying the earlier selection.
    public func retry() {
        guard lastError != nil, !lastUtterances.isEmpty else { return }
        let index = lastUtterances.firstIndex { $0.verseNumber == recoveryVerseNumber } ?? 0
        let restoreAfterSession = restorePreferredVoiceOnNextStart
        restorePreferredVoiceOnNextStart = false
        start(utterances: lastUtterances, startingAt: index)
        restorePreferredVoiceOnNextStart = restoreAfterSession
    }

    public func clearCachedAudio() async throws {
        stop()
        try await cache?.clear()
    }

    public func isAvailable() -> Bool { activeService.isAvailable() }

    /// Resolve the initial voice through the injected service. Kept nonisolated
    /// so production's blocking discovery can run off the main actor.
    nonisolated public func bestAvailableVoice(
        locale: Locale = .current
    ) -> NarrationVoice? {
        service.bestAvailableVoice(locale: locale)
    }

    /// Starts a replacement session, cancelling consumption of the old stream first.
    public func start(utterances: [NarrationVerseUtterance], startingAt: Int = 0) {
        if restorePreferredVoiceOnNextStart {
            restorePreferredVoiceOnNextStart = false
            stop()
            if let settings, settings.openAIAvailable {
                voice = settings.record.preferredVoiceId.flatMap(NarrationVoice.init(id:)) ?? .appleDefault
            }
        }
        // The old consumer must check cancellation before handling buffered terminal events,
        // or it can overwrite the replacement session's state.
        streamTask?.cancel()
        streamTask = nil
        lastError = nil

        self.lastUtterances = utterances
        recoveryVerseNumber = utterances.isEmpty ? nil
            : utterances[min(max(0, startingAt), utterances.count - 1)].verseNumber
        guard !isCaptureActive else {
            handle(.failed(.preemptedByVoiceInput))
            return
        }
        guard !utterances.isEmpty else { activeService.stop(); state = .idle; currentVerseNumber = nil; return }
        state = .preparing
        currentVerseNumber = nil
        let stream = activeService.startSpeaking(utterances, rate: rate, voice: voice, startingAt: startingAt)
        streamTask = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                self.handle(event)
            }
        }
    }

    public func pause() {
        guard state == .speaking || state == .preparing else { return }
        activeService.pause()
    }

    public func resume() {
        guard state == .paused else { return }
        activeService.resume()
    }

    /// Stops playback and returns to idle synchronously; also clears failed-session recovery.
    public func stop() {
        // Navigation also stops an already failed session. Its Retry must not revive
        // the old chapter or translation after the reader has changed context.
        lastError = nil
        recoveryVerseNumber = nil
        guard state != .idle else { return }
        activeService.stop()
        streamTask?.cancel()
        streamTask = nil
        handle(.cancelled)
    }

    public func skipNext() {
        guard state != .idle else { return }
        activeService.skipForward()
    }

    /// One tap restarts this verse; a second within skipPreviousDoubleTapWindow jumps back.
    public func skipPrevious() {
        guard state != .idle else { return }
        let timestamp = now()
        if let last = lastSkipPreviousAt,
           timestamp.timeIntervalSince(last) < Self.skipPreviousDoubleTapWindow {
            // Consume the pair so a third quick tap starts a new double-tap intent.
            lastSkipPreviousAt = nil
            activeService.skipToPreviousVerse()
        } else {
            lastSkipPreviousAt = timestamp
            activeService.skipBackward()
        }
    }

    /// Processes an event synchronously for deterministic state-transition tests.
    @MainActor
    func _simulateEvent(_ event: NarrationEvent) {
        handle(event)
    }

    /// Drains the active consumer; returns immediately without one.
    func _waitForPendingStreamTask() async {
        await streamTask?.value
    }

    /// Capture before replacement to await the previous consumer's cancellation.
    var _currentStreamTask: Task<Void, Never>? { streamTask }

    private func handle(_ event: NarrationEvent) {
        switch event {
        case .preparing(let verseNumber):
            recoveryVerseNumber = verseNumber
            if state != .paused { state = .preparing }
        case .started(let verseNumber):
            currentVerseNumber = verseNumber
            recoveryVerseNumber = verseNumber
            state = .speaking
        case .finishedVerse:
            break
        case .paused:
            state = .paused
        case .resumed:
            state = .speaking
        case .completed, .cancelled:
            guard state != .idle else { return }
            currentVerseNumber = nil
            state = .idle
            onCompletion?()
        case .failed(let error, let verseNumber):
            if let verseNumber { recoveryVerseNumber = verseNumber }
            currentVerseNumber = nil
            lastError = error
            state = .idle
            onCompletion?()
        }
    }
}
