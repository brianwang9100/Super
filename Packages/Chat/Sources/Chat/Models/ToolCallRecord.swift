import Core
import Foundation
import GRDB

/// Lifecycle of a single tool invocation requested by the assistant.
///
/// `awaitingConfirmation` is the pause used for destructive actions: the
/// session writes the row in this state and yields a UI (User Interface)
/// event, then resumes when the user approves or rejects.
public enum ToolCallStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case executing
    case success
    case failed
    case cancelled
    case awaitingConfirmation
}

/// A single tool call requested by the assistant within a conversation.
///
/// `id` is the locally-unique primary key. For providers that supply a
/// tool-use id (Anthropic `toolu_…`, OpenAI `call_…`, modern Gemini) it *is*
/// that wire id, so the call round-trips into the next assistant turn
/// unchanged. For legacy id-less Gemini calls the orchestrator mints a
/// locally-unique, marked id (see `locallyMintedID`) so two turns calling the
/// same tool can't collide on this PK — the wire still carries name-only for
/// those (the Gemini adapter recognizes the marker). `parameters` and
/// `result` are JSON (JavaScript Object Notation) strings rather than
/// `JSONValue` so the row codec stays trivial; callers serialize at the
/// boundary. `conversationId` is denormalized off `messageId` so per-
/// conversation queries don't need a join.
public struct ToolCallRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "toolCall"

    /// Prefix marking a tool-call id we minted locally because the provider
    /// supplied none (legacy id-less Gemini calls, where the stream reducer
    /// falls back to the tool name). Distinct from every provider's id shape
    /// (`toolu_`, `call_`, Gemini's opaque tokens) so the Gemini adapter can
    /// recognize a synthetic id and still emit name-only on the wire — a
    /// fabricated id must never reach Gemini, which round-trips the ids it
    /// minted. Strict providers (Anthropic/OpenAI) receive the marked id
    /// verbatim: they require unique `tool_use` ids and the marker is just a
    /// unique string to them.
    public static let locallyMintedIDPrefix = "localtoolu_"

    /// Compose a locally-minted tool-call id from a unique raw token (typically
    /// an injected id generator's next value).
    public static func locallyMintedID(_ raw: String) -> String { locallyMintedIDPrefix + raw }

    /// Whether `id` was minted locally (provider supplied no tool-use id).
    public static func isLocallyMintedID(_ id: String) -> Bool { id.hasPrefix(locallyMintedIDPrefix) }

    public var id: String
    public var messageId: String
    public var conversationId: String
    public var toolName: String
    public var parameters: String
    public var result: String?
    public var status: ToolCallStatus
    public var createdAt: Date
    public var completedAt: Date?
    /// Opaque provider continuation token for the call (today Gemini's
    /// `thoughtSignature`). Persisted so it survives the DB round-trip the turn
    /// loop makes between requesting a tool and replaying the assistant turn,
    /// and is echoed back on the next `functionCall` — Gemini's thinking models
    /// reject a replay that omits it. `nil` for providers that emit none.
    public var signature: String?

    public init(
        id: String,
        messageId: String,
        conversationId: String,
        toolName: String,
        parameters: String,
        result: String? = nil,
        status: ToolCallStatus,
        createdAt: Date,
        completedAt: Date? = nil,
        signature: String? = nil
    ) {
        self.id = id
        self.messageId = messageId
        self.conversationId = conversationId
        self.toolName = toolName
        self.parameters = parameters
        self.result = result
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.signature = signature
    }
}

extension ToolCallRecord {
    /// Decode `parameters` into a `JSONValue`. Throws if the column does
    /// not hold valid JSON (JavaScript Object Notation) — should not
    /// happen for rows the session orchestrator wrote, since it serializes
    /// via `encode(_:)` below, but worth surfacing instead of crashing
    /// when a corrupted database is opened.
    public func decodedParameters() throws -> JSONValue {
        try decode(parameters)
    }

    /// Decode `result` into a `JSONValue`, or nil if the call hasn't
    /// completed yet.
    public func decodedResult() throws -> JSONValue? {
        guard let result else { return nil }
        return try decode(result)
    }

    /// Encode a `JSONValue` to the canonical string form stored in the
    /// `parameters` and `result` columns. Use this at the write boundary
    /// so every row uses the same encoder settings.
    public static func encode(_ value: JSONValue) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ToolCallCodecError.invalidUTF8
        }
        return string
    }

    private func decode(_ string: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
    }
}

/// Errors thrown by `ToolCallRecord`'s JSON codec helpers.
public enum ToolCallCodecError: Error, Sendable, Equatable {
    /// Encoder produced bytes that aren't valid UTF-8 — should not happen
    /// for `JSONValue` (JSON text is UTF-8 by spec), but the conversion
    /// is fallible at the type level.
    case invalidUTF8
}
