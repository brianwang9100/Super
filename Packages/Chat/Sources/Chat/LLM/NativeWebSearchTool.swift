import Core
import Foundation

/// Shared convention for asking a native provider to enable its own
/// server-side web search on a turn, without changing the frozen
/// `LLMProvider.stream(messages:model:tools:temperature:)` signature.
///
/// `ChatSession` includes a sentinel `LLMTool` named ``sentinelToolName`` in
/// the `tools` array when search should be active for the turn (the cost-gate
/// wiring that decides *when* lands in a later PR). Each native adapter
/// recognizes the name, translates it into that provider's server-tool
/// descriptor (`{"type":"web_search"}`, `{"google_search":{}}`, …), and strips
/// it from the normal function-tool list. Non-native adapters never see it.
enum NativeWebSearch {
    /// Reserved tool name flagging "enable native web search this turn". The
    /// double-underscore marks it as an internal protocol token, not a tool
    /// the model is ever shown.
    static let sentinelToolName = "__native_web_search__"

    /// Partition advertised tools into the client `function` tools and a flag
    /// for whether the native-search sentinel was present. Shared by the
    /// native adapters so they recognize the sentinel identically.
    static func partition(_ tools: [LLMTool]) -> (clientTools: [LLMTool], searchEnabled: Bool) {
        var clientTools: [LLMTool] = []
        var searchEnabled = false
        for tool in tools {
            if tool.name == sentinelToolName {
                searchEnabled = true
            } else {
                clientTools.append(tool)
            }
        }
        return (clientTools, searchEnabled)
    }
}
