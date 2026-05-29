import Foundation

/// Resolves the `source` and `modelId` a `bible.note` tool call should stamp
/// on the note it writes.
///
/// Notes written through the tool are always assistant-authored, but *which*
/// LLM (Large Language Model) wrote one lives in the active Chat session, not
/// in the tool's input — so it's injected through this seam. Tests substitute
/// a fake to assert stamping without spinning up a real session; the
/// integration milestone (PR 3) wires a provider backed by the active model.
public protocol BibleNoteStampProvider: Sendable {
    func stamp() -> BibleNoteStamp
}

/// Provenance stamp applied to a note a single tool call writes.
public struct BibleNoteStamp: Sendable, Equatable {
    public let source: BibleNoteSource
    public let modelId: String?

    public init(source: BibleNoteSource, modelId: String?) {
        self.source = source
        self.modelId = modelId
    }
}

/// Default provider used in production until the integration milestone (PR 3)
/// wires the active session. Stamps `.assistant` with a nil `modelId` — the
/// card's provenance footer reads "Written by …" once a real provider lands.
public struct DefaultBibleNoteStampProvider: BibleNoteStampProvider {
    public init() {}
    public func stamp() -> BibleNoteStamp {
        BibleNoteStamp(source: .assistant, modelId: nil)
    }
}
