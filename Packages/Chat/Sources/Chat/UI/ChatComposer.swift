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

/// Return inserts a newline; the send button submits trimmed text for the host to interpret.
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
    /// Collapses the chat through its host. Omit when the composer has no overlay host.
    public let onMinimize: (() -> Void)?
    /// Resizes the host using the same screen-space translation as the top handle.
    public let onDragChanged: ((_ translation: CGSize) -> Void)?
    /// Snaps the host using the drag's final and predicted translations.
    public let onDragEnded: ((_ translation: CGSize, _ predictedEndTranslation: CGSize) -> Void)?
    /// Zero is the minimized pill; one is the full composer. Intermediate values drive the morph.
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
        onMinimize: (() -> Void)? = nil,
        onDragChanged: ((_ translation: CGSize) -> Void)? = nil,
        onDragEnded: ((_ translation: CGSize, _ predictedEndTranslation: CGSize) -> Void)? = nil,
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
        self.onMinimize = onMinimize
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
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
    @GestureState private var isMinimizeDragging = false
    @State private var minimizeDragTranslation: CGSize?

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

    /// Collapse metadata and the minimize target together, leaving no footer space in pill mode.
    /// The 44pt touch target extends beyond its 12pt layout slot.
    private var footerHeight: CGFloat {
        CGFloat(footerOpacity) * (onMinimize == nil ? 34 : 40)
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
        Self.lerp(progress, 12, onMinimize == nil ? 8 : 2)
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
        VStack(spacing: 0) {
            ChatComposerFooter(
                modelOptions: modelOptions,
                selectedModelId: selectedModelId,
                onSelectModel: onSelectModel,
                onManageModels: onManageModels,
                usedTokens: usedTokens,
                maxTokens: maxTokens
            )
            .frame(height: onMinimize == nil ? 34 : 28, alignment: .top)
            // The expanded handle target yields to the model selector above it.
            .zIndex(1)
            minimizeHandle
        }
        .frame(height: footerHeight, alignment: .top)
        .opacity(footerOpacity)
        .clipped()
        // Hide the collapsed dropdown from accessibility while allowing an active drag to finish.
        .allowsHitTesting(footerOpacity > 0.05 || isMinimizeDragging)
        .accessibilityHidden(footerOpacity <= 0.05)
    }

    /// Keep this host mounted while the footer collapses so its drag can end.
    @ViewBuilder
    private var minimizeHandle: some View {
        if onMinimize != nil {
            Color.clear
                .frame(width: ChatDragHandle.barWidth, height: ChatDragHandle.barHeight)
                .superGlassButton(in: ChatDragHandle.barShape, interactive: false)
                // Compensate the target's upward offset to retain 1.5pt visual padding.
                .padding(.top, 17.5)
                .frame(maxWidth: .infinity)
                .frame(height: 44, alignment: .top)
                .contentShape(Rectangle())
                .gesture(minimizeGesture)
                .accessibilityRepresentation {
                    if footerOpacity > 0.95 {
                        Button("Minimize chat", action: minimizeChat)
                            .frame(height: 44)
                            .accessibilityHint("Tap to minimize, or drag up or down to resize chat")
                            .accessibilityIdentifier("chat.composer.minimize")
                    }
                }
                // Keep the full target above the keyboard without adding visible spacing.
                .offset(y: -16)
                .frame(height: 12, alignment: .top)
                // Balance the asymmetric composer insets to center on the chat handle.
                .padding(.trailing, capsuleLeadingPadding - capsuleTrailingPadding)
                .allowsHitTesting(footerOpacity > 0.95 || isMinimizeDragging)
                .onChange(of: isMinimizeDragging) { _, active in
                    if !active { finishCancelledMinimizeDrag() }
                }
                .onDisappear { finishCancelledMinimizeDrag() }
        }
    }

    private var minimizeGesture: some Gesture {
        ChatDragHandle.resizeGesture(minimumDistance: 5)
            .updating($isMinimizeDragging) { _, active, _ in active = true }
            .onChanged { value in
                minimizeDragTranslation = value.translation
                onDragChanged?(value.translation)
            }
            .onEnded { value in
                minimizeDragTranslation = nil
                onDragEnded?(value.translation, value.predictedEndTranslation)
            }
            .exclusively(before: TapGesture().onEnded { minimizeChat() })
    }

    private func minimizeChat() {
        hapticsEngine.play(.selection)
        onMinimize?()
    }

    /// Cancellation settles at the nearest anchor without introducing a flick.
    private func finishCancelledMinimizeDrag() {
        guard let translation = minimizeDragTranslation else { return }
        minimizeDragTranslation = nil
        onDragEnded?(translation, translation)
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
