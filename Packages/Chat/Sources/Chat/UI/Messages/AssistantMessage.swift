import Core
import SwiftUI

struct AssistantMessage: View {
    let thinking: String?
    let thinkingDurationMs: Int?
    let text: String
    let toolCalls: [MessageList.ToolCallItem]
    var sources: [SourceCitationPillModel] = []
    /// Google requires the grounding suggestions to remain unmodified and always visible.
    var searchSuggestionsHTML: String?
    var searchSystem: String?
    var searchQuery: String?
    let verbosity: ChatVerbosity
    var isStreaming: Bool = false
    var onCopyTapped: () -> Void = {}
    var onRegenerateRequested: () -> Void = {}
    var onConfirmSearch: (String) -> Void = { _ in }
    var onSkipSearch: (String) -> Void = { _ in }
    var thinkingExpansion: Binding<Bool>?
    @Environment(\.superTheme) private var theme
    @Environment(\.chatAppearance) private var appearance

    var body: some View {
        // Providers can emit whitespace alongside tool calls; those turns have no copyable body.
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            if let thinking, !thinking.isEmpty {
                ThinkingBlock(
                    text: thinking,
                    durationSource: .finished(durationMs: thinkingDurationMs),
                    verbosity: verbosity,
                    expansion: thinkingExpansion
                )
            }
            ForEach(toolCalls) { call in
                // Keep internal proposal names and JSON out of the search confirmation UI.
                if call.toolName == NativeWebSearch.proposalToolName {
                    SearchConfirmationRow(
                        call: call,
                        onSearch: { onConfirmSearch(call.id) },
                        onSkip: { onSkipSearch(call.id) }
                    )
                } else if call.toolName == MemoryTool.toolID, call.status == .success {
                    MemoryUpdatedPill(call: call)
                } else {
                    ToolCallBlock(call: call, verbosity: verbosity)
                }
            }
            // Metadata preserves the search record even when it returned no sources.
            if !sources.isEmpty || searchQuery != nil || searchSystem != nil {
                WebSearchCallCell(
                    system: searchSystem,
                    query: searchQuery,
                    sourceCount: sources.count
                )
            }
            if hasText {
                ResponseTextBlock(text: text)
            }
            if let searchSuggestionsHTML, !searchSuggestionsHTML.isEmpty {
                GeminiSearchSuggestionsView(html: searchSuggestionsHTML)
            }
            if !sources.isEmpty {
                SourceCitationsPill(sources: sources)
            }
            if hasText {
                ResponseActions(
                    onCopy: onCopyTapped,
                    onRegenerate: onRegenerateRequested,
                    isRegenerateDisabled: isStreaming
                )
            }
        }
        .padding(.vertical, appearance.assistantRowVerticalPadding)
    }
}
