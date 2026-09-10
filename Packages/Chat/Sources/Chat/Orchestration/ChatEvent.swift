import Core
import Foundation

/// Send streams never throw; terminal failures arrive as error before closure.
/// Already-persisted messages and tool calls are not rolled back.
public enum ChatEvent: Sendable, Equatable {
    case userMessageSaved(MessageRecord)

    /// Accumulate deltas in memory; assistantMessageSaved supplies the persisted row.
    case textDelta(String)

    case thinkingDelta(String)

    /// The call is persisted as pending before execution begins.
    case toolCallStarted(ToolCallRecord)

    /// Persisted as awaitingConfirmation; the turn suspends until confirmToolCall or skipToolCall.
    case toolCallAwaitingConfirmation(ToolCallRecord)

    /// The successful call and its tool-result message are already persisted.
    case toolCallCompleted(ToolCallRecord, ToolResult)

    /// The failed call and an error-content tool message are already persisted.
    case toolCallFailed(ToolCallRecord, String)

    /// Fires after `.messageComplete` writes the canonical assistant row.
    case assistantMessageSaved(MessageRecord)

    /// Clear compaction UI on either compactionCompleted or terminal error.
    case compactionStarted

    case compactionCompleted(CompactionCheckpointRecord)

    case error(LLMError)
}
