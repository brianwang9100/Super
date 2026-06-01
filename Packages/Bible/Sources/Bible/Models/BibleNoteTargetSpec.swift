import Foundation

/// A fully-specified note target: which book, which chapter (when relevant),
/// which verse range (when relevant).
///
/// Pairs the polymorphic `BibleNoteTarget` discriminator with the IDs needed
/// to address one specific range group. Used as the identity for the note
/// list sheet's `.sheet(item:)`, by the chapter reader when grouping rows for
/// trailing note glyphs, by the book picker and chapter title when a glyph is
/// tapped, and by `BibleScreenViewModel` when it presents the list or composes
/// a new note.
///
/// Deliberately separate from `BibleAnnotationTargetSpec` even though the
/// cases match — notes and annotations are decoupled features, and coupling
/// their specs would let a change to one silently reshape the other (the same
/// rationale `BibleNoteTarget` follows against `BibleAnnotationTarget`).
public enum BibleNoteTargetSpec: Sendable, Equatable, Hashable, Identifiable {
    case book(bookId: String)
    case chapter(bookId: String, chapterNumber: Int)
    case verseRange(bookId: String, chapterNumber: Int, verseStart: Int, verseEnd: Int)

    /// Stable string identity for `.sheet(item:)` and `ForEach` diffing.
    /// Encodes the case discriminator plus its associated values so two
    /// adjacent verse ranges in the same chapter don't collapse.
    public var id: String {
        switch self {
        case .book(let bookId):
            return "book:\(bookId)"
        case .chapter(let bookId, let chapterNumber):
            return "chapter:\(bookId):\(chapterNumber)"
        case .verseRange(let bookId, let chapterNumber, let verseStart, let verseEnd):
            return "verse:\(bookId):\(chapterNumber):\(verseStart):\(verseEnd)"
        }
    }

    /// The corresponding polymorphic-table discriminator.
    public var target: BibleNoteTarget {
        switch self {
        case .book: return .book
        case .chapter: return .chapter
        case .verseRange: return .verse
        }
    }

    public var bookId: String {
        switch self {
        case .book(let bookId),
             .chapter(let bookId, _),
             .verseRange(let bookId, _, _, _):
            return bookId
        }
    }

    public var chapterNumber: Int? {
        switch self {
        case .book: return nil
        case .chapter(_, let n), .verseRange(_, let n, _, _): return n
        }
    }

    public var verseStart: Int? {
        if case .verseRange(_, _, let start, _) = self { return start }
        return nil
    }

    public var verseEnd: Int? {
        if case .verseRange(_, _, _, let end) = self { return end }
        return nil
    }
}

/// A request to present the note list sheet for one range.
///
/// Carries the target range plus whether the editor should open in create
/// mode the instant the list mounts. `autoCompose` distinguishes the two ways
/// a list is opened: a note glyph (filled or outline) means "browse this
/// range's notes" (`false`); the verse-selection "Add note" tile means "write
/// a note here" (`true`), where the list mounts behind the editor so a saved
/// note lands the user on the populated list. Identity is the spec's id so
/// `.sheet(item:)` treats two presentations of the same range as the same
/// sheet.
public struct BibleNoteListPresentation: Sendable, Equatable, Identifiable {
    public let spec: BibleNoteTargetSpec
    public let autoCompose: Bool

    /// Identity folds in `autoCompose` so `.sheet(item:)` re-presents when the
    /// same range is re-requested in a *different* mode — issuing
    /// `composeNote(for:)` for a range whose list is already showing in browse
    /// mode swaps to a fresh presentation that opens the editor, rather than
    /// SwiftUI seeing no identity change and silently leaving the editor shut.
    /// Re-presenting the identical (range, mode) pair is still a no-op, so
    /// there's no flicker on a repeat of the same request.
    public var id: String { "\(spec.id)|\(autoCompose)" }

    public init(spec: BibleNoteTargetSpec, autoCompose: Bool) {
        self.spec = spec
        self.autoCompose = autoCompose
    }
}
