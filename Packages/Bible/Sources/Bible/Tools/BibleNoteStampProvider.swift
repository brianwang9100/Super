import Foundation

/// Model provenance belongs to the active session and must not come from tool input.
public protocol BibleNoteStampProvider: Sendable {
    func stamp() -> BibleNoteStamp
}

public struct BibleNoteStamp: Sendable, Equatable {
    public let source: BibleNoteSource
    public let modelId: String?

    public init(source: BibleNoteSource, modelId: String?) {
        self.source = source
        self.modelId = modelId
    }
}

/// Stamps assistant authorship with no model attribution; inject a session provider when available.
public struct DefaultBibleNoteStampProvider: BibleNoteStampProvider {
    public init() {}
    public func stamp() -> BibleNoteStamp {
        BibleNoteStamp(source: .assistant, modelId: nil)
    }
}
