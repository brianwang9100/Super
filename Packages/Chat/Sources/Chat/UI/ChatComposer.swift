import Core
import SwiftUI

/// Snapshot seam: SwiftUI's accessibilityReduceMotion environment value is read-only.
private struct ChatComposerReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var chatComposerReduceMotionOverride: Bool? {
        get { self[ChatComposerReduceMotionOverrideKey.self] }
        set { self[ChatComposerReduceMotionOverrideKey.self] = newValue }
    }
}

public struct ChatComposer: View {
    @Binding public var text: String
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
    /// Zero is the minimized pill; one is the full editor. Intermediate values drive the morph.
    public let progress: Double

    public let references: [VerseReferencePillModel]
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
    @Environment(\.superTypography) private var typography
    /// System faces ignore relativeTo, so ScaledMetric adds Dynamic Type to app font scaling.
    @ScaledMetric(relativeTo: .subheadline) private var editorBase: CGFloat = 17
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.chatComposerReduceMotionOverride) private var reduceMotionOverride
    @Environment(\.hapticsEngine) private var hapticsEngine
    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: CGFloat = 0.6

    #if DEBUG
    @Environment(\.chatComposerPreviewPulse) private var previewPulse
    #endif

    private var recordingPulseScale: CGFloat {
        #if DEBUG
        if let previewPulse { return previewPulse.scale }
        #endif
        return pulseScale
    }

    private var recordingPulseOpacity: CGFloat {
        #if DEBUG
        if let previewPulse { return previewPulse.opacity }
        #endif
        return pulseOpacity
    }

    private var shouldAnimateRecordingPulse: Bool {
        #if DEBUG
        ChatComposerPreviewPulse.shouldAnimate(reduceMotion: reduceMotion, override: previewPulse)
        #else
        !reduceMotion
        #endif
    }

    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasContent: Bool { !trimmed.isEmpty }

    // Delay the footer until the morph provides space; show the backdrop with the transcript.

    private var pillLabelOpacity: Double {
        1 - Self.smoothstep(progress, from: 0, to: 0.2)
    }

    private var editorOpacity: Double {
        Self.smoothstep(progress, from: 0, to: 0.2)
    }

    private var footerOpacity: Double {
        Self.smoothstep(progress, from: 0.15, to: 0.45)
    }

    private var footerHeight: CGFloat {
        CGFloat(footerOpacity) * 34
    }

    /// Let taps and drags reach the pill overlay while the editor is barely visible.
    private var editorInteractive: Bool {
        progress > ChatPresentationState.editorInteractiveThreshold && !isRecording
    }

    private var gradientOpacity: Double {
        Self.smoothstep(progress, from: 0.3, to: 0.6)
    }

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

    private var outerTopPadding: CGFloat { Self.lerp(progress, 0, 10) }
    private var outerSidePadding: CGFloat { Self.lerp(progress, 16, 16) }
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
            // ChatScreen.verticalMaskBleed leaves room for this glass shadow over the applet.
            .superGlassSurface(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(isFocused ? theme.border : theme.borderFaint, lineWidth: 1)
            )
            .shadow(color: focusGlowColor, radius: 4, x: 0, y: 0)
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
        // New Chat intentionally plays creation feedback first, then focus feedback when ready to type.
        .onChange(of: isFocused) { _, focused in
            if focused { hapticsEngine.play(.selection) }
        }
    }

    private var focusGlowColor: Color {
        isFocused ? theme.accent.opacity(0.12) : .clear
    }

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
            // Share one slot to keep the trailing button and row height stable through the morph.
            Text("Chat with Super")
                .font(typography.font(size: editorBase))
                .foregroundStyle(theme.inkFaint)
                .opacity(pillLabelOpacity)
                .allowsHitTesting(false)
                .padding(.vertical, 4)
            editor
                .opacity(editorOpacity)
                .disabled(!editorInteractive)
                // Exclude the invisible editor from VoiceOver.
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
        .font(typography.font(size: editorBase))
        .foregroundStyle(theme.ink)
        .tint(theme.accent)
        .focused($isFocused)
        .submitLabel(.return)
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
        .clipped()
        // Prevent interaction with the collapsed footer.
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
                .font(typography.font(.callout, weight: .bold))
                .foregroundStyle(theme.accentInk)
                .frame(width: 34, height: 34)
                .superGlassCTAButton(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Send message")
    }

    private var micButton: some View {
        Button(action: onMicTap) {
            Image(systemName: "mic")
                .font(typography.font(.callout))
                .foregroundStyle(theme.inkSoft)
                .frame(width: 34, height: 34)
                .superGlassButton(in: Circle())
        }
        .buttonStyle(GlassHapticButtonStyle(.selection))
        .accessibilityLabel("Voice input")
    }

    private var micButtonDimmed: some View {
        Button(action: {}) {
            Image(systemName: "mic.slash")
                .font(typography.font(.callout))
                .foregroundStyle(theme.inkSoft.opacity(0.4))
                .frame(width: 34, height: 34)
                .superGlassSurface(in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(true)
        .accessibilityLabel("Voice input unavailable")
        .accessibilityHint("On-device speech recognition isn't available for your language.")
    }

    private var recordingButton: some View {
        Button(action: onStopRecording) {
            Image(systemName: "stop.fill")
                .font(typography.font(.callout, weight: .bold))
                .foregroundStyle(theme.accentInk)
                .frame(width: 34, height: 34)
                .superGlassCTAButton(in: Circle())
                .overlay {
                    if !reduceMotion {
                        Circle()
                            .stroke(theme.accent.opacity(recordingPulseOpacity), lineWidth: 2)
                            .scaleEffect(recordingPulseScale)
                    }
                }
        }
        .buttonStyle(GlassHapticButtonStyle(.selection))
        .accessibilityLabel("Stop recording")
        .accessibilityHint("Double-tap to stop voice input and insert the transcript.")
        .onAppear {
            guard shouldAnimateRecordingPulse else { return }
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                pulseScale = 1.5
                pulseOpacity = 0
            }
        }
    }

    private var cancelButton: some View {
        Button(action: onCancelStreaming) {
            Image(systemName: "stop.fill")
                .font(typography.font(.subheadline, weight: .bold))
                .foregroundStyle(theme.accentInk)
                .frame(width: 34, height: 34)
                .superGlassCTAButton(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop generating")
    }

    private func submit() {
        let value = trimmed
        guard !value.isEmpty else { return }
        onSubmit(value)
    }

    private static func lerp(_ t: Double, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, t))
        return a + (b - a) * CGFloat(clamped)
    }

    /// Smooth endpoints avoid the visual kink of a linear opacity ramp.
    private static func smoothstep(_ value: Double, from: Double, to: Double) -> Double {
        guard to > from else { return value >= to ? 1 : 0 }
        let t = min(1, max(0, (value - from) / (to - from)))
        return t * t * (3 - 2 * t)
    }
}
