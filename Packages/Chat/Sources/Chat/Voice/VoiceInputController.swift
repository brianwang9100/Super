import Foundation

/// `@Observable @MainActor` view-model collaborator owned by
/// ``ChatScreenViewModel`` (one per chat screen). Coordinates a single
/// in-flight ``VoiceInputService`` session: drives `toggle()`/`stop()`
/// from the composer mic button, exposes the live `partialTranscript`
/// for the composer to render, and fires `onFinalTranscript` once at
/// session end so the view model can commit the text into the composer
/// buffer.
///
/// State machine (per spec §5.3):
///
///     .idle ── toggle()/permissions OK + available ──► .listening
///       ▲                                                │
///       └── stop() / .final / silenceTimeout ────────────┘
///
///     .idle ── permissions denied ────► .denied
///     .idle ── !isAvailable ──────────► .unavailable
///     .listening ── stream throws ────► .failed(reason)
///
/// `toggle()` is idempotent across rapid calls — a second tap inside the
/// same task tick (before `state` flips to `.listening`) is dropped.
@Observable
@MainActor
public final class VoiceInputController {
    /// Coarse UI state. The composer dims its mic on `.unavailable`,
    /// renders the recording stop button on `.listening`, and the view
    /// model maps `.denied`/`.failed` to the error banner via
    /// `handleVoiceStateChange(_:)`.
    public enum State: Equatable, Sendable {
        case idle
        case listening
        case denied
        case unavailable
        case failed(String)
    }

    public private(set) var state: State = .idle
    /// Most recent `.partial` transcript from the active session. The
    /// service accumulates utterances committed across natural pauses
    /// inside a single session, so this value grows as the user keeps
    /// speaking — a pause-then-resume looks like a single continuous
    /// dictation, not two separate sessions. Empty outside
    /// `.listening`.
    public private(set) var partialTranscript: String = ""

    /// Fires once per session with the committed final text (including
    /// the silence-timeout commit path). The view model installs this in
    /// init to write the transcript into the composer text buffer.
    public var onFinalTranscript: ((String) -> Void)?

    private let service: any VoiceInputService
    private var streamTask: Task<Void, Never>?
    /// Set true on every `toggle()` start path, cleared on completion,
    /// so a second `toggle()` arriving in the same task tick (before
    /// `state` flips to `.listening`) doesn't double-start the service.
    private var isStarting = false

    public init(service: any VoiceInputService) {
        self.service = service
        // Initial availability check — if no on-device model is
        // installed for the device locale, boot into `.unavailable` so
        // the composer dims the mic button before the user ever taps it.
        if !service.isAvailable(locale: .current) {
            self.state = .unavailable
        }
    }

    /// Start a new session if idle, stop the current one if listening.
    /// Idempotent across rapid calls inside the same task tick.
    public func toggle(locale: Locale = .current) async {
        switch state {
        case .listening:
            stop()
            return
        case .unavailable:
            // Defensive arm — the composer renders the mic as
            // `.disabled(true)` while state is `.unavailable`, so a tap
            // shouldn't normally reach the controller in this state. If
            // it does (e.g. a programmatic invocation), re-check
            // availability in case the locale's on-device model finished
            // downloading since boot, and either drop into `.idle` to
            // continue or return silently — the dimmed mic conveys the
            // unavailable state on its own; no banner.
            if service.isAvailable(locale: locale) {
                state = .idle
            } else {
                return
            }
        case .denied, .failed, .idle:
            break
        }

        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        let permission = await service.requestPermissions()
        guard permission == .granted else {
            state = .denied
            return
        }
        guard service.isAvailable(locale: locale) else {
            state = .unavailable
            return
        }

        partialTranscript = ""
        state = .listening
        startStream(locale: locale)
    }

    /// Cancel the in-flight stream. The service's `onTermination` block
    /// tears down the audio engine; the controller resets to `.idle`
    /// here without waiting for a final event.
    public func stop() {
        streamTask?.cancel()
        streamTask = nil
        if state == .listening {
            // Commit whatever partial we have so a user-initiated stop
            // behaves the same as an upstream `.final` event. This is
            // the spec §6 "final transcript (last partial) commits"
            // path that also runs on silence timeout.
            let committed = partialTranscript
            partialTranscript = ""
            state = .idle
            onFinalTranscript?(committed)
        }
    }

    private func startStream(locale: Locale) {
        let stream = service.startRecognition(locale: locale)
        streamTask = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self else { return }
                    self.handle(event)
                }
                // Stream ended cleanly without a `.final` event — treat
                // as a normal stop so the controller doesn't strand in
                // `.listening`.
                guard let self else { return }
                if self.state == .listening {
                    let committed = self.partialTranscript
                    self.partialTranscript = ""
                    self.state = .idle
                    self.onFinalTranscript?(committed)
                }
            } catch is CancellationError {
                // `stop()` already wrote the terminal state.
                return
            } catch let error as VoiceInputError {
                guard let self else { return }
                self.handle(error)
            } catch {
                guard let self else { return }
                self.partialTranscript = ""
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private func handle(_ event: VoiceInputEvent) {
        switch event {
        case .partial(let text):
            partialTranscript = text
        case .final(let text):
            partialTranscript = ""
            state = .idle
            onFinalTranscript?(text)
        }
    }

    private func handle(_ error: VoiceInputError) {
        switch error {
        case .silenceTimeout:
            // Treat as a normal stop — commit whatever the most recent
            // `.partial` was. Per spec §7 "final transcript (last
            // partial) commits; controller returns to `.idle`; no banner".
            let committed = partialTranscript
            partialTranscript = ""
            state = .idle
            onFinalTranscript?(committed)
        case .permissionDenied:
            partialTranscript = ""
            state = .denied
        case .unavailable:
            partialTranscript = ""
            state = .unavailable
        case .recognizerFailed(let reason), .audioEngineFailed(let reason):
            partialTranscript = ""
            state = .failed(reason)
        }
    }
}
