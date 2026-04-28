import SwiftUI

/// Rounded composer capsule with a multi-line text editor, the
/// `ChatComposerFooter` row, and a single trailing 34pt circle button that
/// flips between mic (empty composer) and send (non-empty).
///
/// Behavior:
/// - Enter submits; Shift-Enter inserts a newline.
/// - Submitting a slash command (`/compact`, `/...`) is the parent's
///   responsibility; this view just hands the trimmed text up via
///   `onSubmit(_:)`.
/// - The mic button is wired through `onMicTap` for M11; for M7 the parent
///   passes a no-op closure.
///
/// Mirrors `Composer` in `.design-tmp/chat/project/src/chat-view.jsx`.
public struct ChatComposer: View {
    @Binding public var text: String
    public let isStreaming: Bool
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
    public let onCancelStreaming: () -> Void

    public init(
        text: Binding<String>,
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
        onCancelStreaming: @escaping () -> Void = {}
    ) {
        self._text = text
        self.isStreaming = isStreaming
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
        self.onCancelStreaming = onCancelStreaming
    }

    @Environment(\.superTheme) private var theme
    @FocusState private var isFocused: Bool

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
    }

    @ViewBuilder
    private var trailingButton: some View {
        if isStreaming {
            cancelButton
        } else if hasContent {
            sendButton
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
