import Foundation
import Observation

/// Nil title denotes the flat search/alphabetical group.
public struct BibleBookGroup: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String?
    public let books: [BibleBookSummary]

    public init(id: String, title: String?, books: [BibleBookSummary]) {
        self.id = id
        self.title = title
        self.books = books
    }
}

/// Anchor long grids to the current chapter cell so a book-row anchor cannot leave it offscreen.
public enum BibleBookSheetScrollAnchor: Hashable, Sendable {
    case bookRow(bookId: String)
    case chapterCell(bookId: String, chapterNumber: Int)
}

@MainActor
@Observable
public final class BibleBookSheetViewModel: Identifiable {
    /// Stable during one presentation, including search changes.
    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    public var query: String = "" {
        didSet {
            if query != oldValue { autoCollapsedBookId = nil }
        }
    }
    public var order: BibleBookOrder = .traditional
    /// Manual expansion survives filtering out and restoring its book.
    public private(set) var expandedBookId: String?

    // Remember manual collapse of an auto-expanded result until the query changes.
    private var autoCollapsedBookId: String?

    public let currentPosition: BiblePosition?

    private let catalog: BibleBookCatalog

    // Share columns with layout so scroll-anchor arithmetic cannot drift.
    static let chapterGridColumns = 6

    // Eight rows fit at default Dynamic Type. Larger type can still place medium-late
    // chapters below the viewport; a measured-height threshold would be needed to address that.
    private static let chapterGridRowAnchorThreshold = 8

    /// A supplied position opens its book grid; nil starts at the canon's top with all books collapsed.
    public init(currentPosition: BiblePosition?, catalog: BibleBookCatalog = .standard) {
        self.currentPosition = currentPosition
        self.expandedBookId = currentPosition?.bookId
        self.catalog = catalog
    }

    // Cache parsing per query because every row reads expansion state. Still read observed
    // query in the getter so the ignored cache cannot break dependency tracking.
    @ObservationIgnored private var cachedParseInput: String?
    @ObservationIgnored private var cachedParse = BibleSearchQuery(bookNameQuery: "", resolved: nil)
    private var parsed: BibleSearchQuery {
        if cachedParseInput != query {
            cachedParseInput = query
            cachedParse = BibleSearchQueryParser.parse(query, in: catalog)
        }
        return cachedParse
    }

    public var deepLinkResult: BibleSearchResult? { parsed.resolved }

    public var bookNameFilter: String { parsed.bookNameQuery }

    public var autoExpandedBookId: String? {
        guard deepLinkResult == nil else { return nil }
        let books = groups.flatMap(\.books)
        return books.count == 1 ? books.first?.id : nil
    }

    /// A unique search result exclusively controls expansion unless manually collapsed;
    /// otherwise expandedBookId governs.
    public func isBookExpanded(_ bookId: String) -> Bool {
        if let autoExpandedBookId {
            return bookId == autoExpandedBookId && bookId != autoCollapsedBookId
        }
        return bookId == expandedBookId
    }

    public var groups: [BibleBookGroup] {
        let trimmed = parsed.bookNameQuery.trimmingCharacters(in: .whitespaces)

        var books = catalog.books
        if order == .alphabetical {
            books.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        if !trimmed.isEmpty {
            books = books.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        }

        if order == .alphabetical || !trimmed.isEmpty {
            return books.isEmpty ? [] : [BibleBookGroup(id: "all", title: nil, books: books)]
        }
        return [
            BibleBookGroup(
                id: "ot",
                title: "Old Testament",
                books: books.filter { $0.testament == .oldTestament }
            ),
            BibleBookGroup(
                id: "nt",
                title: "New Testament",
                books: books.filter { $0.testament == .newTestament }
            ),
        ].filter { !$0.books.isEmpty }
    }

    public var hasResults: Bool { deepLinkResult != nil || !groups.isEmpty }

    public var initialScrollAnchor: BibleBookSheetScrollAnchor? {
        guard let position = currentPosition else { return nil }
        let rowIndex = (position.chapterNumber - 1) / Self.chapterGridColumns
        if rowIndex >= Self.chapterGridRowAnchorThreshold {
            return .chapterCell(bookId: position.bookId, chapterNumber: position.chapterNumber)
        }
        return .bookRow(bookId: position.bookId)
    }

    public func toggleExpansion(bookId: String) {
        if isBookExpanded(bookId) {
            if expandedBookId == bookId { expandedBookId = nil }
            if bookId == autoExpandedBookId { autoCollapsedBookId = bookId }
        } else {
            expandedBookId = bookId
            autoCollapsedBookId = nil
        }
    }

    public func clearQuery() {
        query = ""
    }
}
