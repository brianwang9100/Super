import Core
import Foundation

/// View-facing stream event emitted by `ChatSession`. Translates the
/// transport-level `LLMStreamEvent` into a coarser surface that view models
/// consume directly: text/thinking deltas during streaming, persisted record
/// values once they hit the database, and a single `.error` for any failure
/// path.
///
/// Stream contract: a `ChatSession.send(...)` `AsyncStream<ChatEvent>` always
/// finishes (it never throws). Failures arrive as `.error(...)` immediately
/// before the stream closes, so consumers always get a clean signal that
/// the turn is done and can persist whatever did make it through.
public enum ChatEvent: Sendable, Equatable {
    /// User's outgoing message has been written to the database. Fires once
    /// per `send(...)` call, before any LLM (Large Language Model) round
    /// trip. View models use this to confirm the user's bubble is now
    /// authoritative in GRDB-backed reactive lists.
    case userMessageSaved(MessageRecord)

    /// Streaming text fragment. Accumulate in the view model; the persisted
    /// `MessageRecord` arrives via `.assistantMessageSaved` once the message
    /// completes (per ADR-BB-003 we never write per-delta).
    case textDelta(String)

    /// Streaming reasoning fragment from a thinking-capable model. Same
    /// accumulate-in-view-model pattern as `.textDelta`.
    case thinkingDelta(String)

    /// LLM requested a tool call. Record is already persisted with status
    /// `.pending`. Fires before execution starts so the UI can show a
    /// pending action card immediately.
    case toolCallStarted(ToolCallRecord)

    /// Tool finished successfully. Record is already updated to `.success`
    /// in the database, and a `MessageRecord` with the result has also been
    /// persisted (role `.tool`) so the LLM's next turn sees it in history.
    case toolCallCompleted(ToolCallRecord, ToolResult)

    /// Tool execution failed. Record is `.failed`; an error-content
    /// `MessageRecord` has been written so the LLM can apologize/retry on
    /// the next turn. The string carries the human-readable failure for
    /// the UI's failed-action card.
    case toolCallFailed(ToolCallRecord, String)

    /// Assistant `MessageRecord` (text + token count, no tool blocks) has
    /// been written. Fires once per assistant turn, after `.messageComplete`
    /// from the provider. The view model can clear its streaming buffer at
    /// this point since the canonical row is now in GRDB.
    case assistantMessageSaved(MessageRecord)

    /// Terminal error for the turn. The next thing the consumer's
    /// `for await` loop sees is the stream closing — no further events
    /// will be yielded. Persisted partial state (already-saved messages
    /// and tool calls) is kept; nothing is rolled back.
    case error(LLMError)
}
