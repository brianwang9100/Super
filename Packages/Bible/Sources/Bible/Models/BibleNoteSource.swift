import Foundation

/// Who wrote a note.
///
/// `.user` is a note the reader typed in the editor. `.assistant` is a note
/// the chat assistant wrote through the `bible.note` tool — the only source
/// that carries a non-nil `modelId`, and the only one that shows a provenance
/// footer ("Written by …") on its card.
public enum BibleNoteSource: String, Codable, Sendable, Equatable, CaseIterable {
    case user
    case assistant
}
