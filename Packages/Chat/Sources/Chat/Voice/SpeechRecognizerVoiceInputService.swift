import AVFoundation
import Foundation
import Speech

/// Production ``VoiceInputService`` backed by `SFSpeechRecognizer`
/// (SFSpeech = Apple's Speech-recognition framework) and `AVAudioEngine`.
/// Pinned to **on-device** recognition (`requiresOnDeviceRecognition =
/// true`) so transcripts never leave the device — privacy + offline use
/// per spec §2.
///
/// One session per `startRecognition(locale:)` call: builds a fresh
/// `SFSpeechAudioBufferRecognitionRequest` and `SFSpeechRecognitionTask`
/// each time, bridges the task's callback API into an
/// `AsyncThrowingStream`, and tears down the audio engine + recognition
/// task in the stream's `onTermination` block. A 30 s trailing-silence
/// watchdog finishes the stream with `.silenceTimeout` if no `.partial`
/// event arrives in that window — the controller treats that as a normal
/// stop and commits the most recent partial.
public final class SpeechRecognizerVoiceInputService: VoiceInputService {
    /// Trailing-silence cap. Reset on every interim result; on fire we
    /// finish the stream with `.silenceTimeout`.
    private let silenceTimeout: Duration

    public init(silenceTimeout: Duration = .seconds(30)) {
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
            // mutation through its own serial queue.
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
/// recognition request, and the recognition task. Lifted out of the
/// service so a single `RecognitionSession` instance can be referenced
/// from both the synchronous setup path and the async `onTermination`
/// callback.
private final class RecognitionSession: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<VoiceInputEvent, Error>.Continuation
    private let silenceTimeout: Duration
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var watchdogTask: Task<Void, Never>?
    private var lastPartial: String = ""
    private var torndown = false
    private let lock = NSLock()

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

        #if os(iOS) || os(visionOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw VoiceInputError.audioEngineFailed(error.localizedDescription)
        }
        #endif

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            throw VoiceInputError.audioEngineFailed(error.localizedDescription)
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                self.handlePartial(text: text, isFinal: result.isFinal)
            }
            if let error {
                self.handleError(error)
            }
        }

        startWatchdog()
    }

    private func handlePartial(text: String, isFinal: Bool) {
        lock.lock()
        lastPartial = text
        lock.unlock()
        if isFinal {
            continuation.yield(.final(text))
            continuation.finish()
            tearDown()
        } else {
            continuation.yield(.partial(text))
            startWatchdog()
        }
    }

    private func handleError(_ error: Error) {
        let nsError = error as NSError
        // SFSpeech fires `kAFAssistantErrorDomain` code 1101 ("no speech
        // detected") when the user taps stop without speaking — a clean
        // finish, not a banner-worthy failure. Every other code in that
        // domain (1700-series for missing on-device model, 203 for
        // network invalidation, 1107 for audio source disabled, etc.)
        // is a real failure the user needs to see — surface it through
        // `.recognizerFailed` and include the domain+code in the
        // message so we can diagnose simulator-only failures from the
        // banner text alone, without rebuilding with logs.
        if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1101 {
            let last: String
            lock.lock(); last = lastPartial; lock.unlock()
            continuation.yield(.final(last))
            continuation.finish()
        } else {
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
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        #if os(iOS) || os(visionOS) || os(tvOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
