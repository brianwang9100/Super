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

/// Rounded composer capsule that doubles as the chat's minimized pill at
/// `progress == 0`. Renders:
///
/// - A `ZStack`-stacked editor slot in the top row: a multi-line text
///   editor (visible at full progress) and a "Chat with Super" pill
///   label behind it (visible at low progress). The single trailing
///   34pt circle button morphs between mic (empty composer), send
///   (non-empty), recording-stop (mid-dictation), or cancel (mid-LLM-
///   stream) and stays on this row at every progress so the pill keeps
///   its right-side affordance.
/// - A footer row below the editor — `ChatComposerFooter` (model pill +
///   context meter) — whose opacity and height interpolate with
///   `progress` so the row collapses smoothly to zero in pill mode.
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
/// - At `progress < 0.15` the text editor is disabled so taps fall
///   through to the chat-screen's pill-surface tap-or-drag overlay.
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
    public let usedTokens: Int
    public let maxTokens: Int
    public let onSubmit: (String) -> Void
    public let onMicTap: () -> Void
    public let onStopRecording: () -> Void
    public let onCancelStreaming: () -> Void
    /// `0` renders the composer as the minimized pill ("Chat with Super"
    /// label + mic, no footer); `1` renders the full composer (multi-line
    /// editor, footer with model selector + context meter, send/mic
    /// button). Intermediate values cross-fade the label out and the
    /// editor in, fade the footer's opacity, and collapse its height so
    /// the chat surface resizes smoothly under a drag.
    public let progress: Double

    /// Verse-reference pills attached in the composer. Rendered in a strip
    /// above the text editor; empty for an ordinary message.
    public let references: [VerseReferencePillModel]
    /// Invoked with a pill's id when the user taps its × control.
    public let onRemoveReference: (String) -> Void

    public init(
        text: Binding<String>,
        isFocused: FocusState<Bool>.Binding,
        isStreaming: Bool,
        modelOptions: [ModelPill.Option],
        selectedModelId: String?,
        onSelectModel: @escaping (String) -> Void,
        onManageModels: @escaping () -> Void = {},
        usedTokens: Int,
        maxTokens: Int,
        onSubmit: @escaping (String) -> Void,
        onMicTap: @escaping () -> Void = {},
        onCancelStreaming: @escaping () -> Void = {},
        isRecording: Bool = false,
        isMicAvailable: Bool = true,
        onStopRecording: @escaping () -> Void = {},
        progress: Double = 1,
        references: [VerseReferencePillModel] = [],
        onRemoveReference: @escaping (String) -> Void = { _ in }
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
        self.usedTokens = usedTokens
        self.maxTokens = maxTokens
        self.onSubmit = onSubmit
        self.onMicTap = onMicTap
        self.onStopRecording = onStopRecording
        self.onCancelStreaming = onCancelStreaming
        self.progress = progress
        self.references = references
        self.onRemoveReference = onRemoveReference
    }

    @Environment(\.superTheme) private var theme
    /// The composer's text editor tracks the chat font slider so what the
    /// user types renders at the same size as the message it'll become.
    @Environment(\.chatAppearance) private var appearance
    /// Base editor size declared via `@ScaledMetric` so Dynamic Type
    /// composes with the chat font-scale knob — same pattern as
    /// ``UserBubble``. Plain `appearance.bodyFont` would drop the
    /// Dynamic-Type response the prior `.subheadline` styling had.
    @ScaledMetric(relativeTo: .subheadline) private var editorBase: CGFloat = 17
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

    // MARK: - Progress-driven interpolations
    //
    // The thresholds below tune the crossfade timing so the pill label
    // disappears just as the editor becomes interactive (≈ 0.15), the
    // footer takes a little longer to appear (≈ 0.15 → 0.45) so the row
    // doesn't pop into view before there's vertical space to host it,
    // and the outer gradient backdrop only shows once the transcript
    // above is also coming in (≈ 0.3).

    /// Visible at low progress; faded as the editor takes over.
    private var pillLabelOpacity: Double {
        1 - Self.smoothstep(progress, from: 0, to: 0.2)
    }

    /// Visible at high progress; hidden in pill mode.
    private var editorOpacity: Double {
        Self.smoothstep(progress, from: 0, to: 0.2)
    }

    /// Footer fades in over a wider band than the editor so the model
    /// pill and context meter slide in *after* the editor has settled,
    /// giving the morph a clear "first the text field, then the
    /// metadata" cadence.
    private var footerOpacity: Double {
        Self.smoothstep(progress, from: 0.15, to: 0.45)
    }

    /// Footer row height interpolates from 0 to its intrinsic height so
    /// the row collapses cleanly without leaving an empty slot at low
    /// progress. The intrinsic height tracks the trailing button's
    /// 34pt anchor for the editor row (footer items render slightly
    /// shorter); pinning to 34pt gives ample room for both the
    /// `ModelPill` and the `ContextMeter` per the `chat-view.jsx`
    /// reference.
    private var footerHeight: CGFloat {
        CGFloat(footerOpacity) * 34
    }

    /// Disables the text editor below the threshold so a tap or drag on
    /// the pill surface falls through to the chat-screen overlay rather
    /// than landing on a barely-visible text field.
    private var editorInteractive: Bool {
        progress > ChatPresentationState.editorInteractiveThreshold && !isRecording
    }

    /// Composer outer gradient backdrop — the transcript-to-composer
    /// fade. Hidden in pill mode because there's no transcript above to
    /// fade from; fades in alongside the transcript.
    private var gradientOpacity: Double {
        Self.smoothstep(progress, from: 0.3, to: 0.6)
    }

    /// Faint accent ring around the composer pill — fades in once the
    /// panel surround in `ChatScreen` is taking over the lifted-surface
    /// job. Hidden in pure pill mode (minimized) so the pill reads as a
    /// flat capsule sitting directly on the applet, per the 2026-05-14
    /// design feedback. Without this gate the heavy two-layer shadow
    /// gave the minimized pill a misleading raised look.
    private var pillShadowAlpha: Double {
        Self.smoothstep(progress, from: 0.05, to: 0.15)
            * (1 - Self.smoothstep(progress, from: 0.9, to: 1.0))
    }

    /// Capsule padding interpolates between the prior `MinimizedChatPill`
    /// values (18 horizontal / 12 vertical) and the full composer's
    /// values (16 leading / 10 trailing, 10 top / 8 bottom).
    private var capsuleLeadingPadding: CGFloat {
        Self.lerp(progress, 18, 16)
    }
    private var capsuleTrailingPadding: CGFloat {
        Self.lerp(progress, 18, 10)
    }
    private var capsuleTopPadding: CGFloat {
        Self.lerp(progress, 12, 10)
    }
    private var capsuleBottomPadding: CGFloat {
        Self.lerp(progress, 12, 8)
    }

    /// Outer padding around the capsule: in pill mode the chat-surface
    /// itself is small (no transcript fade above), so we drop the top
    /// padding; in full mode we restore the 10/14 ring that matches the
    /// prior composer.
    private var outerTopPadding: CGFloat { Self.lerp(progress, 0, 10) }
    private var outerSidePadding: CGFloat { Self.lerp(progress, 12, 14) }
    private var outerBottomPadding: CGFloat { Self.lerp(progress, 14, 14) }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                referencesStrip
                HStack(spacing: 4) {
                    editorSlot
                    trailingButton
                }
                footerRow
            }
            .padding(EdgeInsets(
                top: capsuleTopPadding,
                leading: capsuleLeadingPadding,
                bottom: capsuleBottomPadding,
                trailing: capsuleTrailingPadding
            ))
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(theme.backgroundRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(isFocused ? theme.border : theme.borderFaint, lineWidth: 1)
            )
            .shadow(color: focusGlowColor, radius: 4, x: 0, y: 0)
            .shadow(color: Color.black.opacity(0.15 * pillShadowAlpha), radius: 12, x: 0, y: 12)
            .shadow(color: Color.black.opacity(0.10 * pillShadowAlpha), radius: 30, x: 0, y: 24)
        }
        .padding(EdgeInsets(
            top: outerTopPadding,
            leading: outerSidePadding,
            bottom: outerBottomPadding,
            trailing: outerSidePadding
        ))
        .background(
            LinearGradient(
                colors: [theme.background.opacity(0), theme.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .opacity(gradientOpacity)
        )
    }

    private var focusGlowColor: Color {
        isFocused ? theme.accent.opacity(0.12) : .black.opacity(0.05)
    }

    /// Horizontal strip of attached verse-reference pills above the text
    /// editor. Hidden in pill mode (`editorOpacity` near zero) — there's
    /// no room — so references added while the composer is minimized
    /// surface only once it expands. Scrolls horizontally when the pills
    /// overflow the composer width.
    @ViewBuilder
    private var referencesStrip: some View {
        if !references.isEmpty && editorOpacity > 0.05 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(references) { reference in
                        VerseReferencePill(
                            label: reference.label,
                            onRemove: { onRemoveReference(reference.id) }
                        )
                    }
                }
                .padding(.vertical, 1)
            }
            .opacity(editorOpacity)
        }
    }

    @ViewBuilder
    private var editorSlot: some View {
        ZStack(alignment: .leading) {
            // Pill label sits behind the editor in the same slot so the
            // trailing button stays on the right at every progress and
            // the row's height doesn't jump as the morph crosses the
            // transition band.
            Text("Chat with Super")
                .font(.system(size: editorBase * appearance.fontScale))
                .foregroundStyle(theme.inkFaint)
                .opacity(pillLabelOpacity)
                .allowsHitTesting(false)
                .padding(.vertical, 4)
            editor
                .opacity(editorOpacity)
                .disabled(!editorInteractive)
                // Keep the editor out of the accessibility tree below the
                // interactivity threshold so VoiceOver doesn't read an
                // invisible text field over the pill label.
                .accessibilityHidden(!editorInteractive)
        }
    }

    @ViewBuilder
    private var editor: some View {
        TextField(
            "Chat with Super",
            text: $text,
            axis: .vertical
        )
        .lineLimit(1...6)
        .font(.system(size: editorBase * appearance.fontScale))
        .foregroundStyle(theme.ink)
        .tint(theme.accent)
        .focused($isFocused)
        .submitLabel(.send)
        .onSubmit(submit)
        .padding(.vertical, 4)
        .accessibilityHint(isRecording ? "Recording. Double-tap stop to commit." : "")
    }

    @ViewBuilder
    private var footerRow: some View {
        ChatComposerFooter(
            modelOptions: modelOptions,
            selectedModelId: selectedModelId,
            onSelectModel: onSelectModel,
            onManageModels: onManageModels,
            usedTokens: usedTokens,
            maxTokens: maxTokens
        )
        .frame(height: footerHeight, alignment: .top)
        .opacity(footerOpacity)
        // Clip the slot so the partially-faded footer doesn't bleed
        // outside its allotted height during the morph.
        .clipped()
        // Stops VoiceOver/Switch Control from focusing the dropdown when
        // it's visually collapsed in pill mode.
        .allowsHitTesting(footerOpacity > 0.05)
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

    // MARK: - Math helpers

    /// Linear interpolation between `a` and `b` by `t` (clamped to [0, 1]).
    private static func lerp(_ t: Double, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, t))
        return a + (b - a) * CGFloat(clamped)
    }

    /// Hermite (3t² − 2t³) smoothstep mapping `value` from `[from, to]`
    /// onto `[0, 1]`. Outside that band the result clamps. Used to fade
    /// composer subviews around progress milestones without the kink a
    /// linear ramp would leave at the band endpoints.
    private static func smoothstep(_ value: Double, from: Double, to: Double) -> Double {
        guard to > from else { return value >= to ? 1 : 0 }
        let t = min(1, max(0, (value - from) / (to - from)))
        return t * t * (3 - 2 * t)
    }
}
