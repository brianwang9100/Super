import SwiftUI

/// Internal override for the recording-pulse animation. Defaults to
/// `nil` so the composer uses the system `\.accessibilityReduceMotion`
/// value at render time. Snapshot tests inject a non-nil value because
/// SwiftUI's accessibility env values aren't writable from a test
/// wrapper, so we can't otherwise pin the reduce-motion baseline.
private struct ChatComposerReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var chatComposerReduceMotionOverride: Bool? {
        get { self[ChatComposerReduceMotionOverrideKey.self] }
        set { self[ChatComposerReduceMotionOverrideKey.self] = newValue }
    }
}

/// Rounded composer capsule with a multi-line text editor, the
/// `ChatComposerFooter` row, and a single trailing 34pt circle button that
/// flips between mic (empty composer), send (non-empty), recording-stop
/// (mid-dictation), or cancel (mid-LLM-stream).
///
/// Behavior:
/// - Enter submits; Shift-Enter inserts a newline.
/// - Submitting a slash command (`/compact`, `/...`) is the parent's
///   responsibility; this view just hands the trimmed text up via
///   `onSubmit(_:)`.
/// - Mic taps fire `onMicTap`; while recording the trailing button
///   becomes a stop affordance wired to `onStopRecording`.
/// - When `isMicAvailable == false` the mic renders dimmed + disabled;
///   used for the on-device-recognizer-not-installed case from M11.
///
/// Mirrors `Composer` in `.design-tmp/chat/project/src/chat-view.jsx`.
public struct ChatComposer: View {
    @Binding public var text: String
    /// Focus state owned by the parent (`ChatScreen`) so taps outside the
    /// composer (transcript area, hamburger button) can dismiss the
    /// keyboard by setting this to `false`. The composer mirrors the value
    /// onto its `TextField` via `.focused(...)`.
    @FocusState.Binding public var isFocused: Bool
    public let isStreaming: Bool
    public let isRecording: Bool
    public let isMicAvailable: Bool
    public let modelOptions: [ModelPill.Option]
    public let selectedModelId: String?
    public let onSelectModel: (String) -> Void
    public let onManageModels: () -> Void
    public let verbosity: ChatVerbosity
    public let onSelectVerbosity: (ChatVerbosity) -> Void
    public let usedTokens: Int
    public let maxTokens: Int
    public let onSubmit: (String) -> Void
    public let onMicTap: () -> Void
    public let onStopRecording: () -> Void
    public let onCancelStreaming: () -> Void

    public init(
        text: Binding<String>,
        isFocused: FocusState<Bool>.Binding,
        isStreaming: Bool,
        modelOptions: [ModelPill.Option],
        selectedModelId: String?,
        onSelectModel: @escaping (String) -> Void,
        onManageModels: @escaping () -> Void = {},
        verbosity: ChatVerbosity,
        onSelectVerbosity: @escaping (ChatVerbosity) -> Void,
        usedTokens: Int,
        maxTokens: Int,
        onSubmit: @escaping (String) -> Void,
        onMicTap: @escaping () -> Void = {},
        onCancelStreaming: @escaping () -> Void = {},
        isRecording: Bool = false,
        isMicAvailable: Bool = true,
        onStopRecording: @escaping () -> Void = {}
    ) {
        self._text = text
        self._isFocused = isFocused
        self.isStreaming = isStreaming
        self.isRecording = isRecording
        self.isMicAvailable = isMicAvailable
        self.modelOptions = modelOptions
        self.selectedModelId = selectedModelId
        self.onSelectModel = onSelectModel
        self.onManageModels = onManageModels
        self.verbosity = verbosity
        self.onSelectVerbosity = onSelectVerbosity
        self.usedTokens = usedTokens
        self.maxTokens = maxTokens
        self.onSubmit = onSubmit
        self.onMicTap = onMicTap
        self.onStopRecording = onStopRecording
        self.onCancelStreaming = onCancelStreaming
    }

    @Environment(\.superTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.chatComposerReduceMotionOverride) private var reduceMotionOverride
    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: CGFloat = 0.6

    /// Effective reduce-motion flag — test override wins when set, the
    /// system env value is the default. Lets snapshot tests pin the
    /// no-pulse rendering even though `\.accessibilityReduceMotion`
    /// isn't writable.
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasContent: Bool { !trimmed.isEmpty }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                editor
                HStack(spacing: 4) {
                    ChatComposerFooter(
                        modelOptions: modelOptions,
                        selectedModelId: selectedModelId,
                        onSelectModel: onSelectModel,
                        onManageModels: onManageModels,
                        verbosity: verbosity,
                        onSelectVerbosity: onSelectVerbosity,
                        usedTokens: usedTokens,
                        maxTokens: maxTokens
                    )
                    trailingButton
                }
            }
            .padding(EdgeInsets(top: 10, leading: 16, bottom: 8, trailing: 10))
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(theme.backgroundRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(isFocused ? theme.border : theme.borderFaint, lineWidth: 1)
            )
            .shadow(color: focusGlowColor, radius: 4, x: 0, y: 0)
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 14, trailing: 14))
        .background(
            LinearGradient(
                colors: [theme.background.opacity(0), theme.background],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var focusGlowColor: Color {
        isFocused ? theme.accent.opacity(0.12) : .black.opacity(0.05)
    }

    @ViewBuilder
    private var editor: some View {
        TextField(
            "Chat with Super",
            text: $text,
            axis: .vertical
        )
        .lineLimit(1...6)
        .font(.system(.subheadline))
        .foregroundStyle(theme.ink)
        .tint(theme.accent)
        .focused($isFocused)
        .submitLabel(.send)
        .onSubmit(submit)
        .padding(.vertical, 4)
        .disabled(isRecording)
        .accessibilityHint(isRecording ? "Recording. Double-tap stop to commit." : "")
    }

    @ViewBuilder
    private var trailingButton: some View {
        if isStreaming {
            cancelButton
        } else if isRecording {
            recordingButton
        } else if hasContent {
            sendButton
        } else if !isMicAvailable {
            micButtonDimmed
        } else {
            micButton
        }
    }

    private var sendButton: some View {
        Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.system(.callout).weight(.bold))
                .foregroundStyle(theme.accentInk)
                .frame(width: 34, height: 34)
                .background(Circle().fill(theme.accent))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Send message")
    }

    private var micButton: some View {
        Button(action: onMicTap) {
            Image(systemName: "mic")
                .font(.system(.callout))
                .foregroundStyle(theme.inkSoft)
                .frame(width: 34, height: 34)
                .background(Circle().fill(theme.backgroundSunken))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Voice input")
    }

    /// Dimmed mic for the on-device-recognizer-unavailable case. Same
    /// shape as `micButton` but disabled and painted in faded ink so the
    /// button still anchors the trailing slot without inviting taps.
    private var micButtonDimmed: some View {
        Button(action: {}) {
            Image(systemName: "mic.slash")
                .font(.system(.callout))
                .foregroundStyle(theme.inkSoft.opacity(0.4))
                .frame(width: 34, height: 34)
                .background(Circle().fill(theme.backgroundSunken))
        }
        .buttonStyle(.plain)
        .disabled(true)
        .accessibilityLabel("Voice input unavailable")
        .accessibilityHint("On-device speech recognition isn't available for your language.")
    }

    /// Mid-dictation stop affordance: accent-filled circle with a stop
    /// glyph and an animated outer ring that pulses outward to signal
    /// "still recording." The pulse overlay is suppressed when Reduce
    /// Motion is on; the static button still flips so the user gets the
    /// affordance change either way.
    private var recordingButton: some View {
        Button(action: onStopRecording) {
            Image(systemName: "stop.fill")
                .font(.system(.callout).weight(.bold))
                .foregroundStyle(theme.accentInk)
                .frame(width: 34, height: 34)
                .background(Circle().fill(theme.accent))
                .overlay {
                    if !reduceMotion {
                        Circle()
                            .stroke(theme.accent.opacity(pulseOpacity), lineWidth: 2)
                            .scaleEffect(pulseScale)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop recording")
        .accessibilityHint("Double-tap to stop voice input and insert the transcript.")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                pulseScale = 1.5
                pulseOpacity = 0
            }
        }
    }

    private var cancelButton: some View {
        Button(action: onCancelStreaming) {
            Image(systemName: "stop.fill")
                .font(.system(.subheadline).weight(.bold))
                .foregroundStyle(theme.accentInk)
                .frame(width: 34, height: 34)
                .background(Circle().fill(theme.accent))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop generating")
    }

    private func submit() {
        let value = trimmed
        guard !value.isEmpty else { return }
        onSubmit(value)
    }
}
