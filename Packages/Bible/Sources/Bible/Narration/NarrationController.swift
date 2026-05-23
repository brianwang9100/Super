import AVFoundation
import Foundation
import Observation

/// `@Observable @MainActor` view-model collaborator owned by
/// ``BibleScreenViewModel``. Drives a single in-flight
/// ``NarrationService`` session: forwards start/pause/resume/stop/skip
/// commands and maps the service's `AsyncStream<NarrationEvent>` into
/// `state` / `currentVerseNumber` / `lastError` the reader and the
/// transport sheet observe.
///
/// State machine:
///
///     .idle  ── start() ──►  (service)  ── .started ──►  .speaking
///                                                            │
///       .paused ◄── .paused ── pause() ──┘                   │
///              ── resume() / .resumed ──► .speaking          │
///       .idle  ◄── .completed / .cancelled / .failed ────────┘
///
/// `stop()` is idempotent: a second call before the service's
/// `.cancelled` event arrives is a no-op (the controller is already
/// running its teardown).
@Observable
@MainActor
public final class NarrationController {
    /// Coarse UI state. The transport sheet swaps its play/pause glyph on
    /// `.paused`; the nav bar pill renders only when state is
    /// `.speaking` / `.paused`; everything else lives in `.idle`.
    public enum State: Equatable, Sendable {
        case idle
        case speaking
        case paused
    }

    public private(set) var state: State = .idle
    /// Verse currently being spoken, or `nil` when idle. Drives the
    /// reader's underline and the auto-scroll proxy.
    public private(set) var currentVerseNumber: Int?
    /// Most recent terminal error from a failed session. Cleared on the
    /// next successful `start(...)`.
    public private(set) var lastError: NarrationError?
    /// Playback speed as a **user-facing multiple of normal speech**
    /// (1.0 = normal, 0.5 = half-speed, 1.5 = one-and-a-half). The
    /// service maps this to the AVSpeech absolute-rate scale through a
    /// conservative curve so the *perceived* speedup matches the
    /// display value — Apple's `AVSpeechUtterance.rate` is non-linear
    /// (1.0 absolute is ~3-4× perceived, not 2×) and naively passing
    /// the display value through made 1.5× sound like 2× and 2× sound
    /// like 4×. Range and step are policy of the transport sheet's
    /// slider; the controller / service accept any positive value and
    /// clamp internally.
    public var rate: Float = 1.0 {
        didSet {
            // Picker may write back the same value (re-selecting the
            // already-selected row in a SwiftUI `Menu`). Forwarding a
            // no-op rate to the service would trigger a needless
            // `stopSpeaking + requeue` mid-verse — audible click for
            // zero behavioural change.
            guard rate != oldValue else { return }
            service.setRate(rate)
        }
    }
    /// Selected synthesizer voice, or `nil` for the system default. The
    /// transport sheet's picker writes here; the controller forwards the
    /// change to the service so the new voice is audible from the next
    /// verse boundary, without the user having to stop and re-start.
    public var voice: AVSpeechSynthesisVoice? {
        didSet {
            // Same idempotence as `rate`: re-selecting the active
            // voice in the picker writes the same identifier back and
            // must not requeue. `AVSpeechSynthesisVoice` isn't
            // `Equatable`, so compare by `identifier`.
            guard voice?.identifier != oldValue?.identifier else { return }
            service.setVoice(voice)
        }
    }

    /// Optional terminal-event hook. Fires once per session when it
    /// lands in `.idle` via any terminal event (`.completed`,
    /// `.cancelled`, or `.failed`). Currently unused by `BibleScreen`
    /// — the transport card is intentionally kept open after a
    /// completed playthrough so the big play button can re-trigger
    /// Narrate without reopening the spark menu, consistent with the
    /// `Stop-keeps-the-card` rule. Reserve this for callers that *do*
    /// want a notification (e.g. a future "auto-advance to next
    /// chapter" preference).
    public var onCompletion: (@MainActor () -> Void)?

    private let service: any NarrationService
    private var streamTask: Task<Void, Never>?
    private let now: @MainActor () -> Date
    /// Timestamp of the most recent `skipPrevious()` tap, used to detect
    /// double-taps within ``skipPreviousDoubleTapWindow``. `nil` once the
    /// window has lapsed or after a session terminates.
    private var lastSkipPreviousAt: Date?

    /// Window inside which a second `skipPrevious()` tap counts as a
    /// "jump to previous verse" rather than a "restart current verse".
    /// 1.0s mirrors the 2000s-music-player rewind interaction the spec
    /// calls for — short enough that a deliberate single tap stays a
    /// restart, long enough to forgive the second tap.
    public static let skipPreviousDoubleTapWindow: TimeInterval = 1.0

    public init(
        service: any NarrationService,
        now: @MainActor @escaping () -> Date = { Date() }
    ) {
        self.service = service
        self.now = now
    }

    public func isAvailable() -> Bool { service.isAvailable() }

    /// Highest-quality installed voice for `locale`, preferring Premium
    /// over Enhanced over nothing. Returns `nil` when the user has only
    /// Compact voices installed — the caller then proceeds with the
    /// system default (which sounds robotic) and ideally prompts the
    /// user to install Enhanced voices in iOS Settings.
    ///
    /// AVSpeech's default voice on a fresh iOS install is a Compact
    /// voice; Enhanced and Premium voices are user-downloaded under
    /// Settings → Accessibility → Spoken Content → Voices. We hide
    /// Compact voices from the picker so the user can't accidentally
    /// pick the robotic option, but if none of the better tiers are
    /// installed we still let narration fall through to the system
    /// default rather than refusing to speak.
    /// Marked `nonisolated` so callers can dispatch it to a detached
    /// background task — `AVSpeechSynthesisVoice.speechVoices()` is a
    /// ~100-300 ms synchronous file scan, and the first-Narrate path
    /// (`BibleScreenViewModel.startNarration`) hops off main to avoid
    /// freezing the menu → card animation.
    nonisolated public static func bestAvailableVoice(
        locale: Locale = .current
    ) -> AVSpeechSynthesisVoice? {
        let prefix = locale.language.languageCode?.identifier ?? "en"
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
        return candidates.first { $0.quality == .premium }
            ?? candidates.first { $0.quality == .enhanced }
    }

    /// Begin a new session. Cancels any in-flight session first so the
    /// underlying service only ever has one queue in flight.
    public func start(utterances: [NarrationVerseUtterance]) {
        // Tear down any prior session synchronously. The prior stream
        // task is cancelled cooperatively (Swift Concurrency doesn't
        // preempt), and its for-await loop checks `Task.isCancelled`
        // on every iteration so it exits *before* processing any
        // `.cancelled` event the service will yield as part of its own
        // teardown — without that guard the old task would overwrite
        // the new session's freshly-set `state = .speaking` with
        // `state = .idle` and the nav-bar speaker would flicker back to
        // sparkles on every Narrate retap.
        streamTask?.cancel()
        streamTask = nil
        lastError = nil

        let stream = service.startSpeaking(utterances, rate: rate, voice: voice)
        streamTask = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                self.handle(event)
            }
        }
    }

    public func pause() {
        guard state == .speaking else { return }
        service.pause()
    }

    public func resume() {
        guard state == .paused else { return }
        service.resume()
    }

    /// Cancel the in-flight session. Idempotent — the controller stays
    /// in whatever state it's in until the service yields `.cancelled`.
    public func stop() {
        guard state != .idle else { return }
        service.stop()
    }

    public func skipNext() {
        guard state == .speaking || state == .paused else { return }
        service.skipForward()
    }

    /// 2000s-music-player rewind: a single tap restarts the current
    /// verse; a second tap within
    /// ``skipPreviousDoubleTapWindow`` jumps to the previous verse
    /// instead. The service handles the queue rewind for both paths.
    public func skipPrevious() {
        guard state == .speaking || state == .paused else { return }
        let timestamp = now()
        if let last = lastSkipPreviousAt,
           timestamp.timeIntervalSince(last) < Self.skipPreviousDoubleTapWindow {
            // Inside the double-tap window — jump back a verse and
            // clear the timestamp so a third quick tap doesn't chain
            // into yet another previous-verse jump (each step is a
            // discrete double-tap intent).
            lastSkipPreviousAt = nil
            service.skipToPreviousVerse()
        } else {
            lastSkipPreviousAt = timestamp
            service.skipBackward()
        }
    }

    /// Test seam: synchronously process one event without routing
    /// through the AsyncStream consumer Task. Production code goes
    /// through `start(utterances:)`'s stream-consumer Task on the
    /// service's `AsyncStream<NarrationEvent>`; this lets tests drive
    /// state transitions without polling the scheduler for the stream
    /// Task to wake up — see root AGENTS.md §Testing.2 on why
    /// condition-polling on `Task.yield()` is forbidden. Underscore
    /// prefix marks it as a non-stable surface, not part of the
    /// production API.
    @MainActor
    func _simulateEvent(_ event: NarrationEvent) {
        handle(event)
    }

    /// Test seam: await the in-flight stream-consumer `Task` so a test
    /// can synchronize on "the controller has drained its
    /// subscription" without polling. Returns immediately when no
    /// session is active. Mirrors
    /// `ChatScreenViewModel._waitForPendingStreamTask()`.
    func _waitForPendingStreamTask() async {
        await streamTask?.value
    }

    /// Test seam: the current stream-consumer `Task`, or `nil` when no
    /// session is in flight. Lets a test capture the *prior* task
    /// before `start(_:)` replaces it, then `await task?.value` to
    /// deterministically synchronize on the prior task's exit (used
    /// to verify it bails out via `Task.isCancelled` before
    /// processing a buffered `.cancelled` event left behind by the
    /// service's teardown).
    var _currentStreamTask: Task<Void, Never>? { streamTask }

    private func handle(_ event: NarrationEvent) {
        switch event {
        case .started(let verseNumber):
            currentVerseNumber = verseNumber
            state = .speaking
        case .finishedVerse:
            // No transition — the next `.started` or a terminal event
            // follows immediately.
            break
        case .paused:
            state = .paused
        case .resumed:
            state = .speaking
        case .completed, .cancelled:
            currentVerseNumber = nil
            state = .idle
            onCompletion?()
        case .failed(let error):
            lastError = error
            currentVerseNumber = nil
            state = .idle
            onCompletion?()
        }
    }
}
