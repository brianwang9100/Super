import AVFoundation
import Foundation
import os

/// Production ``NarrationService`` backed by `AVSpeechSynthesizer`.
/// Wraps the synthesizer's delegate callbacks into the
/// `AsyncStream<NarrationEvent>` the controller iterates.
///
/// One session at a time, and **one utterance in the synth's queue at a
/// time**: `startSpeaking(_:rate:voice:)` speaks only the first verse and
/// the delegate's `didFinish` queues the next, so the synth never holds a
/// batch it could reorder or drop (see ``speakVerse(at:expectedVersion:)``).
/// The delegate routes per-utterance start/finish callbacks back into the
/// active continuation. Audio Session: switches to
/// `.playback` / `.spokenAudio` / `.duckOthers` on session start and
/// restores the saved category on tear-down — TTS = text-to-speech.
public final class AVSpeechSynthesizerNarrationService: NSObject, NarrationService, @unchecked Sendable {
    private let synth: any SpeechSynthesizing
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

    public convenience init(coordinator: (any NarrationAudioCoordinator)? = nil) {
        self.init(coordinator: coordinator, synthesizer: AVSpeechSynthesizer())
    }

    /// Designated initializer with an injectable synthesizer — `internal`
    /// so the seam stays out of the public surface; tests reach it via
    /// `@testable import`.
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

    public func isAvailable() -> Bool {
        !AVSpeechSynthesisVoice.speechVoices().isEmpty
    }

    /// Prefer Premium over Enhanced voices in the locale's language. When
    /// only Compact voices are installed, leave playback on the system default.
    public func bestAvailableVoice(locale: Locale) -> AVSpeechSynthesisVoice? {
        let prefix = locale.language.languageCode?.identifier ?? "en"
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
        return candidates.first { $0.quality == .premium }
            ?? candidates.first { $0.quality == .enhanced }
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

            let version = lock.withLock { state -> Int in
                state.continuation = continuation
                state.pendingUtterances = utterances
                state.currentIndex = 0
                state.currentRate = rate
                state.currentVoice = voice
                state.sessionVersion += 1
                state.utteranceVerse.removeAll(keepingCapacity: true)
                state.didEmitTerminal = false
                return state.sessionVersion
            }
            continuation.onTermination = { [weak self] _ in
                self?.releaseAudioSession()
            }
            speakVerse(at: 0, expectedVersion: version)
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
            // `requeue` owns the stop → re-speak ordering.
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
            requeue(from: restartIndex)
        }
    }

    // MARK: Queue management

    /// Rewind the live session to `index` and speak that verse next —
    /// the shared path for skip, restart, and rate/voice changes.
    ///
    /// Bumps the session version and clears the in-flight entry *before*
    /// stopping the synth, so the cancelled utterance's stale
    /// `didCancel` / `didFinish` callbacks find no matching entry and
    /// fall through: they can neither terminate the session nor advance
    /// it. Only then is the new verse queued.
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

    /// Speak exactly the verse at `index` — never the rest of the
    /// chapter. The next verse is queued only when this one's
    /// `didFinish` lands (see the delegate), so **at most one utterance
    /// is ever in the synthesizer's queue**. That makes
    /// ``State/currentIndex`` the single source of truth for playback
    /// position: the synthesizer can't reorder or drop a verse we never
    /// handed it. This is the regression this design closes — queuing a
    /// whole chapter at once let the synth come back out of order or a
    /// verse short on a device whose Enhanced/Premium voice streams in
    /// mid-queue (audible as "started on verse 6", then "jumped back to
    /// verse 5"). A no-op once `index` runs past the last verse.
    ///
    /// - Parameter expectedVersion: the session version live at the
    ///   caller's decision point (the lock pass where it set
    ///   `currentIndex`). `didFinish` is delivered on the AVSpeech
    ///   delegate thread while the main actor may be in
    ///   `requeue` (skip / rate / voice), so a requeue can bump the
    ///   version in the gap between *deciding* to speak this verse and
    ///   actually registering it — or between this method's own two lock
    ///   passes. Both lock passes below bail unless the version still
    ///   matches, so a superseded verse's entry is never registered. The
    ///   synth may momentarily hold such a ghost utterance, but with no
    ///   entry its callbacks are all dropped — it can't advance or
    ///   complete the session.
    private func speakVerse(at index: Int, expectedVersion: Int) {
        // Read the verse + current rate/voice under the lock (all
        // `Sendable`), then build the `AVSpeechUtterance` outside it —
        // `AVSpeechUtterance` isn't `Sendable`, so it can't cross the
        // lock's return.
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
        // `ObjectIdentifier` is `Sendable`; compute it out here so the
        // lock closure doesn't capture the non-`Sendable` utterance.
        // Re-check the version: a requeue may have landed while the
        // utterance was being built, which would make this verse stale.
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
        // `NotificationCenter` delivers `interruptionNotification` on an
        // arbitrary thread (commonly the audio I/O thread).
        // `AVSpeechSynthesizer` isn't documented thread-safe; our other
        // `synth.*` calls run either on the main actor (start / skip /
        // rate / voice) or on the AVSpeech delegate thread that owns the
        // chain (`speakVerse` from `didFinish`). This handler is on
        // neither, so funnel it through the main actor.
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
            // `currentIndex` is set when the verse is queued (see
            // `speakVerse(at:)`), so there's nothing to remap here — just
            // drop stale callbacks left over from a cancelled queue so
            // they don't yield a phantom `.started` for a verse the
            // current session has already moved past.
            guard let entry = state.utteranceVerse[key],
                  entry.sessionVersion == state.sessionVersion else {
                return (nil, nil)
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
        // What follows this verse: speak the next one, or — when it was
        // the last — complete the session. Because verses are queued one
        // at a time, the finished utterance is always the one at
        // `currentIndex`, so completion is a clean index check rather
        // than the old "is the map empty and was this the last verse?"
        // heuristic that depended on the synth's queue ordering.
        // `.speak` carries the session version it was decided under, so
        // `speakVerse` can reject it if a requeue supersedes the advance
        // in the gap before the next verse is actually queued.
        enum Advance { case speak(index: Int, version: Int); case complete }
        let outcome: (
            verseNumber: Int,
            continuation: AsyncStream<NarrationEvent>.Continuation,
            next: Advance
        )? = lock.withLock { state in
            guard let entry = state.utteranceVerse.removeValue(forKey: key) else {
                return nil
            }
            // Stale callback from a cancelled/requeued queue — consumed
            // for hygiene, but it can't advance or complete the session.
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
        // With one utterance in flight at a time, a matching `didCancel`
        // means the live verse was stopped by something *other* than our
        // own requeue (an external interruption / preemption) — `stop()`
        // and `startSpeaking` emit their terminal explicitly first, so
        // `didEmitTerminal` is already set on those paths. A requeue
        // bumps `sessionVersion` and clears the entry *before* stopping,
        // so its cancelled utterance fails both guards below and can't
        // fire a spurious `.cancelled` against the new verse.
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

// MARK: Synthesizer seam

/// The slice of `AVSpeechSynthesizer` that
/// ``AVSpeechSynthesizerNarrationService`` drives. Exists as a protocol
/// so tests can substitute a fake that records `speak` / `stopSpeaking`
/// calls and fires the delegate callbacks synchronously — a real
/// synthesizer needs audio hardware and speaks in real time, so the
/// "one utterance queued at a time" invariant can't otherwise be
/// asserted. Production uses `AVSpeechSynthesizer` unchanged.
protocol SpeechSynthesizing: AnyObject {
    var delegate: AVSpeechSynthesizerDelegate? { get set }
    func speak(_ utterance: AVSpeechUtterance)
    @discardableResult func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
    @discardableResult func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool
    @discardableResult func continueSpeaking() -> Bool
}

extension AVSpeechSynthesizer: SpeechSynthesizing {}
