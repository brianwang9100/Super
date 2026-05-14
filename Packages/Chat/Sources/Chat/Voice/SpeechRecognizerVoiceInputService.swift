import AVFoundation
import Foundation
import Speech
import os

/// Production ``VoiceInputService`` backed by `SFSpeechRecognizer`
/// (SFSpeech = Apple's Speech-recognition framework) and `AVAudioEngine`.
/// Pinned to **on-device** recognition (`requiresOnDeviceRecognition =
/// true`) so transcripts never leave the device — privacy + offline use
/// per spec §2.
///
/// One session per `startRecognition(locale:)` call: builds a fresh
/// audio engine + tap and bridges Apple's recognition callbacks into an
/// `AsyncThrowingStream`. Within a single session the service performs
/// **long-form dictation**: Apple's on-device recognizer auto-endpoints
/// after roughly 600 ms–1.5 s of silence and fires `isFinal = true`; the
/// service treats that as advisory, commits the just-finished utterance
/// to an internal ``DictationTranscriptAccumulator``, and transparently
/// spins up a fresh `SFSpeechAudioBufferRecognitionRequest` +
/// `SFSpeechRecognitionTask` against the same engine so the user can
/// keep speaking after a pause without re-tapping the mic. Every
/// `.partial` event carries the merged committed-plus-in-flight
/// transcript. The session terminates only on user stop (stream
/// cancellation), the 10 s trailing-silence watchdog, or an error.
public final class SpeechRecognizerVoiceInputService: VoiceInputService {
    /// Trailing-silence cap. Reset on every `.partial` event the
    /// service yields (including the synthetic post-commit partial
    /// after a transparent task restart). On fire we finish the stream
    /// with `.silenceTimeout` — the controller treats that as a normal
    /// stop and commits the accumulated transcript. Default 10 s: with
    /// auto-endpoint no longer terminating the session, the watchdog
    /// is the only "user has actually stopped" signal, and 30 s is too
    /// long to wait before auto-committing a forgotten session. This
    /// value is a UX trade-off, not a hard requirement — if users
    /// report sessions auto-committing during natural mid-message
    /// pauses (e.g. "thinking" silences while composing a longer
    /// thought), raising it is the lowest-impact lever to pull.
    private let silenceTimeout: Duration

    public init(silenceTimeout: Duration = .seconds(10)) {
        self.silenceTimeout = silenceTimeout
    }

    public func isAvailable(locale: Locale) -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    public func requestPermissions() async -> VoiceInputPermissionStatus {
        let speechStatus = await Self.requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            return speechStatus == .restricted ? .restricted : .denied
        }
        let micGranted = await Self.requestMicrophonePermission()
        return micGranted ? .granted : .denied
    }

    public func startRecognition(locale: Locale) -> AsyncThrowingStream<VoiceInputEvent, Error> {
        let resolvedLocale = SFSpeechRecognizer(locale: locale) != nil ? locale : Locale(identifier: "en-US")
        let timeout = silenceTimeout
        return AsyncThrowingStream { continuation in
            // The session owner holds the audio engine + recognition
            // task references so `onTermination` (called from any actor)
            // can tear them down. `@unchecked Sendable` because `AVAudio*`
            // and `SFSpeech*` types aren't `Sendable`-annotated yet —
            // the session enforces single-thread access by routing every
            // mutation through its own serial queue + lock.
            let session = RecognitionSession(continuation: continuation, silenceTimeout: timeout)
            do {
                try session.start(locale: resolvedLocale)
            } catch let error as VoiceInputError {
                continuation.finish(throwing: error)
                return
            } catch {
                continuation.finish(throwing: VoiceInputError.audioEngineFailed(error.localizedDescription))
                return
            }
            continuation.onTermination = { _ in
                session.tearDown()
            }
        }
    }

    // MARK: - Permission helpers

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private static func requestMicrophonePermission() async -> Bool {
        #if os(iOS) || os(visionOS) || os(tvOS)
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        #else
        // macOS and other platforms grant microphone via system prompt
        // automatically the first time `AVAudioEngine` taps input. The
        // bundle still needs `NSMicrophoneUsageDescription`.
        return true
        #endif
    }
}

/// Owns one in-flight recognition session: the audio engine, the
/// current recognition request/task, and the
/// ``DictationTranscriptAccumulator`` that merges utterances spoken
/// across natural pauses into a single rendered transcript. Lifted out
/// of the service so a single `RecognitionSession` instance can be
/// referenced from both the synchronous setup path and the async
/// `onTermination` callback.
///
/// Concurrency: the recognition-task callback fires on Apple's
/// internal queue and the audio tap closure fires on `AVAudioEngine`'s
/// real-time render thread. `lock` (`OSAllocatedUnfairLock`, the
/// project-prescribed primitive for multi-step atomic mutations per
/// AGENTS.md §Synchronization) serializes every read / write of
/// `accumulator`, `taskGeneration`, `recognitionRequest`,
/// `recognitionTask`, `recognizer`, and the `torndown` flag — so a
/// concurrent `tearDown` can't race a transparent task restart and
/// leak the new task past cleanup, and so the tap's reading of
/// `recognitionRequest` always sees a consistent value. Apple's
/// `SFSpeechAudioBufferRecognitionRequest.append(_:)` and
/// `endAudio()` are documented thread-safe, so we only hold the lock
/// long enough to snapshot the current request — the `append` itself
/// happens outside the lock. An unfair lock is preferable to a
/// futex-backed mutex here because every critical section is a
/// pointer snapshot or flag flip, well below the spinlock break-even
/// where contention would otherwise be a concern.
private final class RecognitionSession: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<VoiceInputEvent, Error>.Continuation
    private let silenceTimeout: Duration
    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var watchdogTask: Task<Void, Never>?
    private var accumulator = DictationTranscriptAccumulator()
    /// Bumped each time a new recognition task is installed. The task
    /// callback closure captures the value it was installed with and
    /// bails when its captured generation no longer matches the
    /// session's current generation — a superseded task can still
    /// deliver one delayed callback, and we must ignore it so it
    /// doesn't double-commit an utterance the new task has started
    /// capturing.
    private var taskGeneration: Int = 0
    private var torndown = false
    private let lock = OSAllocatedUnfairLock()

    init(
        continuation: AsyncThrowingStream<VoiceInputEvent, Error>.Continuation,
        silenceTimeout: Duration
    ) {
        self.continuation = continuation
        self.silenceTimeout = silenceTimeout
    }

    func start(locale: Locale) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw VoiceInputError.unavailable
        }
        guard recognizer.isAvailable else {
            throw VoiceInputError.unavailable
        }
        self.recognizer = recognizer

        #if os(iOS) || os(visionOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw VoiceInputError.audioEngineFailed(error.localizedDescription)
        }
        #endif

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        // Tap runs on the render thread. Snapshot the current
        // `recognitionRequest` under the lock so a mid-session swap
        // (auto-restart in `handlePartial`) can replace it without
        // racing the read; do the actual `append` outside the lock —
        // it's documented thread-safe on Apple's side.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            let request = self.recognitionRequest
            self.lock.unlock()
            request?.append(buffer)
        }

        // Wire up the initial recognition request + task before the
        // engine starts so buffers don't fly past a nil
        // `recognitionRequest`. The engine isn't running yet, so no
        // audio can race the assignment.
        lock.lock()
        taskGeneration += 1
        let generation = taskGeneration
        let (request, task) = makeRecognitionTask(on: recognizer, generation: generation)
        recognitionRequest = request
        recognitionTask = task
        lock.unlock()

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            throw VoiceInputError.audioEngineFailed(error.localizedDescription)
        }

        startWatchdog()
    }

    /// Build a fresh recognition request + task against `recognizer`,
    /// tagging the task callback with `generation` so stale delayed
    /// callbacks from a superseded task can recognize themselves and
    /// bail. Does **not** touch `taskGeneration` or assign the new
    /// request/task to `self` — caller bumps `taskGeneration` under
    /// the lock first, then releases the lock before invoking this so
    /// Apple's `recognitionTask(with:)` call (50–200 ms on cold paths)
    /// doesn't stall the audio render thread that takes the same lock
    /// to snapshot `recognitionRequest`. Caller is then responsible
    /// for assigning the returned pair to `self` under the lock with a
    /// torndown / generation recheck so a racing `tearDown` or a
    /// further auto-restart can't leak the new task.
    private func makeRecognitionTask(
        on recognizer: SFSpeechRecognizer,
        generation: Int
    ) -> (SFSpeechAudioBufferRecognitionRequest, SFSpeechRecognitionTask) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            // Handler runs synchronously on Apple's callback queue.
            // `handlePartial` and `handleError` serialize their own
            // state mutations through `lock`, so concurrent tap
            // appends and a racing `tearDown` can't corrupt the
            // request/task swap.
            if let result {
                self.handlePartial(
                    text: result.bestTranscription.formattedString,
                    isFinal: result.isFinal,
                    generation: generation
                )
            }
            if let error {
                self.handleError(error, generation: generation)
            }
        }
        return (request, task)
    }

    /// Either ingests a refining partial for the current utterance OR
    /// commits a finalized utterance and transparently spins up the
    /// next recognition task so the same recording session can capture
    /// more speech after a natural pause. The auto-restart path builds
    /// the new task **outside** the lock — Apple's
    /// `recognitionTask(with:)` can take 50–200 ms on cold paths and
    /// the audio render thread takes the same lock to snapshot
    /// `recognitionRequest`, so building under the lock would stall
    /// audio capture. A torndown / generation recheck on re-acquire
    /// guarantees a racing `tearDown` (or a further auto-restart)
    /// can't leak the new task past cleanup.
    private func handlePartial(text: String, isFinal: Bool, generation: Int) {
        lock.lock()
        // Stale-callback guard: a superseded task can still deliver one
        // delayed callback. Ignore it so it doesn't double-commit.
        guard generation == taskGeneration, !torndown else {
            lock.unlock()
            return
        }

        let rendered: String
        if isFinal {
            accumulator.commitCurrentUtterance(text)
            rendered = accumulator.renderedTranscript
            let outgoingRequest = recognitionRequest
            let currentRecognizer = recognizer
            taskGeneration += 1
            let nextGeneration = taskGeneration
            lock.unlock()

            // Defensive: `recognizer` is only nilled by `tearDown`,
            // which also sets `torndown = true` — the guard at the top
            // of this method would have returned early on that path,
            // so this branch shouldn't be reachable. Belt-and-braces:
            // if it ever is (future refactor relaxing the invariant),
            // yield the committed text so the user doesn't lose it
            // and exit without trying to install a new task.
            guard let currentRecognizer else {
                outgoingRequest?.endAudio()
                continuation.yield(.partial(rendered))
                startWatchdog()
                return
            }

            // Slow Apple call OUTSIDE the lock so the audio tap can
            // keep snapshotting `recognitionRequest`. The new task's
            // callbacks won't fire until we install its request below
            // — until then the tap is still routing buffers to the
            // old request, which has been `endAudio`'d by the time we
            // get here on the normal path (or will be momentarily).
            let (request, task) = makeRecognitionTask(on: currentRecognizer, generation: nextGeneration)

            // Re-acquire to install. If `tearDown` ran (or a later
            // auto-restart bumped `taskGeneration` past us) during the
            // slow build, cancel the new task so it doesn't leak past
            // cleanup and don't yield/restart the watchdog — the
            // session is over.
            lock.lock()
            if torndown || nextGeneration != taskGeneration {
                lock.unlock()
                task.cancel()
                outgoingRequest?.endAudio()
                return
            }
            recognitionRequest = request
            recognitionTask = task
            lock.unlock()

            // End audio on the outgoing request AFTER the swap so a
            // tap buffer that races us routes to the new task; this
            // call is idempotent and thread-safe per Apple's docs.
            outgoingRequest?.endAudio()
        } else {
            accumulator.ingestPartial(text)
            rendered = accumulator.renderedTranscript
            lock.unlock()
        }

        continuation.yield(.partial(rendered))
        startWatchdog()
    }

    /// Maps Apple's errors onto the protocol's terminal events.
    private func handleError(_ error: Error, generation: Int) {
        lock.lock()
        guard generation == taskGeneration, !torndown else {
            lock.unlock()
            return
        }
        let nsError = error as NSError
        // SFSpeech fires `kAFAssistantErrorDomain` code 1101 ("no
        // speech detected") when the user taps stop without speaking —
        // a clean finish, not a banner-worthy failure. Every other code
        // in that domain (1700-series for missing on-device model, 203
        // for network invalidation, 1107 for audio source disabled, etc.)
        // is a real failure the user needs to see — surface it through
        // `.recognizerFailed` and include the domain+code in the
        // message so we can diagnose simulator-only failures from the
        // banner text alone, without rebuilding with logs.
        if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1101 {
            let rendered = accumulator.renderedTranscript
            lock.unlock()
            continuation.yield(.final(rendered))
            continuation.finish()
        } else {
            lock.unlock()
            let detail = "\(nsError.domain) #\(nsError.code): \(nsError.localizedDescription)"
            continuation.finish(throwing: VoiceInputError.recognizerFailed(detail))
        }
        tearDown()
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        let timeout = silenceTimeout
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, !Task.isCancelled else { return }
            self.fireSilenceTimeout()
        }
    }

    private func fireSilenceTimeout() {
        continuation.finish(throwing: VoiceInputError.silenceTimeout)
        tearDown()
    }

    func tearDown() {
        // Hold the lock across the *entire* teardown so the
        // `SFSpeechRecognitionTask` callback queue, the watchdog Task,
        // and the stream's `onTermination` (any of which can race here
        // from arbitrary queues) can't double-cancel `recognitionTask`,
        // double-`removeTap` the audio node (AVAudioEngine is not
        // thread-safe per Apple docs — concurrent removeTap has been
        // observed to crash in production), or double-deactivate the
        // audio session. The flag check + flip + cleanup must be one
        // critical section.
        lock.lock()
        defer { lock.unlock() }
        guard !torndown else { return }
        torndown = true

        watchdogTask?.cancel()
        watchdogTask = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognizer = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        #if os(iOS) || os(visionOS) || os(tvOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
