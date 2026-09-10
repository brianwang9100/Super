import Foundation

/// Assistant notes carry modelId and a provenance footer; user notes do not.
public enum BibleNoteSource: String, Codable, Sendable, Equatable, CaseIterable {
    case user
    case assistant
}
