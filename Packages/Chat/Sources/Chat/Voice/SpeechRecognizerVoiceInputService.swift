import AVFoundation
import Foundation
import Speech
import os

/// On-device microphone recognition. Pauses finalize individual utterances and
/// restart recognition against the same engine; prior phrases are never replayed.
public final class SpeechRecognizerVoiceInputService: VoiceInputService {
    private let silenceTimeout: Duration
    private let activeSession = OSAllocatedUnfairLock<RecognitionSession?>(initialState: nil)

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
        let (stream, continuation) = AsyncThrowingStream<VoiceInputEvent, Error>.makeStream()
        let session = RecognitionSession(continuation: continuation, silenceTimeout: silenceTimeout)
        activeSession.withLock { active in
            active?.stop()
            active = session
            do {
                try session.start(locale: resolvedLocale)
            } catch {
                session.tearDown()
                continuation.finish(throwing: error as? VoiceInputError
                    ?? .audioEngineFailed(error.localizedDescription))
            }
        }
        continuation.onTermination = { _ in session.tearDown() }
        return stream
    }

    public func stopRecognition() {
        activeSession.withLock { session in
            session?.stop()
            session = nil
        }
    }

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
        // The first audio input tap prompts automatically; the bundle still needs NSMicrophoneUsageDescription.
        return true
        #endif
    }
}

/// Owns one audio engine and its sequence of recognition tasks. The unfair lock
/// serializes callback generations, event publication, watchdog state, and teardown.
/// Slow recognition-task creation happens outside the lock to keep the tap responsive.
private final class RecognitionSession: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<VoiceInputEvent, Error>.Continuation
    private let silenceTimeout: Duration
    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var watchdogTask: Task<Void, Never>?
    private var taskGeneration = 0
    private var watchdogGeneration = 0
    private var finishing = false
    private var torndown = false
    private var tapInstalled = false
    // Recognition can call back during setup. Defer physical teardown until setup
    // exits, so an early failure cannot remove resources that setup then restarts.
    private var isSettingUp = true
    private let lock = OSAllocatedUnfairLock()

    init(continuation: AsyncThrowingStream<VoiceInputEvent, Error>.Continuation, silenceTimeout: Duration) {
        self.continuation = continuation
        self.silenceTimeout = silenceTimeout
    }

    func start(locale: Locale) throws {
        defer { finishSetup() }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
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
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            let request = self.recognitionRequest
            self.lock.unlock()
            request?.append(buffer)
        }
        tapInstalled = true
        taskGeneration += 1
        let (request, task) = makeRecognitionTask(on: recognizer, generation: taskGeneration)
        lock.lock()
        guard !finishing else {
            lock.unlock()
            task.cancel()
            request.endAudio()
            return
        }
        recognitionRequest = request
        recognitionTask = task
        lock.unlock()
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            throw VoiceInputError.audioEngineFailed(error.localizedDescription)
        }
        lock.lock()
        if !torndown && !finishing { resetWatchdogLocked() }
        lock.unlock()
    }

    private func makeRecognitionTask(
        on recognizer: SFSpeechRecognizer, generation: Int
    ) -> (SFSpeechAudioBufferRecognitionRequest, SFSpeechRecognitionTask) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.handlePartial(text: result.bestTranscription.formattedString,
                                   isFinal: result.isFinal, generation: generation)
            }
            if let error { self.handleError(error, generation: generation) }
        }
        return (request, task)
    }

    private func handlePartial(text: String, isFinal: Bool, generation: Int) {
        lock.lock()
        guard generation == taskGeneration, !torndown, !finishing else {
            lock.unlock()
            return
        }
        // Publish under the generation lock BEFORE allowing the next task to emit.
        // These are phrase-local values; no whole-session transcript is reconstructed.
        continuation.yield(isFinal ? .utterance(text) : .partial(text))
        resetWatchdogLocked()
        guard isFinal, let recognizer else {
            lock.unlock()
            return
        }
        let outgoingRequest = recognitionRequest
        taskGeneration += 1
        let nextGeneration = taskGeneration
        lock.unlock()

        let (request, task) = makeRecognitionTask(on: recognizer, generation: nextGeneration)
        lock.lock()
        guard !torndown, !finishing, nextGeneration == taskGeneration else {
            lock.unlock()
            task.cancel()
            outgoingRequest?.endAudio()
            return
        }
        recognitionRequest = request
        recognitionTask = task
        lock.unlock()
        outgoingRequest?.endAudio()
    }

    private func handleError(_ error: Error, generation: Int) {
        lock.lock()
        guard generation == taskGeneration, !torndown, !finishing else {
            lock.unlock()
            return
        }
        finishing = true
        lock.unlock()
        let error = error as NSError
        // No-speech detection closes the current utterance; the controller retains
        // its last nonempty hypothesis if Apple's terminal result is empty.
        if error.domain == "kAFAssistantErrorDomain" && error.code == 1101 {
            continuation.yield(.final(""))
            continuation.finish()
        } else {
            let detail = "\(error.domain) #\(error.code): \(error.localizedDescription)"
            continuation.finish(throwing: VoiceInputError.recognizerFailed(detail))
        }
        tearDown()
    }

    /// Caller holds the lock. A timer that has already awakened must still match
    /// the current generation before it can terminate recognition after a reset.
    private func resetWatchdogLocked() {
        watchdogTask?.cancel()
        watchdogGeneration += 1
        let generation = watchdogGeneration
        let timeout = silenceTimeout
        watchdogTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.fireSilenceTimeout(generation: generation)
        }
    }

    private func fireSilenceTimeout(generation: Int) {
        lock.lock()
        guard !torndown, !finishing, generation == watchdogGeneration else {
            lock.unlock()
            return
        }
        finishing = true
        lock.unlock()
        // finish invokes onTermination, which takes the same teardown lock.
        continuation.finish(throwing: VoiceInputError.silenceTimeout)
        tearDown()
    }

    /// Stop first releases resources, then closes the stream for a lossless drain.
    func stop() {
        tearDown()
        continuation.finish()
    }

    private func finishSetup() {
        lock.lock()
        isSettingUp = false
        let needsCleanup = finishing
        lock.unlock()
        if needsCleanup { tearDown() }
    }

    func tearDown() {
        lock.lock()
        defer { lock.unlock() }
        guard !torndown else { return }
        finishing = true
        guard !isSettingUp else { return }
        torndown = true
        watchdogTask?.cancel()
        watchdogTask = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognizer = nil
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        #if os(iOS) || os(visionOS) || os(tvOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
