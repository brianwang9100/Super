import SwiftUI

/// Persisted assistant turn: optional thinking trace, any tool calls, and
/// the rendered markdown text with a Copy/Regenerate action row beneath
/// (only when there's actual text to copy).
struct AssistantMessage: View {
    let thinking: String?
    let thinkingDurationMs: Int?
    let text: String
    let toolCalls: [MessageList.ToolCallItem]
    /// Web sources this turn cited (native or standalone search). Rendered as
    /// the collapsible "N sources" pill below the answer; empty hides it.
    var sources: [SourceCitationPillModel] = []
    let verbosity: ChatVerbosity
    /// Disables Regenerate while a turn is mid-stream. Copy stays
    /// enabled — copying text from an older response during a new one
    /// is harmless.
    var isStreaming: Bool = false
    /// Fired when the user taps Copy. The host is responsible for both
    /// writing to the pasteboard and surfacing the transient
    /// confirmation pill so the side effects stay co-located in
    /// ``ChatScreen``.
    var onCopyTapped: () -> Void = {}
    /// Fired when the user taps Regenerate. The host stages a
    /// confirmation dialog before actually trimming the transcript and
    /// re-streaming.
    var onRegenerateRequested: () -> Void = {}
    @Environment(\.superTheme) private var theme
    @Environment(\.chatAppearance) private var appearance

    var body: some View {
        // Some providers emit a stray newline or single space alongside a
        // tool call, so `text.isEmpty` would return false even though
        // there's nothing to show. Trim before gating so tool-call-only
        // turns reliably hide the body text + action row.
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            if let thinking, !thinking.isEmpty {
                ThinkingBlock(
                    text: thinking,
                    durationSource: .finished(durationMs: thinkingDurationMs),
                    verbosity: verbosity
                )
            }
            ForEach(toolCalls) { call in
                // Successful `memory` calls collapse into the friendlier
                // inline pill — the verbose tool-call card is overkill
                // for a one-line preference write. Failures still hit
                // the generic card so the error surface stays consistent.
                if call.toolName == MemoryTool.toolID, call.status == .success {
                    MemoryUpdatedPill(call: call)
                } else {
                    ToolCallBlock(call: call, verbosity: verbosity)
                }
            }
            if hasText {
                MarkdownText(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                // Copy + Regenerate only attach to a row that actually has
                // text — for tool-call-only or thinking-only turns there's
                // nothing to copy and the next turn carries the real reply,
                // so the action row would just be visual noise.
                HStack(spacing: 4) {
                    MessageActionButton(
                        systemName: "doc.on.doc",
                        label: "Copy",
                        action: onCopyTapped
                    )
                    MessageActionButton(
                        systemName: "arrow.clockwise",
                        label: "Regenerate",
                        action: onRegenerateRequested,
                        disabled: isStreaming
                    )
                }
            }
            // Citations sit below the answer (and its action row), mirroring
            // the way a grounded reply reads: claim first, sources after.
            if !sources.isEmpty {
                SourceCitationsPill(sources: sources)
            }
        }
        .padding(.vertical, appearance.assistantRowVerticalPadding)
    }
}
