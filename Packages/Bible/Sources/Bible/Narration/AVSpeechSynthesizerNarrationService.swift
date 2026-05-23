import AVFoundation
import Foundation
import os

/// Production ``NarrationService`` backed by `AVSpeechSynthesizer`.
/// Wraps the synthesizer's delegate callbacks into the
/// `AsyncStream<NarrationEvent>` the controller iterates.
///
/// One session at a time. Each `startSpeaking(_:rate:voice:)` builds a
/// fresh `[AVSpeechUtterance]` and feeds it to a single shared synth;
/// the delegate routes per-utterance start/finish callbacks back into
/// the active continuation. Audio Session: switches to
/// `.playback` / `.spokenAudio` / `.duckOthers` on session start and
/// restores the saved category on tear-down — TTS = text-to-speech.
public final class AVSpeechSynthesizerNarrationService: NSObject, NarrationService, @unchecked Sendable {
    private let synth = AVSpeechSynthesizer()
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private weak var coordinator: (any NarrationAudioCoordinator)?

    /// Mutable state, gated by `lock`. Carried as a flat struct so any
    /// mutation that has to be atomic across multiple fields (e.g.
    /// "requeue under a new sessionVersion") fits in a single
    /// `withLock` closure.
    private struct State {
        var continuation: AsyncStream<NarrationEvent>.Continuation?
        var utteranceVerse: [ObjectIdentifier: UtteranceEntry] = [:]
        var pendingUtterances: [NarrationVerseUtterance] = []
        var currentIndex: Int = 0
        var currentRate: Float = AVSpeechUtteranceDefaultSpeechRate
        var currentVoice: AVSpeechSynthesisVoice?
        /// Session-version counter — incremented on every requeue
        /// (skip, setRate, setVoice, restart) and at session start.
        /// Each utterance entry carries the version it was enqueued
        /// under, and the delegate callbacks gate on a match: a stale
        /// callback (left over from a just-cancelled queue) consumes
        /// its entry silently and does NOT terminate the live session.
        /// This closes the race where `didCancel` fires between
        /// `requeue`'s `removeAll` and the first `enqueue` insert and
        /// would otherwise see an empty map + live continuation, and
        /// spuriously emit `.cancelled`.
        var sessionVersion: Int = 0
        /// Whether the synth was explicitly stopped (`stop()` /
        /// preempted / interruption). On the next `didCancel` we yield
        /// `.cancelled` exactly once.
        var didEmitTerminal: Bool = false
        #if os(iOS)
        var savedSessionCategory: AVAudioSession.Category?
        var savedSessionMode: AVAudioSession.Mode?
        var savedSessionOptions: AVAudioSession.CategoryOptions = []
        #endif
    }

    /// Per-utterance bookkeeping kept on the lock-gated `State`. Pairs
    /// the verse the synth is speaking with the session version it was
    /// enqueued under, so the delegate can distinguish a live callback
    /// from one left over after a `stopSpeaking + requeue` pivot.
    private struct UtteranceEntry {
        let verseNumber: Int
        let sessionVersion: Int
    }

    public init(coordinator: (any NarrationAudioCoordinator)? = nil) {
        self.coordinator = coordinator
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

    public func isAvailable() -> Bool {
        !AVSpeechSynthesisVoice.speechVoices().isEmpty
    }

    public func startSpeaking(
        _ utterances: [NarrationVerseUtterance],
        rate: Float,
        voice: AVSpeechSynthesisVoice?
    ) -> AsyncStream<NarrationEvent> {
        // Close any prior session's continuation so the caller's old
        // stream consumer drops; the synth is stopped synchronously.
        teardownActiveSession(emit: .cancelled)
        synth.stopSpeaking(at: .immediate)

        return AsyncStream { continuation in
            // If the mic currently holds the audio session, refuse —
            // voice input wins ties.
            if coordinator?.isVoiceInputActive() == true {
                continuation.yield(.failed(.preemptedByVoiceInput))
                continuation.finish()
                return
            }

            do {
                try acquireAudioSession()
            } catch {
                // `acquireAudioSession` saves the prior category
                // *before* attempting `setCategory` / `setActive`, so
                // a throw from the second call leaves the session
                // changed but the new continuation never installs an
                // `onTermination` handler — `releaseAudioSession` would
                // never run on its own. Restore explicitly here so a
                // failed startup doesn't strand the session in our
                // category.
                releaseAudioSession()
                continuation.yield(.failed(.audioSessionFailed(error.localizedDescription)))
                continuation.finish()
                return
            }

            lock.withLock { state in
                state.continuation = continuation
                state.pendingUtterances = utterances
                state.currentIndex = 0
                state.currentRate = rate
                state.currentVoice = voice
                state.sessionVersion += 1
                state.utteranceVerse.removeAll(keepingCapacity: true)
                state.didEmitTerminal = false
            }
            continuation.onTermination = { [weak self] _ in
                self?.releaseAudioSession()
            }
            enqueue(from: 0, rate: rate, voice: voice)
        }
    }

    public func pause() {
        synth.pauseSpeaking(at: .word)
    }

    public func resume() {
        _ = synth.continueSpeaking()
    }

    public func stop() {
        teardownActiveSession(emit: .cancelled)
        synth.stopSpeaking(at: .immediate)
    }

    public func skipForward() {
        let nextIndex = lock.withLock { state -> Int? in
            let candidate = state.currentIndex + 1
            return candidate < state.pendingUtterances.count ? candidate : nil
        }
        if let nextIndex {
            synth.stopSpeaking(at: .immediate)
            requeue(from: nextIndex)
        } else {
            // Past the last verse — finish the session as a normal
            // completion.
            teardownActiveSession(emit: .completed)
            synth.stopSpeaking(at: .immediate)
        }
    }

    public func skipBackward() {
        let restartIndex = lock.withLock { state in state.currentIndex }
        synth.stopSpeaking(at: .immediate)
        requeue(from: restartIndex)
    }

    public func skipToPreviousVerse() {
        // Decrement only when there's room; at the first verse this is
        // a no-op so the queue stays put. The controller's double-tap
        // window decides when to fire this vs `skipBackward`.
        let targetIndex: Int? = lock.withLock { state in
            guard state.currentIndex > 0 else { return nil }
            return state.currentIndex - 1
        }
        guard let targetIndex else { return }
        synth.stopSpeaking(at: .immediate)
        requeue(from: targetIndex)
    }

    public func setRate(_ rate: Float) {
        // Read `currentIndex` and `continuation != nil` in the same
        // lock pass that writes the new rate. The prior two-pass form
        // had a narrow window where a concurrent `startSpeaking` or
        // `stop` could slip between acquisitions and either flip
        // `live`'s meaning or shift `currentIndex` out from under us.
        let (restartIndex, live): (Int, Bool) = lock.withLock { state in
            state.currentRate = rate
            return (state.currentIndex, state.continuation != nil)
        }
        if live {
            synth.stopSpeaking(at: .immediate)
            requeue(from: restartIndex)
        }
    }

    public func setVoice(_ voice: AVSpeechSynthesisVoice?) {
        // Single lock pass — same atomicity rationale as `setRate`. The
        // current verse restarts under the new voice; without the
        // requeue, the change would only take effect at the *next*
        // verse boundary, which the user perceives as the picker doing
        // nothing.
        let (restartIndex, live): (Int, Bool) = lock.withLock { state in
            state.currentVoice = voice
            return (state.currentIndex, state.continuation != nil)
        }
        if live {
            synth.stopSpeaking(at: .immediate)
            requeue(from: restartIndex)
        }
    }

    // MARK: Queue management

    /// Build `AVSpeechUtterance`s for the verses at `index..<count` and
    /// feed them to the synth, bumping the session version so stale
    /// callbacks from prior queues fall through.
    private func requeue(from index: Int) {
        let (utterances, rate, voice) = lock.withLock { state -> (
            [NarrationVerseUtterance], Float, AVSpeechSynthesisVoice?
        ) in
            state.sessionVersion += 1
            state.currentIndex = index
            state.utteranceVerse.removeAll(keepingCapacity: true)
            return (state.pendingUtterances, state.currentRate, state.currentVoice)
        }
        enqueue(from: index, in: utterances, rate: rate, voice: voice)
    }

    private func enqueue(
        from index: Int,
        rate: Float,
        voice: AVSpeechSynthesisVoice?
    ) {
        let utterances = lock.withLock { $0.pendingUtterances }
        enqueue(from: index, in: utterances, rate: rate, voice: voice)
    }

    private func enqueue(
        from index: Int,
        in utterances: [NarrationVerseUtterance],
        rate: Float,
        voice: AVSpeechSynthesisVoice?
    ) {
        guard index < utterances.count else { return }
        let absoluteRate = Self.absoluteRate(forMultiple: rate)
        for verse in utterances[index...] {
            let utterance = AVSpeechUtterance(string: verse.text)
            utterance.rate = absoluteRate
            utterance.preUtteranceDelay = verse.preDelay
            if let voice {
                utterance.voice = voice
            }
            let key = ObjectIdentifier(utterance)
            lock.withLock { state in
                state.utteranceVerse[key] = UtteranceEntry(
                    verseNumber: verse.verseNumber,
                    sessionVersion: state.sessionVersion
                )
            }
            synth.speak(utterance)
        }
    }

    // MARK: Rate mapping

    /// Map a user-facing speed multiple (1.0 = normal) onto the
    /// AVSpeech absolute rate scale. AVSpeech's `rate` is not linear in
    /// perceived speed — its `Default` (~0.5) is normal but its
    /// `Maximum` (~1.0) is roughly 6-7× perceived speed.
    ///
    /// Slope calibrated empirically: at scale=0.30 the user reported
    /// "1.25× sounds like 1.5×, 1.5× sounds like 2×" — a 2:1 ratio
    /// between perceived and display. Halving to `0.15` per display
    /// unit puts perceived speed in line with the label, so 2.0×
    /// display lands at absolute 0.650, which is genuinely ~2× faster
    /// than default. Values are clamped to AVSpeech's documented
    /// bounds so an extreme slider doesn't drop below 0 or above 1.
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

    /// Close the active stream with `terminal` exactly once. Subsequent
    /// calls are no-ops, so callbacks landing after `stop()` don't
    /// double-emit.
    private func teardownActiveSession(emit terminal: NarrationEvent) {
        let continuation: AsyncStream<NarrationEvent>.Continuation? = lock.withLock { state in
            guard let continuation = state.continuation, !state.didEmitTerminal else {
                return nil
            }
            state.didEmitTerminal = true
            state.continuation = nil
            return continuation
        }
        continuation?.yield(terminal)
        continuation?.finish()
    }

    // MARK: Interruption

    #if os(iOS)
    @objc private func handleAudioInterruption(_ note: Notification) {
        guard
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        // `.began` → pause and emit .paused. `.ended` is ignored — per
        // Apple's HIG we don't auto-resume; the user re-taps the pill.
        guard type == .began else { return }
        // `NotificationCenter` delivers `interruptionNotification` on
        // an arbitrary thread (commonly the audio I/O thread). Every
        // other `synth.*` call in this class reaches the synthesizer
        // from a main-actor context — `AVSpeechSynthesizer` isn't
        // documented thread-safe, so funnel this one through the main
        // actor too.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.synth.pauseSpeaking(at: .word)
            let continuation = self.lock.withLock { $0.continuation }
            continuation?.yield(.paused)
        }
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
        let (verseNumber, continuation) = lock.withLock {
            state -> (Int?, AsyncStream<NarrationEvent>.Continuation?) in
            // Drop stale callbacks (left over from a `stopSpeaking +
            // requeue` pivot) so they don't shift `currentIndex` or
            // yield a phantom `.started` for a verse the current
            // session isn't on.
            guard let entry = state.utteranceVerse[key],
                  entry.sessionVersion == state.sessionVersion else {
                return (nil, nil)
            }
            if let index = state.pendingUtterances
                .firstIndex(where: { $0.verseNumber == entry.verseNumber }) {
                state.currentIndex = index
            }
            return (entry.verseNumber, state.continuation)
        }
        guard let verseNumber, let continuation else { return }
        continuation.yield(.started(verseNumber: verseNumber))
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let key = ObjectIdentifier(utterance)
        let (verseNumber, continuation, isLast) = lock.withLock {
            state -> (Int?, AsyncStream<NarrationEvent>.Continuation?, Bool) in
            guard let entry = state.utteranceVerse.removeValue(forKey: key) else {
                return (nil, nil, false)
            }
            // Stale callbacks consume their entry for hygiene but
            // can't drive completion of the live session.
            guard entry.sessionVersion == state.sessionVersion else {
                return (nil, nil, false)
            }
            // Completion depends on the synth delivering `didFinish`
            // for utterances in the order they were `speak()`d.
            // AVSpeechSynthesizer doesn't formally document strict
            // FIFO ordering, but its implementation reads one
            // utterance at a time from a serial queue, so an
            // out-of-order delivery would require the synth to
            // restructure how it dispatches — load-bearing for the
            // `.completed` event but not at risk in practice.
            let isLast = state.utteranceVerse.isEmpty
                && (entry.verseNumber == state.pendingUtterances.last?.verseNumber)
            return (entry.verseNumber, state.continuation, isLast)
        }
        guard let verseNumber, let continuation else { return }
        continuation.yield(.finishedVerse(verseNumber: verseNumber))
        if isLast {
            teardownActiveSession(emit: .completed)
        }
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didPause utterance: AVSpeechUtterance
    ) {
        let continuation = lock.withLock { $0.continuation }
        continuation?.yield(.paused)
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didContinue utterance: AVSpeechUtterance
    ) {
        let continuation = lock.withLock { $0.continuation }
        continuation?.yield(.resumed)
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        // The synth fires didCancel once per pending utterance after
        // `stopSpeaking`. `teardownActiveSession` is idempotent, so the
        // first callback that lands while a session is live emits
        // `.cancelled` and the rest fall through.
        //
        // Stale callbacks (from a `stopSpeaking + requeue` pivot)
        // would otherwise see an empty map + live continuation and
        // fire `.cancelled` against the new session — the
        // `sessionVersion` check below is what blocks that race.
        let key = ObjectIdentifier(utterance)
        let shouldEmit = lock.withLock {
            state -> Bool in
            guard let entry = state.utteranceVerse.removeValue(forKey: key) else {
                // No entry means the utterance is from a prior queue
                // whose entries were wiped by `requeue`'s `removeAll`,
                // OR it was already consumed by a prior callback.
                // Either way, do nothing.
                return false
            }
            guard entry.sessionVersion == state.sessionVersion else {
                // Stale callback from a requeued queue — consumed for
                // hygiene but not allowed to terminate the live session.
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
