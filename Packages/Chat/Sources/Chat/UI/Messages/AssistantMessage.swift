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
    /// Gemini's mandatory "Google Search Suggestions" HTML, present only on a
    /// grounded Gemini turn. Rendered unmodified and always visible (not
    /// collapsible) per Google's grounding terms; nil hides it.
    var searchSuggestionsHTML: String? = nil
    /// Search-engine label + query for the expandable "Web search" cell
    /// (`nil` when this turn ran no search).
    var searchSystem: String? = nil
    var searchQuery: String? = nil
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
    /// Fired with the parked `request_web_search` tool-call id when the user
    /// approves the inline search prompt ("Search").
    var onConfirmSearch: (String) -> Void = { _ in }
    /// Fired with the parked tool-call id when the user declines ("Skip").
    var onSkipSearch: (String) -> Void = { _ in }
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
                // The native web-search proposal renders its own inline
                // approve/skip prompt (and post-decision summary) instead of
                // the generic card — the internal `request_web_search` name +
                // JSON args would otherwise leak into the transcript.
                if call.toolName == NativeWebSearch.proposalToolName {
                    SearchConfirmationRow(
                        call: call,
                        onSearch: { onConfirmSearch(call.id) },
                        onSkip: { onSkipSearch(call.id) }
                    )
                // Successful `memory` calls collapse into the friendlier
                // inline pill — the verbose tool-call card is overkill
                // for a one-line preference write. Failures still hit
                // the generic card so the error surface stays consistent.
                } else if call.toolName == MemoryTool.toolID, call.status == .success {
                    MemoryUpdatedPill(call: call)
                } else {
                    ToolCallBlock(call: call, verbosity: verbosity)
                }
            }
            // A turn that searched the web — evidenced by cited sources *or*
            // the captured query/system metadata — announces it with a
            // tool-call-style cell above the answer (sequence: search call →
            // grounded answer → sources). Gating on the metadata too (not just
            // `sources`) means an approved search that returned *zero* results
            // still leaves a record in the transcript rather than vanishing.
            if !sources.isEmpty || searchQuery != nil || searchSystem != nil {
                WebSearchCallCell(
                    system: searchSystem,
                    query: searchQuery,
                    sourceCount: sources.count
                )
            }
            if hasText {
                MarkdownText(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Google's required Search-Suggestions strip sits directly under a
            // grounded Gemini answer (always visible, unmodified). It precedes
            // our own collapsible sources pill.
            if let searchSuggestionsHTML, !searchSuggestionsHTML.isEmpty {
                GeminiSearchSuggestionsView(html: searchSuggestionsHTML)
            }
            // Citations sit below the answer, as a tool-call-style collapsible
            // card: claim first, sources after.
            if !sources.isEmpty {
                SourceCitationsPill(sources: sources)
            }
            // Copy + Regenerate sit at the very bottom of the turn — beneath the
            // sources card — and only attach to a row that actually has text
            // (tool-call-only or thinking-only turns have nothing to copy, and
            // the next turn carries the real reply).
            if hasText {
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
        }
        .padding(.vertical, appearance.assistantRowVerticalPadding)
    }
}
