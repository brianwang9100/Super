import AVFoundation
import Foundation
import os

/// Queues one verse at a time; didFinish queues the next so downloaded voices
/// cannot reorder or drop a chapter-sized batch. Acquires playback/spokenAudio
/// with duckOthers and restores the previous audio category on teardown.
public final class AVSpeechSynthesizerNarrationService: NSObject, NarrationService, @unchecked Sendable {
    private let synth: any SpeechSynthesizing
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private weak var coordinator: (any NarrationAudioCoordinator)?

    // Group state so multi-field transitions share one lock acquisition.
    private struct State {
        var continuation: AsyncStream<NarrationEvent>.Continuation?
        var utteranceVerse: [ObjectIdentifier: UtteranceEntry] = [:]
        var pendingUtterances: [NarrationVerseUtterance] = []
        var currentIndex: Int = 0
        var currentRate: Float = AVSpeechUtteranceDefaultSpeechRate
        var currentVoice: AVSpeechSynthesisVoice?
        /// Retained even when AVSpeech cannot pause a preparing utterance yet.
        /// Requeues preserve the user's intent; Resume or teardown clears it.
        var pauseRequested = false
        // Increment on start and requeue. Versioned entries reject stale callbacks,
        // including cancellations arriving between clearing the old queue and inserting the new verse.
        var sessionVersion: Int = 0
        var didEmitTerminal: Bool = false
        var activeUtterance: UtteranceIdentity? {
            guard continuation != nil, let (key, entry) = utteranceVerse.first,
                  entry.sessionVersion == sessionVersion else { return nil }
            return UtteranceIdentity(key: key, version: sessionVersion)
        }
        #if os(iOS)
        var savedSessionCategory: AVAudioSession.Category?
        var savedSessionMode: AVAudioSession.Mode?
        var savedSessionOptions: AVAudioSession.CategoryOptions = []
        #endif
    }

    private struct UtteranceEntry {
        let verseNumber: Int
        let sessionVersion: Int
        /// Actual delegate acknowledgement, separate from requested pause intent.
        var isPaused = false
    }

    private struct UtteranceIdentity: Sendable {
        let key: ObjectIdentifier
        let version: Int
    }

    public convenience init(coordinator: (any NarrationAudioCoordinator)? = nil) {
        self.init(coordinator: coordinator, synthesizer: AVSpeechSynthesizer())
    }

    init(coordinator: (any NarrationAudioCoordinator)?, synthesizer: any SpeechSynthesizing) {
        self.coordinator = coordinator
        self.synth = synthesizer
        super.init()
        synth.delegate = self
        #if os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        #endif
    }

    deinit {
        #if os(iOS)
        NotificationCenter.default.removeObserver(self)
        #endif
    }

    // MARK: NarrationService

    nonisolated public func isAvailable() -> Bool {
        !AVSpeechSynthesisVoice.speechVoices().isEmpty
    }

    /// Prefer Premium over Enhanced voices in the locale's language. When
    /// only Compact voices are installed, leave playback on the system default.
    public func bestAvailableVoice(locale: Locale) -> NarrationVoice? {
        Self.installedVoice(locale: locale)
    }

    /// Queries downloaded Apple voices without constructing a speech synthesizer.
    public static func installedVoice(locale: Locale = .current) -> NarrationVoice? {
        let prefix = locale.language.languageCode?.identifier ?? "en"
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
        return (candidates.first { $0.quality == .premium }
            ?? candidates.first { $0.quality == .enhanced }).map(NarrationVoice.init)
    }

    nonisolated public func startSpeaking(
        _ utterances: [NarrationVerseUtterance],
        rate: Float,
        voice: NarrationVoice?,
        startingAt: Int = 0
    ) -> AsyncStream<NarrationEvent> {
        teardownActiveSession(emit: .cancelled)
        synth.stopSpeaking(at: .immediate)

        return AsyncStream { continuation in
            // Voice input owns audio priority.
            if coordinator?.isVoiceInputActive() == true {
                continuation.yield(.failed(.preemptedByVoiceInput))
                continuation.finish()
                return
            }

            do {
                try acquireAudioSession()
            } catch {
                // Acquisition may change category before throwing, before onTermination exists.
                // Restore explicitly so failed startup cannot strand the audio session.
                releaseAudioSession()
                continuation.yield(.failed(.audioSessionFailed(error.localizedDescription)))
                continuation.finish()
                return
            }

            let version = lock.withLock { state -> Int in
                state.continuation = continuation
                state.pendingUtterances = utterances
                state.currentIndex = startingAt
                state.currentRate = rate
                state.currentVoice = voice?.appleVoice
                state.sessionVersion += 1
                state.utteranceVerse.removeAll(keepingCapacity: true)
                state.didEmitTerminal = false
                state.pauseRequested = false
                return state.sessionVersion
            }
            continuation.onTermination = { [weak self] _ in
                self?.releaseAudioSession()
            }
            speakVerse(at: startingAt, expectedVersion: version)
        }
    }

    nonisolated public func pause() {
        requestPause()
    }

    nonisolated public func resume() {
        let identity = lock.withLock { state -> UtteranceIdentity? in
            guard state.continuation != nil else { return nil }
            state.pauseRequested = false
            return state.activeUtterance
        }
        if let identity { applyPlaybackIntent(paused: false, to: identity) }
    }

    private func requestPause(expectedVersion: Int? = nil) {
        let identity = lock.withLock { state -> UtteranceIdentity? in
            guard state.continuation != nil,
                  expectedVersion == nil || state.sessionVersion == expectedVersion else { return nil }
            state.pauseRequested = true
            return state.activeUtterance
        }
        if let identity { applyPlaybackIntent(paused: true, to: identity, boundary: .word) }
    }

    /// A delegate correction applies only to the utterance that produced it.
    /// Recheck after leaving the callback's lock pass, then call AVSpeech outside
    /// the lock because it may synchronously acknowledge the request.
    private func applyPlaybackIntent(
        paused: Bool,
        to identity: UtteranceIdentity,
        boundary: AVSpeechBoundary = .immediate
    ) {
        let shouldApply = lock.withLock { state in
            state.continuation != nil && state.pauseRequested == paused
                && state.sessionVersion == identity.version
                && state.utteranceVerse[identity.key]?.sessionVersion == identity.version
        }
        guard shouldApply else { return }
        if paused {
            synth.pauseSpeaking(at: boundary)
        } else if !synth.continueSpeaking() {
            failRefusedContinuation(for: identity)
        }
    }

    private func failRefusedContinuation(for identity: UtteranceIdentity) {
        let failure = lock.withLock { state -> (AsyncStream<NarrationEvent>.Continuation, Int)? in
            // Preparation-time Resume may only withdraw an unacknowledged pause.
            // Recheck after AVSpeech returns so synchronous acknowledgements,
            // newer intent, and replacement sessions supersede this refusal.
            guard state.sessionVersion == identity.version,
                  let entry = state.utteranceVerse[identity.key],
                  entry.sessionVersion == identity.version, entry.isPaused,
                  !state.pauseRequested, !state.didEmitTerminal,
                  let continuation = state.continuation else { return nil }
            state.didEmitTerminal = true
            state.continuation = nil
            state.pauseRequested = false
            return (continuation, entry.verseNumber)
        }
        guard let (continuation, verseNumber) = failure else { return }
        synth.stopSpeaking(at: .immediate)
        continuation.yield(.failed(.unavailable, verseNumber: verseNumber))
        continuation.finish()
    }

    nonisolated public func stop() {
        teardownActiveSession(emit: .cancelled)
        synth.stopSpeaking(at: .immediate)
    }

    nonisolated public func skipForward() {
        let nextIndex = lock.withLock { state -> Int? in
            let candidate = state.currentIndex + 1
            return candidate < state.pendingUtterances.count ? candidate : nil
        }
        if let nextIndex {
            requeue(from: nextIndex)
        } else {
            teardownActiveSession(emit: .completed)
            synth.stopSpeaking(at: .immediate)
        }
    }

    nonisolated public func skipBackward() {
        let restartIndex = lock.withLock { state in state.currentIndex }
        requeue(from: restartIndex)
    }

    nonisolated public func skipToPreviousVerse() {
        let targetIndex: Int? = lock.withLock { state in
            guard state.currentIndex > 0 else { return nil }
            return state.currentIndex - 1
        }
        guard let targetIndex else { return }
        requeue(from: targetIndex)
    }

    nonisolated public func setRate(_ rate: Float) {
        // Capture position and liveness atomically with the new rate so start/stop cannot interleave.
        let (restartIndex, live): (Int, Bool) = lock.withLock { state in
            state.currentRate = rate
            return (state.currentIndex, state.continuation != nil)
        }
        if live {
            requeue(from: restartIndex)
        }
    }

    nonisolated public func setVoice(_ voice: NarrationVoice?) {
        // Atomically capture position and liveness; restart now so voice changes do not wait for a verse boundary.
        let (restartIndex, live): (Int, Bool) = lock.withLock { state in
            state.currentVoice = voice?.appleVoice
            return (state.currentIndex, state.continuation != nil)
        }
        if live {
            requeue(from: restartIndex)
        }
    }

    // MARK: Queue management

    /// Bump the version and clear entries before stopping the synth, so stale cancel/finish
    /// callbacks cannot terminate or advance the replacement session.
    private func requeue(from index: Int) {
        let version = lock.withLock { state -> Int in
            state.sessionVersion += 1
            state.currentIndex = index
            state.utteranceVerse.removeAll(keepingCapacity: true)
            return state.sessionVersion
        }
        synth.stopSpeaking(at: .immediate)
        speakVerse(at: index, expectedVersion: version)
    }

    /// Queue only this verse. A chapter-sized batch can reorder or lose verses when an
    /// Enhanced/Premium voice finishes downloading mid-queue.
    /// Check expectedVersion in both lock passes: requeue may supersede this advance
    /// while the utterance is built. An unregistered stale utterance's callbacks are dropped.
    private func speakVerse(at index: Int, expectedVersion: Int) {
        // Build the non-Sendable utterance outside the lock from the captured state.
        let prepared: (
            text: String, preDelay: TimeInterval, verseNumber: Int,
            rate: Float, voice: AVSpeechSynthesisVoice?
        )? = lock.withLock { state in
            guard state.sessionVersion == expectedVersion,
                  index < state.pendingUtterances.count else { return nil }
            let verse = state.pendingUtterances[index]
            return (verse.text, verse.preDelay, verse.verseNumber, state.currentRate, state.currentVoice)
        }
        guard let prepared else { return }
        let utterance = AVSpeechUtterance(string: prepared.text)
        utterance.rate = Self.absoluteRate(forMultiple: prepared.rate)
        utterance.preUtteranceDelay = prepared.preDelay
        if let voice = prepared.voice {
            utterance.voice = voice
        }
        // Capture the Sendable identity, then recheck version in case construction raced requeue.
        let key = ObjectIdentifier(utterance)
        let shouldSpeak = lock.withLock { state -> Bool in
            guard state.sessionVersion == expectedVersion else { return false }
            state.utteranceVerse[key] = UtteranceEntry(
                verseNumber: prepared.verseNumber,
                sessionVersion: expectedVersion
            )
            return true
        }
        guard shouldSpeak else { return }
        synth.speak(utterance)
    }

    // MARK: Rate mapping

    /// AVSpeech rate is nonlinear in perceived speed. The empirically calibrated 0.15
    /// slope maps displayed multiples to its absolute scale; clamp to platform bounds.
    static func absoluteRate(forMultiple multiple: Float) -> Float {
        let scale: Float = 0.15
        let raw = AVSpeechUtteranceDefaultSpeechRate + (multiple - 1.0) * scale
        return max(AVSpeechUtteranceMinimumSpeechRate,
                   min(AVSpeechUtteranceMaximumSpeechRate, raw))
    }

    // MARK: Audio session

    private func acquireAudioSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        lock.withLock { state in
            state.savedSessionCategory = session.category
            state.savedSessionMode = session.mode
            state.savedSessionOptions = session.categoryOptions
        }
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true, options: [])
        #endif
    }

    private func releaseAudioSession() {
        #if os(iOS)
        let (cat, mode, options) = lock.withLock { state -> (
            AVAudioSession.Category?, AVAudioSession.Mode?, AVAudioSession.CategoryOptions
        ) in
            (state.savedSessionCategory, state.savedSessionMode, state.savedSessionOptions)
        }
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        if let cat, let mode {
            try? session.setCategory(cat, mode: mode, options: options)
        }
        #endif
    }

    // MARK: Teardown

    private func teardownActiveSession(emit terminal: NarrationEvent) {
        let continuation: AsyncStream<NarrationEvent>.Continuation? = lock.withLock { state in
            guard let continuation = state.continuation, !state.didEmitTerminal else {
                return nil
            }
            state.didEmitTerminal = true
            state.continuation = nil
            state.pauseRequested = false
            return continuation
        }
        continuation?.yield(terminal)
        continuation?.finish()
    }

    // MARK: Interruption

    /// Capture the session before the actor hop; returning its task also lets
    /// tests drain a delayed interruption without posting global notifications.
    @discardableResult
    func pauseForAudioInterruption() -> Task<Void, Never>? {
        guard let version = lock.withLock({ state in
            state.continuation == nil ? nil : state.sessionVersion
        }) else { return nil }
        return Task { @MainActor [weak self] in
            self?.requestPause(expectedVersion: version)
        }
    }

    #if os(iOS)
    @objc private func handleAudioInterruption(_ note: Notification) {
        guard
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        // Interruptions pause without automatically resuming; playback requires a user action.
        guard type == .began else { return }
        // Notifications may arrive on an arbitrary thread; funnel synthesizer access through the main actor.
        pauseForAudioInterruption()
    }
    #endif
}

// MARK: AVSpeechSynthesizerDelegate

extension AVSpeechSynthesizerNarrationService: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        let key = ObjectIdentifier(utterance)
        let started = lock.withLock { state -> (Int, AsyncStream<NarrationEvent>.Continuation, UtteranceIdentity)? in
            // currentIndex was set at enqueue. Drop stale callbacks to avoid phantom starts.
            guard let entry = state.utteranceVerse[key],
                  entry.sessionVersion == state.sessionVersion,
                  let continuation = state.continuation else {
                return nil
            }
            return (entry.verseNumber, continuation, UtteranceIdentity(key: key, version: entry.sessionVersion))
        }
        guard let (verseNumber, continuation, identity) = started else { return }
        continuation.yield(.started(verseNumber: verseNumber))
        // A preparation-time pause can be refused. Retain it until AVSpeech
        // actually starts, and publish start before any synchronous pause ack.
        applyPlaybackIntent(paused: true, to: identity)
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let key = ObjectIdentifier(utterance)
        // One queued verse makes currentIndex authoritative. Carry the captured session
        // version so requeue can supersede this advance before the next verse is registered.
        enum Advance { case speak(index: Int, version: Int); case complete }
        let outcome: (
            verseNumber: Int,
            continuation: AsyncStream<NarrationEvent>.Continuation,
            next: Advance
        )? = lock.withLock { state in
            guard let entry = state.utteranceVerse.removeValue(forKey: key) else {
                return nil
            }
            guard entry.sessionVersion == state.sessionVersion,
                  let continuation = state.continuation else {
                return nil
            }
            let nextIndex = state.currentIndex + 1
            if nextIndex < state.pendingUtterances.count {
                state.currentIndex = nextIndex
                return (entry.verseNumber, continuation, .speak(index: nextIndex, version: state.sessionVersion))
            }
            return (entry.verseNumber, continuation, .complete)
        }
        guard let outcome else { return }
        outcome.continuation.yield(.finishedVerse(verseNumber: outcome.verseNumber))
        switch outcome.next {
        case .speak(let index, let version):
            speakVerse(at: index, expectedVersion: version)
        case .complete:
            teardownActiveSession(emit: .completed)
        }
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didPause utterance: AVSpeechUtterance
    ) {
        acknowledgePlayback(paused: true, utterance: utterance)
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didContinue utterance: AVSpeechUtterance
    ) {
        acknowledgePlayback(paused: false, utterance: utterance)
    }

    private func acknowledgePlayback(paused: Bool, utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        let acknowledgement = lock.withLock { state -> (AsyncStream<NarrationEvent>.Continuation, UtteranceIdentity, Bool)? in
            guard let entry = state.utteranceVerse[key],
                  entry.sessionVersion == state.sessionVersion,
                  let continuation = state.continuation else { return nil }
            state.utteranceVerse[key]?.isPaused = paused
            return (continuation, UtteranceIdentity(key: key, version: entry.sessionVersion), state.pauseRequested)
        }
        guard let (continuation, identity, pauseRequested) = acknowledgement else { return }
        if paused == pauseRequested {
            continuation.yield(paused ? .paused : .resumed)
        } else {
            // A newer explicit request superseded this acknowledgement. Do not
            // record new intent, and do not let an old utterance control a new one.
            applyPlaybackIntent(paused: pauseRequested, to: identity)
        }
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        // A matching cancellation is external: explicit stop/start already emitted terminal,
        // while requeue cleared entries and bumped the version before stopping the old utterance.
        let key = ObjectIdentifier(utterance)
        let shouldEmit = lock.withLock { state -> Bool in
            guard let entry = state.utteranceVerse.removeValue(forKey: key) else {
                return false
            }
            guard entry.sessionVersion == state.sessionVersion else {
                return false
            }
            return state.utteranceVerse.isEmpty
                && state.continuation != nil
                && !state.didEmitTerminal
        }
        if shouldEmit {
            teardownActiveSession(emit: .cancelled)
        }
    }
}

// MARK: Synthesizer seam

// Tests deliver synchronous delegate callbacks without real-time speech or audio hardware.
protocol SpeechSynthesizing: AnyObject {
    var delegate: AVSpeechSynthesizerDelegate? { get set }
    func speak(_ utterance: AVSpeechUtterance)
    @discardableResult func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
    @discardableResult func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool
    @discardableResult func continueSpeaking() -> Bool
}

extension AVSpeechSynthesizer: SpeechSynthesizing {}
