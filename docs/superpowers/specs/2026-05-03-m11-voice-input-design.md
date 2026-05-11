# M11 — Voice Input · Design Spec

- **Date:** 2026-05-03
- **Author:** Brian Wang (with Claude)
- **Status:** Implemented + shipped — physical-device verification cleared 2026-05-10
- **Implements:** M11 row in the archived MVP build log (`docs/archived/IMPLEMENTATION_STATUS.md`)

## 1. Goal

Replace the no-op mic placeholder on `ChatComposer` with on-device voice dictation. Tapping the mic streams a partial transcript live into the composer text field; tapping stop commits the final transcript so the user can edit and send normally.

## 2. Non-goals

- Off-device speech recognition (intentionally on-device only — privacy + offline use).
- Server-side transcription, Whisper, or any cloud STT provider.
- Voice output / TTS playback of assistant replies.
- Multi-language UI for picking a recognition locale (defaults to device locale; M12 may add a Settings row).
- Continuous "always listening" / wake-word.
- Sound input level meter / waveform visualization (defer to a future polish pass).

## 3. UX decisions (resolved during brainstorming)

| # | Decision | Choice |
|---|---|---|
| 1 | Interaction model | **Tap to start, tap to stop** |
| 2 | Where transcript lands | **Live into composer field** (partial replaces, final commits) |
| 3 | Permission denial UX | **Inline error banner above composer** with a `Settings` action button |
| 4 | Recording-state visuals | **Stop square on accent-fill 34pt circle + slow accent-glow pulse**, no waveform |
| 5a | Locale | **Device locale**, fall back to `en-US` if no on-device model |
| 5b | Auto-stop on silence | **Yes — 30s trailing-silence safety timeout** (commits whatever exists) |
| 5c | Recognizer unavailable | **Dim + disable mic button**, no tap action; `accessibilityHint` explains why |

## 4. Architecture

### 4.1 File layout

```
Packages/Chat/Sources/Chat/
  Voice/
    VoiceInputService.swift                   # NEW — protocol + value types
    SpeechRecognizerVoiceInputService.swift   # NEW — production
    VoiceInputController.swift                # NEW — @Observable @MainActor view-model class
  UI/
    ChatComposer.swift                        # MODIFY — add isRecording branch + pulse + onStopRecording
    MessageListView.swift                     # MODIFY — extend ErrorBanner with optional action
  ViewModels/
    ChatScreenViewModel.swift                 # MODIFY — own controller, thread partial into composer
App/Info.plist                                # MODIFY — add two usage descriptions
```

### 4.2 Pattern choice — controller-as-view-model-collaborator

`VoiceInputController` is owned by `ChatScreenViewModel` (one per chat screen) rather than injected via SwiftUI `@Environment` like `PasteboardClient`. Reasoning: voice state is global to the chat screen (only one recording at a time, partial text mutates a single composer binding), so it belongs alongside the screen-scoped view model — same lifecycle, same composition root. The `CodeBlockCopyController` (M10) injection-via-`@Environment` pattern fits per-instance state inside a repeating view; that's not the shape here.

> **Open follow-up (memory: feedback_pattern_terminology):** establish a written taxonomy for `*Controller` / `*ViewModel` / `*Service` patterns in `Packages/Chat/CLAUDE.md` before introducing additional Controller classes.

### 4.3 Dependency direction

```
ChatScreenViewModel ──owns──► VoiceInputController ──owns──► VoiceInputService (protocol)
                                                              │
                                                              ├── SpeechRecognizerVoiceInputService (production)
                                                              └── FakeVoiceInputService (test)
```

Production wiring is in the composition root (`SuperApp` or the Chat-level factory that already builds `ChatScreenViewModel`). Tests pass a `FakeVoiceInputService` directly into `VoiceInputController.init`, then a controller into the view model.

## 5. Components

### 5.1 `VoiceInputService` (protocol)

```swift
public protocol VoiceInputService: Sendable {
    func isAvailable(locale: Locale) -> Bool
    func requestPermissions() async -> VoiceInputPermissionStatus
    func startRecognition(locale: Locale) -> AsyncThrowingStream<VoiceInputEvent, Error>
}

public enum VoiceInputPermissionStatus: Sendable, Equatable { case granted, denied, restricted }
public enum VoiceInputEvent: Sendable, Equatable { case partial(String), final(String) }
public enum VoiceInputError: Error, Sendable, Equatable {
    case permissionDenied
    case unavailable
    case recognizerFailed(String)
    case audioEngineFailed(String)
    case silenceTimeout
}
```

- `isAvailable` is cheap and synchronous; safe to call at controller init to gate the dimmed-mic state.
- `requestPermissions` is idempotent — returns `.granted` only if **both** speech recognition and microphone permissions land granted.
- `startRecognition` returns an `AsyncThrowingStream` that emits `.partial(String)` repeatedly, then exactly one terminal event (`.final(String)` on user stop, or throws on failure). Cancelling the consuming `Task` stops the audio engine cleanly via the stream's `onTermination`.

### 5.2 `SpeechRecognizerVoiceInputService` (production)

- Wraps `SFSpeechRecognizer` (with `requiresOnDeviceRecognition = true`) + `AVAudioEngine` mic input tap.
- One-shot: builds a fresh `SFSpeechAudioBufferRecognitionRequest` and `SFSpeechRecognitionTask` per `startRecognition` call. New session = new request.
- Bridges `SFSpeechRecognitionTask` callbacks → `AsyncThrowingStream` continuation:
  - Each interim result → `continuation.yield(.partial(bestTranscription.formattedString))`
  - Final result → `continuation.yield(.final(text))` then `continuation.finish()`
  - Error → `continuation.finish(throwing: VoiceInputError.recognizerFailed(...))`
- 30s silence-timeout watchdog: a `Task.sleep(for: .seconds(30))` reset on every `.partial` emission; on fire, finishes the stream with `.failed(.silenceTimeout)`. Controller treats this as a normal stop (commits whatever final transcript exists from the most recent `.partial`).
- `onTermination` block on the continuation: cancels the recognition task, removes the audio tap, stops the audio engine, deactivates the audio session.

### 5.3 `VoiceInputController` (`@Observable @MainActor`)

```swift
@Observable @MainActor
public final class VoiceInputController {
    public enum State: Equatable {
        case idle
        case listening
        case denied
        case unavailable
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var partialTranscript: String = ""

    /// Fires once per session with the committed final text (including the
    /// silence-timeout commit). View model installs this in init to write
    /// the transcript into composer text.
    public var onFinalTranscript: ((String) -> Void)?

    private let service: any VoiceInputService
    private var streamTask: Task<Void, Never>?

    public init(service: any VoiceInputService) {
        self.service = service
        // Initial availability check — if no on-device model installed
        // for device locale, controller boots into .unavailable so the
        // composer dims the mic button immediately.
        if !service.isAvailable(locale: .current) {
            self.state = .unavailable
        }
    }

    public func toggle(locale: Locale = .current) async { ... }
    public func stop() { ... }
}
```

State transitions:

```
                        toggle()
   .idle ──────permissions OK + available──────► .listening
     ▲                                              │
     │                            stop() / final / silence-timeout
     │                                              │
     └──────────────────────────────────────────────┘

   .idle ──permissions denied──► .denied
   .idle ──!isAvailable──────► .unavailable      (set at init or re-check on toggle)
   .listening ──stream throws──► .failed(reason)
```

`toggle()` is idempotent across rapid calls (guarded by checking current state).

### 5.4 `ChatComposer` modifications

- Two new public params: `isRecording: Bool = false`, `onStopRecording: () -> Void = {}`.
- New private param: `isMicAvailable: Bool = true` (defaults true so existing call sites keep working).
- `trailingButton` branching order becomes:
  1. `isStreaming` → `cancelButton` (existing)
  2. `isRecording` → `recordingButton` (NEW)
  3. `hasContent` → `sendButton` (existing)
  4. `isMicAvailable == false` → `micButtonDimmed` (NEW)
  5. else → `micButton` (existing) — `onMicTap` is unchanged
- `recordingButton`: 34pt circle, `.fill(theme.accent)`, `Image(systemName: "stop.fill")` foreground `theme.accentInk`. An `.overlay { Circle().stroke(theme.accent.opacity(0.6), lineWidth: 2) }` scales 1.0 → 1.5 and fades 0.6 → 0 on a 1.2s `.easeOut` repeat-forever animation. Pulse overlay guarded by `@Environment(\.accessibilityReduceMotion)` — skipped when true. `accessibilityLabel("Stop recording")`, `accessibilityHint("Double-tap to stop voice input and insert the transcript.")`.
- `micButtonDimmed`: same shape as `micButton` but foreground `theme.inkSoft.opacity(0.4)`, `.disabled(true)`. `accessibilityHint("On-device speech recognition isn't available for your language.")`.

### 5.5 `MessageListView.ErrorBanner` extension

```swift
public struct ErrorBanner: Equatable {
    public var message: String
    public var actionLabel: String?     // NEW (optional)
    // Action closure stored alongside but ignored by Equatable (reference identity isn't meaningful).
    // MainActor because the banner row that renders it is itself MainActor-bound (SwiftUI).
    public var action: (@MainActor () -> Void)?  // NEW (optional)

    public static func == (lhs: ErrorBanner, rhs: ErrorBanner) -> Bool {
        lhs.message == rhs.message && lhs.actionLabel == rhs.actionLabel
    }
}
```

The banner row renders the action button only when both `actionLabel != nil` and `action != nil`. All existing call sites pass only `message` and continue to work unchanged.

### 5.6 `ChatScreenViewModel` modifications

- New stored property: `let voice: VoiceInputController` (injected via init).
- New stored property: `private(set) var committedComposerText: String = ""` — the user-typed prefix at the moment recording started. Used by the view to compute the displayed composer text.
- In init, install the final-transcript callback:
  ```swift
  voice.onFinalTranscript = { [weak self] text in
      guard let self else { return }
      self.composerText = self.committedComposerText.isEmpty
          ? text
          : "\(self.committedComposerText) \(text)"
      self.committedComposerText = ""
  }
  ```
- New methods:
  ```swift
  func handleMicTap() async {
      committedComposerText = composerText          // freeze user-typed prefix
      await voice.toggle()
  }
  func handleStopRecording() { voice.stop() }

  /// Called from `ChatScreen` via `.onChange(of: voice.state)`. Translates
  /// terminal failure states into the existing error-banner surface.
  func handleVoiceStateChange(_ state: VoiceInputController.State) {
      switch state {
      case .denied:
          error = .init(
              message: "Voice input needs Speech Recognition and Microphone permissions. Open Settings to enable them.",
              actionLabel: "Settings",
              action: { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
          )
      case .failed(let reason):
          error = .init(message: "Voice input failed: \(reason)")
      case .unavailable, .idle, .listening:
          // .unavailable is reflected via dimmed mic, not a banner.
          // .idle / .listening: do nothing (don't auto-clear an unrelated error).
          break
      }
  }
  ```
- **Composer presentation rule** (lives in the view, not the view model — keeps the binding logic close to the `TextField`):
  ```swift
  // In ChatScreen body:
  ChatComposer(
      text: composerBinding,
      isStreaming: viewModel.isStreaming,
      isRecording: viewModel.voice.state == .listening,
      isMicAvailable: viewModel.voice.state != .unavailable,
      ...
      onMicTap: { Task { await viewModel.handleMicTap() } },
      onStopRecording: viewModel.handleStopRecording
  )
  .onChange(of: viewModel.voice.state) { _, newState in
      viewModel.handleVoiceStateChange(newState)
  }

  private var composerBinding: Binding<String> {
      Binding(
          get: {
              if viewModel.voice.state == .listening {
                  let partial = viewModel.voice.partialTranscript
                  return viewModel.committedComposerText
                      + (partial.isEmpty ? "" : " \(partial)")
              }
              return viewModel.composerText
          },
          set: { newValue in viewModel.composerText = newValue }
      )
  }
  ```
- The `TextField` is `.disabled(viewModel.voice.state == .listening)` so manual edits during recording can't conflict with the streaming partial. Re-enables when state returns to `.idle`. (Both states are reachable from a single re-render — no animation work.)
- SwiftUI re-renders the screen automatically whenever `voice.partialTranscript` or `voice.state` mutates because `VoiceInputController` is `@Observable` — no manual subscription needed. The `.onChange(of: voice.state)` modifier exists only to relay state into the imperative banner side-effect.

### 5.7 `Info.plist` additions

```xml
<key>NSSpeechRecognitionUsageDescription</key>
<string>Super uses speech recognition to dictate your chat messages on-device.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Super needs microphone access to capture your voice for dictation.</string>
```

## 6. Data flow

```
User taps mic
    │
    ▼
ChatScreenViewModel.handleMicTap()
    │ committedComposerText ← composerText (freeze prefix)
    ▼
VoiceInputController.toggle()
    │ service.requestPermissions()  ──► .denied? → state = .denied → banner
    │ service.isAvailable()          ──► false?   → state = .unavailable → banner
    │ ▼ both OK
    │ state = .listening
    │ streamTask = Task { for try await event in service.startRecognition(locale:) { ... } }
    ▼
SpeechRecognizerVoiceInputService streams events
    │ .partial(text) → controller.partialTranscript = text  ──► SwiftUI re-renders ChatScreen
    │ .final(text)   → controller.onFinalTranscript?(text)
    │                  controller.partialTranscript = ""
    │                  controller.state = .idle
    │ throws         → controller.state = .failed(reason) → banner
    ▼
User taps stop OR silence-timeout fires
    │ controller.stop() cancels streamTask
    │ stream's onTermination tears down audio engine + recognition task
    │ service emits one final .final or .failed(.silenceTimeout)
    ▼
View-model callback writes final into committedComposerText
composerText now reflects the committed text; user can edit + send normally
```

## 7. Error handling

| Trigger | `controller.state` | UI surface |
|---|---|---|
| First tap, user denies either permission | `.denied` | Error banner above composer with copy + "Settings" action button |
| First tap, both permissions previously denied | `.denied` (immediate, no prompt re-shown) | Same banner |
| `SFSpeechRecognizer.isAvailable == false` at controller init | `.unavailable` | Mic button rendered dimmed + disabled; tap is a no-op |
| `SFSpeechRecognizer` becomes unavailable mid-session | `.failed("Recognition unavailable. Try again.")` | Banner; mic returns to idle |
| `AVAudioEngine` fails to start (audio-session conflict) | `.failed("Microphone unavailable — close other audio apps.")` | Banner; mic returns to idle |
| 30s silence timeout | Treated as normal stop | Final transcript (last partial) commits; controller returns to `.idle`; no banner |

Banner copy strings live alongside the controller for centralized review and i18n later.

## 8. Accessibility

- `recordingButton` pulse overlay guarded by `@Environment(\.accessibilityReduceMotion)` — when true, render the stop button without the pulse.
- VoiceOver labels/hints on all three button states (`micButton`, `recordingButton`, `micButtonDimmed`).
- While recording, the composer's `TextField` carries `.accessibilityValue(committedComposerText)` and `.accessibilityHint("Recording. Double-tap stop to commit.")` so VoiceOver doesn't re-announce every partial. Once recording ends, normal accessibility resumes.
- Banner action button: `.accessibilityLabel("Open Settings")`.

## 9. Testing

### 9.1 Unit — `VoiceInputControllerTests.swift` (new)

Mirrors `CodeBlockCopyControllerTests` style: injected `FakeVoiceInputService` with `CheckedContinuation`-driven event injection.

| Test | Asserts |
|---|---|
| `toggleStartsListeningWhenPermissionsGranted` | `idle → .listening`; `service.startRecognition` called once |
| `toggleStopsListeningOnSecondCall` | `.listening → .idle`; stream task cancelled |
| `permissionDeniedSetsDeniedState` | Fake returns `.denied` → controller `.denied`, no stream started |
| `serviceUnavailableSetsUnavailableState` | Fake `isAvailable == false` → controller boots into `.unavailable` |
| `partialTranscriptReflectsServiceEvents` | Three `.partial` events update `partialTranscript` in order |
| `finalEventCommitsViaCallback` | `onFinalTranscript` fires once with final text; state → `.idle`; partial clears |
| `streamFailureSetsFailedState` | Fake throws `.recognizerFailed("x")` → state `.failed("x")`, partial clears |
| `silenceTimeoutCommitsLastPartial` | `.partial("hello")` then `.failed(.silenceTimeout)` → `onFinalTranscript("hello")`; state `.idle`; no banner |
| `rapidToggleDoesNotDoubleStart` | Two `toggle()` inside the same task tick → exactly one `startRecognition` call |

### 9.2 Unit — `ChatScreenViewModelTests.swift` (extend)

| Test | Asserts |
|---|---|
| `micTapFreezesPrefixAndForwardsToggle` | `handleMicTap()` copies `composerText` into `committedComposerText` and forwards to `voice.toggle()` |
| `finalTranscriptAppendsToComposerText` | After `voice.onFinalTranscript("hello")` fires, `composerText == "<committed prefix> hello"`; `committedComposerText == ""` |
| `voiceStateDeniedSetsErrorBanner` | `handleVoiceStateChange(.denied)` → `error.actionLabel == "Settings"`, `error.action != nil` |
| `voiceStateFailedSetsErrorBanner` | `handleVoiceStateChange(.failed("x"))` → `error.message` contains `"x"`, `error.actionLabel == nil` |
| `voiceStateUnavailableLeavesErrorAlone` | `handleVoiceStateChange(.unavailable)` doesn't touch `error` (dimmed mic suffices) |

### 9.3 Snapshot — `ChatComposerSnapshotTests.swift` (extend)

- `composer_recording_light` — recording state, first frame of pulse, light theme
- `composer_recording_dark` — recording state, dark theme
- `composer_recording_reduce_motion` — recording with `\.accessibilityReduceMotion` true (no pulse overlay)
- `composer_mic_unavailable_light` — dimmed mic + disabled
- `composer_recording_xxl` — recording state at Dynamic Type XXL

### 9.4 Snapshot — `MessageListViewSnapshotTests.swift` (extend)

- `list_error_banner_with_action_light` — banner with the new "Settings" action button

### 9.5 Test helper — `FakeVoiceInputService.swift` (new, `Tests/ChatTests/Voice/Helpers/`)

In-memory implementation with knobs for `permissionStatus`, `isAvailableValue`, and a `CheckedContinuation`-driven event injector. Same shape as the M10 `SleepGate` helper.

### 9.6 Production service — not unit-tested

`SpeechRecognizerVoiceInputService` itself isn't unit-tested — `SFSpeechRecognizer` and `AVAudioEngine` can't be sensibly mocked. We rely on (a) controller-level coverage with the fake, plus (b) manual verification on simulator (§10).

### 9.7 Coverage

Per `AGENTS.md` §Testing.2: applets ≥70%. The controller and the view-model wiring (the parts we own and can test) constitute the majority of new logic. The production service is a thin adapter — manual gate suffices.

## 10. Manual verification (gate before marking M11 done)

1. `swift test` from `Packages/Chat/` → all green.
2. `xcodebuild -scheme Super build` clean.
3. Install on iPhone 17 sim (UUID `472D292D-71F0-4D2B-ADFC-C5D5BAF14450`).
4. Tap mic → grant both permissions → speak "hello there how are you" → tap stop → confirm transcript appears in composer.
5. Tap send → confirm message dispatches normally.
6. Sim Settings → revoke Speech Recognition → re-tap mic → confirm banner with "Settings" button → tap it → confirm iOS Settings opens.
7. Toggle Reduce Motion in sim Accessibility → tap mic → confirm no pulse overlay (button still flips to stop).
8. Tap mic → wait silently 30s → confirm controller auto-stops, state returns to `.idle` (composer either empty or contains whatever the recognizer captured).

## 11. Open questions (none blocking)

- **Pattern terminology** (memory: `feedback_pattern_terminology`): we'll codify `*Controller` vs `*ViewModel` vs `*Service` in `Packages/Chat/CLAUDE.md` in a follow-up before adding more Controller-style classes.
- **Locale picker in Settings**: deferred to M12 polish if user demand surfaces.
- **Audio session category coordination**: production service will use `.playAndRecord` with `.measurement` mode; revisit if/when we add a TTS / audio-output feature.

## 12. Out of scope (intentionally not doing)

- Wake word / continuous listening
- Cloud STT / Whisper
- Voice output (TTS)
- Locale picker UI
- Sound input level meter / waveform
- Multi-recording (concurrent dictation across screens)
