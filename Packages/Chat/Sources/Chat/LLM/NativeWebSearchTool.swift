import Core
import Foundation

/// Shared convention for the native web-search cost gate and for asking a
/// native provider to enable its own server-side web search on a turn,
/// without changing the frozen
/// `LLMProvider.stream(messages:model:tools:temperature:)` signature.
///
/// Two tool names travel in the `tools` array:
///
/// - ``sentinelToolName`` (``sentinelTool``) — an internal token the
///   `ChatSession` turn loop appends when native search should run *this
///   turn*. Each native adapter recognizes it via ``partition(_:)``,
///   translates it into that provider's server-tool descriptor
///   (`{"type":"web_search"}`, `{"google_search":{}}`, …), and strips it
///   from the normal function-tool list. The model never sees it.
/// - ``proposalToolName`` (``proposalTool``) — a real client function the
///   model *does* see, used only while the cost gate is ON. The model calls
///   `request_web_search(query, reason)` instead of searching directly; the
///   turn loop parks that call at `.awaitingConfirmation`, and on approval
///   re-issues the turn with the sentinel instead. See `ChatSession`'s turn
///   loop for the gate mechanics and `docs/superpowers/specs/`
///   `2026-05-31-native-web-search-providers-design.md` §7.
enum NativeWebSearch {
    /// `ModelConfiguration.searchBackend` / `LLMModel.searchBackend` value
    /// that selects a provider's own server-side search. Stays an untyped
    /// string until a PR first *branches* on the full value set (it gains
    /// `"tavily"`/`"brave"` in the standalone-search phase); centralized
    /// here so the comparison isn't a scattered magic literal.
    static let nativeBackendValue = "native"

    /// Whether the active model opted into the provider's native web search.
    /// The native adapter stamps `searchBackend` onto the `LLMModel` it
    /// vends (from its `ModelConfiguration`), so the turn loop reads it off
    /// the model it already holds — no new `send(...)` parameter.
    static func usesNativeSearch(_ model: LLMModel) -> Bool {
        model.searchBackend == nativeBackendValue
    }

    /// `searchBackend` value selecting the DEBUG client-side mock backend —
    /// canned search results fulfilled in-process by a `WebSearchFulfilling`
    /// rather than the model's own provider. Lets the full search flow (cost
    /// gate → confirm row → sources pill) run against *any* model with no
    /// real search calls. Only ever set on a model in DEBUG builds, but the
    /// constant lives here (not behind `#if DEBUG`) so the turn-loop branch
    /// that reads it is plain, testable production code.
    static let mockBackendValue = "debug"

    /// Whether the active model opted into the client-side mock search
    /// backend. Mutually exclusive with ``usesNativeSearch(_:)`` — a model
    /// carries one `searchBackend` value.
    static func usesMockSearch(_ model: LLMModel) -> Bool {
        model.searchBackend == mockBackendValue
    }

    // MARK: - Sentinel (search active this turn)

    /// Reserved tool name flagging "enable native web search this turn". The
    /// double-underscore marks it as an internal protocol token, not a tool
    /// the model is ever shown.
    static let sentinelToolName = "__native_web_search__"

    /// The sentinel as an `LLMTool` the turn loop appends to the advertised
    /// tools. Carries no parameters and an empty description — every native
    /// adapter strips it before serializing the request, so the model never
    /// receives it.
    static let sentinelTool = LLMTool(
        id: sentinelToolName,
        name: sentinelToolName,
        description: "",
        category: .system,
        parameters: [],
        appletId: "chat"
    )

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

    // MARK: - Proposal (cost gate ON)

    /// Name of the client-side proposal tool the model calls to *request* a
    /// search while the cost gate is ON. The turn loop intercepts a call to
    /// this name (it is never registered with `ToolRegistry`) and parks it
    /// at `.awaitingConfirmation` for user approval.
    static let proposalToolName = "request_web_search"

    /// Parameter name carrying the model's single proposed search query.
    static let proposalQueryParameter = "query"

    /// Parameter name carrying the model's one-sentence justification.
    static let proposalReasonParameter = "reason"

    /// The `request_web_search(query, reason)` proposal tool advertised to
    /// the model while the gate is ON. A `.query` category since it proposes
    /// a read-only search; the actual side effect (and its cost) only occurs
    /// after the user approves and the turn is re-issued with the sentinel.
    static let proposalTool = LLMTool(
        id: proposalToolName,
        name: proposalToolName,
        description: """
        Request permission to search the web. Call this only when answering \
        well requires current, post-training, or fast-changing facts that you \
        do not already know. Provide a single best search query and a \
        one-sentence reason. Do not answer the user yet — wait for the search \
        result before responding.
        """,
        category: .query,
        parameters: [
            LLMToolParameter(
                name: proposalQueryParameter,
                type: .string,
                description: "The single best web-search query to run.",
                isRequired: true
            ),
            LLMToolParameter(
                name: proposalReasonParameter,
                type: .string,
                description: "One sentence on why a web search is needed.",
                isRequired: true
            )
        ],
        appletId: "chat"
    )

    /// Pull the proposed query out of a parked `request_web_search` call's
    /// stored parameters JSON for display in the confirm prompt. Returns an
    /// empty string when the model omitted it (the gate still renders).
    static func proposedQuery(fromParametersJSON json: String) -> String {
        proposedFields(fromParametersJSON: json).query
    }

    /// Pull the model's one-sentence reason out of a parked call's stored
    /// parameters JSON. Empty when absent.
    static func proposedReason(fromParametersJSON json: String) -> String {
        proposedFields(fromParametersJSON: json).reason
    }

    /// Decode both proposal fields in a single pass. The confirm row reads
    /// query + reason together every render, so this avoids parsing the JSON
    /// twice. Missing/malformed fields come back as empty strings (the gate
    /// still renders) rather than throwing.
    static func proposedFields(fromParametersJSON json: String) -> (query: String, reason: String) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)),
              case .object(let dict) = value else {
            return ("", "")
        }
        func string(_ name: String) -> String {
            if case .string(let value)? = dict[name] { return value }
            return ""
        }
        return (string(proposalQueryParameter), string(proposalReasonParameter))
    }
}
